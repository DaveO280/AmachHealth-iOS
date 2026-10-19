// BackupEngine.swift
// AmachHealth
//
// Backup, restore and verify for format v1 (BACKUP-FORMAT.md). No UI and
// no networking of its own: it reads the vault, encrypts with BackupKey,
// and moves opaque objects through a BackupTransport.
//
// Crash safety: chunk objects are immutable (a changed chunk gets new
// random ids), and the root index is written only after the objects it
// names. A backup interrupted at any point leaves the previous index and
// all its objects intact. Objects no index points at are deleted at the
// end of a later successful run.

import Foundation
import GRDB

final class BackupEngine {
    enum Progress: Equatable {
        case preparing
        case uploading(done: Int, total: Int)
        case downloading(done: Int, total: Int)
        case verifying(done: Int, total: Int)
    }

    struct BackupResult: Equatable {
        var uploadedChunks = 0
        var removedChunks = 0
        var unchangedChunks = 0
        var bytesUploaded = 0
        var generation = 0
        var committed = false
    }

    struct RestoreResult: Equatable {
        var chunks = 0
        var rowsInserted = 0
        var chunksKeptLocal = 0
        var generation = 0
    }

    struct VerifyResult: Equatable {
        var chunks = 0
        var objects = 0
        var bytes = 0
    }

    enum EngineError: LocalizedError {
        /// A backup exists that this vault hasn't restored; backing up now
        /// would replace it with less data.
        case needsRestore

        var errorDescription: String? {
            "An encrypted backup already exists for this wallet. Restore it before backing up."
        }
    }

    static let generationKey = "backup_generation"
    static let lastSuccessKey = "backup_last_success"
    static let indexBodyKey = "backup_index_body"

    /// Commit the index after this many changed chunks or bytes, so a long
    /// first backup keeps its progress if it's interrupted.
    static let commitEveryChunks = 40
    static let commitEveryBytes = 24 * 1024 * 1024
    static let downloadBatchBytes = 16 * 1024 * 1024

    let vault: VaultDatabase
    let key: BackupKey
    let transport: BackupTransport
    var onProgress: ((Progress) -> Void)?
    var now: () -> Date = Date.init

    init(vault: VaultDatabase, key: BackupKey, transport: BackupTransport) {
        self.vault = vault
        self.key = key
        self.transport = transport
    }

    // MARK: - Backup

