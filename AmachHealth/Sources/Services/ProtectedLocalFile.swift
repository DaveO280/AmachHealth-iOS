// ProtectedLocalFile.swift
// AmachHealth
//
// Every JSON file the app keeps in Documents (chat sessions, conversation
// memory, health events/baselines/insights) is written through here so it is
// encrypted while the device is locked (FileProtectionType.complete) and left
// out of iCloud/iTunes backups. Chat and memory already sync to Storj, so a
// phone switch loses nothing.

import Foundation

enum ProtectedLocalFile {
    /// Atomically write `data` with complete file protection, excluded from backup.
    static func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        excludeFromBackup(url)
    }

    /// Apply protection + backup exclusion to a file written by an older build.
    /// No-op when the file doesn't exist.
    static func protectExisting(at url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )
        excludeFromBackup(url)
    }

    private static func excludeFromBackup(_ url: URL) {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try? mutableURL.setResourceValues(values)
    }
}
