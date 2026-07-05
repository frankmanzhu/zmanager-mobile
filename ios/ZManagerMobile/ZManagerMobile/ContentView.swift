import QuickLook
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
                searchQuery: $importModel.entrySearchQuery,
                sort: $importModel.entrySort,
                viewMode: $importModel.entryViewMode,
                selectedEntryIds: $importModel.selectedEntryIds,
                previewState: importModel.previewState,
                previewPassword: $importModel.previewPasswordInput,
                testState: importModel.testState,
                testPassword: $importModel.testPasswordInput,
                onSubmitPassword: importModel.retryListingWithPassword,
                onPreviewEntry: { importModel.startPreview(entry: $0) },
                onSubmitPreviewPassword: { importModel.retryPreviewWithPassword(entry: $0) },
                onTestEntries: { importModel.startTest(selectedEntries: $0) },
                onSubmitTestPassword: { importModel.retryTestWithPassword(selectedEntries: $0) }
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
        .sheet(
            item: $importModel.previewDocument,
            onDismiss: importModel.cleanupActivePreview
        ) { document in
            QuickLookPreview(url: document.url)
        }
    }
}

struct PreviewDocument: Identifiable, Equatable {
    let id = UUID()
    let url: URL
}

struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        context.coordinator.url = url
        controller.reloadData()
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL

        init(url: URL) {
            self.url = url
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            1
        }

        func previewController(
            _ controller: QLPreviewController,
            previewItemAt index: Int
        ) -> QLPreviewItem {
            url as NSURL
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
    @Binding var searchQuery: String
    @Binding var sort: ArchiveEntrySort
    @Binding var viewMode: ArchiveEntryViewMode
    @Binding var selectedEntryIds: Set<String>
    let previewState: ArchivePreviewState
    @Binding var previewPassword: String
    let testState: ArchiveTestState
    @Binding var testPassword: String
    let onSubmitPassword: () -> Void
    let onPreviewEntry: (ArchiveEntrySummary) -> Void
    let onSubmitPreviewPassword: (ArchiveEntrySummary) -> Void
    let onTestEntries: ([ArchiveEntrySummary]) -> Void
    let onSubmitTestPassword: ([ArchiveEntrySummary]) -> Void

    var body: some View {
        switch state {
        case .idle:
            EmptyView()
        case .loading:
            Text("Reading archive")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        case .ready(let summary):
            ArchiveListingReadyPanel(
                summary: summary,
                searchQuery: $searchQuery,
                sort: $sort,
                viewMode: $viewMode,
                selectedEntryIds: $selectedEntryIds,
                previewState: previewState,
                previewPassword: $previewPassword,
                testState: testState,
                testPassword: $testPassword,
                onPreviewEntry: onPreviewEntry,
                onSubmitPreviewPassword: onSubmitPreviewPassword,
                onTestEntries: onTestEntries,
                onSubmitTestPassword: onSubmitTestPassword
            )
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
    @Binding var searchQuery: String
    @Binding var sort: ArchiveEntrySort
    @Binding var viewMode: ArchiveEntryViewMode
    @Binding var selectedEntryIds: Set<String>
    let previewState: ArchivePreviewState
    @Binding var previewPassword: String
    let testState: ArchiveTestState
    @Binding var testPassword: String
    let onPreviewEntry: (ArchiveEntrySummary) -> Void
    let onSubmitPreviewPassword: (ArchiveEntrySummary) -> Void
    let onTestEntries: ([ArchiveEntrySummary]) -> Void
    let onSubmitTestPassword: ([ArchiveEntrySummary]) -> Void

    private var groups: [ArchiveEntryGroup] {
        summary.visibleGroups(searchQuery: searchQuery, sort: sort, viewMode: viewMode)
    }

    private var selectedEntries: [ArchiveEntrySummary] {
        summary.selectedEntries(selectedEntryIds: selectedEntryIds)
    }

    private var previewEntry: ArchiveEntrySummary? {
        summary.previewableSelectedEntry(selectedEntryIds: selectedEntryIds)
    }

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
            TextField("Search", text: $searchQuery)
                .textFieldStyle(.roundedBorder)
            Picker("Sort", selection: $sort) {
                Text("Name").tag(ArchiveEntrySort.pathAscending)
                Text("Size").tag(ArchiveEntrySort.sizeDescending)
                Text("Type").tag(ArchiveEntrySort.kindAscending)
            }
            .pickerStyle(.segmented)
            Picker("View", selection: $viewMode) {
                Text("List").tag(ArchiveEntryViewMode.list)
                Text("Folders").tag(ArchiveEntryViewMode.folders)
            }
            .pickerStyle(.segmented)
            HStack(spacing: 12) {
                Text("\(selectedEntries.count) selected")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Select Visible") {
                    selectedEntryIds.formUnion(groups.flatMap { $0.entries }.map { $0.id })
                }
                .disabled(groups.allSatisfy { $0.entries.isEmpty })
                Button("Clear") {
                    selectedEntryIds.removeAll()
                }
                .disabled(selectedEntries.isEmpty)
                Button("Preview") {
                    if let previewEntry {
                        onPreviewEntry(previewEntry)
                    }
                }
                .disabled(previewEntry == nil || previewState.isLoading)
                Button("Test") {
                    onTestEntries(selectedEntries)
                }
                .disabled(testState.isLoading)
            }
            ArchivePreviewPanel(
                state: previewState,
                password: $previewPassword,
                onSubmitPassword: onSubmitPreviewPassword
            )
            ArchiveTestPanel(
                state: testState,
                selectedEntries: selectedEntries,
                password: $testPassword,
                onSubmitPassword: onSubmitTestPassword
            )
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if groups.isEmpty {
                        Text("No entries")
                            .font(.subheadline)
                    }
                    ForEach(groups) { group in
                        Text(group.label)
                            .font(.subheadline.weight(.semibold))
                        ForEach(group.entries) { entry in
                            Button {
                                if selectedEntryIds.contains(entry.id) {
                                    selectedEntryIds.remove(entry.id)
                                } else {
                                    selectedEntryIds.insert(entry.id)
                                }
                            } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: selectedEntryIds.contains(entry.id) ? "checkmark.circle.fill" : "circle")
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(entry.displayName)
                                            .font(.subheadline)
                                        Text(entry.detailText)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .frame(maxHeight: 280)
        }
    }
}