    func backup() async throws -> BackupResult {
        onProgress?(.preparing)
        var mirror = try loadMirror()
        let generation = try vault.meta(Self.generationKey).flatMap(Int.init)

        if generation == nil, mirror.isEmpty,
           try await transport.get([key.indexObjectId])[key.indexObjectId] != nil {
            throw EngineError.needsRestore
        }

        // Where every pending record lives: now, and where the index last
        // put it (catches deletions and records that moved chunk).
        var recordIndex: [String: Set<String>] = [:]
        for entry in mirror.values {
            for id in entry.recordIds ?? [] { recordIndex[id, default: []].insert(entry.key) }
        }
        let (affected, orphans): ([String: [(String, String)]], [(String, String)]) = try await vault.dbQueue.read { db in
            var affected: [String: [(String, String)]] = [:]
            var orphans: [(String, String)] = []
            let pending = try Row.fetchAll(db, sql: """
                SELECT record_type, record_id FROM backup_state WHERE local_version > backed_up_version
                """)
            for row in pending {
                let type: String = row["record_type"], id: String = row["record_id"]
                var chunks = Set(try BackupChunkKey.liveChunks(recordType: type, recordId: id, db: db))
                chunks.formUnion(recordIndex["\(type)|\(id)"] ?? [])
                if chunks.isEmpty { orphans.append((type, id)) }
                for chunk in chunks { affected[chunk, default: []].append((type, id)) }
            }
            if generation == nil {
                for chunk in try self.vault.allBackupChunkKeys(db) where affected[chunk] == nil {
                    affected[chunk] = []
                }
            }
            return (affected, orphans)
        }

        var result = BackupResult(generation: generation ?? 0)
        let keys = affected.keys.sorted()
        if keys.isEmpty {
            if !orphans.isEmpty { try markBackedUp(orphans.map { ($0.0, $0.1, Int64.max) }) }
            return result
        }

        var nextGeneration = (generation ?? 0) + 1
        var batch = PendingCommit()
        var done = 0
        onProgress?(.uploading(done: 0, total: keys.count))

        for chunkKey in keys {
            try Task.checkCancellation()
            let records = affected[chunkKey] ?? []
            let (snapshot, versions) = try await vault.dbQueue.read { db -> (BackupChunkSnapshot, [(String, String, Int64)]) in
                let snapshot = try self.vault.backupSnapshot(chunk: chunkKey, db)
                var versions: [(String, String, Int64)] = []
                for (type, id) in records {
                    let v = try Int64.fetchOne(db, sql: """
                        SELECT local_version FROM backup_state WHERE record_type = ? AND record_id = ?
                        """, arguments: [type, id]) ?? 0
                    versions.append((type, id, v))
                }
                return (snapshot, versions)
            }
            batch.versions += versions
            let existing = mirror[chunkKey]

            if let plaintext = snapshot.plaintext {
                let sha = BackupKey.sha256Hex(plaintext)
                if let existing, existing.sha256 == sha {
                    result.unchangedChunks += 1
                } else {
                    let (parts, objects) = try sealParts(plaintext)
                    let entry = BackupChunkEntry(
                        key: chunkKey, kind: snapshot.kind, tables: snapshot.tables, month: snapshot.month,
                        recordIds: snapshot.listRecordIds ? snapshot.recordIds : nil,
                        version: (existing?.version ?? 0) + 1, sha256: sha, size: plaintext.count, parts: parts
                    )
                    batch.objects += objects
                    batch.bytes += objects.reduce(0) { $0 + $1.data.count }
                    batch.superseded += existing?.parts.map(\.id) ?? []
                    mirror[chunkKey] = entry
                    batch.changed[chunkKey] = entry
                    result.uploadedChunks += 1
                }
            } else if let existing {
                batch.superseded += existing.parts.map(\.id)
                mirror[chunkKey] = nil
                batch.removed.insert(chunkKey)
                result.removedChunks += 1
            }

            done += 1
            if batch.changed.count + batch.removed.count >= Self.commitEveryChunks || batch.bytes >= Self.commitEveryBytes {
                result.bytesUploaded += try await commit(&batch, mirror: mirror, generation: nextGeneration)
                result.committed = true
                result.generation = nextGeneration
                nextGeneration += 1
            }
            onProgress?(.uploading(done: done, total: keys.count))
        }

        batch.versions += orphans.map { ($0.0, $0.1, Int64.max) }
        if batch.needsIndex || generation == nil {
            result.bytesUploaded += try await commit(&batch, mirror: mirror, generation: nextGeneration)
            result.committed = true
            result.generation = nextGeneration
        } else {
            // Nothing changed remotely; just record what's now up to date.
            try markBackedUp(batch.versions)
            try vault.setMeta(Self.lastSuccessKey, String(now().unixMillis))
        }

        if result.committed { try? await collectGarbage(mirror: mirror) }
        return result
    }

    private struct PendingCommit {
        var objects: [(id: String, data: Data)] = []
        var bytes = 0
        var changed: [String: BackupChunkEntry] = [:]
        var removed: Set<String> = []
        var superseded: [String] = []
        var versions: [(String, String, Int64)] = []
        var needsIndex: Bool { !changed.isEmpty || !removed.isEmpty }
    }

