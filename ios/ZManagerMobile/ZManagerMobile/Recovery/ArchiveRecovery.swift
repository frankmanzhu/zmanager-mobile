import QuickLook
import CryptoKit
import Network
import PhotosUI
import Security
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ArchiveRecoveryRecord: Codable, Identifiable, Equatable {
    let id: UUID
    let archivePath: String
    let archiveDisplayName: String
    let selectedPaths: [String]
    let stagingRoot: String
    let destinationLabel: String
    let message: String
    let createdAt: Date
}

final class ArchiveRecoveryStore {
    private let fileManager: FileManager
    private let root: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.root = support.appendingPathComponent("ZManagerMobile/ArchiveRecovery", isDirectory: true)
    }

    @discardableResult
    func save(
        archive: ImportedArchive,
        selectedPaths: [String],
        stagingRoot: URL,
        destinationLabel: String,
        message: String
    ) throws -> ArchiveRecoveryRecord {
        guard isInside(fileManager.temporaryDirectory, stagingRoot) else {
            throw ArchiveExtractionError.unavailableStaging
        }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let record = ArchiveRecoveryRecord(
            id: UUID(),
            archivePath: archive.localPath,
            archiveDisplayName: archive.displayName,
            selectedPaths: selectedPaths,
            stagingRoot: stagingRoot.standardizedFileURL.path,
            destinationLabel: destinationLabel,
            message: message,
            createdAt: Date()
        )
        try encoder.encode(record).write(to: fileURL(record.id), options: .atomic)
        return record
    }

    func records(now: Date = Date()) -> [ArchiveRecoveryRecord] {
        cleanupExpired(now: now)
        return (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "json" }
            .compactMap(read)
            .sorted { $0.createdAt > $1.createdAt } ?? []
    }

    func files(for record: ArchiveRecoveryRecord) -> [URL] {
        let rootURL = URL(fileURLWithPath: record.stagingRoot, isDirectory: true)
        guard isInside(fileManager.temporaryDirectory, rootURL),
              let enumerator = fileManager.enumerator(at: rootURL, includingPropertiesForKeys: [.isRegularFileKey])
        else { return [] }
        return enumerator.compactMap { item in
            guard let url = item as? URL,
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
            return url
        }
    }

    func discard(_ record: ArchiveRecoveryRecord) {
        let staging = URL(fileURLWithPath: record.stagingRoot, isDirectory: true)
        if isInside(fileManager.temporaryDirectory, staging) {
            try? fileManager.removeItem(at: staging.deletingLastPathComponent())
        }
        try? fileManager.removeItem(at: fileURL(record.id))
    }

    private func cleanupExpired(now: Date) {
        recordsWithoutCleanup().filter { now.timeIntervalSince($0.createdAt) > 7 * 24 * 60 * 60 }
            .forEach(discard)
    }

    private func recordsWithoutCleanup() -> [ArchiveRecoveryRecord] {
        (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "json" }
            .compactMap(read) ?? []
    }

    private func read(_ url: URL) -> ArchiveRecoveryRecord? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(ArchiveRecoveryRecord.self, from: data)
    }

    private func fileURL(_ id: UUID) -> URL {
        root.appendingPathComponent("\(id.uuidString).json")
    }

    private func isInside(_ parent: URL, _ child: URL) -> Bool {
        let parentPath = parent.standardizedFileURL.path.hasSuffix("/")
            ? parent.standardizedFileURL.path
            : parent.standardizedFileURL.path + "/"
        return child.standardizedFileURL.path == parent.standardizedFileURL.path
            || child.standardizedFileURL.path.hasPrefix(parentPath)
    }
}

struct ArchiveOperationReport {
    let operation: String
    let subject: String
    let status: String
    let message: String
    let destination: String?
    let entries: UInt64?
    let verified: Bool?
}

enum ArchiveOperationReportStore {
    static func save(
        operation: String,
        subject: String,
        status: String,
        message: String,
        destination: String?,
        entries: UInt64?,
        verified: Bool?
    ) -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ZManagerMobile/OperationReports", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let file = root.appendingPathComponent("\(stamp)-\(safe(operation)).json")
        var object: [String: Any] = [
            "operation": operation,
            "subject": subject,
            "status": status,
            "message": message,
            "redaction": "Passwords, transfer tokens, and provider credentials are never included."
        ]
        if let destination { object["destination"] = destination }
        if let entries { object["entries"] = entries }
        if let verified { object["verified"] = verified }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        try? data.write(to: file, options: .atomic)
        return file
    }

    private static func safe(_ value: String) -> String {
        let allowed = value.map { character in
            character.isLetter || character.isNumber || character == "." || character == "_" || character == "-"
                ? character : "_"
        }
        let result = String(allowed).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return result.isEmpty ? "operation" : result
    }
}

/// Persists only explicit device fingerprint approvals. The fingerprint is
/// shown to the user and is never used as a password or transfer credential.
