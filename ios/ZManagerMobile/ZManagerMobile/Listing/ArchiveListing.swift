import QuickLook
import CryptoKit
import Network
import PhotosUI
import Security
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ArchiveListingPanel: View {
    let state: ArchiveListingState
    @Binding var password: String
    @Binding var searchQuery: String
    @Binding var sort: ArchiveEntrySort
    @Binding var viewMode: ArchiveEntryViewMode
    let windowSize: Int
    let onLoadMore: () -> Void
    let onWindowReset: () -> Void
    @Binding var selectedEntryIds: Set<String>
    @Binding var selectedEverything: Bool
    let onSelectEverything: (ArchiveListingSummary) -> Void
    let previewState: ArchivePreviewState
    @Binding var previewPassword: String
    let testState: ArchiveTestState
    @Binding var testPassword: String
    let onSubmitPassword: () -> Void
    let onPreviewEntry: (ArchiveEntrySummary) -> Void
    let onOpenNestedArchive: (ArchiveEntrySummary) -> Void
    let onSubmitPreviewPassword: (ArchiveEntrySummary) -> Void
    let onTestEntries: ([ArchiveEntrySummary]) -> Void
    let onSubmitTestPassword: ([ArchiveEntrySummary]) -> Void
    let extractionState: ArchiveExtractionState
    @Binding var extractionPassword: String
    let onExtractEntries: ([ArchiveEntrySummary]) -> Void
    let onChooseDestination: () -> Void
    let onStartExtraction: (ExtractionReview) -> Void
    let onCancelExtraction: () -> Void
    let onRetryExtractionPassword: ([ArchiveEntrySummary]) -> Void
    let repackagingState: ArchiveRepackagingState
    @Binding var repackagingPassword: String
    let onRepackageEntries: ([ArchiveEntrySummary]) -> Void
    let onRetryRepackagingWithPassword: ([ArchiveEntrySummary], String) -> Void
    let onShareRepackagedOutput: ([String]) -> Void
    let onStartRepackaging: () -> Void
    let onCancelRepackaging: () -> Void

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
                windowSize: windowSize,
                onLoadMore: onLoadMore,
                onWindowReset: onWindowReset,
                selectedEntryIds: $selectedEntryIds,
                selectedEverything: $selectedEverything,
                onSelectEverything: onSelectEverything,
                previewState: previewState,
                previewPassword: $previewPassword,
                testState: testState,
                testPassword: $testPassword,
                onPreviewEntry: onPreviewEntry,
                onOpenNestedArchive: onOpenNestedArchive,
                onSubmitPreviewPassword: onSubmitPreviewPassword,
                onTestEntries: onTestEntries,
                onSubmitTestPassword: onSubmitTestPassword,
                extractionState: extractionState,
                extractionPassword: $extractionPassword,
                onExtractEntries: onExtractEntries,
                onChooseDestination: onChooseDestination,
                onStartExtraction: onStartExtraction,
                onCancelExtraction: onCancelExtraction,
                onRetryExtractionPassword: onRetryExtractionPassword,
                repackagingState: repackagingState,
                repackagingPassword: $repackagingPassword,
                onRepackageEntries: onRepackageEntries,
                onRetryRepackagingWithPassword: onRetryRepackagingWithPassword,
                onShareRepackagedOutput: onShareRepackagedOutput,
                onStartRepackaging: onStartRepackaging,
                onCancelRepackaging: onCancelRepackaging
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
                StableSecureInputField("Password", text: $password)
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
    let windowSize: Int
    let onLoadMore: () -> Void
    let onWindowReset: () -> Void
    @Binding var selectedEntryIds: Set<String>
    @Binding var selectedEverything: Bool
    let onSelectEverything: (ArchiveListingSummary) -> Void
    let previewState: ArchivePreviewState
    @Binding var previewPassword: String
    let testState: ArchiveTestState
    @Binding var testPassword: String
    let onPreviewEntry: (ArchiveEntrySummary) -> Void
    let onOpenNestedArchive: (ArchiveEntrySummary) -> Void
    let onSubmitPreviewPassword: (ArchiveEntrySummary) -> Void
    let onTestEntries: ([ArchiveEntrySummary]) -> Void
    let onSubmitTestPassword: ([ArchiveEntrySummary]) -> Void
    let extractionState: ArchiveExtractionState
    @Binding var extractionPassword: String
    let onExtractEntries: ([ArchiveEntrySummary]) -> Void
    let onChooseDestination: () -> Void
    let onStartExtraction: (ExtractionReview) -> Void
    let onCancelExtraction: () -> Void
    let onRetryExtractionPassword: ([ArchiveEntrySummary]) -> Void
    let repackagingState: ArchiveRepackagingState
    @Binding var repackagingPassword: String
    let onRepackageEntries: ([ArchiveEntrySummary]) -> Void
    let onRetryRepackagingWithPassword: ([ArchiveEntrySummary], String) -> Void
    let onShareRepackagedOutput: ([String]) -> Void
    let onStartRepackaging: () -> Void
    let onCancelRepackaging: () -> Void

    private var filteredEntries: [ArchiveEntrySummary] {
        summary.filteredSortedEntries(searchQuery: searchQuery, sort: sort)
    }

    private var windowedEntries: [ArchiveEntrySummary] {
        Array(filteredEntries.prefix(windowSize))
    }

    private var groups: [ArchiveEntryGroup] {
        windowedEntries.grouped(viewMode: viewMode)
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
                .onChange(of: searchQuery) { _ in onWindowReset() }
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
            if windowedEntries.count < filteredEntries.count {
                HStack {
                    Text("Showing \(windowedEntries.count) of \(filteredEntries.count) entries")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Load more", action: onLoadMore)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("\(selectedEntries.count) selected")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Select Visible") {
                    selectedEverything = false
                    selectedEntryIds.formUnion(groups.flatMap { $0.entries }.map { $0.id })
                }
                .disabled(groups.allSatisfy { $0.entries.isEmpty })
                Button("Select all \(filteredEntries.count)") {
                    if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        onSelectEverything(summary)
                    } else {
                        selectedEverything = false
                        selectedEntryIds.formUnion(filteredEntries.map(\.id))
                    }
                }
                .disabled(filteredEntries.isEmpty)
                Button("Clear") {
                    selectedEverything = false
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
                Button("Extract") {
                    onExtractEntries(selectedEntries.isEmpty ? summary.entries : selectedEntries)
                }
                .disabled(extractionState.isBusy)
                Button("Create archive from selection") {
                    onRepackageEntries(selectedEntries)
                }
                .disabled(selectedEntries.isEmpty || repackagingState.isBusy)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
            ArchiveExtractionPanel(
                state: extractionState,
                selectedEntries: selectedEntries.isEmpty ? summary.entries : selectedEntries,
                password: $extractionPassword,
                onChooseDestination: onChooseDestination,
                onStart: onStartExtraction,
                onCancel: onCancelExtraction,
                onRetryWithPassword: onRetryExtractionPassword
            )
            ArchiveRepackagingPanel(
                state: repackagingState,
                password: $repackagingPassword,
                onRetryWithPassword: onRetryRepackagingWithPassword,
                onShareOutput: onShareRepackagedOutput,
                onStart: onStartRepackaging,
                onCancel: onCancelRepackaging
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
                            HStack(alignment: .top, spacing: 8) {
                                Button {
                                    selectedEverything = false
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
                                    }
                                }
                                .buttonStyle(.plain)
                                Spacer()
                                if NestedArchiveSupport.canOpen(entry) {
                                    Button("Open") { onOpenNestedArchive(entry) }
                                        .buttonStyle(.bordered)
                                }
                            }
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
                StableSecureInputField("Password", text: $password)
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
                StableSecureInputField("Password", text: $password)
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
    func filteredSortedEntries(searchQuery: String, sort: ArchiveEntrySort) -> [ArchiveEntrySummary] {
        entries
            .filter { $0.matches(searchQuery: searchQuery) }
            .sortedForBrowser(using: sort)
    }

    /// A caller that windows the listing should call `filteredSortedEntries`,
    /// `.prefix(windowSize)`, then `Array.grouped(viewMode:)` directly
    /// instead of this. This combined form (filter+sort+group over every
    /// entry, unwindowed) exists for callers, such as tests, that do not need
    /// to window. See Track 3 in docs/mobile-code-health-remediation-plan.md.
    func visibleGroups(
        searchQuery: String,
        sort: ArchiveEntrySort,
        viewMode: ArchiveEntryViewMode
    ) -> [ArchiveEntryGroup] {
        filteredSortedEntries(searchQuery: searchQuery, sort: sort).grouped(viewMode: viewMode)
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

extension Array where Element == ArchiveEntrySummary {
    func grouped(viewMode: ArchiveEntryViewMode) -> [ArchiveEntryGroup] {
        switch viewMode {
        case .list:
            return isEmpty ? [] : [
                ArchiveEntryGroup(id: "all", label: "All entries", entries: self)
            ]
        case .folders:
            let grouped = Dictionary(grouping: self) { entry in
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
    func planExtraction(
        path: String,
        destinationRoot: String,
        selectedPaths: [String],
        password: String?,
        collisionPolicy: ExtractionCollisionPolicy
    ) throws -> PlanExtractResult
    func startExtraction(
        path: String,
        destinationRoot: String,
        selectedPaths: [String],
        password: String?,
        collisionPolicy: ExtractionCollisionPolicy,
        planToken: String
    ) throws -> StartJobResult
    func pollJob(jobId: String, cursor: UInt64) throws -> PollJobEventsResult
    func cancelJob(jobId: String) throws
    func planCreation(request: PlanCreateRequest) throws -> PlanCreateResult
    func startCreation(request: StartCreateRequest) throws -> StartJobResult
}

extension ArchiveBridgeClient {
    func planExtraction(
        path: String,
        destinationRoot: String,
        selectedPaths: [String],
        password: String?,
        collisionPolicy: ExtractionCollisionPolicy
    ) throws -> PlanExtractResult {
        throw ArchiveExtractionError.unavailable
    }

    func startExtraction(
        path: String,
        destinationRoot: String,
        selectedPaths: [String],
        password: String?,
        collisionPolicy: ExtractionCollisionPolicy,
        planToken: String
    ) throws -> StartJobResult {
        throw ArchiveExtractionError.unavailable
    }

    func pollJob(jobId: String, cursor: UInt64) throws -> PollJobEventsResult {
        throw ArchiveExtractionError.unavailable
    }

    func cancelJob(jobId: String) throws {}

    func planCreation(request: PlanCreateRequest) throws -> PlanCreateResult {
        throw ArchiveCreationError.unavailable
    }

    func startCreation(request: StartCreateRequest) throws -> StartJobResult {
        throw ArchiveCreationError.unavailable
    }
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

    func planExtraction(
        path: String,
        destinationRoot: String,
        selectedPaths: [String],
        password: String?,
        collisionPolicy: ExtractionCollisionPolicy
    ) throws -> PlanExtractResult {
        try planExtract(
            request: PlanExtractRequest(
                archivePath: path,
                destinationRoot: destinationRoot,
                password: password,
                selectedPaths: selectedPaths,
                stripComponents: 0,
                collisionPolicy: collisionPolicy
            )
        )
    }

    func startExtraction(
        path: String,
        destinationRoot: String,
        selectedPaths: [String],
        password: String?,
        collisionPolicy: ExtractionCollisionPolicy,
        planToken: String
    ) throws -> StartJobResult {
        try startExtract(
            request: StartExtractRequest(
                archivePath: path,
                destinationRoot: destinationRoot,
                password: password,
                selectedPaths: selectedPaths,
                stripComponents: 0,
                collisionPolicy: collisionPolicy,
                planToken: planToken
            )
        )
    }

    func pollJob(jobId: String, cursor: UInt64) throws -> PollJobEventsResult {
        try pollJobEvents(request: PollJobEventsRequest(jobId: jobId, cursor: cursor))
    }

    func cancelJob(jobId: String) throws {
        _ = try ZManagerMobile.cancelJob(request: CancelJobRequest(jobId: jobId))
    }

    func planCreation(request: PlanCreateRequest) throws -> PlanCreateResult {
        try planCreate(request: request)
    }

    func startCreation(request: StartCreateRequest) throws -> StartJobResult {
        try startCreate(request: request)
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
        } catch ZmanagerGuiError.Bridge(
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
        } catch ZmanagerGuiError.Bridge(
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
        } catch ZmanagerGuiError.Bridge(
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
            entries: entries.enumerated().map { offset, entry in
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

