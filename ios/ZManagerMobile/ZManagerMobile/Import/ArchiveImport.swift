import QuickLook
import CryptoKit
import Network
import PhotosUI
import Security
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ImportedArchive: Identifiable, Equatable {
    let id: UUID
    let displayName: String
    let localPath: String
    let byteSize: Int64?
    let importedAt: Date
}

enum ArchiveAutomationAction: Equatable {
    case open
    case extract
    case create
    case verify
    case importShared
}

struct ArchiveAutomationRequest: Equatable {
    let action: ArchiveAutomationAction
    let archiveURL: URL?
    let sourceURLs: [URL]
    let sharedIdentifier: String?

    init(
        action: ArchiveAutomationAction,
        archiveURL: URL?,
        sourceURLs: [URL],
        sharedIdentifier: String? = nil
    ) {
        self.action = action
        self.archiveURL = archiveURL
        self.sourceURLs = sourceURLs
        self.sharedIdentifier = sharedIdentifier
    }
}

enum ArchiveAutomationError: LocalizedError, Equatable {
    case unsupportedScheme
    case unsupportedAction
    case credentialQuery
    case missingArchive
    case missingFiles
    case nonLocalURL
    case missingSharedImport
    case invalidSharedImport

    var errorDescription: String? {
        switch self {
        case .unsupportedScheme: return "Unsupported automation scheme."
        case .unsupportedAction: return "Unsupported automation action."
        case .credentialQuery: return "Passwords and credentials are not accepted by automation."
        case .missingArchive: return "Automation requires a local archive URL."
        case .missingFiles: return "Create automation requires local files."
        case .nonLocalURL: return "Automation accepts only local file URLs."
        case .missingSharedImport: return "Share import is missing its handoff identifier."
        case .invalidSharedImport: return "Share import contains an invalid handoff identifier."
        }
    }
}

enum ArchiveAutomationParser {
    static func parse(_ url: URL) throws -> ArchiveAutomationRequest {
        guard url.scheme?.lowercased() == "zmanager" else {
            throw ArchiveAutomationError.unsupportedScheme
        }
        let action: ArchiveAutomationAction
        switch url.host?.lowercased() {
        case "open": action = .open
        case "extract": action = .extract
        case "create": action = .create
        case "verify": action = .verify
        case "import": action = .importShared
        default: throw ArchiveAutomationError.unsupportedAction
        }
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if queryItems.contains(where: { ["password", "pass", "secret", "token", "pin"].contains($0.name.lowercased()) }) {
            throw ArchiveAutomationError.credentialQuery
        }
        switch action {
        case .create:
            let sources = queryItems.first(where: { $0.name == "files" })?.value?
                .split(separator: "|")
                .compactMap { URL(string: String($0)) }
                .filter { $0.isFileURL } ?? []
            guard !sources.isEmpty else { throw ArchiveAutomationError.missingFiles }
            guard sources.count == queryItems.first(where: { $0.name == "files" })?.value?.split(separator: "|").count else {
                throw ArchiveAutomationError.nonLocalURL
            }
            return ArchiveAutomationRequest(action: action, archiveURL: nil, sourceURLs: sources)
        case .open, .extract, .verify:
            guard let archiveValue = queryItems.first(where: { $0.name == "archive" })?.value,
                  let archive = URL(string: archiveValue), archive.isFileURL else {
                throw ArchiveAutomationError.missingArchive
            }
            return ArchiveAutomationRequest(action: action, archiveURL: archive, sourceURLs: [])
        case .importShared:
            guard let identifier = queryItems.first(where: { $0.name == "id" })?.value else {
                throw ArchiveAutomationError.missingSharedImport
            }
            guard SharedImportStore.isValidIdentifier(identifier) else {
                throw ArchiveAutomationError.invalidSharedImport
            }
            return ArchiveAutomationRequest(
                action: action,
                archiveURL: nil,
                sourceURLs: [],
                sharedIdentifier: identifier
            )
        }
    }
}

enum ArchiveImportError: LocalizedError {
    case emptySelection
    case directoryUnsupported
    case cacheUnavailable
    case conflictingVolumeNames