    /// Upload the batch's objects, then a new index naming them, then record
    /// it locally. Returns bytes uploaded.
    private func commit(_ batch: inout PendingCommit, mirror: [String: BackupChunkEntry], generation: Int) async throws -> Int {
        try await transport.put(batch.objects)

        let body = BackupIndexBody(chunks: mirror.values.sorted { $0.key < $1.key })
        let bodyData = try BackupJSON.encoder.encode(body)
        let (bodyParts, bodyObjects) = try sealParts(bodyData)
        try await transport.put(bodyObjects)
        let root = BackupIndexRoot(
            schemaVersion: VaultDatabase.currentSchemaVersion, generation: generation,
            updatedAt: now().unixMillis, body: bodyParts, bodySha256: BackupKey.sha256Hex(bodyData)
        )
        let rootId = key.indexObjectId
        let rootObject = try key.seal(try BackupJSON.encoder.encode(root), objectId: rootId)
        try await transport.put([(rootId, rootObject)])

        let previousBody = (try? vault.meta(Self.indexBodyKey)).flatMap { $0 }
            .flatMap { try? BackupJSON.decoder.decode([BackupChunkEntry.Part].self, from: Data($0.utf8)) } ?? []
        let changed = batch.changed, removed = batch.removed, versions = batch.versions
        let stamp = now().unixMillis
        let bodyJSON = String(decoding: try BackupJSON.encoder.encode(bodyParts), as: UTF8.self)
        try await vault.dbQueue.write { db in
            for (chunkKey, entry) in changed {
                let json = String(decoding: try BackupJSON.encoder.encode(entry), as: UTF8.self)
                try db.execute(sql: """
                    INSERT INTO backup_objects (chunk_key, entry_json, updated_at) VALUES (?, ?, ?)
                    ON CONFLICT(chunk_key) DO UPDATE SET entry_json = excluded.entry_json, updated_at = excluded.updated_at
                    """, arguments: [chunkKey, json, stamp])
            }
            for chunkKey in removed {
                try db.execute(sql: "DELETE FROM backup_objects WHERE chunk_key = ?", arguments: [chunkKey])
            }
            try Self.markBackedUp(versions, db)
            for (k, v) in [(Self.generationKey, String(generation)), (Self.lastSuccessKey, String(stamp)), (Self.indexBodyKey, bodyJSON)] {
                try db.execute(sql: """
                    INSERT INTO vault_meta (key, value) VALUES (?, ?)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value
                    """, arguments: [k, v])
            }
        }

        let uploaded = batch.bytes + bodyObjects.reduce(0) { $0 + $1.data.count } + rootObject.count
        // The new index no longer names these; delete them now (GC catches
        // any that fail).
        try? await transport.delete(batch.superseded + previousBody.map(\.id))
        batch = PendingCommit()
        return uploaded
    }

    private func markBackedUp(_ versions: [(String, String, Int64)]) throws {
        try vault.dbQueue.write { db in try Self.markBackedUp(versions, db) }
    }

    /// Int64.max means "whatever the record's version is now" (records with
    /// nothing left to back up).
    private static func markBackedUp(_ versions: [(String, String, Int64)], _ db: Database) throws {
        for (type, id, version) in versions {
            try db.execute(sql: """
                UPDATE backup_state
                SET backed_up_version = MAX(backed_up_version, MIN(?, local_version))
                WHERE record_type = ? AND record_id = ?
                """, arguments: [version, type, id])
        }
    }

    /// Delete objects in the backup folder that the current index doesn't name.
    func collectGarbage(mirror: [String: BackupChunkEntry]? = nil) async throws {
        let mirror = try mirror ?? loadMirror()
        var keep = Set(mirror.values.flatMap { $0.parts.map(\.id) })
        keep.insert(key.indexObjectId)
        let body = (try? vault.meta(Self.indexBodyKey)).flatMap { $0 }
            .flatMap { try? BackupJSON.decoder.decode([BackupChunkEntry.Part].self, from: Data($0.utf8)) } ?? []
        keep.formUnion(body.map(\.id))
        let stray = try await transport.listIds().filter { !keep.contains($0) }
        try await transport.delete(stray)
    }