struct ArchivePreviewPanel: View {
    let state: ArchivePreviewState
    @Binding var password: String
    let onSubmitPassword: (ArchiveEntrySummary) -> Void

    var body: some View {
        switch state {
        case .idle:
            EmptyView()
        case .loading(let entry):
            Text("Preparing preview for \(entry.displayName)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        case .ready(let summary):
            VStack(alignment: .leading, spacing: 4) {
                Text("Preview prepared for \(summary.entry.displayName)")
                    .font(.subheadline)
                ForEach(summary.warnings, id: \.self) { warning in
                    Text(warning)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        case .passwordRequired(let entry, let error):
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
                Button("Retry Preview") {
                    onSubmitPassword(entry)
                }
                .disabled(password.isEmpty)
            }
        case .failed(_, let error):
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

struct ArchiveTestPanel: View {
    let state: ArchiveTestState
    let selectedEntries: [ArchiveEntrySummary]
    @Binding var password: String
    let onSubmitPassword: ([ArchiveEntrySummary]) -> Void

    var body: some View {
        switch state {
        case .idle:
            EmptyView()
        case .loading(let selectedCount):
            Text(selectedCount == 0 ? "Testing archive" : "Testing \(selectedCount) selected entries")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        case .ready(let summary):
            VStack(alignment: .leading, spacing: 4) {
                Text(summary.verified ? "Archive verified" : "Archive verification failed")
                    .font(.subheadline)
                Text("\(summary.testedEntries) tested - \(summary.skippedEntries) skipped - \(summary.testedBytes) bytes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(summary.warnings, id: \.self) { warning in
                    Text(warning)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
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
                Button("Retry Test") {
                    onSubmitPassword(selectedEntries)
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
    let displayName: String
    let parentPath: String
    let kindLabel: String
    let kind: ArchiveEntryKind
    let size: UInt64?

    var isPreviewable: Bool {
        kind == .file
    }

    var detailText: String {
        if let size = size {
            return "\(path) - \(kindLabel) - \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))"
        }
        return "\(path) - \(kindLabel)"
    }
}

struct ArchiveListingError: Equatable {
    let code: String
    let message: String
    let recoveryHint: String?
    let retryable: Bool
}

enum ArchiveEntrySort: String, CaseIterable {
    case pathAscending
    case sizeDescending
    case kindAscending
}

enum ArchiveEntryViewMode: String, CaseIterable {
    case list
    case folders
}

struct ArchiveEntryGroup: Identifiable, Equatable {
    let id: String
    let label: String
    let entries: [ArchiveEntrySummary]
}

enum ArchivePreviewState: Equatable {
    case idle
    case loading(ArchiveEntrySummary)
    case ready(ArchivePreviewSummary)
    case passwordRequired(ArchiveEntrySummary, ArchiveListingError)
    case failed(ArchiveEntrySummary?, ArchiveListingError)

    var isLoading: Bool {
        if case .loading = self {
            return true
        }
        return false
    }
}

enum ArchiveTestState: Equatable {
    case idle
    case loading(Int)
    case ready(ArchiveTestSummary)
    case passwordRequired(ArchiveListingError)
    case failed(ArchiveListingError)

    var isLoading: Bool {
        if case .loading = self {
            return true
        }
        return false
    }
}

struct ArchivePreviewSummary: Equatable {
    let entry: ArchiveEntrySummary
    let cleanupRoot: String
    let previewPath: String
    let writtenBytes: UInt64
    let warnings: [String]
}

struct ArchiveTestSummary: Equatable {
    let formatLabel: String
    let verified: Bool
    let testedEntries: UInt64
    let skippedEntries: UInt64
    let totalEntries: UInt64
    let testedBytes: UInt64
    let selectedCount: Int
    let warnings: [String]
}

extension ArchiveListingSummary {
    func visibleGroups(
        searchQuery: String,
        sort: ArchiveEntrySort,
        viewMode: ArchiveEntryViewMode
    ) -> [ArchiveEntryGroup] {
        let filtered = entries
            .filter { $0.matches(searchQuery: searchQuery) }
            .sortedForBrowser(using: sort)

        switch viewMode {
        case .list:
            return filtered.isEmpty ? [] : [
                ArchiveEntryGroup(id: "all", label: "All entries", entries: filtered)
            ]
        case .folders:
            let grouped = Dictionary(grouping: filtered) { entry in
                entry.parentPath.isEmpty ? "/" : entry.parentPath
            }
            return grouped.keys
                .sorted { left, right in
                    if left == "/" {
                        return true
                    }
                    if right == "/" {
                        return false
                    }
                    return left.localizedCaseInsensitiveCompare(right) == .orderedAscending
                }
                .map { parentPath in
                    ArchiveEntryGroup(
                        id: parentPath,
                        label: parentPath,
                        entries: grouped[parentPath] ?? []
                    )
                }
        }
    }

    func selectedEntries(selectedEntryIds: Set<String>) -> [ArchiveEntrySummary] {
        entries.filter { selectedEntryIds.contains($0.id) }
    }

    func previewableSelectedEntry(selectedEntryIds: Set<String>) -> ArchiveEntrySummary? {
        return selectedEntries(selectedEntryIds: selectedEntryIds)
            .first
            .flatMap { selectedEntryIds.count == 1 && $0.isPreviewable ? $0 : nil }
    }
}

private extension ArchiveEntrySummary {
    func matches(searchQuery: String) -> Bool {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return true
        }
        return path.localizedCaseInsensitiveContains(query)
            || displayName.localizedCaseInsensitiveContains(query)
            || parentPath.localizedCaseInsensitiveContains(query)
    }
}

private extension Array where Element == ArchiveEntrySummary {
    func sortedForBrowser(using sort: ArchiveEntrySort) -> [ArchiveEntrySummary] {
        switch sort {
        case .pathAscending:
            return sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
        case .sizeDescending:
            return sorted {
                if $0.size == $1.size {
                    return $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending
                }
                return ($0.size ?? 0) > ($1.size ?? 0)
            }
        case .kindAscending:
            return sorted {
                if $0.kindLabel == $1.kindLabel {
                    return $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending
                }
                return $0.kindLabel < $1.kindLabel
            }
        }
    }
}

protocol ArchiveBridgeClient {
    func detectArchiveMetadata(path: String) throws -> DetectArchiveResult
    func listArchiveContents(path: String, password: String?) throws -> ListArchiveResult
    func materializePreviewEntry(
        path: String,
        entryPath: String,
        password: String?
    ) throws -> MaterializePreviewResult
    func testArchiveContents(
        path: String,
        selectedPaths: [String],
        password: String?
    ) throws -> TestArchiveResult
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

    func materializePreviewEntry(
        path: String,
        entryPath: String,
        password: String?
    ) throws -> MaterializePreviewResult {
        try materializePreview(
            request: MaterializePreviewRequest(
                archivePath: path,
                entryPath: entryPath,
                password: password,
                stripComponents: 0
            )
        )
    }

    func testArchiveContents(
        path: String,
        selectedPaths: [String],
        password: String?
    ) throws -> TestArchiveResult {
        try testArchive(
            request: TestArchiveRequest(
                archivePath: path,
                password: password,
                selectedPaths: selectedPaths
            )
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

struct ArchivePreviewLoader {
    private static let passwordRequiredCode = "password_required"
    private static let invalidPasswordCode = "invalid_password"
    private static let unknownErrorCode = "unknown_error"

    private let bridge: ArchiveBridgeClient

    init(bridge: ArchiveBridgeClient = GeneratedArchiveBridgeClient()) {
        self.bridge = bridge
    }

    func materialize(
        archive: ImportedArchive,
        entry: ArchiveEntrySummary,
        password: String?
    ) -> ArchivePreviewState {
        do {
            let preview = try bridge.materializePreviewEntry(
                path: archive.localPath,
                entryPath: entry.path,
                password: password
            )
            return .ready(preview.summary(entry: entry))
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
                return .passwordRequired(entry, error)
            }
            return .failed(entry, error)
        } catch {
            return .failed(
                entry,
                ArchiveListingError(
                    code: Self.unknownErrorCode,
                    message: "Unable to preview that archive entry.",
                    recoveryHint: nil,
                    retryable: false
                )
            )
        }
    }
}

struct ArchiveTestLoader {
    private static let passwordRequiredCode = "password_required"
    private static let invalidPasswordCode = "invalid_password"
    private static let unknownErrorCode = "unknown_error"

    private let bridge: ArchiveBridgeClient

    init(bridge: ArchiveBridgeClient = GeneratedArchiveBridgeClient()) {
        self.bridge = bridge
    }

    func test(
        archive: ImportedArchive,
        selectedEntries: [ArchiveEntrySummary],
        password: String?
    ) -> ArchiveTestState {
        do {
            let result = try bridge.testArchiveContents(
                path: archive.localPath,
                selectedPaths: selectedEntries.map(\.path),
                password: password
            )
            return .ready(result.summary(selectedCount: selectedEntries.count))
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
                    message: "Unable to test that archive.",
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
        let normalizedSeparators = path.replacingOccurrences(of: "\\", with: "/")
        let pieces = normalizedSeparators.split(separator: "/", omittingEmptySubsequences: false)
        let displayName = pieces.last.map(String.init).flatMap { $0.isEmpty ? nil : $0 } ?? path
        let parentPath = pieces.dropLast().joined(separator: "/")

        return ArchiveEntrySummary(
            id: id,
            path: path,
            displayName: displayName,
            parentPath: parentPath,
            kindLabel: kind.displayLabel,
            kind: kind,
            size: size
        )
    }
}

private extension MaterializePreviewResult {
    func summary(entry: ArchiveEntrySummary) -> ArchivePreviewSummary {
        return ArchivePreviewSummary(
            entry: entry,
            cleanupRoot: cleanupRoot,
            previewPath: previewPath,
            writtenBytes: writtenBytes,
            warnings: warnings.map(\.message)
        )
    }
}

private extension TestArchiveResult {
    func summary(selectedCount: Int) -> ArchiveTestSummary {
        return ArchiveTestSummary(
            formatLabel: formatLabel,
            verified: verified,
            testedEntries: testedEntries,
            skippedEntries: skippedEntries,
            totalEntries: totalEntries,
            testedBytes: testedBytes,
            selectedCount: selectedCount,
            warnings: warnings.map(\.message)
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
    @Published var previewPasswordInput = ""
    @Published var testPasswordInput = ""
    @Published var entrySearchQuery = ""
    @Published var entrySort: ArchiveEntrySort = .pathAscending
    @Published var entryViewMode: ArchiveEntryViewMode = .folders
    @Published var selectedEntryIds = Set<String>()
    @Published var previewState: ArchivePreviewState = .idle
    @Published var testState: ArchiveTestState = .idle
    @Published var previewDocument: PreviewDocument?

    private let importStore: ArchiveImportStore
    private let listingLoader: ArchiveListingLoader
    private let previewLoader: ArchivePreviewLoader
    private let testLoader: ArchiveTestLoader
    private var importGeneration = 0
    private var listingGeneration = 0
    private var previewGeneration = 0
    private var testGeneration = 0
    private var activePreviewCleanupRoot: URL?

    init(
        importStore: ArchiveImportStore = ArchiveImportStore(),
        listingLoader: ArchiveListingLoader = ArchiveListingLoader(),
        previewLoader: ArchivePreviewLoader = ArchivePreviewLoader(),
        testLoader: ArchiveTestLoader = ArchiveTestLoader()
    ) {
        self.importStore = importStore
        self.listingLoader = listingLoader
        self.previewLoader = previewLoader
        self.testLoader = testLoader
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
        clearPreviewState()
        clearTestState()
        let currentImportGeneration = importGeneration
        isImporting = true
        errorMessage = nil
        importedArchive = nil
        listingState = .idle
        passwordInput = ""
        entrySearchQuery = ""
        selectedEntryIds.removeAll()

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

    func startPreview(entry: ArchiveEntrySummary) {
        guard let archive = importedArchive else {
            return
        }
        loadPreview(for: archive, entry: entry, password: nil)
    }

    func retryPreviewWithPassword(entry: ArchiveEntrySummary) {
        guard let archive = importedArchive else {
            return
        }
        let password = previewPasswordInput.isEmpty ? nil : previewPasswordInput
        previewPasswordInput = ""
        loadPreview(for: archive, entry: entry, password: password)
    }

    func startTest(selectedEntries: [ArchiveEntrySummary]) {
        guard let archive = importedArchive else {
            return
        }
        loadTest(for: archive, selectedEntries: selectedEntries, password: nil)
    }

    func retryTestWithPassword(selectedEntries: [ArchiveEntrySummary]) {
        guard let archive = importedArchive else {
            return
        }
        let password = testPasswordInput.isEmpty ? nil : testPasswordInput
        testPasswordInput = ""
        loadTest(for: archive, selectedEntries: selectedEntries, password: password)
    }

    func cleanupActivePreview() {
        guard let activePreviewCleanupRoot else {
            return
        }
        try? FileManager.default.removeItem(at: activePreviewCleanupRoot)
        self.activePreviewCleanupRoot = nil
        previewDocument = nil
        if case .ready = previewState {
            previewState = .idle
        }
    }

    private func loadListing(for archive: ImportedArchive, password: String?) {
        listingGeneration += 1
        let currentListingGeneration = listingGeneration
        selectedEntryIds.removeAll()
        clearPreviewState()
        clearTestState()
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

    private func loadPreview(
        for archive: ImportedArchive,
        entry: ArchiveEntrySummary,
        password: String?
    ) {
        previewGeneration += 1
        let currentPreviewGeneration = previewGeneration
        cleanupActivePreview()
        previewDocument = nil
        previewPasswordInput = ""
        previewState = .loading(entry)
        let previewLoader = previewLoader
        Task {
            let state = await Task.detached(priority: .userInitiated) {
                previewLoader.materialize(archive: archive, entry: entry, password: password)
            }.value
            guard currentPreviewGeneration == previewGeneration, importedArchive?.id == archive.id else {
                return
            }
            previewState = state
            if case .ready(let summary) = state {
                activePreviewCleanupRoot = URL(fileURLWithPath: summary.cleanupRoot)
                previewDocument = PreviewDocument(url: URL(fileURLWithPath: summary.previewPath))
            }
        }
    }

    private func loadTest(
        for archive: ImportedArchive,
        selectedEntries: [ArchiveEntrySummary],
        password: String?
    ) {
        testGeneration += 1
        let currentTestGeneration = testGeneration
        testPasswordInput = ""
        testState = .loading(selectedEntries.count)
        let testLoader = testLoader
        Task {
            let state = await Task.detached(priority: .userInitiated) {
                testLoader.test(archive: archive, selectedEntries: selectedEntries, password: password)
            }.value
            guard currentTestGeneration == testGeneration, importedArchive?.id == archive.id else {
                return
            }
            testState = state
        }
    }

    private func clearPreviewState() {
        previewGeneration += 1
        cleanupActivePreview()
        previewDocument = nil
        previewPasswordInput = ""
        previewState = .idle
    }

    private func clearTestState() {
        testGeneration += 1
        testPasswordInput = ""
        testState = .idle
    }
}

#Preview {
    ContentView()
}