    var errorDescription: String? {
        switch self {
        case .emptySelection:
            return "No archive was selected."
        case .directoryUnsupported:
            return "Choose an archive file instead of a folder."
        case .cacheUnavailable:
            return "Unable to prepare the app cache for that archive."
        case .conflictingVolumeNames:
            return "Selected archive volumes have conflicting names."
        }
    }
}

/// Keeps security-scoped URL lifetime management in the native shell. Tests
/// can inject a recorder without depending on a real Files provider.
struct SecurityScopedResourceAccess {
    let start: (URL) -> Bool
    let stop: (URL) -> Void

    static let system = SecurityScopedResourceAccess(
        start: { $0.startAccessingSecurityScopedResource() },
        stop: { $0.stopAccessingSecurityScopedResource() }
    )

    func withAccess<T>(_ url: URL, operation: () throws -> T) rethrows -> T {
        let didStart = start(url)
        defer {
            if didStart {
                stop(url)
            }
        }
        return try operation()
    }
}

struct ArchiveImportStore {
    static let allowedContentTypes: [UTType] = [.data]

    private let fileManager: FileManager
    private let cacheRoot: URL?
    private let securityScope: SecurityScopedResourceAccess

    init(
        fileManager: FileManager = .default,
        cacheRoot: URL? = nil,
        securityScope: SecurityScopedResourceAccess = .system
    ) {
        self.fileManager = fileManager
        self.cacheRoot = cacheRoot
        self.securityScope = securityScope
    }

    func importArchive(from url: URL) throws -> ImportedArchive {
        try importArchives(from: [url])
    }

    func importArchives(from urls: [URL]) throws -> ImportedArchive {
        guard !urls.isEmpty else {
            throw ArchiveImportError.emptySelection
        }
        let scopedURLs = urls.map { url in
            (url, securityScope.start(url))
        }
        defer {
            scopedURLs.forEach { url, didStartAccessing in
                if didStartAccessing {
                    securityScope.stop(url)
                }
            }
        }
        for (url, _) in scopedURLs {
            if try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                throw ArchiveImportError.directoryUnsupported
            }
        }

