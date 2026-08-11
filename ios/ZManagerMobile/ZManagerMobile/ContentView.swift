import QuickLook
import CryptoKit
import Network
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var importModel = ArchiveImportModel()
    @State private var isFileImporterPresented = false
    @State private var isDestinationPickerPresented = false
    @State private var isCreationFilesImporterPresented = false
    @State private var isCreationFolderImporterPresented = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("ZManager")
                    .font(.largeTitle.weight(.semibold))

                Text("Open an archive, inspect its contents, then extract safely.")
                    .font(.body)
                    .foregroundStyle(.secondary)
#if DEBUG
                Button("Load nested fixture") {
                    importModel.importMaestroFixture(named: "maestro-nested.zip")
                }
                Button("Create debug folder archive") {
                    importModel.createDebugFixture()
                }
#endif
            }

            if let archive = importModel.importedArchive {
                if !importModel.archiveBreadcrumbs.isEmpty {
                    HStack {
                        Button("Back") { importModel.navigateBackFromNested() }
                        Text(importModel.archiveBreadcrumbs.joined(separator: " / "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
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
                onOpenNestedArchive: { importModel.openNestedArchive(entry: $0) },
                onSubmitPreviewPassword: { importModel.retryPreviewWithPassword(entry: $0) },
                onTestEntries: { importModel.startTest(selectedEntries: $0) },
                onSubmitTestPassword: { importModel.retryTestWithPassword(selectedEntries: $0) },
                extractionState: importModel.extractionState,
                extractionPassword: $importModel.extractionPasswordInput,
                onExtractEntries: { importModel.planExtraction(selectedEntries: $0) },
                onChooseDestination: { isDestinationPickerPresented = true },
                onStartExtraction: importModel.startExtraction,
                onCancelExtraction: importModel.cancelExtraction,
                onRetryExtractionPassword: { importModel.retryExtractionWithPassword(selectedEntries: $0) },
                repackagingState: importModel.repackagingState,
                onRepackageEntries: importModel.startRepackaging,
                onStartRepackaging: importModel.runRepackaging,
                onCancelRepackaging: importModel.cancelRepackaging
            )
            if let message = importModel.nestedOpenError {
                Text(message).foregroundStyle(.red)
            }

            ArchiveCreationPanel(
                state: importModel.creationState,
                format: importModel.creationFormat,
                password: importModel.creationPasswordInput,
                onPasswordChanged: { importModel.creationPasswordInput = $0 },
                onFormatChanged: { importModel.creationFormat = $0 },
                onChooseFiles: { isCreationFilesImporterPresented = true },
                onChooseFolder: { isCreationFolderImporterPresented = true },
                onStart: importModel.startCreation,
                onCancel: importModel.cancelCreation
            )
            LocalSendPanel(
                archive: importModel.importedArchive,
                state: importModel.localSendState,
                onDiscover: importModel.discoverLocalSendDevices,
                onSend: { importModel.sendCurrentArchive(to: $0) },
                onCancelSend: importModel.cancelLocalSend,
                onStartReceive: importModel.startLocalReceive,
                onStopReceive: importModel.stopLocalReceive
            )

            Spacer()

            HStack {
                Spacer()
#if DEBUG
                Button("Load Maestro fixture") {
                    importModel.importMaestroFixture()
                }
                .disabled(importModel.isImporting)
                Menu("Load test fixture") {
                    Button("ZIP fixture") {
                        importModel.importMaestroFixture(named: "maestro-files.zip")
                    }
                    Button("7z fixture") {
                        importModel.importMaestroFixture(named: "maestro-files.7z")
                    }
                    Button("TGZ fixture") {
                        importModel.importMaestroFixture(named: "maestro-files.tgz")
                    }
                    Button("TAR.ZST fixture") {
                        importModel.importMaestroFixture(named: "maestro-files.tar.zst")
                    }
                    Button("TZAP fixture") {
                        importModel.importMaestroFixture(named: "maestro-files.tzap")
                    }
                    Button("Nested ZIP fixture") {
                        importModel.importMaestroFixture(named: "maestro-nested.zip")
                    }
                    Button("Apple Archive fixture") {
                        importModel.importMaestroFixture(named: "maestro-files.aar")
                    }
                    Button("Split ZIP fixture") {
                        importModel.importMaestroFixture(
                            named: "maestro-split.zip",
                            companionNames: ["maestro-split.z01"]
                        )
                    }
                    Button("Split 7z fixture") {
                        importModel.importMaestroFixture(
                            named: "maestro-split.7z.001",
                            companionNames: ["maestro-split.7z.002"]
                        )
                    }
                    Button("Split TZAP fixture") {
                        importModel.importMaestroFixture(
                            named: "maestro-split.vol000.tzap",
                            companionNames: [
                                "maestro-split.vol001.tzap",
                                "maestro-split.vol002.tzap",
                                "maestro-split.vol003.tzap",
                                "maestro-split.vol004.tzap",
                                "maestro-split.vol005.tzap"
                            ]
                        )
                    }
                    Button("Multipart RAR fixture") {
                        importModel.importMaestroFixture(
                            named: "maestro-split-rar.part1.rar",
                            companionNames: [
                                "maestro-split-rar.part2.rar",
                                "maestro-split-rar.part3.rar",
                                "maestro-split-rar.part4.rar",
                                "maestro-split-rar.part5.rar"
                            ]
                        )
                    }
                    Button("DEB fixture") {
                        importModel.importMaestroFixture(named: "maestro-files.deb")
                    }
                    Button("CAB fixture") {
                        importModel.importMaestroFixture(named: "maestro-files.cab")
                    }
                }
                .disabled(importModel.isImporting)
#endif
                Button(importModel.isImporting ? "Importing" : "Open Archive") {
                    isFileImporterPresented = true
                }
                .disabled(importModel.isImporting)
                .buttonStyle(.borderedProminent)
            }
        }
    }
        .padding(24)
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: ArchiveImportStore.allowedContentTypes,
            allowsMultipleSelection: true
        ) { result in
            importModel.handleFileImporterResult(result)
        }
        .fileImporter(
            isPresented: $isDestinationPickerPresented,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                importModel.planExtraction(selectedEntries: importModel.currentSelectedEntries, destination: .folder(url))
            }
        }
        .fileImporter(
            isPresented: $isCreationFilesImporterPresented,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            importModel.handleCreationFilesResult(result)
        }
        .fileImporter(
            isPresented: $isCreationFolderImporterPresented,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            importModel.handleCreationFolderResult(result)
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

struct StagedCreationSources {
    let root: URL
    let sourcePaths: [String]
}

/// Copies security-scoped document-provider URLs into app-owned temporary storage
/// before the Rust create bridge is called.
struct ArchiveCreationSourceStager {
    let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func stageFiles(_ urls: [URL]) throws -> StagedCreationSources {
        guard !urls.isEmpty else { throw ArchiveImportError.emptySelection }
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("ZManagerMobile/CreationSources/\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            var paths: [String] = []
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let target = uniqueTarget(root: root, name: ArchiveImportStore.sanitizedDisplayName(url.lastPathComponent))
                try fileManager.copyItem(at: url, to: target)
                paths.append(target.path)
            }
            return StagedCreationSources(root: root, sourcePaths: paths)
        } catch {
            try? fileManager.removeItem(at: root)
            throw error
        }
    }

    func stageFolder(_ url: URL) throws -> StagedCreationSources {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("ZManagerMobile/CreationSources/\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            let target = root.appendingPathComponent(ArchiveImportStore.sanitizedDisplayName(url.lastPathComponent), isDirectory: true)
            try fileManager.copyItem(at: url, to: target)
            return StagedCreationSources(root: root, sourcePaths: [target.path])
        } catch {
            try? fileManager.removeItem(at: root)
            throw error
        }
    }

    func discard(_ staged: StagedCreationSources) {
        try? fileManager.removeItem(at: staged.root)
    }

    /// Deterministic app-owned source used by debug/device E2E only.
    func stageDebugFixture() throws -> StagedCreationSources {
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("ZManagerMobile/CreationSources/\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("fixture-folder", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            try Data("ZManager Mobile creation fixture\n".utf8)
                .write(to: folder.appendingPathComponent("readme.txt"))
            let nested = folder.appendingPathComponent("nested", isDirectory: true)
            try fileManager.createDirectory(at: nested, withIntermediateDirectories: true)
            try Data([0, 1, 2, 3, 4, 5]).write(to: nested.appendingPathComponent("data.bin"))
            return StagedCreationSources(root: root, sourcePaths: [folder.path])
        } catch {
            try? fileManager.removeItem(at: root)
            throw error
        }
    }

    private func uniqueTarget(root: URL, name: String) -> URL {
        let safeName = name.isEmpty ? "file" : name
        var candidate = root.appendingPathComponent(safeName)
        var index = 1
        while fileManager.fileExists(atPath: candidate.path) {
            let base = candidate.deletingPathExtension().lastPathComponent
            let ext = candidate.pathExtension
            let next = ext.isEmpty ? "\(base) (\(index))" : "\(base) (\(index)).\(ext)"
            candidate = root.appendingPathComponent(next)
            index += 1
        }
        return candidate
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
    let onRepackageEntries: ([ArchiveEntrySummary]) -> Void
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
                selectedEntryIds: $selectedEntryIds,
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
                onRepackageEntries: onRepackageEntries,
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
    let onRepackageEntries: ([ArchiveEntrySummary]) -> Void
    let onStartRepackaging: () -> Void
    let onCancelRepackaging: () -> Void

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
                Button("Extract") {
                    onExtractEntries(selectedEntries.isEmpty ? summary.entries : selectedEntries)
                }
                .disabled(extractionState.isBusy)
                Button("Create archive from selection") {
                    onRepackageEntries(selectedEntries)
                }
                .disabled(selectedEntries.isEmpty || repackagingState.isBusy)
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

struct ArchiveRepackagingPanel: View {
    let state: ArchiveRepackagingState
    let onStart: () -> Void
    let onCancel: () -> Void

    var body: some View {
        switch state {
        case .idle:
            EmptyView()
        case .planning:
            Text("Preparing repackaging plan")
                .font(.subheadline)
        case .review(let review):
            VStack(alignment: .leading, spacing: 4) {
                Text("Ready to repackage \(review.request.selectedPaths.count) selected path(s)")
                    .font(.subheadline)
                Text("Output: \(review.request.destinationArchivePath)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Format: \(String(describing: review.request.format)); verification enabled")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(review.extractionReview.plan.warnings, id: \.message) { warning in
                    Text(warning.message)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                HStack {
                    Button("Start", action: onStart)
                    Button("Cancel", action: onCancel)
                }
            }
        case .running(_, let message):
            HStack {
                Text(message).font(.subheadline)
                Spacer()
                Button("Cancel", action: onCancel)
            }
        case .completed(let outputPath, let verified):
            VStack(alignment: .leading, spacing: 2) {
                Text("Created \(outputPath)").font(.subheadline)
                Text(verified ? "Verified" : "Created without verification")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .cancelled:
            Text("Repackaging cancelled").font(.subheadline)
        case .failed(let message):
            Text(message).font(.subheadline).foregroundStyle(.red)
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
        try importArchives(from: [url])
    }

    func importArchives(from urls: [URL]) throws -> ImportedArchive {
        guard !urls.isEmpty else {
            throw ArchiveImportError.emptySelection
        }
        let scopedURLs = urls.map { url in
            (url, url.startAccessingSecurityScopedResource())
        }
        defer {
            scopedURLs.forEach { url, didStartAccessing in
                if didStartAccessing {
                    url.stopAccessingSecurityScopedResource()
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

enum ArchiveRepackagingState {
    case idle
    case planning
    case review(ArchiveRepackagingReview)
    case running(ArchiveRepackagingReview, String)
    case completed(outputPath: String, verified: Bool)
    case cancelled
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .planning, .review, .running: return true
        default: return false
        }
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
    func pollExtractionJob(jobId: String, cursor: UInt64) throws -> PollJobEventsResult
    func cancelExtractionJob(jobId: String) throws
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

    func pollExtractionJob(jobId: String, cursor: UInt64) throws -> PollJobEventsResult {
        throw ArchiveExtractionError.unavailable
    }

    func cancelExtractionJob(jobId: String) throws {}

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

    func pollExtractionJob(jobId: String, cursor: UInt64) throws -> PollJobEventsResult {
        try pollJobEvents(request: PollJobEventsRequest(jobId: jobId, cursor: cursor))
    }

    func cancelExtractionJob(jobId: String) throws {
        _ = try cancelJob(request: CancelJobRequest(jobId: jobId))
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
    @Published var extractionState: ArchiveExtractionState = .idle
    @Published var extractionPasswordInput = ""
    @Published var repackagingState: ArchiveRepackagingState = .idle
    @Published var previewDocument: PreviewDocument?
    @Published var creationState: ArchiveCreationState = .idle
    @Published var creationFormat: CreateArchiveFormat = .zip
    @Published var creationPasswordInput = ""
    @Published var localSendState: LocalSendUIState = .idle

    private let importStore: ArchiveImportStore
    private let listingLoader: ArchiveListingLoader
    private let previewLoader: ArchivePreviewLoader
    private let testLoader: ArchiveTestLoader
    private let extractionCoordinator: ArchiveExtractionCoordinator
    private let creationCoordinator: ArchiveCreationCoordinator
    private let creationSourceStager: ArchiveCreationSourceStager
    private let repackagingCoordinator: ArchiveRepackagingCoordinator
    private let localSendClient: LocalSendClient
    private let localSendReceiver: LocalSendReceiver
    private var activeLocalSendDevice: LocalSendDevice?
    private var activeLocalSendSessionID: String?
    private var stagedCreationSources: StagedCreationSources?
    private var importGeneration = 0
    private var listingGeneration = 0
    private var previewGeneration = 0
    private var testGeneration = 0
    private var activePreviewCleanupRoot: URL?
    private let archiveSessions = ArchiveSessionStack()

    init(
        importStore: ArchiveImportStore = ArchiveImportStore(),
        listingLoader: ArchiveListingLoader = ArchiveListingLoader(),
        previewLoader: ArchivePreviewLoader = ArchivePreviewLoader(),
        testLoader: ArchiveTestLoader = ArchiveTestLoader(),
        extractionCoordinator: ArchiveExtractionCoordinator = ArchiveExtractionCoordinator(),
        creationCoordinator: ArchiveCreationCoordinator = ArchiveCreationCoordinator(),
        creationSourceStager: ArchiveCreationSourceStager = ArchiveCreationSourceStager(),
        repackagingCoordinator: ArchiveRepackagingCoordinator? = nil,
        localSendClient: LocalSendClient = LocalSendClient(),
        localSendReceiver: LocalSendReceiver = LocalSendReceiver()
    ) {
        self.importStore = importStore
        self.listingLoader = listingLoader
        self.previewLoader = previewLoader
        self.testLoader = testLoader
        self.extractionCoordinator = extractionCoordinator
        self.creationCoordinator = creationCoordinator
        self.creationSourceStager = creationSourceStager
        self.repackagingCoordinator = repackagingCoordinator ?? ArchiveRepackagingCoordinator(
            extraction: extractionCoordinator,
            creation: creationCoordinator
        )
        self.localSendClient = localSendClient
        self.localSendReceiver = localSendReceiver
    }

    deinit {
        localSendReceiver.stop()
    }

    func handleFileImporterResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard !urls.isEmpty else {
                errorMessage = ArchiveImportError.emptySelection.localizedDescription
                return
            }
            importExternalURLs(urls)
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    func importExternalURL(_ url: URL) {
        importExternalURLs([url])
    }

    func importExternalURLs(_ urls: [URL]) {
        importGeneration += 1
        listingGeneration += 1
        archiveSessions.clear()
        _nestedOpenError = nil
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
                    try importStore.importArchives(from: urls)
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

    func importMaestroFixture() {
        importMaestroFixture(named: "maestro-files.zip")
    }

    func importMaestroFixture(named fixtureName: String, companionNames: [String] = []) {
        let fixtureURLs = ([fixtureName] + companionNames).compactMap {
            Bundle.main.url(forResource: $0, withExtension: nil)
        }
        guard fixtureURLs.count == companionNames.count + 1 else {
            errorMessage = "The Maestro fixture is not available in this build."
            return
        }
        importExternalURLs(fixtureURLs)
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

    var currentSelectedEntries: [ArchiveEntrySummary] {
        guard case .ready(let summary) = listingState else { return [] }
        let selected = summary.selectedEntries(selectedEntryIds: selectedEntryIds)
        return selected.isEmpty ? summary.entries : selected
    }

    func startRepackaging(selectedEntries: [ArchiveEntrySummary]) {
        guard let archive = importedArchive else { return }
        // Repackaging requires an explicit source selection. An empty list is
        // reserved by extraction for "the whole archive".
        let selectedPaths = selectedEntries.map(\.path)
        let suffix: String
        switch creationFormat {
        case .zip: suffix = ".zip"
        case .sevenZ: suffix = ".7z"
        case .tarZst: suffix = ".tar.zst"
        case .tzap: suffix = ".tzap"
        }
        let request = ArchiveRepackagingRequest(
            sourceArchive: archive,
            selectedPaths: selectedPaths,
            destinationArchivePath: creationCoordinator.appStorageOutput(displayName: "repackaged\(suffix)").path,
            format: creationFormat,
            sourcePassword: passwordInput.isEmpty ? nil : passwordInput,
            destinationPassword: creationPasswordInput.isEmpty ? nil : creationPasswordInput
        )
        repackagingState = .planning
        Task {
            do {
                let review = try await Task.detached(priority: .userInitiated) {
                    try self.repackagingCoordinator.plan(request: request)
                }.value
                repackagingState = .review(review)
            } catch {
                repackagingState = .failed(error.localizedDescription)
            }
        }
    }

    func runRepackaging() {
        guard case .review(let review) = repackagingState else { return }
        repackagingState = .running(review, "Repackaging selected entries")
        Task {
            let outcome = await repackagingCoordinator.run(review: review) { message in
                Task { @MainActor in self.repackagingState = .running(review, message) }
            }
            switch outcome {
            case .completed(let outputPath, let verified):
                repackagingState = .completed(outputPath: outputPath, verified: verified)
            case .cancelled:
                repackagingState = .cancelled
            case .failed(let message):
                repackagingState = .failed(message)
            }
            passwordInput = ""
            creationPasswordInput = ""
        }
    }

    func cancelRepackaging() {
        if case .review(let review) = repackagingState {
            repackagingCoordinator.discard(review: review)
            repackagingState = .idle
        } else if case .running(let review, _) = repackagingState {
            repackagingCoordinator.cancel(review: review)
        }
    }

    private func extractionSelectedPaths(for selectedEntries: [ArchiveEntrySummary]) -> [String] {
        guard case .ready(let summary) = listingState else {
            return selectedEntries.map(\.path)
        }
        let selectedPaths = Set(selectedEntries.map(\.path))
        let allPaths = Set(summary.entries.map(\.path))
        return selectedPaths == allPaths ? [] : selectedEntries.map(\.path)
    }

    func planExtraction(
        selectedEntries: [ArchiveEntrySummary],
        destination: ExtractionDestination? = nil,
        password: String? = nil
    ) {
        guard let archive = importedArchive else { return }
        clearExtractionState()
        let destination = destination ?? extractionCoordinator.appStorageDestination()
        let selectedPaths = extractionSelectedPaths(for: selectedEntries)
        extractionState = .planning(destination.label)
        Task {
            do {
                let review = try await Task.detached(priority: .userInitiated) {
                    try self.extractionCoordinator.plan(
                        archive: archive,
                        // An empty selection means every entry. Preserve that
                        // bridge contract so full extraction reaches the
                        // format's native backend rather than per-entry I/O.
                        selectedPaths: selectedPaths,
                        destination: destination,
                        password: password,
                        collisionPolicy: .refuse
                    )
                }.value
                extractionState = review.plan.canStart
                    ? .review(review)
                    : .failed(review.plan.warnings.first?.message ?? "This extraction plan cannot be started.")
            } catch let ZmanagerGuiError.Bridge(code, userMessage, _, _, _) where code == "password_required" || code == "invalid_password" {
                extractionState = .passwordRequired(userMessage)
            } catch {
                extractionState = .failed(error.localizedDescription)
            }
        }
    }

    func retryExtractionWithPassword(selectedEntries: [ArchiveEntrySummary]) {
        let password = extractionPasswordInput.isEmpty ? nil : extractionPasswordInput
        extractionPasswordInput = ""
        planExtraction(selectedEntries: selectedEntries, password: password)
    }

    func handleCreationFilesResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            do { try planCreation(staged: creationSourceStager.stageFiles(urls)) }
            catch { creationState = .failed(error.localizedDescription) }
        case .failure(let error):
            creationState = .failed(error.localizedDescription)
        }
    }

    func handleCreationFolderResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            do { try planCreation(staged: creationSourceStager.stageFolder(url)) }
            catch { creationState = .failed(error.localizedDescription) }
        case .failure(let error):
            creationState = .failed(error.localizedDescription)
        }
    }

    #if DEBUG
    func createDebugFixture() {
        do {
            try planCreation(staged: creationSourceStager.stageDebugFixture())
        } catch {
            creationState = .failed(error.localizedDescription)
        }
    }
    #endif

    func startCreation(_ review: ArchiveCreationReview) {
        creationPasswordInput = ""
        creationState = .starting(review)
        Task {
            do {
                let jobID = try await Task.detached(priority: .userInitiated) {
                    try self.creationCoordinator.start(review: review)
                }.value
                creationState = .running(review, jobID, "Creating archive")
                let outcome = try await creationCoordinator.awaitCompletion(review: review, jobId: jobID) { progress in
                    Task { @MainActor in
                        self.creationState = .running(review, jobID, progress.message)
                    }
                }
                creationState = outcome.creationState
                if case .completed = outcome { discardCreationSources() }
                if case .cancelled = outcome { discardCreationSources() }
            } catch {
                creationCoordinator.discard(review: review)
                discardCreationSources()
                creationState = .failed(error.localizedDescription)
            }
        }
    }

    func cancelCreation() {
        switch creationState {
        case .running(_, let jobID, _):
            Task.detached { try? self.creationCoordinator.cancel(jobId: jobID) }
        case .review(let review):
            creationCoordinator.discard(review: review)
            discardCreationSources()
            creationState = .idle
        default:
            break
        }
    }

    func discoverLocalSendDevices() {
        localSendState = .discovering
        Task {
            do {
                localSendState = .devices(try await localSendClient.discover())
            } catch {
                localSendState = .failed("Unable to discover LocalSend devices.")
            }
        }
    }

    func sendCurrentArchive(to device: LocalSendDevice) {
        guard let archive = importedArchive else { return }
        localSendState = .sending(device, "Preparing transfer")
        Task {
            do {
                let file = LocalSendTransferFile(url: URL(fileURLWithPath: archive.localPath), displayName: archive.displayName)
                let session = try await localSendClient.prepareUpload(to: device, files: [file])
                activeLocalSendDevice = device
                activeLocalSendSessionID = session.sessionID
                localSendState = .sending(device, "Uploading \(archive.displayName)")
                try await localSendClient.upload(to: device, session: session, files: [file])
                activeLocalSendDevice = nil
                activeLocalSendSessionID = nil
                localSendState = .completed(device)
            } catch is CancellationError {
                activeLocalSendDevice = nil
                activeLocalSendSessionID = nil
                localSendState = .failed("LocalSend transfer cancelled.")
            } catch {
                activeLocalSendDevice = nil
                activeLocalSendSessionID = nil
                localSendState = .failed(error.localizedDescription)
            }
        }
    }

    func cancelLocalSend() {
        guard case .sending = localSendState else { return }
        let device = activeLocalSendDevice
        let sessionID = activeLocalSendSessionID
        localSendClient.cancelActiveUpload()
        activeLocalSendDevice = nil
        activeLocalSendSessionID = nil
        Task {
            if let device, let sessionID {
                try? await localSendClient.cancel(to: device, sessionID: sessionID)
            }
            localSendState = .failed("LocalSend transfer cancelled.")
        }
    }

    func startLocalReceive() {
        guard case .idle = localSendState else { return }
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ZManagerMobile/ReceivedFiles", isDirectory: true)
        do {
            let port = try localSendReceiver.start(destinationRoot: root)
            localSendState = .receiving(port)
        } catch {
            localSendState = .failed("Unable to receive LocalSend files.")
        }
    }

    func stopLocalReceive() {
        localSendReceiver.stop()
        localSendState = .idle
    }

    private func planCreation(staged: StagedCreationSources) throws {
        discardCreationSources()
        stagedCreationSources = staged
        let suffix: String
        switch creationFormat {
        case .zip: suffix = ".zip"
        case .sevenZ: suffix = ".7z"
        case .tarZst: suffix = ".tar.zst"
        case .tzap: suffix = ".tzap"
        }
        let request = ArchiveCreationRequest(
            sourcePaths: staged.sourcePaths,
            destinationArchivePath: creationCoordinator.appStorageOutput(displayName: "archive\(suffix)").path,
            format: creationFormat,
            password: creationPasswordInput.isEmpty ? nil : creationPasswordInput
        )
        creationState = .planning
        Task {
            do {
                let review = try await Task.detached(priority: .userInitiated) {
                    try self.creationCoordinator.plan(request: request)
                }.value
                creationState = review.plan.canStart
                    ? .review(review)
                    : .failed(review.plan.warnings.first?.message ?? "This creation plan cannot be started.")
            } catch {
                discardCreationSources()
                creationState = .failed(error.localizedDescription)
            }
        }
    }

    private func discardCreationSources() {
        if let stagedCreationSources {
            creationSourceStager.discard(stagedCreationSources)
            self.stagedCreationSources = nil
        }
    }

    func startExtraction(_ review: ExtractionReview) {
        extractionState = .starting(review)
        Task {
            do {
                let jobId = try await Task.detached(priority: .userInitiated) {
                    try self.extractionCoordinator.start(review: review)
                }.value
                extractionState = .running(review, jobId, "Extracting archive")
                let outcome = try await extractionCoordinator.awaitCompletion(review: review, jobId: jobId) { progress in
                    Task { @MainActor in
                        self.extractionState = .running(review, jobId, progress.message)
                    }
                }
                extractionState = outcome.state
            } catch {
                extractionCoordinator.discard(review: review)
                extractionState = .failed(error.localizedDescription)
            }
        }
    }

    func cancelExtraction() {
        guard case .running(_, let jobId, _) = extractionState else {
            if case .review(let review) = extractionState { extractionCoordinator.discard(review: review) }
            extractionState = .idle
            return
        }
        Task.detached { try? self.extractionCoordinator.cancel(jobId: jobId) }
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

    var archiveBreadcrumbs: [String] {
        archiveSessions.sessions.map(\.archive.displayName)
    }

    var nestedOpenError: String? {
        get { _nestedOpenError }
    }

    @Published private var _nestedOpenError: String?

    func openNestedArchive(entry: ArchiveEntrySummary) {
        guard let parent = importedArchive, NestedArchiveSupport.canOpen(entry) else { return }
        _nestedOpenError = nil
        let loader = previewLoader
        Task {
            let state = await Task.detached(priority: .userInitiated) {
                loader.materialize(archive: parent, entry: entry, password: nil)
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
                loadListing(for: child, password: nil)
            case .passwordRequired(_, let error):
                _nestedOpenError = error.message
            case .failed(_, let error):
                _nestedOpenError = error.message
            default:
                _nestedOpenError = "Unable to open that nested archive."
            }
        }
    }

    func navigateBackFromNested() {
        guard archiveSessions.current != nil else { return }
        _ = archiveSessions.pop()
        guard let parent = archiveSessions.current?.archive else {
            importedArchive = nil
            listingState = .idle
            return
        }
        _nestedOpenError = nil
        importedArchive = parent
        loadListing(for: parent, password: nil)
    }

    private func clearExtractionState() {
        if case .review(let review) = extractionState { extractionCoordinator.discard(review: review) }
        extractionState = .idle
        extractionPasswordInput = ""
    }
}

#Preview {
    ContentView()
}

enum ArchiveCreationState {
    case idle
    case planning
    case review(ArchiveCreationReview)
    case starting(ArchiveCreationReview)
    case running(ArchiveCreationReview, String, String)
    case completed(ArchiveCreationOutcome)
    case cancelled
    case failed(String)
}

private extension ArchiveCreationOutcome {
    var creationState: ArchiveCreationState {
        switch self {
        case .completed(let outputPath, let verified):
            return .completed(.completed(outputPath: outputPath, verified: verified))
        case .cancelled:
            return .cancelled
        case .failed(let message):
            return .failed(message)
        }
    }
}

struct ArchiveCreationPanel: View {
    let state: ArchiveCreationState
    let format: CreateArchiveFormat
    let password: String
    let onPasswordChanged: (String) -> Void
    let onFormatChanged: (CreateArchiveFormat) -> Void
    let onChooseFiles: () -> Void
    let onChooseFolder: () -> Void
    let onStart: (ArchiveCreationReview) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Create archive").font(.headline)
            Picker("Format", selection: Binding(
                get: { format },
                set: onFormatChanged
            )) {
                Text("ZIP").tag(CreateArchiveFormat.zip)
                Text("7z").tag(CreateArchiveFormat.sevenZ)
                Text("TAR.ZST").tag(CreateArchiveFormat.tarZst)
                Text("TZAP").tag(CreateArchiveFormat.tzap)
            }
            .pickerStyle(.segmented)
            SecureField("Optional password", text: Binding(
                get: { password },
                set: onPasswordChanged
            ))
            .textFieldStyle(.roundedBorder)
            switch state {
            case .idle, .failed, .completed, .cancelled:
                HStack {
                    Button("Choose files", action: onChooseFiles)
                    Button("Choose folder", action: onChooseFolder)
                }
                if case .failed(let message) = state { Text(message).foregroundStyle(.red) }
                if case .completed(let outcome) = state,
                   case .completed(let outputPath, let verified) = outcome {
                    Text("Created \(outputPath)")
                    Text(verified ? "Verified" : "Created without verification")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if case .cancelled = state { Text("Archive creation cancelled") }
            case .planning:
                Text("Preparing creation plan")
            case .review(let review):
                Text("\(review.plan.totalEntries) entries - \(review.plan.totalBytes) bytes")
                ForEach(review.plan.warnings, id: \.self) { warning in
                    Text(warning.message).foregroundStyle(.red)
                }
                HStack {
                    Button("Cancel", action: onCancel)
                    Button("Start creation") { onStart(review) }
                        .buttonStyle(.borderedProminent)
                }
            case .starting:
                Text("Starting archive creation")
            case .running(_, _, let message):
                Text(message)
                Button("Cancel creation", action: onCancel)
            }
        }
    }
}

struct LocalSendPanel: View {
    let archive: ImportedArchive?
    let state: LocalSendUIState
    let onDiscover: () -> Void
    let onSend: (LocalSendDevice) -> Void
    let onCancelSend: () -> Void
    let onStartReceive: () -> Void
    let onStopReceive: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Share on local network").font(.headline)
            Button(state.isDiscovering ? "Discovering" : "Find LocalSend devices", action: onDiscover)
                .disabled(archive == nil || state.isDiscovering)
            if case .receiving(let port) = state {
                Button("Stop receiving", action: onStopReceive)
                Text("Receiving LocalSend files on port \(port) into app storage.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button("Receive files", action: onStartReceive)
            }
            switch state {
            case .idle, .receiving, .discovering:
                EmptyView()
            case .devices(let devices):
                if devices.isEmpty { Text("No compatible devices found.") }
                ForEach(devices) { device in
                    HStack {
                        Text("\(device.alias) (\(device.address))")
                        Spacer()
                        Button("Send archive") { onSend(device) }
                    }
                }
            case .sending(let device, let message):
                HStack {
                    Text("\(message) to \(device.alias)")
                    Spacer()
                    Button("Cancel", action: onCancelSend)
                }
            case .completed(let device):
                Text("Sent to \(device.alias)")
            case .failed(let message):
                Text(message).foregroundStyle(.red)
            }
        }
    }
}

private extension LocalSendUIState {
    var isDiscovering: Bool {
        if case .discovering = self { return true }
        return false
    }
}

enum ArchiveExtractionError: LocalizedError {
    case unavailable
    case expiredReview
    case unavailableStaging

    var errorDescription: String? {
        switch self {
        case .unavailable: return "Archive extraction is unavailable in this build."
        case .expiredReview: return "The extraction review expired. Review the archive again."
        case .unavailableStaging: return "The staged extraction is unavailable."
        }
    }
}

enum ExtractionDestination: Equatable {
    case appStorage(URL)
    case folder(URL)

    var label: String {
        switch self {
        case .appStorage: return "App storage"
        case .folder: return "Selected folder"
        }
    }

    var rootURL: URL {
        switch self {
        case .appStorage(let url), .folder(let url): return url
        }
    }
}

struct ExtractionReview {
    let id: UUID
    let destination: ExtractionDestination
    let plan: PlanExtractResult
    let collisionPolicy: ExtractionCollisionPolicy
}

struct ExtractionProgress {
    let message: String
}

enum ArchiveExtractionState {
    case idle
    case planning(String)
    case review(ExtractionReview)
    case starting(ExtractionReview)
    case running(ExtractionReview, String, String)
    case completed(UInt64, String)
    case cancelled
    case passwordRequired(String)
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .planning, .starting, .running: return true
        default: return false
        }
    }
}

private extension ArchiveExtractionCoordinator.Outcome {
    var state: ArchiveExtractionState {
        switch self {
        case .completed(let entries, let destination): return .completed(entries, destination)
        case .cancelled: return .cancelled
        case .failed(let message): return .failed(message)
        }
    }
}

final class ArchiveExtractionCoordinator: @unchecked Sendable {
    enum Outcome {
        case completed(UInt64, String)
        case cancelled
        case failed(String)
    }

    private struct Session {
        let archive: ImportedArchive
        let selectedPaths: [String]
        let stagingRoot: URL
        let destination: ExtractionDestination
        let collisionPolicy: ExtractionCollisionPolicy
        let stagingCollisionPolicy: ExtractionCollisionPolicy
        var password: String?
    }

    private let bridge: ArchiveBridgeClient
    private let fileManager: FileManager
    private let lock = NSLock()
    private var sessions = [UUID: Session]()

    init(bridge: ArchiveBridgeClient = GeneratedArchiveBridgeClient(), fileManager: FileManager = .default) {
        self.bridge = bridge
        self.fileManager = fileManager
    }

    func appStorageDestination() -> ExtractionDestination {
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ZManagerMobile/Extracted", isDirectory: true)
        return .appStorage(root)
    }

    func plan(
        archive: ImportedArchive,
        selectedPaths: [String],
        destination: ExtractionDestination,
        password: String?,
        collisionPolicy: ExtractionCollisionPolicy
    ) throws -> ExtractionReview {
        let id = UUID()
        let stagingRoot = fileManager.temporaryDirectory
            .appendingPathComponent("ZManagerMobile/extractions/\(id.uuidString)/staging", isDirectory: true)
        let plan = try bridge.planExtraction(
            path: archive.localPath,
            destinationRoot: stagingRoot.path,
            selectedPaths: selectedPaths,
            password: password,
            // The stage is private and freshly created. Replace avoids Android cache
            // filesystems rejecting AtomicOutputFile's refuse-policy hard-link commit.
            collisionPolicy: .replace
        )
        lock.lock()
        sessions[id] = Session(
            archive: archive,
            selectedPaths: selectedPaths,
            stagingRoot: stagingRoot,
            destination: destination,
            collisionPolicy: collisionPolicy,
            stagingCollisionPolicy: .replace,
            password: password
        )
        lock.unlock()
        return ExtractionReview(id: id, destination: destination, plan: plan, collisionPolicy: collisionPolicy)
    }

    func start(review: ExtractionReview) throws -> String {
        guard review.plan.canStart, !review.plan.planToken.isEmpty else {
            throw ArchiveExtractionError.expiredReview
        }
        lock.lock()
        guard let session = sessions[review.id] else {
            lock.unlock()
            throw ArchiveExtractionError.expiredReview
        }
        lock.unlock()
        let result = try bridge.startExtraction(
            path: session.archive.localPath,
            destinationRoot: session.stagingRoot.path,
            selectedPaths: session.selectedPaths,
            password: session.password,
            collisionPolicy: session.stagingCollisionPolicy,
            planToken: review.plan.planToken
        )
        lock.lock()
        var clearedSession = session
        clearedSession.password = nil
        sessions[review.id] = clearedSession
        lock.unlock()
        return result.jobId
    }

    func awaitCompletion(
        review: ExtractionReview,
        jobId: String,
        onProgress: @escaping (ExtractionProgress) -> Void
    ) async throws -> Outcome {
        var cursor: UInt64 = 0
        while true {
            let update = try bridge.pollExtractionJob(jobId: jobId, cursor: cursor)
            cursor = update.nextCursor
            if let event = update.events.last {
                onProgress(ExtractionProgress(message: event.message ?? event.path ?? "Extracting archive"))
            }
            if update.isTerminal {
                switch update.status {
                case .completed:
                    return commit(review: review)
                case .cancelled:
                    discard(review: review)
                    return .cancelled
                default:
                    return .failed(update.events.last?.error?.message ?? update.events.last?.message ?? "Archive extraction failed.")
                }
            }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
    }

    func cancel(jobId: String) throws {
        try bridge.cancelExtractionJob(jobId: jobId)
    }

    func discard(review: ExtractionReview) {
        lock.lock()
        let session = sessions.removeValue(forKey: review.id)
        lock.unlock()
        if let session {
            try? fileManager.removeItem(at: session.stagingRoot.deletingLastPathComponent())
        }
    }

    private func commit(review: ExtractionReview) -> Outcome {
        lock.lock()
        guard let session = sessions[review.id] else {
            lock.unlock()
            return .failed(ArchiveExtractionError.expiredReview.localizedDescription)
        }
        lock.unlock()
        do {
            switch session.destination {
            case .appStorage(let root):
                try commit(stagingRoot: session.stagingRoot, to: root, policy: review.collisionPolicy)
            case .folder(let root):
                guard root.startAccessingSecurityScopedResource() else {
                    return .failed("The selected folder is no longer available.")
                }
                defer { root.stopAccessingSecurityScopedResource() }
                var coordinationError: NSError?
                var commitError: Error?
                let coordinator = NSFileCoordinator()
                coordinator.coordinate(writingItemAt: root, options: .forReplacing, error: &coordinationError) { _ in
                    do { try commit(stagingRoot: session.stagingRoot, to: root, policy: review.collisionPolicy) }
                    catch { commitError = error }
                }
                if let coordinationError { throw coordinationError }
                if let commitError { throw commitError }
            }
            let writtenEntries = review.plan.writableEntries
            let destination = session.destination.label
            discard(review: review)
            return .completed(writtenEntries, destination)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func commit(stagingRoot: URL, to destinationRoot: URL, policy: ExtractionCollisionPolicy) throws {
        guard fileManager.fileExists(atPath: stagingRoot.path) else { throw ArchiveExtractionError.unavailableStaging }
        let files = try fileManager.subpathsOfDirectory(atPath: stagingRoot.path)
        for relativePath in files {
            let source = stagingRoot.appendingPathComponent(relativePath)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            let target = destinationRoot.appendingPathComponent(relativePath)
            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let resolved = try resolveCollision(target, policy: policy)
            try fileManager.copyItem(at: source, to: resolved)
        }
    }

    private func resolveCollision(_ target: URL, policy: ExtractionCollisionPolicy) throws -> URL {
        guard fileManager.fileExists(atPath: target.path) else { return target }
        switch policy {
        case .replace:
            try fileManager.removeItem(at: target)
            return target
        case .rename:
            let base = target.deletingPathExtension().lastPathComponent
            let ext = target.pathExtension
            for index in 1...10_000 {
                let name = ext.isEmpty ? "\(base) (\(index))" : "\(base) (\(index)).\(ext)"
                let candidate = target.deletingLastPathComponent().appendingPathComponent(name)
                if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            }
            throw CocoaError(.fileWriteFileExists)
        case .refuse:
            throw CocoaError(.fileWriteFileExists)
        }
    }
}

struct ArchiveExtractionPanel: View {
    let state: ArchiveExtractionState
    let selectedEntries: [ArchiveEntrySummary]
    @Binding var password: String
    let onChooseDestination: () -> Void
    let onStart: (ExtractionReview) -> Void
    let onCancel: () -> Void
    let onRetryWithPassword: ([ArchiveEntrySummary]) -> Void

    var body: some View {
        switch state {
        case .idle: EmptyView()
        case .planning(let destination): Text("Preparing extraction plan for \(destination)")
        case .review(let review):
            VStack(alignment: .leading, spacing: 6) {
                Text("Review extraction").font(.headline)
                Text("\(review.plan.writableEntries) files will be extracted to \(review.destination.label).")
                if let estimated = review.plan.estimatedBytes { Text("\(estimated) bytes estimated") }
                ForEach(review.plan.warnings, id: \.self) { Text($0.message).foregroundStyle(.red) }
                HStack {
                    Button("Choose folder", action: onChooseDestination)
                    Button("Cancel", action: onCancel)
                    Button("Start extraction") { onStart(review) }.buttonStyle(.borderedProminent)
                }
            }
        case .starting: Text("Starting extraction")
        case .running(_, _, let message):
            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                Button("Cancel extraction", action: onCancel)
            }
        case .completed(let entries, let destination): Text("Extraction complete: \(entries) files saved to \(destination).")
        case .cancelled: Text("Extraction cancelled")
        case .passwordRequired(let message):
            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                SecureField("Password", text: $password).textFieldStyle(.roundedBorder)
                Button("Retry extraction") { onRetryWithPassword(selectedEntries) }.disabled(password.isEmpty)
            }
        case .failed(let message): Text(message).foregroundStyle(.red)
        }
    }
}

struct ArchiveCreationRequest {
    let sourcePaths: [String]
    let destinationArchivePath: String
    let format: CreateArchiveFormat
    var password: String?
    let preserveMetadata: Bool
    let replaceExisting: Bool
    let cleanSource: Bool
    let verifyAfterCreate: Bool
    let level: UInt32
    let encryptFileNames: Bool
    let volumeSize: UInt64?
    let recoveryPercentage: UInt8
    let volumeLossTolerance: UInt8

    init(
        sourcePaths: [String],
        destinationArchivePath: String,
        format: CreateArchiveFormat,
        password: String? = nil,
        preserveMetadata: Bool = true,
        replaceExisting: Bool = false,
        cleanSource: Bool = false,
        verifyAfterCreate: Bool = true,
        level: UInt32 = 6,
        encryptFileNames: Bool = false,
        volumeSize: UInt64? = nil,
        recoveryPercentage: UInt8 = 0,
        volumeLossTolerance: UInt8 = 0
    ) {
        self.sourcePaths = sourcePaths
        self.destinationArchivePath = destinationArchivePath
        self.format = format
        self.password = password
        self.preserveMetadata = preserveMetadata
        self.replaceExisting = replaceExisting
        self.cleanSource = cleanSource
        self.verifyAfterCreate = verifyAfterCreate
        self.level = level
        self.encryptFileNames = encryptFileNames
        self.volumeSize = volumeSize
        self.recoveryPercentage = recoveryPercentage
        self.volumeLossTolerance = volumeLossTolerance
    }
}

struct ArchiveCreationReview {
    let id: UUID
    let request: ArchiveCreationRequest
    let plan: PlanCreateResult
}

struct ArchiveCreationProgress {
    let message: String
    let processedBytes: UInt64?
    let totalBytes: UInt64?
    let processedEntries: UInt64?
    let totalEntries: UInt64?
}

enum ArchiveCreationOutcome: Equatable {
    case completed(outputPath: String, verified: Bool)
    case cancelled
    case failed(String)
}

enum ArchiveCreationError: LocalizedError {
    case unavailable
    case expiredReview

    var errorDescription: String? {
        switch self {
        case .unavailable: return "Archive creation is unavailable in this build."
        case .expiredReview: return "The creation review expired. Review the inputs again."
        }
    }
}

final class ArchiveCreationCoordinator: @unchecked Sendable {
    private var sessions = [UUID: ArchiveCreationRequest]()
    private let bridge: ArchiveBridgeClient
    private let lock = NSLock()
    private let fileManager: FileManager

    init(
        bridge: ArchiveBridgeClient = GeneratedArchiveBridgeClient(),
        fileManager: FileManager = .default
    ) {
        self.bridge = bridge
        self.fileManager = fileManager
    }

    func appStorageOutput(displayName: String) -> URL {
        let safeName = displayName
            .replacingOccurrences(of: "[\\\\/:*?\"<>|]", with: "_", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = safeName.isEmpty ? "archive.zip" : safeName
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ZManagerMobile/CreatedArchives", isDirectory: true)
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent(name)
    }

    func plan(request: ArchiveCreationRequest) throws -> ArchiveCreationReview {
        guard !request.sourcePaths.isEmpty else { throw ArchiveCreationError.expiredReview }
        let result = try bridge.planCreation(
            request: PlanCreateRequest(
                sourcePaths: request.sourcePaths,
                destinationArchivePath: request.destinationArchivePath,
                format: request.format,
                password: request.password,
                preserveMetadata: request.preserveMetadata,
                replaceExisting: request.replaceExisting,
                cleanSource: request.cleanSource,
                verifyAfterCreate: request.verifyAfterCreate
            )
        )
        let review = ArchiveCreationReview(id: UUID(), request: request, plan: result)
        lock.lock()
        sessions[review.id] = request
        lock.unlock()
        return review
    }

    func start(review: ArchiveCreationReview) throws -> String {
        lock.lock()
        guard let request = sessions[review.id] else {
            lock.unlock()
            throw ArchiveCreationError.expiredReview
        }
        lock.unlock()
        guard review.plan.canStart else { throw ArchiveCreationError.expiredReview }
        let result = try bridge.startCreation(
            request: StartCreateRequest(
                sourcePaths: request.sourcePaths,
                destinationArchivePath: request.destinationArchivePath,
                format: request.format,
                password: request.password,
                preserveMetadata: request.preserveMetadata,
                replaceExisting: request.replaceExisting,
                cleanSource: request.cleanSource,
                verifyAfterCreate: request.verifyAfterCreate,
                excludedPaths: [],
                level: request.level,
                encryptFileNames: request.encryptFileNames,
                volumeSize: request.volumeSize,
                recoveryPercentage: request.recoveryPercentage,
                volumeLossTolerance: request.volumeLossTolerance,
                tzapSigningCertificate: nil,
                tzapSigningPrivateKey: nil,
                tzapSigningChain: [],
                tzapIdentity: nil,
                tzapIdentityPassword: nil
            )
        )
        lock.lock()
        var cleared = request
        cleared.password = nil
        sessions[review.id] = cleared
        lock.unlock()
        return result.jobId
    }

    func awaitCompletion(
        review: ArchiveCreationReview,
        jobId: String,
        onProgress: @escaping (ArchiveCreationProgress) -> Void
    ) async throws -> ArchiveCreationOutcome {
        lock.lock()
        guard let request = sessions[review.id] else {
            lock.unlock()
            return .failed(ArchiveCreationError.expiredReview.localizedDescription)
        }
        lock.unlock()
        var cursor: UInt64 = 0
        while true {
            let update = try bridge.pollExtractionJob(jobId: jobId, cursor: cursor)
            cursor = update.nextCursor
            if let event = update.events.last {
                onProgress(
                    ArchiveCreationProgress(
                        message: event.message ?? event.path ?? "Creating archive",
                        processedBytes: event.totalBytesProcessed ?? event.bytes,
                        totalBytes: event.totalBytes,
                        processedEntries: event.entries,
                        totalEntries: event.totalEntries
                    )
                )
            }
            if update.isTerminal {
                switch update.status {
                case .completed:
                    let verified = request.verifyAfterCreate && update.terminalSummary?.verified == true
                    discard(review: review)
                    return .completed(
                        outputPath: update.terminalSummary?.outputPaths.first ?? request.destinationArchivePath,
                        verified: verified
                    )
                case .cancelled:
                    discard(review: review)
                    return .cancelled
                default:
                    let message = update.events.last?.error?.message
                        ?? update.events.last?.message
                        ?? "Archive creation failed."
                    discard(review: review)
                    return .failed(message)
                }
            }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
    }

    func cancel(jobId: String) throws {
        try bridge.cancelExtractionJob(jobId: jobId)
    }

    func discard(review: ArchiveCreationReview) {
        lock.lock()
        sessions.removeValue(forKey: review.id)
        lock.unlock()
    }
}

struct ArchiveRepackagingRequest {
    let sourceArchive: ImportedArchive
    let selectedPaths: [String]
    let destinationArchivePath: String
    let format: CreateArchiveFormat
    let sourcePassword: String?
    let destinationPassword: String?
    let verifyAfterCreate: Bool

    init(
        sourceArchive: ImportedArchive,
        selectedPaths: [String],
        destinationArchivePath: String,
        format: CreateArchiveFormat,
        sourcePassword: String? = nil,
        destinationPassword: String? = nil,
        verifyAfterCreate: Bool = true
    ) {
        self.sourceArchive = sourceArchive
        self.selectedPaths = selectedPaths
        self.destinationArchivePath = destinationArchivePath
        self.format = format
        self.sourcePassword = sourcePassword
        self.destinationPassword = destinationPassword
        self.verifyAfterCreate = verifyAfterCreate
    }
}

struct ArchiveRepackagingReview {
    let id: UUID
    let request: ArchiveRepackagingRequest
    let extractionReview: ExtractionReview
}

enum ArchiveRepackagingOutcome: Equatable {
    case completed(outputPath: String, verified: Bool)
    case cancelled
    case failed(String)
}

final class ArchiveRepackagingCoordinator: @unchecked Sendable {
    private final class Session {
        let request: ArchiveRepackagingRequest
        let stagingRoot: URL
        var activeJobID: String?
        var cancelRequested = false

        init(request: ArchiveRepackagingRequest, stagingRoot: URL) {
            self.request = request
            self.stagingRoot = stagingRoot
        }
    }

    private let extraction: ArchiveExtractionCoordinator
    private let creation: ArchiveCreationCoordinator
    private let fileManager: FileManager
    private let lock = NSLock()
    private var sessions = [UUID: Session]()

    init(
        extraction: ArchiveExtractionCoordinator = ArchiveExtractionCoordinator(),
        creation: ArchiveCreationCoordinator = ArchiveCreationCoordinator(),
        fileManager: FileManager = .default
    ) {
        self.extraction = extraction
        self.creation = creation
        self.fileManager = fileManager
    }

    func plan(request: ArchiveRepackagingRequest) throws -> ArchiveRepackagingReview {
        guard !request.selectedPaths.isEmpty else { throw ArchiveExtractionError.expiredReview }
        let id = UUID()
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("ZManagerMobile/Repackaging/\(id.uuidString)/input", isDirectory: true)
        let extractionReview = try extraction.plan(
            archive: request.sourceArchive,
            selectedPaths: request.selectedPaths,
            destination: .appStorage(root),
            password: request.sourcePassword,
            collisionPolicy: .refuse
        )
        lock.lock()
        sessions[id] = Session(request: request, stagingRoot: root)
        lock.unlock()
        return ArchiveRepackagingReview(id: id, request: request, extractionReview: extractionReview)
    }

    func run(
        review: ArchiveRepackagingReview,
        onProgress: @escaping (String) -> Void = { _ in }
    ) async -> ArchiveRepackagingOutcome {
        lock.lock()
        let session = sessions[review.id]
        lock.unlock()
        guard let session else { return .failed("The repackaging review expired.") }
        do {
            let extractionJob = try extraction.start(review: review.extractionReview)
            session.activeJobID = extractionJob
            onProgress("Extracting selected archive folder")
            switch try await extraction.awaitCompletion(review: review.extractionReview, jobId: extractionJob) { progress in
                onProgress(progress.message)
            } {
            case .cancelled:
                return finish(review.id, outcome: .cancelled)
            case .failed(let message):
                return finish(review.id, outcome: .failed(message))
            case .completed:
                break
            }
            if session.cancelRequested { return finish(review.id, outcome: .cancelled) }
            let createReview = try creation.plan(
                request: ArchiveCreationRequest(
                    sourcePaths: [session.stagingRoot.path],
                    destinationArchivePath: session.request.destinationArchivePath,
                    format: session.request.format,
                    password: session.request.destinationPassword,
                    verifyAfterCreate: session.request.verifyAfterCreate
                )
            )
            guard createReview.plan.canStart else {
                return finish(review.id, outcome: .failed(createReview.plan.warnings.first?.message ?? "The output archive cannot be created."))
            }
            let creationJob = try creation.start(review: createReview)
            session.activeJobID = creationJob
            onProgress("Creating output archive")
            switch try await creation.awaitCompletion(review: createReview, jobId: creationJob) { progress in
                onProgress(progress.message)
            } {
            case .completed(let outputPath, let verified):
                return finish(review.id, outcome: .completed(outputPath: outputPath, verified: verified))
            case .cancelled:
                return finish(review.id, outcome: .cancelled)
            case .failed(let message):
                return finish(review.id, outcome: .failed(message))
            }
        } catch {
            return finish(review.id, outcome: .failed(error.localizedDescription))
        }
    }

    func discard(review: ArchiveRepackagingReview) {
        extraction.discard(review: review.extractionReview)
        _ = finish(review.id, outcome: .cancelled)
    }

    func cancel(review: ArchiveRepackagingReview) {
        lock.lock()
        let session = sessions[review.id]
        session?.cancelRequested = true
        let activeJobID = session?.activeJobID
        lock.unlock()
        if let activeJobID { try? extraction.cancel(jobId: activeJobID) }
    }

    private func finish(_ id: UUID, outcome: ArchiveRepackagingOutcome) -> ArchiveRepackagingOutcome {
        lock.lock()
        let session = sessions.removeValue(forKey: id)
        lock.unlock()
        if let session { try? fileManager.removeItem(at: session.stagingRoot.deletingLastPathComponent()) }
        return outcome
    }
}

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
    private static let archiveExtensions: Set<String> = [
        "zip", "7z", "rar", "tar", "gz", "tgz", "bz2", "tbz2", "xz", "txz",
        "zst", "tzst", "tzap", "aar", "cab", "deb", "jar", "apk", "ipa", "xip"
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

struct LocalSendDevice: Identifiable, Equatable {
    let id: String
    let address: String
    let port: Int
    let protocolName: String
    let alias: String
    let version: String
    let deviceModel: String?
    let deviceType: String?
    let fingerprint: String?
    let download: Bool

    var baseURL: URL? { URL(string: "\(protocolName)://\(address):\(port)") }
}

struct LocalSendTransferFile {
    let id: String
    let url: URL
    let displayName: String
    let mimeType: String

    init(url: URL, displayName: String? = nil, mimeType: String = "application/octet-stream") {
        self.id = UUID().uuidString
        self.url = url
        self.displayName = displayName ?? url.lastPathComponent
        self.mimeType = mimeType
    }
}

struct LocalSendUploadSession {
    let sessionID: String
    let tokens: [String: String]
}

enum LocalSendUIState {
    case idle
    case receiving(Int)
    case discovering
    case devices([LocalSendDevice])
    case sending(LocalSendDevice, String)
    case completed(LocalSendDevice)
    case failed(String)
}

struct LocalSendAnnouncement: Codable {
    let alias: String
    let version: String
    let deviceModel: String?
    let deviceType: String?
    let fingerprint: String
    let port: Int
    let `protocol`: String
    let download: Bool
    let announce: Bool?
}

/// LocalSend v2.2 outbound HTTP transfer subsystem. It intentionally has no
/// dependency on archive parsing or creation.
final class LocalSendClient: @unchecked Sendable {
    static let multicastAddress = "224.0.0.167"
    static let defaultPort = 53317

    private let alias: String
    private let fingerprint: String
    private let port: Int
    private var activeTask: URLSessionTask?

    init(alias: String = "ZManager Mobile", fingerprint: String = UUID().uuidString, port: Int = LocalSendClient.defaultPort) {
        self.alias = alias
        self.fingerprint = fingerprint
        self.port = port
    }

    func discover(timeout: TimeInterval = 1.5) async throws -> [LocalSendDevice] {
        let group = try NWMulticastGroup(for: [
            NWEndpoint.hostPort(
                host: NWEndpoint.Host(Self.multicastAddress),
                port: NWEndpoint.Port(rawValue: UInt16(Self.defaultPort))!
            )
        ])
        let connection = NWConnectionGroup(with: group, using: .udp)
        return await withCheckedContinuation { continuation in
            let lock = NSLock()
            var finished = false
            var devices = [String: LocalSendDevice]()
            func finish() {
                lock.lock()
                guard !finished else { lock.unlock(); return }
                finished = true
                let result = Array(devices.values)
                lock.unlock()
                connection.cancel()
                continuation.resume(returning: result)
            }
            connection.setReceiveHandler(maximumMessageSize: 16 * 1024, rejectOversizedMessages: true) { message, content, _ in
                guard let content,
                      let json = try? JSONSerialization.jsonObject(with: content) as? [String: Any],
                      let alias = json["alias"] as? String,
                      let port = json["port"] as? Int else { return }
                guard let remoteEndpoint = message.remoteEndpoint,
                      case .hostPort(let endpointHost, _) = remoteEndpoint else { return }
                let host = endpointHost.debugDescription
                guard host != UIDevice.current.name else { return }
                let device = LocalSendDevice(
                    id: "\(host):\(port)",
                    address: host,
                    port: port,
                    protocolName: (json["protocol"] as? String) ?? "http",
                    alias: alias,
                    version: (json["version"] as? String) ?? "2.0",
                    deviceModel: json["deviceModel"] as? String,
                    deviceType: json["deviceType"] as? String,
                    fingerprint: json["fingerprint"] as? String,
                    download: (json["download"] as? Bool) ?? false
                )
                lock.lock()
                devices[device.id] = device
                lock.unlock()
            }
            connection.stateUpdateHandler = { state in
                if case .failed = state { finish() }
            }
            connection.start(queue: .global(qos: .userInitiated))
            let data = try? JSONSerialization.data(withJSONObject: announcement(announce: true))
            if let data { connection.send(content: data, completion: { _ in }) }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                finish()
            }
        }
    }

    /// HTTP registration fallback for networks where multicast discovery is unavailable.
    func discoverHTTP(hosts: [String]) async -> [LocalSendDevice] {
        await withTaskGroup(of: LocalSendDevice?.self, returning: [LocalSendDevice].self) { group in
            for host in hosts {
                group.addTask {
                    guard let url = URL(string: "http://\(host):\(Self.defaultPort)/api/localsend/v2/register") else {
                        return nil
                    }
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = try? JSONSerialization.data(withJSONObject: self.announcement(announce: false))
                    guard let (data, response) = try? await URLSession.shared.data(for: request),
                          (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true,
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let alias = json["alias"] as? String else {
                        return nil
                    }
                    let port = json["port"] as? Int ?? Self.defaultPort
                    let fingerprint = json["fingerprint"] as? String
                    guard fingerprint != self.fingerprint else { return nil }
                    return LocalSendDevice(
                        id: "\(host):\(port)",
                        address: host,
                        port: port,
                        protocolName: (json["protocol"] as? String) ?? "http",
                        alias: alias,
                        version: (json["version"] as? String) ?? "2.0",
                        deviceModel: json["deviceModel"] as? String,
                        deviceType: json["deviceType"] as? String,
                        fingerprint: fingerprint,
                        download: (json["download"] as? Bool) ?? false
                    )
                }
            }
            var devices = [String: LocalSendDevice]()
            for await device in group {
                if let device { devices[device.id] = device }
            }
            return Array(devices.values)
        }
    }

    func prepareUpload(
        to device: LocalSendDevice,
        files: [LocalSendTransferFile],
        pin: String? = nil
    ) async throws -> LocalSendUploadSession {
        guard let baseURL = device.baseURL else { throw URLError(.badURL) }
        var components = URLComponents(url: baseURL.appendingPathComponent("api/localsend/v2/prepare-upload"), resolvingAgainstBaseURL: false)
        if let pin { components?.queryItems = [URLQueryItem(name: "pin", value: pin)] }
        guard let url = components?.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let hashes = try Dictionary(uniqueKeysWithValues: files.map { file in
            (file.id, try sha256(file.url))
        })
        let body: [String: Any] = [
            "info": announcement(announce: false),
            "files": Dictionary(uniqueKeysWithValues: files.map { file in
                (file.id, [
                    "id": file.id,
                    "fileName": file.displayName,
                    "size": (try? file.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0,
                    "fileType": file.mimeType,
                    "sha256": hashes[file.id] as Any
                ])
            })
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let sessionID = try string(json, key: "sessionId")
        let tokenObject = json["files"] as? [String: String] ?? [:]
        return LocalSendUploadSession(sessionID: sessionID, tokens: tokenObject)
    }

    func upload(
        to device: LocalSendDevice,
        session: LocalSendUploadSession,
        files: [LocalSendTransferFile]
    ) async throws {
        guard let baseURL = device.baseURL else { throw URLError(.badURL) }
        for file in files {
            guard let token = session.tokens[file.id] else { throw LocalSendTransferError.missingToken }
            var components = URLComponents(url: baseURL.appendingPathComponent("api/localsend/v2/upload"), resolvingAgainstBaseURL: false)
            components?.queryItems = [
                URLQueryItem(name: "sessionId", value: session.sessionID),
                URLQueryItem(name: "fileId", value: file.id),
                URLQueryItem(name: "token", value: token)
            ]
            guard let url = components?.url else { throw URLError(.badURL) }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            activeTask = URLSession.shared.uploadTask(with: request, fromFile: file.url)
            guard let activeTask else { throw URLError(.cannotCreateFile) }
            activeTask.resume()
            try await activeTask.value()
            self.activeTask = nil
        }
    }

    func cancel(to device: LocalSendDevice, sessionID: String) async throws {
        cancelActiveUpload()
        guard let baseURL = device.baseURL else { throw URLError(.badURL) }
        var components = URLComponents(url: baseURL.appendingPathComponent("api/localsend/v2/cancel"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "sessionId", value: sessionID)]
        guard let url = components?.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let (_, response) = try await URLSession.shared.data(for: request)
        try validate(response)
    }

    func cancelActiveUpload() {
        activeTask?.cancel()
        activeTask = nil
    }

    private func announcement(announce: Bool) -> [String: Any] {
        [
            "alias": alias,
            "version": "2.0",
            "deviceModel": UIDevice.current.model,
            "deviceType": "mobile",
            "fingerprint": fingerprint,
            "port": port,
            "protocol": "http",
            "download": false,
            "announce": announce
        ]
    }

    private func sha256(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw LocalSendTransferError.rejected
        }
    }

    private func string(_ json: [String: Any], key: String) throws -> String {
        guard let value = json[key] as? String else { throw LocalSendTransferError.invalidResponse }
        return value
    }
}

/// LocalSend upload receiver. The listener owns only app-storage paths and
/// commits a file after size, token, and optional SHA-256 checks succeed.
final class LocalSendReceiver: @unchecked Sendable {
    private struct ExpectedFile {
        let id: String
        let displayName: String
        let expectedBytes: Int64
        let sha256: String?
        let token: String
    }

    private final class ReceiveSession {
        let root: URL
        let destinationRoot: URL
        let files: [String: ExpectedFile]
        var completed = Set<String>()

        init(root: URL, destinationRoot: URL, files: [String: ExpectedFile]) {
            self.root = root
            self.destinationRoot = destinationRoot
            self.files = files
        }
    }

    private final class RequestState {
        var headerBuffer = Data()
        var bodyBuffer = Data()
        var headersParsed = false
        var method = ""
        var path = ""
        var headers = [String: String]()
        var remaining = 0
        var session: ReceiveSession?
        var sessionID: String?
        var expected: ExpectedFile?
        var preparedSessionID: String?
        var temporaryFile: URL?
        var fileHandle: FileHandle?
        var digest = SHA256()
    }

    private let alias: String
    private let fingerprint: String
    private let port: UInt16
    private let fileManager: FileManager
    private let queue = DispatchQueue(label: "org.tzap.zmanager.localsend.receiver")
    private var listener: NWListener?
    private var announceConnection: NWConnectionGroup?
    private var announceTimer: DispatchSourceTimer?
    private var sessions = [String: ReceiveSession]()
    private var destinationRoot: URL?

    init(
        alias: String = "ZManager Mobile",
        fingerprint: String = UUID().uuidString,
        port: UInt16 = UInt16(LocalSendClient.defaultPort),
        fileManager: FileManager = .default
    ) {
        self.alias = alias
        self.fingerprint = fingerprint
        self.port = port
        self.fileManager = fileManager
    }

    func start(destinationRoot: URL) throws -> Int {
        guard listener == nil else { throw LocalSendTransferError.receiverAlreadyRunning }
        try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
        self.destinationRoot = destinationRoot
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                NSLog("LocalSend receiver stopped: \(error.localizedDescription)")
            }
        }
        listener.start(queue: queue)
        startAnnouncements()
        return Int(port)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        announceTimer?.cancel()
        announceTimer = nil
        announceConnection?.cancel()
        announceConnection = nil
        sessions.values.forEach { try? fileManager.removeItem(at: $0.root) }
        sessions.removeAll()
        destinationRoot = nil
    }

    private func accept(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                let request = RequestState()
                self?.receive(connection, request: request)
            }
        }
        connection.start(queue: queue)
    }

    private func receive(_ connection: NWConnection, request: RequestState) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            if let data, !data.isEmpty {
                do {
                    try self.consume(data, request: request)
                    if request.remaining == 0, request.headersParsed {
                        self.finish(connection, request: request)
                        return
                    }
                } catch {
                    self.respond(connection, status: 400, body: error.localizedDescription)
                    return
                }
            }
            if isComplete || error != nil {
                connection.cancel()
            } else {
                self.receive(connection, request: request)
            }
        }
    }

    private func consume(_ data: Data, request: RequestState) throws {
        if !request.headersParsed {
            request.headerBuffer.append(data)
            guard let marker = request.headerBuffer.range(of: Data("\r\n\r\n".utf8)) else {
                guard request.headerBuffer.count <= 16 * 1024 else { throw LocalSendTransferError.invalidResponse }
                return
            }
            let headerData = request.headerBuffer.subdata(in: 0..<marker.lowerBound)
            let bodyStart = marker.upperBound
            request.headerBuffer = Data(request.headerBuffer[bodyStart...])
            let lines = String(decoding: headerData, as: UTF8.self).components(separatedBy: "\r\n")
            let requestParts = lines.first?.split(separator: " ", maxSplits: 2).map(String.init) ?? []
            guard requestParts.count == 3 else { throw LocalSendTransferError.invalidResponse }
            request.method = requestParts[0]
            request.path = requestParts[1]
            for line in lines.dropFirst() {
                let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
                if parts.count == 2 { request.headers[parts[0].lowercased()] = parts[1].trimmingCharacters(in: .whitespacesAndNewlines) }
            }
            guard request.method == "POST", let length = Int(request.headers["content-length"] ?? "0"), length >= 0 else {
                throw LocalSendTransferError.invalidResponse
            }
            request.remaining = length
            request.headersParsed = true
            if request.path.hasPrefix("/api/localsend/v2/upload") {
                try prepareUploadFile(request)
            }
            let initialBody = request.headerBuffer
            request.headerBuffer.removeAll(keepingCapacity: false)
            if !initialBody.isEmpty { try consumeBody(initialBody, request: request) }
            return
        }
        try consumeBody(data, request: request)
    }

    private func consumeBody(_ data: Data, request: RequestState) throws {
        guard request.remaining > 0 else { return }
        let count = min(request.remaining, data.count)
        let chunk = data.prefix(count)
        if request.path.hasPrefix("/api/localsend/v2/upload") {
            try request.fileHandle?.write(contentsOf: Data(chunk))
            request.digest.update(data: Data(chunk))
        } else {
            guard request.bodyBuffer.count + count <= 4 * 1024 * 1024 else { throw LocalSendTransferError.invalidResponse }
            request.bodyBuffer.append(chunk)
        }
        request.remaining -= count
    }

    private func prepareUploadFile(_ request: RequestState) throws {
        guard let destinationRoot, let components = URLComponents(string: "http://localhost\(request.path)"),
              let sessionID = components.queryItems?.first(where: { $0.name == "sessionId" })?.value,
              let fileID = components.queryItems?.first(where: { $0.name == "fileId" })?.value,
              let token = components.queryItems?.first(where: { $0.name == "token" })?.value,
              let session = sessions[sessionID], let expected = session.files[fileID], expected.token == token else {
            throw LocalSendTransferError.rejected
        }
        request.session = session
        request.sessionID = sessionID
        request.expected = expected
        let temporary = session.root.appendingPathComponent("\(fileID).part")
        fileManager.createFile(atPath: temporary.path, contents: nil)
        request.temporaryFile = temporary
        request.fileHandle = try FileHandle(forWritingTo: temporary)
        _ = destinationRoot
    }

    private func finish(_ connection: NWConnection, request: RequestState) {
        do {
            if request.path.hasPrefix("/api/localsend/v2/prepare-upload") {
                try prepare(request)
                respond(connection, status: 200, json: prepareResponse(request))
            } else if request.path.hasPrefix("/api/localsend/v2/upload") {
                try commit(request)
                respond(connection, status: 200, body: "OK")
            } else if request.path.hasPrefix("/api/localsend/v2/cancel") {
                cancel(request)
                respond(connection, status: 200, body: "OK")
            } else {
                respond(connection, status: 404, body: "Not found")
            }
        } catch {
            try? request.fileHandle?.close()
            try? request.temporaryFile.map { try fileManager.removeItem(at: $0) }
            respond(connection, status: 400, body: error.localizedDescription)
        }
    }

    private func prepare(_ request: RequestState) throws {
        guard let root = destinationRoot,
              let json = try JSONSerialization.jsonObject(with: request.bodyBuffer) as? [String: Any],
              let files = json["files"] as? [String: Any], !files.isEmpty else {
            throw LocalSendTransferError.invalidResponse
        }
        let sessionID = UUID().uuidString
        let sessionRoot = root.appendingPathComponent(".localsend/\(sessionID)", isDirectory: true)
        try fileManager.createDirectory(at: sessionRoot, withIntermediateDirectories: true)
        var expected = [String: ExpectedFile]()
        for (key, rawValue) in files {
            guard let value = rawValue as? [String: Any] else { throw LocalSendTransferError.invalidResponse }
            let id = value["id"] as? String ?? key
            let name = Self.sanitizeIncomingName(value["fileName"] as? String ?? id)
            expected[id] = ExpectedFile(
                id: id,
                displayName: name,
                expectedBytes: (value["size"] as? NSNumber)?.int64Value ?? -1,
                sha256: value["sha256"] as? String,
                token: UUID().uuidString
            )
        }
        let session = ReceiveSession(root: sessionRoot, destinationRoot: root, files: expected)
        sessions[sessionID] = session
        request.session = session
        request.preparedSessionID = sessionID
    }

    private func prepareResponse(_ request: RequestState) -> [String: Any] {
        let sessionID = request.preparedSessionID ?? ""
        let files = request.session?.files.reduce(into: [String: String]()) { result, item in result[item.key] = item.value.token } ?? [:]
        return ["sessionId": sessionID, "files": files]
    }

    private func commit(_ request: RequestState) throws {
        guard let session = request.session, let expected = request.expected, let temporary = request.temporaryFile else {
            throw LocalSendTransferError.rejected
        }
        try request.fileHandle?.close()
        let values = try temporary.resourceValues(forKeys: [.fileSizeKey])
        let bytes = Int64(values.fileSize ?? 0)
        guard expected.expectedBytes < 0 || expected.expectedBytes == bytes else { throw LocalSendTransferError.rejected }
        if let sha256 = expected.sha256 {
            let actual = request.digest.finalize().map { String(format: "%02x", $0) }.joined()
            guard actual.caseInsensitiveCompare(sha256) == .orderedSame else { throw LocalSendTransferError.rejected }
        }
        let target = Self.uniqueTarget(root: session.destinationRoot, name: expected.displayName, fileManager: fileManager)
        try fileManager.moveItem(at: temporary, to: target)
        session.completed.insert(expected.id)
        if session.completed.count == session.files.count, let sessionID = request.sessionID {
            sessions.removeValue(forKey: sessionID)
            try? fileManager.removeItem(at: session.root)
        }
    }

    private func cancel(_ request: RequestState) {
        let sessionID = URLComponents(string: "http://localhost\(request.path)")?.queryItems?.first(where: { $0.name == "sessionId" })?.value
        if let sessionID, let session = sessions.removeValue(forKey: sessionID) { try? fileManager.removeItem(at: session.root) }
    }

    private func respond(_ connection: NWConnection, status: Int, body: String) {
        respond(connection, status: status, contentType: "text/plain; charset=utf-8", data: Data(body.utf8))
    }

    private func respond(_ connection: NWConnection, status: Int, json: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        respond(connection, status: status, contentType: "application/json", data: data)
    }

    private func respond(_ connection: NWConnection, status: Int, contentType: String, data: Data) {
        let reason = (200..<300).contains(status) ? "OK" : "Error"
        var response = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n".utf8)
        response.append(data)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func startAnnouncements() {
        guard let group = try? NWMulticastGroup(for: [NWEndpoint.hostPort(host: NWEndpoint.Host(LocalSendClient.multicastAddress), port: NWEndpoint.Port(rawValue: port)!)]) else { return }
        let connection = NWConnectionGroup(with: group, using: .udp)
        announceConnection = connection
        connection.start(queue: queue)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1)
        timer.setEventHandler(handler: DispatchWorkItem { [weak self] in
            guard let self, let connection = self.announceConnection else { return }
            let announcement = LocalSendAnnouncement(
                alias: self.alias,
                version: "2.0",
                deviceModel: UIDevice.current.model,
                deviceType: "mobile",
                fingerprint: self.fingerprint,
                port: Int(self.port),
                protocol: "http",
                download: true,
                announce: true
            )
            if let data = try? JSONEncoder().encode(announcement) { connection.send(content: data, completion: { _ in }) }
        })
        announceTimer = timer
        timer.resume()
    }

    static func sanitizeIncomingName(_ raw: String) -> String {
        let name = raw.split(separator: "/").last.map(String.init)?.split(separator: "\\").last.map(String.init) ?? raw
        let cleaned = name.replacingOccurrences(of: #"[\\/:*?\"<>|]"#, with: "_", options: .regularExpression)
            .filter { !$0.isNewline && $0.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) } }
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return cleaned.isEmpty ? "received-file" : cleaned
    }

    private static func uniqueTarget(root: URL, name: String, fileManager: FileManager) -> URL {
        let safe = sanitizeIncomingName(name)
        var candidate = root.appendingPathComponent(safe)
        var index = 1
        while fileManager.fileExists(atPath: candidate.path) {
            let base = candidate.deletingPathExtension().lastPathComponent
            let ext = candidate.pathExtension
            candidate = root.appendingPathComponent(ext.isEmpty ? "\(base) (\(index))" : "\(base) (\(index)).\(ext)")
            index += 1
        }
        return candidate
    }
}

private extension URLSessionTask {
    func value() async throws {
        while state == .running { try await Task.sleep(nanoseconds: 50_000_000) }
        if state == .canceling { throw CancellationError() }
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else {
            throw LocalSendTransferError.rejected
        }
    }
}

enum LocalSendTransferError: LocalizedError {
    case missingToken
    case rejected
    case invalidResponse
    case receiverAlreadyRunning

    var errorDescription: String? {
        switch self {
        case .missingToken: return "The LocalSend device did not provide an upload token."
        case .rejected: return "The LocalSend device rejected the transfer."
        case .invalidResponse: return "The LocalSend device returned an invalid response."
        case .receiverAlreadyRunning: return "LocalSend receiving is already enabled."
        }
    }
}
