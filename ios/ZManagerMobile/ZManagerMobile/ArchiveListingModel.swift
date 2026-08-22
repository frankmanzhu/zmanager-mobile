import Foundation

/// Listing browser state: search/sort/view-mode, selection, and the preview
/// and test panels. Reads the current archive and listing through [session]
/// rather than duplicating them. See Track 7 in
/// docs/mobile-code-health-remediation-plan.md.
@MainActor
final class ArchiveListingModel: ObservableObject {
    @Published var entrySort: ArchiveEntrySort = .pathAscending
    @Published var entryViewMode: ArchiveEntryViewMode = .folders
    @Published var previewState: ArchivePreviewState = .idle
    @Published var previewPasswordInput = ""
    @Published var previewDocument: PreviewDocument?
    @Published var testState: ArchiveTestState = .idle
    @Published var testPasswordInput = ""
    // How many of the filtered/sorted entries are rendered. Raised by
    // "Load more"; reset whenever a new listing loads. Mirrors Android's
    // listingWindowSize. See Track 3 in
    // docs/mobile-code-health-remediation-plan.md.
    @Published var listingWindowSize = ArchiveListingModel.defaultListingWindowSize

    static let defaultListingWindowSize = 200
    private static let listingWindowPageSize = 200

    let previewLoader: ArchivePreviewLoader
    private let testLoader: ArchiveTestLoader
    private unowned let session: ArchiveSessionModel
    private var previewGeneration = 0
    private var testGeneration = 0
    private var activePreviewCleanupRoot: URL?

    init(
        session: ArchiveSessionModel,
        previewLoader: ArchivePreviewLoader = ArchivePreviewLoader(),
        testLoader: ArchiveTestLoader = ArchiveTestLoader()
    ) {
        self.session = session
        self.previewLoader = previewLoader
        self.testLoader = testLoader
    }

    func clearTransientSecrets() {
        previewPasswordInput = ""
        testPasswordInput = ""
    }

    func loadMoreListingEntries() {
        listingWindowSize += Self.listingWindowPageSize
    }

    func resetListingWindow() {
        listingWindowSize = Self.defaultListingWindowSize
    }

    var currentSelectedEntries: [ArchiveEntrySummary] {
        guard case .ready(let summary) = session.listingState else { return [] }
        let selected = summary.selectedEntries(selectedEntryIds: session.selectedEntryIds)
        return selected.isEmpty ? summary.entries : selected
    }

    func startPreview(entry: ArchiveEntrySummary) {
        guard let archive = session.importedArchive else {
            return
        }
        loadPreview(for: archive, entry: entry, password: nil)
    }

    func retryPreviewWithPassword(entry: ArchiveEntrySummary) {
        guard let archive = session.importedArchive else {
            return
        }
        let password = previewPasswordInput.isEmpty ? nil : previewPasswordInput
        previewPasswordInput = ""
        loadPreview(for: archive, entry: entry, password: password)
    }

    func startTest(selectedEntries: [ArchiveEntrySummary]) {
        guard let archive = session.importedArchive else {
            return
        }
        loadTest(for: archive, selectedEntries: selectedEntries, password: nil)
    }

    func retryTestWithPassword(selectedEntries: [ArchiveEntrySummary]) {
        guard let archive = session.importedArchive else {
            return
        }
        let password = testPasswordInput.isEmpty ? nil : testPasswordInput
        testPasswordInput = ""
        loadTest(for: archive, selectedEntries: selectedEntries, password: password)
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
            guard currentPreviewGeneration == previewGeneration, session.importedArchive?.id == archive.id else {
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
            guard currentTestGeneration == testGeneration, session.importedArchive?.id == archive.id else {
                return
            }
            testState = state
        }
    }

    func clearPreviewState() {
        previewGeneration += 1
        cleanupActivePreview()
        previewDocument = nil
        previewPasswordInput = ""
        previewState = .idle
    }

    func clearTestState() {
        testGeneration += 1
        testPasswordInput = ""
        testState = .idle
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
}
