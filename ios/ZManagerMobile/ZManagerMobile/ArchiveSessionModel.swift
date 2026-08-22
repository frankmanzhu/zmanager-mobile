import Foundation

/// Cross-cutting session state: the imported archive, its listing, nested
/// navigation, recovery, and shared status messages. Everything else in the
/// app reads or resets against this, which is why it lives in one place
/// instead of being split per feature. Owns the `ArchiveExtractionCoordinator`
/// and `ArchiveCreationCoordinator` instances that `ArchiveExtractionModel`
/// and `ArchiveCreationModel` also use, so recovery (which iOS exposes via
/// the extraction coordinator, unlike Android's separate recovery store) and
/// job planning share the same underlying job state. See Track 7 in
/// docs/mobile-code-health-remediation-plan.md.
@MainActor
final class ArchiveSessionModel: ObservableObject {
    @Published var importedArchive: ImportedArchive?
    @Published var errorMessage: String?
    @Published var isImporting = false
    @Published var listingState: ArchiveListingState = .idle
    @Published var passwordInput = ""
    @Published var entrySearchQuery = ""
    @Published var selectedEntryIds = Set<String>()
    // True only when the user explicitly chose "Select all" with no active
    // search filter. extractionSelectedPaths reads this rather than
    // inferring "the whole archive" from set equality against
    // summary.entries, since summary.entries is no longer capped at 50 and a
    // window/search can make "every entry currently selected" a real proper
    // subset. Mirrors Android's selectedEverything. See Track 3 in
    // docs/mobile-code-health-remediation-plan.md.
    @Published var selectedEverything = false
    @Published var operationReportMessage: String?
    @Published var defaultExtractionDestinationLabel = "App storage"
    @Published var recoveryRecords = [ArchiveRecoveryRecord]()
    @Published private var _nestedOpenError: String?

    let extractionCoordinator: ArchiveExtractionCoordinator
    let creationCoordinator: ArchiveCreationCoordinator

    let importStore: ArchiveImportStore
    private let listingLoader: ArchiveListingLoader
    private let destinationPreferences: ArchiveDestinationPreferences
    private let sharedImportStore: SharedImportStore
    private let archiveSessions = ArchiveSessionStack()
    private var pendingAutomationAction: ArchiveAutomationAction?
    // Debug/device-E2E pacing only; archive work remains Rust-owned. Shared
    // between import (which sets this ahead of a fixture-driven extraction)
    // and extraction planning (which reads it), same as Android's
    // debugJobPacer. Not private: ArchiveExtractionModel reads and clears it.
    var debugJobPacer: any JobPacer = NoOpJobPacer()
    private var importGeneration = 0
    private var listingGeneration = 0

    init(
        importStore: ArchiveImportStore = ArchiveImportStore(),
        listingLoader: ArchiveListingLoader = ArchiveListingLoader(),
        extractionCoordinator: ArchiveExtractionCoordinator = ArchiveExtractionCoordinator(),
        creationCoordinator: ArchiveCreationCoordinator = ArchiveCreationCoordinator(),
        destinationPreferences: ArchiveDestinationPreferences = ArchiveDestinationPreferences(),
        sharedImportStore: SharedImportStore = SharedImportStore()
    ) {
        self.importStore = importStore
        self.listingLoader = listingLoader
        self.extractionCoordinator = extractionCoordinator
        self.creationCoordinator = creationCoordinator
        self.destinationPreferences = destinationPreferences
        self.sharedImportStore = sharedImportStore
        self.defaultExtractionDestinationLabel = defaultExtractionDestination().label
        self.recoveryRecords = extractionCoordinator.recoveries()
    }

    var archiveBreadcrumbs: [String] {
        archiveSessions.sessions.map(\.archive.displayName)
    }

    var nestedOpenError: String? {
        get { _nestedOpenError }
    }

    func clearSessionSecrets() {
        passwordInput = ""
    }

    func toggleEntrySelected(_ entry: ArchiveEntrySummary) {
        selectedEverything = false
        if selectedEntryIds.contains(entry.id) {
            selectedEntryIds.remove(entry.id)
        } else {
            selectedEntryIds.insert(entry.id)
        }
    }

    func selectEntries(_ entries: [ArchiveEntrySummary]) {
        selectedEverything = false
        selectedEntryIds.formUnion(entries.map(\.id))
    }