    private func sealParts(_ plaintext: Data) throws -> ([BackupChunkEntry.Part], [(id: String, data: Data)]) {
        var parts: [BackupChunkEntry.Part] = []
        var objects: [(id: String, data: Data)] = []
        var offset = 0
        repeat {
            let end = min(offset + BackupChunkKey.maxPartBytes, plaintext.count)
            let slice = plaintext.subdata(in: offset..<end)
            let id = BackupKey.newObjectId()
            let sealed = try key.seal(slice, objectId: id)
            parts.append(.init(id: id, sha256: BackupKey.sha256Hex(slice), size: sealed.count))
            objects.append((id, sealed))
            offset = end
        } while offset < plaintext.count
        return (parts, objects)
    }

    private func loadMirror() throws -> [String: BackupChunkEntry] {
        try vault.dbQueue.read { db in
            var out: [String: BackupChunkEntry] = [:]
            for json in try String.fetchAll(db, sql: "SELECT entry_json FROM backup_objects") {
                let entry = try BackupJSON.decoder.decode(BackupChunkEntry.self, from: Data(json.utf8))
                out[entry.key] = entry
            }
            return out
        }
    }

    // MARK: - Reading the backup

    /// The decrypted root and body, or nil when there is no backup.
    func fetchIndex() async throws -> (BackupIndexRoot, BackupIndexBody)? {
        let rootId = key.indexObjectId
        guard let sealed = try await transport.get([rootId])[rootId] else { return nil }
        let root = try BackupJSON.decoder.decode(BackupIndexRoot.self, from: try key.open(sealed, objectId: rootId))
        guard root.format == BackupIndexRoot.format, root.version == 1 else {
            throw BackupError.malformed("unknown index format")
        }
        guard root.schemaVersion <= VaultDatabase.currentSchemaVersion else {
            throw BackupError.newerSchema(root.schemaVersion)
        }
        let bodyData = try await readParts(root.body, sha256: root.bodySha256)
        return (root, try BackupJSON.decoder.decode(BackupIndexBody.self, from: bodyData))
    }

    private func readParts(_ parts: [BackupChunkEntry.Part], sha256: String, prefetched: [String: Data]? = nil) async throws -> Data {
        let objects: [String: Data]
        if let prefetched { objects = prefetched } else { objects = try await transport.get(parts.map(\.id)) }
        var plaintext = Data()
        for part in parts {
            guard let sealed = objects[part.id] else { throw BackupError.missingObject(part.id) }
            let slice = try key.open(sealed, objectId: part.id)
            guard BackupKey.sha256Hex(slice) == part.sha256 else { throw BackupError.hashMismatch(part.id) }
            plaintext.append(slice)
        }
        guard BackupKey.sha256Hex(plaintext) == sha256 else { throw BackupError.hashMismatch("whole") }
        return plaintext
    }

