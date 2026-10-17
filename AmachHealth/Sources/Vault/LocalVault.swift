// LocalVault.swift
// AmachHealth
//
// Owns the open VaultDatabase for the connected wallet and tells the
// services when it opens or closes.
//
// The vault opens from the Keychain-cached wallet key, so it works offline
// even when the Privy session can't be restored (airplane mode). Without a
// wallet there is no vault: the dashboard falls back to live HealthKit
// queries and chat keeps the current session in memory only.

import Foundation
import Combine

/// Phase 2 switch for the old Storj uploads (health sync, labs, timeline,
/// chat, memory). Phase 3 replaces them; until then they stay on by default.
enum VaultFlags {
    private static let legacyStorjWritesKey = "amach_legacy_storj_writes"

    static var legacyStorjWrites: Bool {
        get { UserDefaults.standard.object(forKey: legacyStorjWritesKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: legacyStorjWritesKey) }
    }
}

@MainActor
final class LocalVault: ObservableObject {
    static let shared = LocalVault()

    @Published private(set) var database: VaultDatabase?
    @Published private(set) var openError: String?
    /// The wallet key the vault was opened with (from the Keychain), so an
    /// import retry works even when the Privy session isn't restored.
    private(set) var walletKey: WalletEncryptionKey?

    private let lastWalletKey = "amach_vault_last_wallet"
    private var cancellables = Set<AnyCancellable>()

    private init() {}

    var isOpen: Bool { database != nil }

    // MARK: - Lifecycle

    /// Call once at launch. Opens the last wallet's vault from the Keychain,
    /// then follows WalletService for connects (key derived). Disconnect
    /// closes it through WalletService.disconnect().
    func start(wallet: WalletService = .shared) {
        if let address = UserDefaults.standard.string(forKey: lastWalletKey),
           let key = try? wallet.loadEncryptionKeyFromKeychain(for: address) {
            open(walletKey: key)
        }

        wallet.$encryptionKey
            .removeDuplicates { $0?.walletAddress == $1?.walletAddress && $0?.encryptionKey == $1?.encryptionKey }
            .sink { [weak self] key in
                guard let self, let key else { return }
                if self.database?.walletAddress != key.walletAddress.lowercased() {
                    self.open(walletKey: key)
                }
            }
            .store(in: &cancellables)
    }

    func open(walletKey: WalletEncryptionKey, directory: URL? = nil) {
        do {
            let vault = try VaultDatabase.open(key: try LocalVaultKey(walletKey: walletKey), directory: directory)
            database = vault
            self.walletKey = walletKey
            openError = nil
            UserDefaults.standard.set(walletKey.walletAddress.lowercased(), forKey: lastWalletKey)
            LegacyLocalDataMigration.run(into: vault)
            didOpen(vault, walletKey: walletKey)
        } catch {
            database = nil
            openError = error.localizedDescription
            #if DEBUG
            print("🔒 [Vault] open failed: \(error.localizedDescription)")
            #endif
        }
    }

    func close(forget: Bool) {
        HealthKitIngestionService.shared.stop()
        database = nil
        walletKey = nil
        if forget { UserDefaults.standard.removeObject(forKey: lastWalletKey) }
        ChatService.shared.vaultDidChange()
        ConversationMemoryStore.shared.vaultDidChange()
        TimelineService.shared.vaultDidChange()
        LabContextService.shared.invalidate()
    }

    private func didOpen(_ vault: VaultDatabase, walletKey: WalletEncryptionKey) {
        ChatService.shared.vaultDidChange()
        ConversationMemoryStore.shared.vaultDidChange()
        TimelineService.shared.vaultDidChange()
        LabContextService.shared.invalidate()
        HealthKitIngestionService.shared.start(vault: vault)
        StorjImportService.shared.runIfNeeded(vault: vault, walletKey: walletKey)
        Task { await DashboardService.shared.load(force: true) }
    }
}

// MARK: - One-time move of pre-vault local files

/// Chat, conversation memory and the timeline cache lived in Documents JSON
/// files and UserDefaults before the vault. Each is copied in once, read
/// back to verify, and only then deleted.
enum LegacyLocalDataMigration {

    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
    }

    static var chatFileURL: URL { documents.appendingPathComponent("amach_chat_sessions.json") }
    static var memoryFileURL: URL { documents.appendingPathComponent("amach_conversation_memory.json") }
    static let timelineDefaultsKey = "amach_timeline_events"

    @MainActor
    static func run(into vault: VaultDatabase, defaults: UserDefaults = .standard) {
        migrateChat(into: vault, from: chatFileURL)
        migrateMemory(into: vault, from: memoryFileURL)
        migrateTimeline(into: vault, defaults: defaults)
    }

    /// Returns true when the file was imported, verified and deleted.
    @discardableResult
    static func migrateChat(into vault: VaultDatabase, from url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        do {
            let sessions = try VaultJSON.decoder.decode([ChatSession].self, from: data)
            // File order: [current, recent...]. Keep the vault's own current
            // session if it already has one.
            let hasCurrent = (try vault.loadChatSessions(recentLimit: 0).current) != nil
            let currentId = hasCurrent ? nil : sessions.first?.id
            for session in sessions {
                if try vault.chatSession(id: session.id) == nil {
                    try vault.saveChatSessions([session], currentId: session.id == currentId ? currentId : nil, origin: "legacy-file")
                }
            }
            // Verify every message made it before deleting the file.
            for session in sessions {
                guard let stored = try vault.chatSession(id: session.id) else { return false }
                let storedIds = Set(stored.messages.map(\.id))
                guard session.messages.allSatisfy({ storedIds.contains($0.id) }) else { return false }
            }
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            #if DEBUG
            print("🔒 [Vault] chat file migration failed, keeping file: \(error.localizedDescription)")
            #endif
            return false
        }
    }

    @discardableResult
    static func migrateMemory(into vault: VaultDatabase, from url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        do {
            let file = try VaultJSON.decoder.decode(ConversationMemoryStorjPayload.self, from: data)
            let existing = try vault.loadMemory()
            let merged = ConversationMemoryStore.merge(local: existing, remote: file)
            try vault.replaceMemory(facts: merged.facts, summaries: merged.summaries)
            // Verify the vault now holds exactly what we meant to write.
            let stored = try vault.loadMemory()
            guard Set(stored.facts.map(\.id)) == Set(merged.facts.map(\.id)),
                  Set(stored.summaries.map(\.id)) == Set(merged.summaries.map(\.id))
            else { return false }
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            #if DEBUG
            print("🔒 [Vault] memory file migration failed, keeping file: \(error.localizedDescription)")
            #endif
            return false
        }
    }

    @discardableResult
    static func migrateTimeline(into vault: VaultDatabase, defaults: UserDefaults) -> Bool {
        guard let data = defaults.data(forKey: timelineDefaultsKey) else { return false }
        do {
            let events = try VaultJSON.decoder.decode([TimelineEvent].self, from: data)
            _ = try vault.insertMissingTimelineEvents(events, origin: "legacy-cache")
            let storedIds = Set(try vault.timelineEvents().map(\.id))
            guard events.allSatisfy({ storedIds.contains($0.id) }) else { return false }
            defaults.removeObject(forKey: timelineDefaultsKey)
            return true
        } catch {
            return false
        }
    }
}
