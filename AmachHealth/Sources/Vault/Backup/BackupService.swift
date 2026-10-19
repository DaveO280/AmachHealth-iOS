// BackupService.swift
// AmachHealth
//
// Opt-in encrypted backup of the vault to Amach's Storj backup project.
//
// - Off by default. When on, changed records are backed up a couple of
//   minutes after they change (debounced on backup_state), and large
//   catch-ups continue in a BGProcessingTask.
// - On a new phone, the first time a wallet's vault opens with no personal
//   data in it, the service looks for a backup and restores it.
// - After a verified backup, the user can delete their old objects from the
//   shared Storj account (storage/delete-raw).
//
// The wallet key never leaves the phone. The website only signs URLs for
// the user's opaque folder; see BACKUP-FORMAT.md and PROJECT_STATE.md.

import Foundation
import Combine
import GRDB
import BackgroundTasks

@MainActor
final class BackupService: ObservableObject {
    static let shared = BackupService()

    enum State: Equatable {
        case idle
        case backingUp(done: Int, total: Int)
        case restoring(done: Int, total: Int)
        case verifying(done: Int, total: Int)
        case failed(String)
    }

    struct LegacyCleanupPlan: Equatable {
        let bucket: String
        let deletable: [String]
        /// Objects the vault hasn't imported (or failed to); never deleted.
        let kept: Int
    }

    enum LegacyCleanupState: Equatable {
        case unavailable
        /// Can be offered; nothing checked yet.
        case available
        case checking
        case ready(LegacyCleanupPlan)
        case deleting(done: Int, total: Int)
        case finished(deleted: Int, kept: Int)
        case failed(String)
    }

    @Published private(set) var isEnabled = false
    @Published private(set) var state: State = .idle
    @Published private(set) var lastBackedUpAt: Date?
    @Published private(set) var pendingCount = 0
    @Published private(set) var lastRestore: BackupEngine.RestoreResult?
    @Published private(set) var legacyCleanup: LegacyCleanupState = .unavailable

    static let enabledKey = "backup_enabled"
    static let restoreCheckedKey = "backup_restore_checked"
    static let legacyCleanupKey = "legacy_storj_cleanup"
    static let backgroundTaskId = "com.amach.health.backup"
    static let debounceSeconds: TimeInterval = 120
    /// Above this many pending records, also schedule a background catch-up.
    static let backgroundThreshold = 2_000

    /// Tests turn this off so opening a vault doesn't reach the network.
    static var autoRunEnabled = true
    /// Tests inject a transport and signer.
    var makeTransport: ((BackupCredentialsClient) -> BackupTransport) = { PresignedStorjTransport(credentials: $0) }
    var makeSigner: () -> BackupSigner? = { WalletBackupSigner() }

    private var vault: VaultDatabase?
    private var walletKey: WalletEncryptionKey?
    private var credentials: BackupCredentialsClient?
    private var transport: BackupTransport?
    private var observation: AnyDatabaseCancellable?
    private var debounceTask: Task<Void, Never>?
    private var runTask: Task<Void, Never>?
    private var walletSubscription: AnyCancellable?

    private init() {}

    var isBusy: Bool {
        switch state {
        case .backingUp, .restoring, .verifying: return true
        default: return false
        }
    }

    // MARK: - Vault lifecycle

    func vaultDidOpen(_ vault: VaultDatabase, walletKey: WalletEncryptionKey) {
        self.vault = vault
        self.walletKey = walletKey
        credentials = nil
        transport = nil
        isEnabled = (try? vault.meta(Self.enabledKey)) ?? nil == "1"
        lastBackedUpAt = Self.lastSuccess(vault)
        state = .idle
        refreshPending()
        refreshLegacyCleanupAvailability()
        observeChanges(vault)

        guard Self.autoRunEnabled else { return }
        Task {
            await restoreIfNewPhone()
            // The one-time Storj import runs after the restore check, so the
            // two don't race to fill an empty vault.
            if let vault = self.vault, let key = self.walletKey {
                StorjImportService.shared.runIfNeeded(vault: vault, walletKey: key)
            }
            if self.isEnabled { self.scheduleBackup(after: 5) }
        }
        // A vault opened offline from the Keychain can't sign yet; retry the
        // restore check once the wallet connects.
        walletSubscription = WalletService.shared.$isConnected
            .removeDuplicates()
            .filter { $0 }
            .sink { [weak self] _ in Task { await self?.restoreIfNewPhone() } }
    }