    /// Chunks grouped so each download batch stays around downloadBatchBytes.
    private func downloadBatches(_ chunks: [BackupChunkEntry]) -> [[BackupChunkEntry]] {
        var batches: [[BackupChunkEntry]] = []
        var current: [BackupChunkEntry] = []
        var bytes = 0
        for chunk in chunks {
            let size = chunk.parts.reduce(0) { $0 + $1.size }
            if !current.isEmpty, bytes + size > Self.downloadBatchBytes || current.count >= 150 {
                batches.append(current); current = []; bytes = 0
            }
            current.append(chunk); bytes += size
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }

    // MARK: - Restore

    /// Rebuild the vault from the backup. Rows already on the phone are kept
    /// (see VaultDatabase.applyBackupRows).
    func restore() async throws -> RestoreResult {
        onProgress?(.preparing)
        guard let index = try await fetchIndex() else { throw BackupError.noBackup }
        let (root, body) = index
        // PDFs after rows, so lab_pdfs rows exist when files arrive.
        let ordered = body.chunks.sorted { ($0.kind == .blob ? 1 : 0, $0.key) < ($1.kind == .blob ? 1 : 0, $1.key) }
        var result = RestoreResult(generation: root.generation)
        var done = 0
        onProgress?(.downloading(done: 0, total: ordered.count))

        for batch in downloadBatches(ordered) {
            try Task.checkCancellation()
            let objects = try await transport.get(batch.flatMap { $0.parts.map(\.id) })
            var decoded: [(BackupChunkEntry, Data)] = []
            for chunk in batch {
                decoded.append((chunk, try await readParts(chunk.parts, sha256: chunk.sha256, prefetched: objects)))
            }
            for (chunk, plaintext) in decoded where chunk.kind == .blob {
                let (_, sha) = VaultDatabase.splitChunkKey(chunk.key)
                try vault.applyBackupPdf(sha256: sha, bytes: plaintext)
            }
            let stamp = now().unixMillis
            let applied: (Int, Int) = try await vault.dbQueue.write { db in
                var rows = 0, keptLocal = 0
                for (chunk, plaintext) in decoded {
                    var complete = true
                    var inserted: [(table: String, id: String)] = []
                    if chunk.kind == .rows {
                        let payload = try BackupJSON.decoder.decode(BackupChunkPayload.self, from: plaintext)
                        let outcome = try self.vault.applyBackupRows(payload, db)
                        complete = outcome.complete
                        inserted = outcome.insertedRecordIds
                        rows += inserted.count
                    }
                    if !complete { keptLocal += 1 }
                    let json = String(decoding: try BackupJSON.encoder.encode(chunk), as: UTF8.self)
                    try db.execute(sql: """
                        INSERT INTO backup_objects (chunk_key, entry_json, updated_at) VALUES (?, ?, ?)
                        ON CONFLICT(chunk_key) DO UPDATE SET entry_json = excluded.entry_json, updated_at = excluded.updated_at
                        """, arguments: [chunk.key, json, stamp])
                    // Matches the backup exactly: nothing to upload for it.
                    if complete {
                        try Self.markBackedUp(inserted.map { ($0.table, $0.id, Int64.max) }, db)
                    }
                }
                return (rows, keptLocal)
            }
            result.rowsInserted += applied.0
            result.chunksKeptLocal += applied.1
            result.chunks += batch.count
            done += batch.count
            onProgress?(.downloading(done: done, total: ordered.count))
        }

        let bodyJSON = String(decoding: try BackupJSON.encoder.encode(root.body), as: UTF8.self)
        try vault.setMeta(Self.generationKey, String(root.generation))
        try vault.setMeta(Self.lastSuccessKey, String(root.updatedAt))
        try vault.setMeta(Self.indexBodyKey, bodyJSON)
        return result
    }

    // MARK: - Verify

    /// Download and decrypt every object, check every hash, and confirm the
    /// backup holds exactly what this phone thinks it backed up.
    func verify() async throws -> VerifyResult {
        onProgress?(.preparing)
        guard let body = try await fetchIndex()?.1 else { throw BackupError.noBackup }
        let mirror = try loadMirror()
        guard Set(body.chunks.map(\.key)) == Set(mirror.keys),
              body.chunks.allSatisfy({ mirror[$0.key]?.sha256 == $0.sha256 }) else {
            throw BackupError.malformed("the backup index doesn't match this phone")
        }
        var result = VerifyResult()
        onProgress?(.verifying(done: 0, total: body.chunks.count))
        for batch in downloadBatches(body.chunks) {
            try Task.checkCancellation()
            let objects = try await transport.get(batch.flatMap { $0.parts.map(\.id) })
            for chunk in batch {
                _ = try await readParts(chunk.parts, sha256: chunk.sha256, prefetched: objects)
                result.objects += chunk.parts.count
                result.bytes += chunk.parts.reduce(0) { $0 + $1.size }
            }
            result.chunks += batch.count
            onProgress?(.verifying(done: result.chunks, total: body.chunks.count))
        }
        return result
    }
}