    func selectEverything(_ summary: ArchiveListingSummary) {
        selectedEntryIds = Set(summary.entries.map(\.id))
        selectedEverything = true
    }

    func clearSelection() {
        selectedEverything = false
        selectedEntryIds.removeAll()
    }

    func defaultExtractionDestination() -> ExtractionDestination {
        destinationPreferences.defaultExtractionDestination(
            appStorage: extractionCoordinator.appStorageDestination().rootURL
        )
    }

    func setDefaultExtractionDestination(_ destination: ExtractionDestination) {
        destinationPreferences.setExtractionDestination(destination)
        defaultExtractionDestinationLabel = defaultExtractionDestination().label
    }

    func resetDefaultExtractionDestination() {
        destinationPreferences.resetExtractionDestination()
        defaultExtractionDestinationLabel = defaultExtractionDestination().label
    }

    func refreshRecoveryRecords() {
        recoveryRecords = extractionCoordinator.recoveries()
    }

    func discardRecovery(_ record: ArchiveRecoveryRecord, onExtractionRecoveryCleared: (UUID) -> Void) {
        extractionCoordinator.discardRecovery(record)
        refreshRecoveryRecords()
        onExtractionRecoveryCleared(record.id)
    }

    func retryRecovery(
        _ record: ArchiveRecoveryRecord,
        onExtractionRecoveryCleared: (UUID) -> Void,
        onPlanExtraction: (_ selectedEntries: [ArchiveEntrySummary], _ destination: ExtractionDestination) -> Void
    ) {
        guard let archive = importedArchive,
              archive.localPath == record.archivePath,
              case .ready(let summary) = listingState else {
            errorMessage = "Import \(record.archiveDisplayName) again to retry the retained extraction."
            return
        }
        let selectedEntries = record.selectedPaths.isEmpty
            ? summary.entries
            : summary.entries.filter { record.selectedPaths.contains($0.path) }
        discardRecovery(record, onExtractionRecoveryCleared: onExtractionRecoveryCleared)
        onPlanExtraction(selectedEntries, defaultExtractionDestination())
    }

    func exportRecovery(_ record: ArchiveRecoveryRecord) -> [URL] {
        extractionCoordinator.recoveryFiles(record)
    }