    func vaultDidClose() {
        debounceTask?.cancel()
        runTask?.cancel()
        observation = nil
        walletSubscription = nil
        vault = nil
        walletKey = nil
        credentials = nil
        transport = nil
        isEnabled = false
        lastBackedUpAt = nil
        state = .idle
        legacyCleanup = .unavailable
    }

    private func observeChanges(_ vault: VaultDatabase) {
        observation = DatabaseRegionObservation(tracking: Table("backup_state"))
            .start(in: vault.dbQueue, onError: { _ in }, onChange: { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.refreshPending()
                    // The engine's own bookkeeping also writes backup_state;
                    // only real changes leave records pending.
                    if self.isEnabled, self.pendingCount > 0, !self.isBusy {
                        self.scheduleBackup(after: Self.debounceSeconds)
                    }
                }
            })
    }

    // MARK: - Toggle

    func setEnabled(_ enabled: Bool) {
        guard let vault else { return }
        try? vault.setMeta(Self.enabledKey, enabled ? "1" : nil)
        isEnabled = enabled
        if enabled {
            backUpNow()
        } else {
            debounceTask?.cancel()
            runTask?.cancel()
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.backgroundTaskId)
        }
    }

    // MARK: - Backup

    func scheduleBackup(after seconds: TimeInterval) {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.backUpNow()
        }
    }

    func backUpNow() {
        guard isEnabled, !isBusy else { return }
        runTask = Task { [weak self] in _ = await self?.runBackup() }
    }

    /// Returns true when the backup finished (or there was nothing to do).
    @discardableResult
    func runBackup() async -> Bool {
        guard isEnabled, !isBusy else { return false }
        guard let engine = makeEngine() else {
            state = .failed(BackupError.walletUnavailable.localizedDescription)
            return false
        }
        state = .backingUp(done: 0, total: 0)
        engine.onProgress = { [weak self] p in
            Task { @MainActor in
                if case .uploading(let done, let total) = p { self?.state = .backingUp(done: done, total: total) }
            }
        }
        do {
            do {
                _ = try await engine.backup()
            } catch BackupEngine.EngineError.needsRestore {
                // Reinstalled with backup on: bring the backup back first.
                try await performRestore(engine)
                _ = try await engine.backup()
            }
            state = .idle
            lastBackedUpAt = Self.lastSuccess(engine.vault)
            refreshPending()
            refreshLegacyCleanupAvailability()
            if pendingCount > 0 { scheduleBackup(after: Self.debounceSeconds) }
            return true
        } catch is CancellationError {
            state = .idle
            scheduleBackgroundCatchUp()
            return false
        } catch {
            state = .failed(error.localizedDescription)
            scheduleBackgroundCatchUp()
            return false
        }
    }

    // MARK: - Restore

    /// On a phone whose vault holds no personal data yet, look for a backup
    /// and restore it. Runs once per vault.
    func restoreIfNewPhone() async {
        guard let vault, !isBusy,
              (try? vault.meta(Self.restoreCheckedKey)) ?? nil == nil,
              (try? vault.meta(BackupEngine.generationKey)) ?? nil == nil,
              Self.looksNew(vault),
              let engine = makeEngine()
        else { return }
        do {
            try await performRestore(engine)
        } catch BackupError.noBackup {
            try? vault.setMeta(Self.restoreCheckedKey, String(Date().unixMillis))
            state = .idle
        } catch {
            // Leave restore_checked unset so the next launch tries again.
            state = .failed(error.localizedDescription)
        }
    }

    /// Restore now (Settings → Restore from backup).
    func restoreNow() {
        guard !isBusy, let engine = makeEngine() else { return }
        runTask = Task { [weak self] in
            do { try await self?.performRestore(engine) }
            catch { self?.state = .failed(error.localizedDescription) }
        }
    }

    private func performRestore(_ engine: BackupEngine) async throws {
        state = .restoring(done: 0, total: 0)
        engine.onProgress = { [weak self] p in
            Task { @MainActor in
                if case .downloading(let done, let total) = p { self?.state = .restoring(done: done, total: total) }
            }
        }
        // HealthKit writes would only race the restore; resume afterwards.
        HealthKitIngestionService.shared.stop()
        defer { HealthKitIngestionService.shared.start(vault: engine.vault) }
        let result = try await engine.restore()
        try engine.vault.setMeta(Self.restoreCheckedKey, String(Date().unixMillis))
        try engine.vault.setMeta(Self.enabledKey, "1")
        isEnabled = true
        lastRestore = result
        lastBackedUpAt = Self.lastSuccess(engine.vault)
        state = .idle
        refreshPending()
        ChatService.shared.vaultDidChange()
        ConversationMemoryStore.shared.vaultDidChange()
        TimelineService.shared.vaultDidChange()
        LabContextService.shared.invalidate()
        await DashboardService.shared.load(force: true)
    }

    /// No lab reports, chats, timeline or memory yet. HealthKit backfill may
    /// already have written metrics; restore merges with those.
    static func looksNew(_ vault: VaultDatabase) -> Bool {
        let count = try? vault.dbQueue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT (SELECT COUNT(*) FROM lab_reports) + (SELECT COUNT(*) FROM chat_messages)
                     + (SELECT COUNT(*) FROM timeline_events) + (SELECT COUNT(*) FROM memory_facts)
                """)
        }
        return (count ?? 0) == 0
    }

    // MARK: - Legacy cleanup

    /// Offered once the vault has imported the old Storj data and a backup in
    /// the new format exists. Verifying happens when the user asks.
    func refreshLegacyCleanupAvailability() {
        guard let vault, isEnabled, lastBackedUpAt != nil,
              (try? vault.meta(StorjImportService.completedKey)) ?? nil != nil,
              (try? vault.meta(Self.legacyCleanupKey)) ?? nil == nil
        else {
            if case .finished = legacyCleanup { return }
            legacyCleanup = .unavailable
            return
        }
        if case .unavailable = legacyCleanup { legacyCleanup = .available }
    }

    /// Verify the backup end to end, then work out which old objects are safe
    /// to delete: only ones the vault imported and has backed up.
    func prepareLegacyCleanup() {
        guard let vault, let walletKey, !isBusy, let engine = makeEngine() else { return }
        legacyCleanup = .checking
        runTask = Task { [weak self] in
            guard let self else { return }
            do {
                if vault.hasPendingBackup() { _ = await self.runBackup() }
                self.state = .verifying(done: 0, total: 0)
                engine.onProgress = { [weak self] p in
                    Task { @MainActor in
                        if case .verifying(let d, let t) = p { self?.state = .verifying(done: d, total: t) }
                    }
                }
                _ = try await engine.verify()
                self.state = .idle
                let bucket = StorjBucketName.make(for: walletKey)
                let objects = try await AmachAPIClient.shared.listRawObjects(bucketName: bucket)
                let safe: Set<String> = try await vault.dbQueue.read { db in
                    Set(try String.fetchAll(db, sql: """
                        SELECT i.object_key FROM storj_imports i
                        JOIN backup_state b ON b.record_type = 'storj_imports' AND b.record_id = i.object_key
                        WHERE i.status IN ('imported', 'duplicate', 'archived')
                          AND b.backed_up_version >= b.local_version
                        """))
                }
                let deletable = objects.map(\.key).filter { safe.contains($0) }
                self.legacyCleanup = .ready(LegacyCleanupPlan(bucket: bucket, deletable: deletable, kept: objects.count - deletable.count))
            } catch {
                self.state = .idle
                self.legacyCleanup = .failed(error.localizedDescription)
            }
        }
    }

    /// Delete the planned objects. Only call after the user confirms.
    func performLegacyCleanup(_ plan: LegacyCleanupPlan) {
        guard let vault, let credentials = credentialsClient() else { return }
        legacyCleanup = .deleting(done: 0, total: plan.deletable.count)
        runTask = Task { [weak self] in
            guard let self else { return }
            var deleted = 0
            do {
                let token = try await credentials.tokenForLegacyDelete()
                for (i, key) in plan.deletable.enumerated() {
                    try Task.checkCancellation()
                    if try await AmachAPIClient.shared.deleteRawObject(bucketName: plan.bucket, objectKey: key, backupToken: token) {
                        deleted += 1
                    }
                    self.legacyCleanup = .deleting(done: i + 1, total: plan.deletable.count)
                }
                let summary = "{\"deleted\":\(deleted),\"kept\":\(plan.kept),\"at\":\(Date().unixMillis)}"
                try? vault.setMeta(Self.legacyCleanupKey, summary)
                self.legacyCleanup = .finished(deleted: deleted, kept: plan.kept)
            } catch {
                self.legacyCleanup = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - Background

    /// Call from App.init, before launch finishes.
    nonisolated static func registerBackgroundTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: backgroundTaskId, using: nil) { task in
            guard let task = task as? BGProcessingTask else { task.setTaskCompleted(success: false); return }
            Task { @MainActor in
                let service = BackupService.shared
                let work = Task { await service.runBackup() }
                task.expirationHandler = { work.cancel() }
                let ok = await work.value
                task.setTaskCompleted(success: ok)
            }
        }
    }

    func scheduleBackgroundCatchUp() {
        guard isEnabled, pendingCount > 0 else { return }
        let request = BGProcessingTaskRequest(identifier: Self.backgroundTaskId)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = pendingCount > Self.backgroundThreshold
        try? BGTaskScheduler.shared.submit(request)
    }

    // MARK: - Helpers

    private func credentialsClient() -> BackupCredentialsClient? {
        if let credentials { return credentials }
        guard let signer = makeSigner() else { return nil }
        let client = BackupCredentialsClient(signer: signer)
        credentials = client
        return client
    }

    private func makeEngine() -> BackupEngine? {
        guard let vault, let walletKey, let backupKey = try? BackupKey(walletKey: walletKey) else { return nil }
        if transport == nil {
            guard let credentials = credentialsClient() else { return nil }
            // The signed-in wallet must be the vault's wallet.
            guard credentials.walletAddress.lowercased() == vault.walletAddress else { return nil }
            transport = makeTransport(credentials)
        }
        guard let transport else { return nil }
        return BackupEngine(vault: vault, key: backupKey, transport: transport)
    }

    private func refreshPending() {
        pendingCount = vault?.pendingBackupCount() ?? 0
        if pendingCount > Self.backgroundThreshold { scheduleBackgroundCatchUp() }
    }

    private static func lastSuccess(_ vault: VaultDatabase) -> Date? {
        ((try? vault.meta(BackupEngine.lastSuccessKey)) ?? nil).flatMap(Int64.init).map(Date.init(unixMillis:))
    }

    /// For tests: point the service at a vault without starting anything.
    func attachForTesting(vault: VaultDatabase, walletKey: WalletEncryptionKey, transport: BackupTransport) {
        self.vault = vault
        self.walletKey = walletKey
        self.transport = transport
        isEnabled = (try? vault.meta(Self.enabledKey)) ?? nil == "1"
        state = .idle
    }
}

extension VaultDatabase {
    func pendingBackupCount() -> Int {
        (try? dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM backup_state WHERE local_version > backed_up_version")
        }) ?? 0
    }

    func hasPendingBackup() -> Bool { pendingBackupCount() > 0 }

    /// Keep an uploaded PDF on the phone so it can be backed up.
    func saveLabPdf(_ bytes: Data, reportId: String?, filename: String?) throws {
        let sha = BackupKey.sha256Hex(bytes)
        try writeLabPdfFile(sha256: sha, bytes: bytes)
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO lab_pdfs (sha256, report_id, filename, byte_count, created_at)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: [sha, reportId, filename, bytes.count, Date().unixMillis])
        }
    }
}
