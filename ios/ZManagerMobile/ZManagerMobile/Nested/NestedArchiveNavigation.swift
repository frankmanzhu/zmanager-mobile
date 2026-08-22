import QuickLook
import CryptoKit
import Network
import PhotosUI
import Security
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ArchiveSession: Identifiable {
    let id: UUID
    let archive: ImportedArchive
    let parentEntryPath: String?
    let cleanupRoot: URL?
}

/// Owns nested archive lifetime and removes materialized files when a session is left.
final class ArchiveSessionStack {
    private(set) var sessions: [ArchiveSession] = []

    var current: ArchiveSession? { sessions.last }

    func push(
        archive: ImportedArchive,
        parentEntryPath: String? = nil,
        cleanupRoot: URL? = nil
    ) -> ArchiveSession {
        let session = ArchiveSession(
            id: UUID(),
            archive: archive,
            parentEntryPath: parentEntryPath,
            cleanupRoot: cleanupRoot
        )
        sessions.append(session)
        return session
    }

    @discardableResult
    func pop() -> ArchiveSession? {
        guard let removed = sessions.popLast() else { return nil }
        if let cleanupRoot = removed.cleanupRoot {
            try? FileManager.default.removeItem(at: cleanupRoot)
        }
        return removed
    }

    @discardableResult
    func popTo(_ sessionID: UUID) -> Bool {
        guard sessions.contains(where: { $0.id == sessionID }) else { return false }
        while sessions.last?.id != sessionID { _ = pop() }
        return true
    }

    func clear() {
        while !sessions.isEmpty { _ = pop() }
    }
}

enum NestedArchiveSupport {
    // Nested-archive browsing is a UI capability over registry-listable
    // formats; the set is pinned by the conformance test against the FFI
    // format registry. XIP is intentionally absent: the FFI reports
    // canList=false for it, so nesting into an .xip always fails.
    static let archiveExtensions: Set<String> = [
        "zip", "7z", "rar", "tar", "gz", "tgz", "bz2", "tbz2", "xz", "txz",
        "zst", "tzst", "lzma", "tlzma", "lz", "lzo", "z", "lz4", "uu", "b64",
        "cpio", "cpgz", "xar", "pkg", "iso", "dmg", "msi", "vhd", "vmdk", "udf",
        "tzap", "aar", "cab", "deb", "jar", "apk", "ipa"
    ]

    static func canOpen(_ entry: ArchiveEntrySummary) -> Bool {
        guard entry.kind == .file else { return false }
        let name = entry.displayName.lowercased()
        if name.hasSuffix(".001") || name.contains(".part") || name.range(of: #"\.z\d{2}$"#, options: .regularExpression) != nil {
            return false
        }
        return archiveExtensions.contains { name.hasSuffix(".\($0)") }
    }
}

