import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var importModel = ArchiveImportModel()
    @State private var isFileImporterPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("ZManager")
                    .font(.largeTitle.weight(.semibold))

                Text("Open an archive, inspect its contents, then extract safely.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }

            if let archive = importModel.importedArchive {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Imported \(archive.displayName)")
                        .font(.headline)
                    if let byteSize = archive.byteSize {
                        Text(ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let message = importModel.errorMessage {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.red)
            }

            ArchiveListingPanel(
                state: importModel.listingState,
                password: $importModel.passwordInput,
                onSubmitPassword: importModel.retryListingWithPassword
            )

            Spacer()

            HStack {
                Spacer()
                Button(importModel.isImporting ? "Importing" : "Open Archive") {
                    isFileImporterPresented = true
                }
                .disabled(importModel.isImporting)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: ArchiveImportStore.allowedContentTypes,
            allowsMultipleSelection: false
        ) { result in
            importModel.handleFileImporterResult(result)
        }
        .onOpenURL { url in
            importModel.importExternalURL(url)
        }
    }
}

struct ImportedArchive: Identifiable, Equatable {
    let id: UUID
    let displayName: String
    let localPath: String
    let byteSize: Int64?
    let importedAt: Date
}

enum ArchiveImportError: LocalizedError {
    case emptySelection
    case directoryUnsupported
    case cacheUnavailable

    var errorDescription: String? {
        switch self {
        case .emptySelection:
            return "No archive was selected."
        case .directoryUnsupported:
            return "Choose an archive file instead of a folder."
        case .cacheUnavailable:
            return "Unable to prepare the app cache for that archive."
        }
    }
}

struct ArchiveListingPanel: View {
    let state: ArchiveListingState
    @Binding var password: String
    let onSubmitPassword: () -> Void

    var body: some View {
        switch state {
        case .idle:
            EmptyView()
        case .loading:
            Text("Reading archive")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        case .ready(let summary):
            ArchiveListingReadyPanel(summary: summary)
        case .passwordRequired(let error):
            VStack(alignment: .leading, spacing: 8) {
                Text(error.message)
                    .font(.subheadline)
                if let recoveryHint = error.recoveryHint {
                    Text(recoveryHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                Button("Retry") {
                    onSubmitPassword()
                }
                .disabled(password.isEmpty)
            }
        case .failed(let error):
            VStack(alignment: .leading, spacing: 4) {
                Text(error.message)
                    .font(.subheadline)
                    .foregroundStyle(.red)
                if let recoveryHint = error.recoveryHint {
                    Text(recoveryHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct ArchiveListingReadyPanel: View {
    let summary: ArchiveListingSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(summary.formatLabel) - \(summary.entryCount) entries")
                .font(.headline)
            if let totalSize = summary.totalSize {
                Text(ByteCountFormatter.string(fromByteCount: Int64(totalSize), countStyle: .file))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(summary.warnings, id: \.self) { warning in
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(summary.entries) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.path)
                            .font(.subheadline)
                        Text(entry.detailText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

struct ArchiveImportStore {
    static let allowedContentTypes: [UTType] = [.data]

    private let fileManager: FileManager
    private let cacheRoot: URL?

    init(fileManager: FileManager = .default, cacheRoot: URL? = nil) {
        self.fileManager = fileManager
        self.cacheRoot = cacheRoot
    }

    func importArchive(from url: URL) throws -> ImportedArchive {
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let values = try url.resourceValues(forKeys: [.isDirectoryKey])
        if values.isDirectory == true {
            throw ArchiveImportError.directoryUnsupported
        }

        let displayName = Self.sanitizedDisplayName(url.lastPathComponent)
        let importRoot = try archiveImportRoot()
        let destination = importRoot.appendingPathComponent(
            "\(UUID().uuidString)-\(displayName)",
            isDirectory: false
        )

        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }

        try fileManager.copyItem(at: url, to: destination)
        let importedValues = try? destination.resourceValues(forKeys: [.fileSizeKey])

        return ImportedArchive(
            id: UUID(),
            displayName: displayName,
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
}

enum ArchiveListingState: Equatable {
    case idle
    case loading
    case ready(ArchiveListingSummary)
    case passwordRequired(ArchiveListingError)
    case failed(ArchiveListingError)
}

struct ArchiveListingSummary: Equatable {
    let formatLabel: String
    let entryCount: UInt64
    let totalSize: UInt64?
    let entries: [ArchiveEntrySummary]
    let warnings: [String]
}

struct ArchiveEntrySummary: Identifiable, Equatable {
    let id: String
    let path: String
    let kindLabel: String
    let size: UInt64?

    var detailText: String {
        if let size = size {
            return "\(kindLabel) - \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))"
        }
        return kindLabel
    }
}

struct ArchiveListingError: Equatable {
    let code: String
    let message: String
    let recoveryHint: String?
    let retryable: Bool
}

protocol ArchiveBridgeClient {
    func detectArchiveMetadata(path: String) throws -> DetectArchiveResult
    func listArchiveContents(path: String, password: String?) throws -> ListArchiveResult
}

struct GeneratedArchiveBridgeClient: ArchiveBridgeClient {
    func detectArchiveMetadata(path: String) throws -> DetectArchiveResult {
        try detectArchive(request: DetectArchiveRequest(archivePath: path))
    }

    func listArchiveContents(path: String, password: String?) throws -> ListArchiveResult {
        try listArchive(
            request: ListArchiveRequest(archivePath: path, password: password)
        )
    }
}

struct ArchiveListingLoader {
    private static let passwordRequiredCode = "password_required"
    private static let invalidPasswordCode = "invalid_password"
    private static let unsupportedFormatCode = "unsupported_format"
    private static let unknownErrorCode = "unknown_error"

    private let bridge: ArchiveBridgeClient

    init(bridge: ArchiveBridgeClient = GeneratedArchiveBridgeClient()) {
        self.bridge = bridge
    }

    func load(archive: ImportedArchive, password: String?) -> ArchiveListingState {
        do {
            let detection = try bridge.detectArchiveMetadata(path: archive.localPath)
            if !detection.canList {
                return .failed(
                    ArchiveListingError(
                        code: Self.unsupportedFormatCode,
                        message: "\(detection.formatLabel) listing is not available.",
                        recoveryHint: "Try another archive format or update ZManager Mobile.",
                        retryable: false
                    )
                )
            }

            let listing = try bridge.listArchiveContents(path: archive.localPath, password: password)
            return .ready(listing.summary)
        } catch ZmanagerMobileError.Bridge(
            let code,
            let userMessage,
            let recoveryHint,
            _,
            let retryable
        ) {
            let error = ArchiveListingError(
                code: code,
                message: userMessage,
                recoveryHint: recoveryHint,
                retryable: retryable
            )
            if code == Self.passwordRequiredCode || code == Self.invalidPasswordCode {
                return .passwordRequired(error)
            }
            return .failed(error)
        } catch {
            return .failed(
                ArchiveListingError(
                    code: Self.unknownErrorCode,
                    message: "Unable to read that archive.",
                    recoveryHint: nil,
                    retryable: false
                )
            )
        }
    }
}

private extension ListArchiveResult {
    var summary: ArchiveListingSummary {
        ArchiveListingSummary(
            formatLabel: formatLabel,
            entryCount: entryCount,
            totalSize: totalSize,
            entries: entries.prefix(50).enumerated().map { offset, entry in
                entry.summary(id: "\(offset)-\(entry.path)")
            },
            warnings: warnings.map(\.message)
        )
    }
}

private extension ArchiveEntry {
    func summary(id: String) -> ArchiveEntrySummary {
        ArchiveEntrySummary(
            id: id,
            path: path,
            kindLabel: kind.displayLabel,
            size: size
        )
    }
}

private extension ArchiveEntryKind {
    var displayLabel: String {
        switch self {
        case .file:
            return "file"
        case .directory:
            return "directory"
        case .symlink:
            return "symlink"
        case .hardlink:
            return "hardlink"
        case .special:
            return "special"
        }
    }
}

@MainActor
final class ArchiveImportModel: ObservableObject {
    @Published var importedArchive: ImportedArchive?
    @Published var errorMessage: String?
    @Published var isImporting = false
    @Published var listingState: ArchiveListingState = .idle
    @Published var passwordInput = ""

    private let importStore: ArchiveImportStore
    private let listingLoader: ArchiveListingLoader
    private var importGeneration = 0
    private var listingGeneration = 0

    init(
        importStore: ArchiveImportStore = ArchiveImportStore(),
        listingLoader: ArchiveListingLoader = ArchiveListingLoader()
    ) {
        self.importStore = importStore
        self.listingLoader = listingLoader
    }

    func handleFileImporterResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else {
                errorMessage = ArchiveImportError.emptySelection.localizedDescription
                return
            }
            importExternalURL(url)
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    func importExternalURL(_ url: URL) {
        importGeneration += 1
        listingGeneration += 1
        let currentImportGeneration = importGeneration
        isImporting = true
        errorMessage = nil
        importedArchive = nil
        listingState = .idle
        passwordInput = ""

        Task {
            do {
                let importStore = importStore
                let imported = try await Task.detached(priority: .userInitiated) {
                    try importStore.importArchive(from: url)
                }.value
                guard currentImportGeneration == importGeneration else {
                    return
                }
                importedArchive = imported
                loadListing(for: imported, password: nil)
            } catch {
                guard currentImportGeneration == importGeneration else {
                    return
                }
                errorMessage = error.localizedDescription
            }
            if currentImportGeneration == importGeneration {
                isImporting = false
            }
        }
    }

    func retryListingWithPassword() {
        guard let archive = importedArchive else {
            return
        }
        let password = passwordInput.isEmpty ? nil : passwordInput
        passwordInput = ""
        loadListing(for: archive, password: password)
    }

    private func loadListing(for archive: ImportedArchive, password: String?) {
        listingGeneration += 1
        let currentListingGeneration = listingGeneration
        listingState = .loading
        let listingLoader = listingLoader
        Task {
            let state = await Task.detached(priority: .userInitiated) {
                listingLoader.load(archive: archive, password: password)
            }.value
            guard currentListingGeneration == listingGeneration, importedArchive?.id == archive.id else {
                return
            }
            listingState = state
        }
    }
}

#Preview {
    ContentView()
}