        let displayNames = urls.map { Self.sanitizedDisplayName($0.lastPathComponent) }
        guard Set(displayNames).count == displayNames.count else {
            throw ArchiveImportError.conflictingVolumeNames
        }
        let primaryName = Self.primaryArchiveName(displayNames) ?? displayNames[0]
        guard let primaryIndex = displayNames.firstIndex(of: primaryName) else {
            throw ArchiveImportError.emptySelection
        }
        let importRoot = try archiveImportRoot()
        let groupRoot = importRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: groupRoot, withIntermediateDirectories: false)

        do {
            for (url, displayName) in zip(urls, displayNames) {
                try fileManager.copyItem(at: url, to: groupRoot.appendingPathComponent(displayName))
            }
        } catch {
            try? fileManager.removeItem(at: groupRoot)
            throw error
        }
        let destination = groupRoot.appendingPathComponent(displayNames[primaryIndex])
        let importedValues = try? destination.resourceValues(forKeys: [.fileSizeKey])

        return ImportedArchive(
            id: UUID(),
            displayName: displayNames[primaryIndex],
            localPath: destination.path,
            byteSize: importedValues?.fileSize.map(Int64.init),
            importedAt: Date()
        )
    }

    private func archiveImportRoot() throws -> URL {
        let root = cacheRoot ?? fileManager.temporaryDirectory
            .appendingPathComponent("ZManagerMobile", isDirectory: true)
            .appendingPathComponent("ImportedArchives", isDirectory: true)
        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true, attributes: nil)
            return root
        } catch {
            throw ArchiveImportError.cacheUnavailable
        }
    }

    static func sanitizedDisplayName(_ rawName: String?) -> String {
        let leafName = rawName?
            .split(whereSeparator: { $0 == "/" || $0 == "\\" })
            .last
            .map(String.init) ?? ""
        let unsafeCharacters = CharacterSet(charactersIn: "\\/:*?\"<>|")
            .union(.controlCharacters)
        let pieces = leafName.components(separatedBy: unsafeCharacters)
        let collapsed = pieces
            .joined(separator: "_")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        let limited = String(collapsed.prefix(120))

        if limited.isEmpty || limited == "." || limited == ".." {
            return "archive"
        }
        return limited
    }

    static func primaryArchiveName(_ names: [String]) -> String? {
        names.first { $0.lowercased().hasSuffix(".vol000.tzap") }
            ?? names.first { $0.range(of: #"(?i)^.+\.part1\.rar$"#, options: .regularExpression) != nil }
            ?? names.first { $0.range(of: #"(?i)^.+\.7z\.001$"#, options: .regularExpression) != nil }
            ?? names.first { $0.lowercased().hasSuffix(".zip") }
    }
}

struct SharedImportBatch {
    let sourceURLs: [URL]
    let cleanupRoot: URL
}

/// App-group handoff used by the iOS Share Extension. The extension only
/// copies provider files here; the main app owns archive import and parsing.
struct SharedImportStore {
    static let appGroupIdentifier = "group.org.tzap.zmanager.mobile"
    static let incomingDirectoryName = "Incoming"

    private let fileManager: FileManager
    private let appGroupContainer: () -> URL?

    init(
        fileManager: FileManager = .default,
        appGroupContainer: (() -> URL?)? = nil
    ) {
        self.fileManager = fileManager
        self.appGroupContainer = appGroupContainer ?? {
            fileManager.containerURL(
                forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier
            )
        }
    }

    static func isValidIdentifier(_ identifier: String) -> Bool {
        !identifier.isEmpty &&
            identifier.count <= 80 &&
            identifier.unicodeScalars.allSatisfy { scalar in
                CharacterSet.alphanumerics.contains(scalar) || scalar == "-"
            }
    }

    func stageIncoming(identifier: String) throws -> SharedImportBatch {
        guard Self.isValidIdentifier(identifier), let container = appGroupContainer() else {
            throw ArchiveAutomationError.invalidSharedImport
        }
        let sourceRoot = container
            .appendingPathComponent(Self.incomingDirectoryName, isDirectory: true)
            .appendingPathComponent(identifier, isDirectory: true)
        let sourceURLs = try fileManager.contentsOfDirectory(
            at: sourceRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !sourceURLs.isEmpty else {
            throw ArchiveAutomationError.missingSharedImport
        }

        let cleanupRoot = fileManager.temporaryDirectory
            .appendingPathComponent("ZManagerMobile/ShareImports", isDirectory: true)
            .appendingPathComponent(identifier, isDirectory: true)
        try fileManager.createDirectory(at: cleanupRoot, withIntermediateDirectories: true)
        do {
            let copiedURLs = try sourceURLs.map { sourceURL -> URL in
                let name = ArchiveImportStore.sanitizedDisplayName(sourceURL.lastPathComponent)
                let destination = uniqueURL(
                    in: cleanupRoot,
                    name: name
                )
                try fileManager.copyItem(at: sourceURL, to: destination)
                return destination
            }
            try? fileManager.removeItem(at: sourceRoot)
            return SharedImportBatch(sourceURLs: copiedURLs, cleanupRoot: cleanupRoot)
        } catch {
            try? fileManager.removeItem(at: cleanupRoot)
            throw error
        }
    }

    func discardIncoming(identifier: String) {
        guard Self.isValidIdentifier(identifier), let container = appGroupContainer() else {
            return
        }
        let sourceRoot = container
            .appendingPathComponent(Self.incomingDirectoryName, isDirectory: true)
            .appendingPathComponent(identifier, isDirectory: true)
        try? fileManager.removeItem(at: sourceRoot)
    }

    private func uniqueURL(in root: URL, name: String) -> URL {
        var candidate = root.appendingPathComponent(name)
        var index = 1
        while fileManager.fileExists(atPath: candidate.path) {
            let base = candidate.deletingPathExtension().lastPathComponent
            let ext = candidate.pathExtension
            candidate = root.appendingPathComponent(
                ext.isEmpty ? "\(base) (\(index))" : "\(base) (\(index)).\(ext)"
            )
            index += 1
        }
        return candidate
    }
}

