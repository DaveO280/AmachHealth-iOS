// StorjImportService.swift
// AmachHealth
//
// One-time import of the wallet's Storj history into the vault, without
// sending the encryption key anywhere:
//
//   1. Compute the bucket name on device (StorjBucketName).
//   2. List keys with storage/list-raw, download ciphertext with
//      storage/download-raw.
//   3. Decrypt on device (WalletPayloadDecryptor) and write each object into
//      the vault by dataType. FHIR reports are normalized with FhirConverter.
//
// Every object gets a storj_imports row: imported, duplicate, archived
// (kept as decrypted JSON, no table of its own yet) or failed (with the
// reason). Nothing is skipped silently. Re-running only retries objects
// that aren't already imported, and the import counts as complete once a
// run finishes with no failures.

import Foundation
import GRDB

@MainActor
final class StorjImportService: ObservableObject {
    static let shared = StorjImportService()

    enum State: Equatable {
        case idle
        case running(done: Int, total: Int)
        case finished(ImportReport)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    /// Last saved report, shown after relaunch.
    @Published private(set) var lastReport: ImportReport?

    static let completedKey = "storj_import_completed"
    static let reportKey = "storj_import_report"

    private var task: Task<Void, Never>?
    private let api: AmachAPIClient

    private init(api: AmachAPIClient = .shared) {
        self.api = api
    }

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    /// Tests turn this off so opening a vault doesn't reach the network.
    static var autoRunEnabled = true

    /// Start the import if it hasn't completed for this vault.
    func runIfNeeded(vault: VaultDatabase, walletKey: WalletEncryptionKey) {
        lastReport = (try? vault.meta(Self.reportKey)).flatMap { $0 }
            .flatMap { try? JSONDecoder().decode(ImportReport.self, from: Data($0.utf8)) }
        guard Self.autoRunEnabled, (try? vault.meta(Self.completedKey)) ?? nil == nil else { return }
        run(vault: vault, walletKey: walletKey)
    }

    /// Run (or re-run) the import now.
    func run(vault: VaultDatabase, walletKey: WalletEncryptionKey) {
        guard !isRunning else { return }
        state = .running(done: 0, total: 0)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let report = try await self.performImport(vault: vault, walletKey: walletKey)
                self.lastReport = report
                self.state = .finished(report)
                ChatService.shared.vaultDidChange()
                ConversationMemoryStore.shared.vaultDidChange()
                TimelineService.shared.vaultDidChange()
                LabContextService.shared.invalidate()
                await DashboardService.shared.load(force: true)
            } catch {
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - Import

    private func performImport(vault: VaultDatabase, walletKey: WalletEncryptionKey) async throws -> ImportReport {
        let bucket = StorjBucketName.make(for: walletKey)
        let objects = try await api.listRawObjects(bucketName: bucket)

        let alreadyDone: Set<String> = try await vault.dbQueue.read { db in
            Set(try String.fetchAll(db, sql: "SELECT object_key FROM storj_imports WHERE status != 'failed'"))
        }
        // Reports before narratives, so a narrative can attach to its report.
        let pending = objects
            .filter { !alreadyDone.contains($0.key) }
            .sorted { lhs, rhs in
                let l = lhs.dataType.hasSuffix("-narrative"), r = rhs.dataType.hasSuffix("-narrative")
                return l == r ? lhs.uploadedAt < rhs.uploadedAt : !l
            }

        var report = ImportReport(objectsListed: objects.count, previouslyImported: objects.count - pending.count)
        let importer = StorjObjectImporter(vault: vault)
        state = .running(done: 0, total: pending.count)

        // Download a few at a time; decrypt and write in upload order.
        let batchSize = 4
        var index = 0
        while index < pending.count {
            let batch = Array(pending[index..<min(index + batchSize, pending.count)])
            let downloads: [(RawObject, Result<Data, Error>)] = await withTaskGroup(of: (Int, Result<Data, Error>).self) { group in
                for (i, object) in batch.enumerated() {
                    group.addTask { [api] in
                        do { return (i, .success(try await api.downloadRawObject(bucketName: bucket, objectKey: object.key))) }
                        catch { return (i, .failure(error)) }
                    }
                }
                var results: [(Int, Result<Data, Error>)] = []
                for await r in group { results.append(r) }
                return results.sorted { $0.0 < $1.0 }.map { (batch[$0.0], $0.1) }
            }
            for (object, download) in downloads {
                let outcome: StorjObjectImporter.Outcome
                switch download {
                case .success(let bytes):
                    outcome = importer.importObject(object, bytes: bytes, passphrase: walletKey.encryptionKey)
                case .failure(let error):
                    outcome = .failed("Download failed: \(error.localizedDescription)")
                }
                report.record(outcome, object: object)
                importer.recordStatus(outcome, object: object)
            }
            index += batch.count
            state = .running(done: index, total: pending.count)
        }

        report.finishedAt = Date()
        report.vaultTotals = ImportReport.Totals(vault: vault)
        if let json = try? JSONEncoder().encode(report) {
            try? vault.setMeta(Self.reportKey, String(decoding: json, as: UTF8.self))
        }
        if report.failures.isEmpty {
            try? vault.setMeta(Self.completedKey, ISO8601DateFormatter().string(from: Date()))
        }
        return report
    }

    typealias RawObject = AmachAPIClient.RawStorjObject
}

// MARK: - Report

struct ImportReport: Codable, Equatable {
    struct Failure: Codable, Equatable, Identifiable {
        var id: String { key }
        let key: String
        let dataType: String
        let reason: String
    }

    /// What the vault holds after the run (all sources).
    struct Totals: Codable, Equatable {
        var dailyMetricRows = 0
        var labReports = 0
        var timelineEvents = 0
        var chatSessions = 0
        var chatMessages = 0
        var memoryFacts = 0
        var memorySummaries = 0

        init() {}

        init(vault: VaultDatabase) {
            dailyMetricRows = (try? vault.dailyMetricCount()) ?? 0
            labReports = (try? vault.labReportCount()) ?? 0
            timelineEvents = (try? vault.timelineEventCount()) ?? 0
            let chat = try? vault.chatCounts()
            chatSessions = chat?.sessions ?? 0
            chatMessages = chat?.messages ?? 0
            let memory = try? vault.memoryCounts()
            memoryFacts = memory?.facts ?? 0
            memorySummaries = memory?.summaries ?? 0
        }
    }

    var objectsListed: Int
    var previouslyImported: Int
    var imported = 0
    var duplicates = 0
    var archived = 0
    /// Records written this run, by kind ("daily_metrics", "bloodwork", "chat_messages", ...).
    var counts: [String: Int] = [:]
    var failures: [Failure] = []
    /// Objects that imported but with a caveat worth showing (e.g. unit guessed).
    var notes: [String] = []
    var finishedAt: Date?
    var vaultTotals = Totals()

    mutating func record(_ outcome: StorjObjectImporter.Outcome, object: AmachAPIClient.RawStorjObject) {
        switch outcome {
        case .imported(_, _, let counts, let note, _):
            imported += 1
            for (k, v) in counts { self.counts[k, default: 0] += v }
            if let note { notes.append("\(object.dataType): \(note)") }
        case .duplicate:
            duplicates += 1
        case .archived:
            archived += 1
        case .failed(let reason):
            failures.append(Failure(key: object.key, dataType: object.dataType, reason: reason))
        }
    }
}