    func handleFileImporterResult(
        _ result: Result<[URL], Error>,
        onImportStarted: @escaping () -> Void,
        onAutomationExtract: @escaping ([ArchiveEntrySummary], ExtractionDestination) -> Void = { _, _ in },
        onAutomationVerify: @escaping ([ArchiveEntrySummary]) -> Void = { _ in }
    ) {
        switch result {
        case .success(let urls):
            guard !urls.isEmpty else {
                errorMessage = ArchiveImportError.emptySelection.localizedDescription
                return
            }
            importExternalURLs(
                urls,
                onImportStarted: onImportStarted,
                onAutomationExtract: onAutomationExtract,
                onAutomationVerify: onAutomationVerify
            )
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    func importExternalURL(
        _ url: URL,
        onImportStarted: @escaping () -> Void,
        onAutomationExtract: @escaping ([ArchiveEntrySummary], ExtractionDestination) -> Void = { _, _ in },
        onAutomationVerify: @escaping ([ArchiveEntrySummary]) -> Void = { _ in }
    ) {
        importExternalURLs(
            [url],
            onImportStarted: onImportStarted,
            onAutomationExtract: onAutomationExtract,
            onAutomationVerify: onAutomationVerify
        )
    }

    func handleAutomationURL(
        _ url: URL,
        onImportStarted: @escaping () -> Void,
        onAutomationExtract: @escaping ([ArchiveEntrySummary], ExtractionDestination) -> Void,
        onAutomationVerify: @escaping ([ArchiveEntrySummary]) -> Void,
        onCreateFiles: (Result<[URL], Error>) -> Void
    ) {
        guard url.scheme?.lowercased() == "zmanager" else {
            importExternalURL(
                url,
                onImportStarted: onImportStarted,
                onAutomationExtract: onAutomationExtract,
                onAutomationVerify: onAutomationVerify
            )
            return
        }
        do {
            let request = try ArchiveAutomationParser.parse(url)
            switch request.action {
            case .create:
                onCreateFiles(.success(request.sourceURLs))
            case .importShared:
                guard let identifier = request.sharedIdentifier else {
                    throw ArchiveAutomationError.missingSharedImport
                }
                let batch = try sharedImportStore.stageIncoming(identifier: identifier)
                importExternalURLs(
                    batch.sourceURLs,
                    cleanupRoot: batch.cleanupRoot,
                    onImportStarted: onImportStarted,
                    onAutomationExtract: onAutomationExtract,
                    onAutomationVerify: onAutomationVerify
                )
            case .open, .extract, .verify:
                if let archiveURL = request.archiveURL {
                    importExternalURLs(
                        [archiveURL],
                        pendingAction: request.action == .open ? nil : request.action,
                        onImportStarted: onImportStarted,
                        onAutomationExtract: onAutomationExtract,
                        onAutomationVerify: onAutomationVerify
                    )
                }
            }
        } catch {
            // Do not surface the URL or any rejected credential value.
            errorMessage = error.localizedDescription
        }
    }

    func importExternalURLs(
        _ urls: [URL],
        pendingAction: ArchiveAutomationAction? = nil,
        cleanupRoot: URL? = nil,
        onImportStarted: @escaping () -> Void,
        onAutomationExtract: @escaping ([ArchiveEntrySummary], ExtractionDestination) -> Void = { _, _ in },
        onAutomationVerify: @escaping ([ArchiveEntrySummary]) -> Void = { _ in }
    ) {
        importGeneration += 1
        listingGeneration += 1
        pendingAutomationAction = pendingAction
        archiveSessions.clear()
        _nestedOpenError = nil
        onImportStarted()
        let currentImportGeneration = importGeneration
        isImporting = true
        errorMessage = nil
        importedArchive = nil
        listingState = .idle
        passwordInput = ""
        entrySearchQuery = ""
        selectedEntryIds.removeAll()
        selectedEverything = false

        Task {
            defer {
                if let cleanupRoot {
                    try? FileManager.default.removeItem(at: cleanupRoot)
                }
            }
            do {
                let importStore = importStore
                let imported = try await Task.detached(priority: .userInitiated) {
                    try importStore.importArchives(from: urls)
                }.value
                guard currentImportGeneration == importGeneration else {
                    return
                }
                importedArchive = imported
                loadListing(
                    for: imported,
                    password: nil,
                    onListingLoadStarted: onImportStarted,
                    onAutomationExtract: onAutomationExtract,
                    onAutomationVerify: onAutomationVerify
                )
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

    func importMaestroFixture(
        onImportStarted: @escaping () -> Void,
        onAutomationExtract: @escaping ([ArchiveEntrySummary], ExtractionDestination) -> Void = { _, _ in },
        onAutomationVerify: @escaping ([ArchiveEntrySummary]) -> Void = { _ in }
    ) {
        importMaestroFixture(
            named: "maestro-files.zip",
            onImportStarted: onImportStarted,
            onAutomationExtract: onAutomationExtract,
            onAutomationVerify: onAutomationVerify
        )
    }

    func importMaestroFixture(
        named fixtureName: String,
        companionNames: [String] = [],
        pendingAction: ArchiveAutomationAction? = nil,
        onImportStarted: @escaping () -> Void,
        onAutomationExtract: @escaping ([ArchiveEntrySummary], ExtractionDestination) -> Void = { _, _ in },
        onAutomationVerify: @escaping ([ArchiveEntrySummary]) -> Void = { _ in }
    ) {
        let fixtureURLs = ([fixtureName] + companionNames).compactMap(Self.maestroFixtureURL)
        guard fixtureURLs.count == companionNames.count + 1 else {
            errorMessage = "The Maestro fixture is not available in this build."
            return
        }
        importExternalURLs(
            fixtureURLs,
            pendingAction: pendingAction,
            onImportStarted: onImportStarted,
            onAutomationExtract: onAutomationExtract,
            onAutomationVerify: onAutomationVerify
        )
    }

    private static func maestroFixtureURL(named fixtureName: String) -> URL? {
        if let url = Bundle.main.url(forResource: fixtureName, withExtension: nil) {
            return url
        }
        // Foundation can fail to resolve bundle resources whose names contain
        // multiple compression suffixes (for example `tar.lz4`). The fixture
        // names are fixed DEBUG resources, so an exact bundle-root fallback is
        // safe and avoids silently turning a supported format into a no-op.
        let exactURL = Bundle.main.bundleURL.appendingPathComponent(fixtureName)
        return FileManager.default.fileExists(atPath: exactURL.path) ? exactURL : nil
    }

    func retryListingWithPassword(
        onListingLoadStarted: @escaping () -> Void,
        onAutomationExtract: @escaping ([ArchiveEntrySummary], ExtractionDestination) -> Void = { _, _ in },
        onAutomationVerify: @escaping ([ArchiveEntrySummary]) -> Void = { _ in }
    ) {
        guard let archive = importedArchive else {
            return
        }
        let password = passwordInput.isEmpty ? nil : passwordInput
        passwordInput = ""
        loadListing(
            for: archive,
            password: password,
            onListingLoadStarted: onListingLoadStarted,
            onAutomationExtract: onAutomationExtract,
            onAutomationVerify: onAutomationVerify
        )
    }

    private func loadListing(
        for archive: ImportedArchive,
        password: String?,
        onListingLoadStarted: @escaping () -> Void,
        onAutomationExtract: @escaping ([ArchiveEntrySummary], ExtractionDestination) -> Void = { _, _ in },
        onAutomationVerify: @escaping ([ArchiveEntrySummary]) -> Void = { _ in }
    ) {
        listingGeneration += 1
        let currentListingGeneration = listingGeneration
        selectedEntryIds.removeAll()
        selectedEverything = false
        onListingLoadStarted()
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
            if case .ready(let summary) = state {
                let action = pendingAutomationAction
                pendingAutomationAction = nil
                switch action {
                case .extract:
                    onAutomationExtract(summary.entries, defaultExtractionDestination())
                case .verify:
                    onAutomationVerify(summary.entries)
                default:
                    break
                }
            }
        }
    }

    func openNestedArchive(
        entry: ArchiveEntrySummary,
        previewLoader: ArchivePreviewLoader,
        onListingLoadStarted: @escaping () -> Void
    ) {
        guard let parent = importedArchive, NestedArchiveSupport.canOpen(entry) else { return }
        _nestedOpenError = nil
        Task {
            let state = await Task.detached(priority: .userInitiated) {
                previewLoader.materialize(archive: parent, entry: entry, password: nil)
            }.value
            switch state {
            case .ready(let summary):
                let childURL = URL(fileURLWithPath: summary.previewPath)
                let values = try? childURL.resourceValues(forKeys: [.fileSizeKey])
                let child = ImportedArchive(
                    id: UUID(),
                    displayName: entry.displayName,
                    localPath: summary.previewPath,
                    byteSize: values?.fileSize.map(Int64.init),
                    importedAt: Date()
                )
                if archiveSessions.current?.archive.id != parent.id {
                    _ = archiveSessions.push(archive: parent)
                }
                _ = archiveSessions.push(
                    archive: child,
                    parentEntryPath: entry.path,
                    cleanupRoot: URL(fileURLWithPath: summary.cleanupRoot)
                )
                importedArchive = child
                loadListing(for: child, password: nil, onListingLoadStarted: onListingLoadStarted)
            case .passwordRequired(_, let error):
                _nestedOpenError = error.message
            case .failed(_, let error):
                _nestedOpenError = error.message
            default:
                _nestedOpenError = "Unable to open that nested archive."
            }
        }
    }

    func navigateBackFromNested(onListingLoadStarted: @escaping () -> Void) {
        guard archiveSessions.current != nil else { return }
        _ = archiveSessions.pop()
        guard let parent = archiveSessions.current?.archive else {
            importedArchive = nil
            listingState = .idle
            return
        }
        _nestedOpenError = nil
        importedArchive = parent
        loadListing(for: parent, password: nil, onListingLoadStarted: onListingLoadStarted)
    }

    func saveExtractionReport(entries: UInt64, destination: String) {
        let file = ArchiveOperationReportStore.save(
            operation: "extract",
            subject: importedArchive?.displayName ?? "archive",
            status: "completed",
            message: "Extraction complete",
            destination: destination,
            entries: entries,
            verified: nil
        )
        operationReportMessage = "Saved operation report: \(file.lastPathComponent)"
    }

    func saveCreationReport(outputPath: String, verified: Bool) {
        let file = ArchiveOperationReportStore.save(
            operation: "create",
            subject: URL(fileURLWithPath: outputPath).lastPathComponent,
            status: "completed",
            message: "Archive creation complete",
            destination: outputPath,
            entries: nil,
            verified: verified
        )
        operationReportMessage = "Saved operation report: \(file.lastPathComponent)"
    }
}
