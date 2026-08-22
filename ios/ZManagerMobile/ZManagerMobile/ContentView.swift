import QuickLook
import CryptoKit
import Network
import PhotosUI
import Security
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@available(iOS 16.0, *)
private struct PhotoCreationPicker: View {
    @State private var selectedItems = [PhotosPickerItem]()
    let onSelection: ([PhotosPickerItem]) -> Void

    var body: some View {
        PhotosPicker(
            selection: $selectedItems,
            maxSelectionCount: 50,
            matching: .any(of: [.images, .videos]),
            preferredItemEncoding: .current
        ) {
            Label("Choose photos or videos", systemImage: "photo.on.rectangle")
        }
        .buttonStyle(.bordered)
        .onChange(of: selectedItems) { items in
            onSelection(items)
            selectedItems = []
        }
    }
}

struct ContentView: View {
    // Split from one ArchiveImportModel into a shared session model plus
    // per-feature models, mirroring Android's ArchiveSessionViewModel +
    // feature-ViewModel split. Unlike Android, SwiftUI has no equivalent of
    // Compose's MutableState re-binding, so every reference below (not just
    // the ones shown in this file) had to be updated individually rather
    // than aliased. See Track 7 in docs/mobile-code-health-remediation-plan.md.
    @StateObject private var session: ArchiveSessionModel
    @StateObject private var listing: ArchiveListingModel
    @StateObject private var extraction: ArchiveExtractionModel
    @StateObject private var batchExtraction: ArchiveBatchExtractionModel
    @StateObject private var creation: ArchiveCreationModel
    @StateObject private var repackaging: ArchiveRepackagingModel
    @StateObject private var localSend: ArchiveLocalSendModel

    private let localSendTrustStore = LocalSendTrustStore()
    @Environment(\.scenePhase) private var scenePhase
    @State private var isFileImporterPresented = false
    @State private var isDestinationPickerPresented = false
    @State private var isCreationFilesImporterPresented = false
    @State private var isCreationFolderImporterPresented = false
    @State private var isBatchArchiveImporterPresented = false
    @State private var isLocalSendFilesImporterPresented = false
    @State private var isLocalSendReceiveDestinationPickerPresented = false
    @State private var localSendTrustVersion = 0
    @State private var recoveryShareURLs = [URL]()
    @State private var createdShareURLs = [URL]()
    @State private var isHelpPresented = false

    init() {
        let session = ArchiveSessionModel()
        let creation = ArchiveCreationModel(session: session)
        _session = StateObject(wrappedValue: session)
        _listing = StateObject(wrappedValue: ArchiveListingModel(session: session))
        _extraction = StateObject(wrappedValue: ArchiveExtractionModel(session: session))
        _batchExtraction = StateObject(wrappedValue: ArchiveBatchExtractionModel(session: session))
        _creation = StateObject(wrappedValue: creation)
        _repackaging = StateObject(wrappedValue: ArchiveRepackagingModel(session: session, creation: creation))
        _localSend = StateObject(wrappedValue: ArchiveLocalSendModel(session: session))
    }

    // MARK: - Coordination wrappers
    //
    // These have the same shape as the original ArchiveImportModel methods
    // they replace, so every call site below reads the same way it did
    // before the split. Cross-model coordination (listing resets on import,
    // recovery clearing a matching extraction state, scene-background
    // fan-out) lives here rather than in any one model, matching Android's
    // ZManagerApp-level wrapper functions.

    private func onListingLoadStarted() {
        listing.clearPreviewState()
        listing.clearTestState()
        listing.resetListingWindow()
    }

    private func onAutomationExtract(_ entries: [ArchiveEntrySummary], _ destination: ExtractionDestination) {
        extraction.planExtraction(selectedEntries: entries, destination: destination)
    }

    private func onAutomationVerify(_ entries: [ArchiveEntrySummary]) {
        listing.startTest(selectedEntries: entries)
    }

    private func importMaestroFixture() {
        session.importMaestroFixture(
            onImportStarted: onListingLoadStarted,
            onAutomationExtract: onAutomationExtract,
            onAutomationVerify: onAutomationVerify
        )
    }

    private func importMaestroFixture(
        named fixtureName: String,
        companionNames: [String] = [],
        pendingAction: ArchiveAutomationAction? = nil
    ) {
        session.importMaestroFixture(
            named: fixtureName,
            companionNames: companionNames,
            pendingAction: pendingAction,
            onImportStarted: onListingLoadStarted,
            onAutomationExtract: onAutomationExtract,
            onAutomationVerify: onAutomationVerify
        )
    }

    private func retryListingWithPassword() {
        session.retryListingWithPassword(
            onListingLoadStarted: onListingLoadStarted,
            onAutomationExtract: onAutomationExtract,
            onAutomationVerify: onAutomationVerify
        )
    }

    private func openNestedArchive(entry: ArchiveEntrySummary) {
        session.openNestedArchive(
            entry: entry,
            previewLoader: listing.previewLoader,
            onListingLoadStarted: onListingLoadStarted
        )
    }

    private func navigateBackFromNested() {
        session.navigateBackFromNested(onListingLoadStarted: onListingLoadStarted)
    }

    private func onExtractionRecoveryCleared(_ recoveryId: UUID) {
        if case .recoveryAvailable(let id, _) = extraction.extractionState, id == recoveryId {
            extraction.extractionState = .idle
        }
    }

    private func retryRecovery(_ record: ArchiveRecoveryRecord) {
        session.retryRecovery(
            record,
            onExtractionRecoveryCleared: onExtractionRecoveryCleared,
            onPlanExtraction: { entries, destination in
                extraction.planExtraction(selectedEntries: entries, destination: destination)
            }
        )
    }

    private func discardRecovery(_ record: ArchiveRecoveryRecord) {
        session.discardRecovery(record, onExtractionRecoveryCleared: onExtractionRecoveryCleared)
    }

    private func handleAutomationURL(_ url: URL) {
        session.handleAutomationURL(
            url,
            onImportStarted: onListingLoadStarted,
            onAutomationExtract: onAutomationExtract,
            onAutomationVerify: onAutomationVerify,
            onCreateFiles: { result in creation.handleCreationFilesResult(result) }
        )
    }

    private func startDebugCancellableExtraction() {
#if DEBUG
        // Keep the simulator job alive long enough for Maestro and manual
        // cancellation to observe the running state after a cold launch.
        session.debugJobPacer = DelayingJobPacer(delayNanoseconds: 60_000_000_000)
        importMaestroFixture(
            named: "maestro-split.zip",
            companionNames: ["maestro-split.z01"],
            pendingAction: .extract
        )
#endif
    }

    /// Creation's cancel button also cancels an in-flight repackaging job,
    /// since repackaging composes staged extraction with the create planner.
    /// The original `cancelCreation()` did both in one method; splitting the
    /// state holders split this too, into `creation.cancelCreation()` plus
    /// `repackaging.cancelRepackaging()` called together here.
    private func cancelCreationAndRepackaging() {
        creation.cancelCreation()
        repackaging.cancelRepackaging()
    }

    /// Fans out to each model's own scene-background handling rather than
    /// one model reaching into the others, so the password-scrubbing and
    /// job-cancellation behavior stays auditable in this one place. Mirrors
    /// Android's handleAppBackground coordinator.
    private func handleSceneBackground() {
        ArchiveSceneBackgroundCoordinator.handle(
            session: session,
            listing: listing,
            extraction: extraction,
            creation: creation,
            repackaging: repackaging,
            batchExtraction: batchExtraction,
            localSend: localSend
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("ZManager")
                    .font(.largeTitle.weight(.semibold))

                Text("Open an archive, inspect its contents, then extract safely.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                Text("Default extraction destination: \(session.defaultExtractionDestinationLabel)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Reset default destination") {
                    session.resetDefaultExtractionDestination()
                }
                Button("About & help") {
                    isHelpPresented = true
                }
                .accessibilityIdentifier("aboutAndHelp")
#if DEBUG
                Button("Load UDF fixture") {
                    importMaestroFixture(named: "maestro-files.udf")
                }
                .accessibilityIdentifier("debugLoadUdfTop")
                Button("Load VMDK fixture") {
                    importMaestroFixture(named: "maestro-files.vmdk")
                }
                .accessibilityIdentifier("debugLoadVmdkTop")
                Button("Load RPM fixture") {
                    importMaestroFixture(named: "maestro-files.rpm")
                }
                .accessibilityIdentifier("debugLoadRpmTop")
                Button("Load LHA fixture") {
                    importMaestroFixture(named: "maestro-files.lha")
                }
                .accessibilityIdentifier("debugLoadLhaTop")
                Button("Load WARC fixture") {
                    importMaestroFixture(named: "maestro-files.warc")
                }
                .accessibilityIdentifier("debugLoadWarcTop")
                Button("Load MTREE fixture") {
                    importMaestroFixture(named: "maestro-files.mtree")
                }
                .accessibilityIdentifier("debugLoadMtreeTop")
                Button("Load nested fixture") {
                    importMaestroFixture(named: "maestro-nested.zip")
                }
                Button("Load encrypted fixture") {
                    importMaestroFixture(named: "maestro-encrypted.zip")
                }
                Button("Create debug folder archive") {
                    creation.createDebugFixture()
                }
                Button("Create debug split archive") {
                    creation.createDebugSplitFixture()
                }
                Button("Create debug separate archives") {
                    creation.createDebugSeparateFixture()
                }
                Button("Run debug batch extraction") {
                    batchExtraction.startDebugBatchFixture()
                }
                Button("Run cancellable extraction") {
                    startDebugCancellableExtraction()
                }
                Button("Load DEB fixture") {
                    importMaestroFixture(named: "maestro-files.deb")
                }
                Button("Load CAB fixture") {
                    importMaestroFixture(named: "maestro-files.cab")
                }
                Button("Load TAR.LZ4 fixture") {
                    importMaestroFixture(named: "maestro-files.tar.lz4")
                }
                .accessibilityIdentifier("debugLoadTarLz4")
                Button("Load UU stream fixture") {
                    importMaestroFixture(named: "maestro-stream.uu")
                }
                .accessibilityIdentifier("debugLoadUuStream")
                Button("Load B64 stream fixture") {
                    importMaestroFixture(named: "maestro-stream.b64")
                }
                .accessibilityIdentifier("debugLoadB64Stream")
                Button("Load XAR fixture") {
                    importMaestroFixture(named: "maestro-files.xar")
                }
                .accessibilityIdentifier("debugLoadXar")
                Button("Load ISO fixture") {
                    importMaestroFixture(named: "maestro-files.iso")
                }
                .accessibilityIdentifier("debugLoadIso")
                Button("Load PKG fixture") {
                    importMaestroFixture(named: "maestro-files.pkg")
                }
                .accessibilityIdentifier("debugLoadPkg")
                Button("Load MSI fixture") {
                    importMaestroFixture(named: "maestro-files.msi")
                }
                .accessibilityIdentifier("debugLoadMsi")
                Button("Load DMG fixture") {
                    importMaestroFixture(named: "maestro-files.dmg")
                }
                .accessibilityIdentifier("debugLoadDmg")
                Button("Load VHD fixture") {
                    importMaestroFixture(named: "maestro-files.vhd")
                }
                .accessibilityIdentifier("debugLoadVhd")
                Button("Load VMDK fixture") {
                    importMaestroFixture(named: "maestro-files.vmdk")
                }
                .accessibilityIdentifier("debugLoadVmdk")
                Button("Load RPM fixture") {
                    importMaestroFixture(named: "maestro-files.rpm")
                }
                .accessibilityIdentifier("debugLoadRpm")
                Button("Load LHA fixture") {
                    importMaestroFixture(named: "maestro-files.lha")
                }
                .accessibilityIdentifier("debugLoadLha")
                Button("Load WARC fixture") {
                    importMaestroFixture(named: "maestro-files.warc")
                }
                .accessibilityIdentifier("debugLoadWarc")
                Button("Load MTREE fixture") {
                    importMaestroFixture(named: "maestro-files.mtree")
                }
                .accessibilityIdentifier("debugLoadMtree")
#endif
            }

            if let archive = session.importedArchive {
                if !session.archiveBreadcrumbs.isEmpty {
                    HStack {
                        Button("Back") { navigateBackFromNested() }
                        Text(session.archiveBreadcrumbs.joined(separator: " / "))
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

            if let message = session.errorMessage {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.red)
            }
            if let message = session.operationReportMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(session.recoveryRecords) { record in
                VStack(alignment: .leading, spacing: 6) {
                    Text("Recovery available for \(record.archiveDisplayName)")
                        .font(.headline)
                    Text(record.message)
                        .foregroundStyle(.red)
                    Text("Retained output: \(record.destinationLabel)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Retry") { retryRecovery(record) }
                        Button("Export") {
                            recoveryShareURLs = session.exportRecovery(record)
                        }
                        Button("Discard") { discardRecovery(record) }
                    }
                }
            }

            ArchiveListingPanel(
                state: session.listingState,
                password: $session.passwordInput,
                searchQuery: $session.entrySearchQuery,
                sort: $listing.entrySort,
                viewMode: $listing.entryViewMode,
                windowSize: listing.listingWindowSize,
                onLoadMore: { listing.loadMoreListingEntries() },
                onWindowReset: { listing.resetListingWindow() },
                selectedEntryIds: $session.selectedEntryIds,
                selectedEverything: $session.selectedEverything,
                onSelectEverything: { summary in session.selectEverything(summary) },
                previewState: listing.previewState,
                previewPassword: $listing.previewPasswordInput,
                testState: listing.testState,
                testPassword: $listing.testPasswordInput,
                onSubmitPassword: retryListingWithPassword,
                onPreviewEntry: { listing.startPreview(entry: $0) },
                onOpenNestedArchive: { openNestedArchive(entry: $0) },
                onSubmitPreviewPassword: { listing.retryPreviewWithPassword(entry: $0) },
                onTestEntries: { listing.startTest(selectedEntries: $0) },
                onSubmitTestPassword: { listing.retryTestWithPassword(selectedEntries: $0) },
                extractionState: extraction.extractionState,
                extractionPassword: $extraction.extractionPasswordInput,
                onExtractEntries: { extraction.planExtraction(
                    selectedEntries: $0,
                    destination: session.defaultExtractionDestination()
                ) },
                onChooseDestination: { isDestinationPickerPresented = true },
                onStartExtraction: extraction.startExtraction,
                onCancelExtraction: extraction.cancelExtraction,
                onRetryExtractionPassword: { extraction.retryExtractionWithPassword(selectedEntries: $0) },
                repackagingState: repackaging.repackagingState,
                repackagingPassword: $repackaging.repackagingPasswordInput,
                onRepackageEntries: { repackaging.startRepackaging(selectedEntries: $0) },
                onRetryRepackagingWithPassword: { entries, password in
                    repackaging.retryRepackagingWithPassword(selectedEntries: entries, password: password)
                },
                onShareRepackagedOutput: { paths in
                    createdShareURLs = paths
                        .map(URL.init(fileURLWithPath:))
                        .filter { FileManager.default.fileExists(atPath: $0.path) }
                },
                onStartRepackaging: repackaging.runRepackaging,
                onCancelRepackaging: repackaging.cancelRepackaging
            )
            if case .completed(let entries, let destination) = extraction.extractionState {
                Button("Save operation report") {
                    session.saveExtractionReport(entries: entries, destination: destination)
                }
            }
            if let message = session.nestedOpenError {
                Text(message).foregroundStyle(.red)
            }

            ArchiveCreationPanel(
                state: creation.creationState,
                format: creation.creationFormat,
                password: creation.creationPasswordInput,
                volumeSizeInput: creation.creationVolumeSizeInput,
                separateItems: creation.creationSeparateItems,
                onPasswordChanged: { creation.creationPasswordInput = $0 },
                onVolumeSizeChanged: { creation.creationVolumeSizeInput = $0 },
                onSeparateItemsChanged: { creation.creationSeparateItems = $0 },
                onFormatChanged: { creation.creationFormat = $0 },
                onChooseFiles: { isCreationFilesImporterPresented = true },
                onChooseFolder: { isCreationFolderImporterPresented = true },
                onDropFiles: creation.handleDroppedCreationFiles,
                onStart: { review in creation.startCreation(review) },
                onStartSeparate: creation.startSeparateCreation,
                onShareOutput: { paths in
                    createdShareURLs = paths
                        .map(URL.init(fileURLWithPath:))
                        .filter { FileManager.default.fileExists(atPath: $0.path) }
                },
                onCancel: cancelCreationAndRepackaging
            )
            if case .completed(let outcome) = creation.creationState,
               case .completed(let outputPath, let verified, _) = outcome {
                Button("Save operation report") {
                    session.saveCreationReport(outputPath: outputPath, verified: verified)
                }
            }
            ArchiveBatchExtractionPanel(
                state: batchExtraction.batchExtractionState,
                onStart: batchExtraction.startBatchExtraction,
                onCancel: batchExtraction.cancelBatchExtraction
            )
#if !os(macOS)
            if #available(iOS 16.0, *) {
                PhotoCreationPicker { items in creation.handlePhotosPickerItems(items) }
            }
#endif
            LocalSendPanel(
                archive: session.importedArchive,
                selectedFileCount: localSend.localSendSelectedFileCount,
                state: localSend.localSendState,
                onDiscover: localSend.discoverLocalSendDevices,
                onChooseFiles: { isLocalSendFilesImporterPresented = true },
                onClearFiles: localSend.clearLocalSendSelection,
                onSend: { localSend.pendingLocalSendDevice = $0 },
                pinInput: $localSend.localSendPinInput,
                onSubmitPin: { device, pin in localSend.sendSelectedFiles(to: device, pin: pin) },
                onCancelSend: localSend.cancelLocalSend,
                receiveDestinationLabel: localSend.localSendReceiveDestinationLabel,
                onChooseReceiveDestination: { isLocalSendReceiveDestinationPickerPresented = true },
                onStartReceive: localSend.startLocalReceive,
                onStopReceive: localSend.stopLocalReceive,
                trustedFingerprints: localSendTrustStore.fingerprints(),
                onForgetTrustedFingerprint: { fingerprint in
                    localSendTrustStore.forget(fingerprint: fingerprint)
                    localSendTrustVersion += 1
                }
            )
            .id(localSendTrustVersion)

            Spacer()

            HStack {
                Spacer()
#if DEBUG
                Button("Load Maestro fixture") {
                    importMaestroFixture()
                }
                .disabled(session.isImporting)
                Menu("Load test fixture") {
                    Button("Load test fixture") {}
                    Button("ZIP fixture") {
                        importMaestroFixture(named: "maestro-files.zip")
                    }
                    Button("7z fixture") {
                        importMaestroFixture(named: "maestro-files.7z")
                    }
                    Button("TGZ fixture") {
                        importMaestroFixture(named: "maestro-files.tgz")
                    }
                    Button("TAR.ZST fixture") {
                        importMaestroFixture(named: "maestro-files.tar.zst")
                    }
                    Button("TZAP fixture") {
                        importMaestroFixture(named: "maestro-files.tzap")
                    }
                    Button("TAR.BZ2 fixture") {
                        importMaestroFixture(named: "maestro-files.tar.bz2")
                    }
                    Button("TAR.XZ fixture") {
                        importMaestroFixture(named: "maestro-files.tar.xz")
                    }
                    Button("TAR.LZMA fixture") {
                        importMaestroFixture(named: "maestro-files.tar.lzma")
                    }
                    Button("TAR.LZ fixture") {
                        importMaestroFixture(named: "maestro-files.tar.lz")
                    }
                    Button("TAR.LZO fixture") {
                        importMaestroFixture(named: "maestro-files.tar.lzo")
                    }
                    Button("TAR.Z fixture") {
                        importMaestroFixture(named: "maestro-files.tar.z")
                    }
                    Button("TAR.LZ4 fixture") {
                        importMaestroFixture(named: "maestro-files.tar.lz4")
                    }
                    .accessibilityIdentifier("maestroFixtureTarLz4")
                    Button("TAR.UU fixture") {
                        importMaestroFixture(named: "maestro-files.tar.uu")
                    }
                    Button("GZIP stream fixture") {
                        importMaestroFixture(named: "maestro-stream.gz")
                    }
                    Button("BZIP2 stream fixture") {
                        importMaestroFixture(named: "maestro-stream.bz2")
                    }
                    Button("XZ stream fixture") {
                        importMaestroFixture(named: "maestro-stream.xz")
                    }
                    Button("LZMA stream fixture") {
                        importMaestroFixture(named: "maestro-stream.lzma")
                    }
                    Button("Lzip stream fixture") {
                        importMaestroFixture(named: "maestro-stream.lz")
                    }
                    Button("LZO stream fixture") {
                        importMaestroFixture(named: "maestro-stream.lzo")
                    }
                    Button("Unix compress stream fixture") {
                        importMaestroFixture(named: "maestro-stream.Z")
                    }
                    Button("LZ4 stream fixture") {
                        importMaestroFixture(named: "maestro-stream.lz4")
                    }
                    Button("Zstd stream fixture") {
                        importMaestroFixture(named: "maestro-stream.zst")
                    }
                    Button("Brotli stream fixture") {
                        importMaestroFixture(named: "maestro-stream.br")
                    }
                    Button("UU stream fixture") {
                        importMaestroFixture(named: "maestro-stream.uu")
                    }
                    Button("B64 stream fixture") {
                        importMaestroFixture(named: "maestro-stream.b64")
                    }
                    Button("Nested ZIP fixture") {
                        importMaestroFixture(named: "maestro-nested.zip")
                    }
                    Button("Encrypted ZIP fixture") {
                        importMaestroFixture(named: "maestro-encrypted.zip")
                    }
                    Button("Apple Archive fixture") {
                        importMaestroFixture(named: "maestro-files.aar")
                    }
                    Button("Split ZIP fixture") {
                        importMaestroFixture(
                            named: "maestro-split.zip",
                            companionNames: ["maestro-split.z01"]
                        )
                    }
                    Button("Split 7z fixture") {
                        importMaestroFixture(
                            named: "maestro-split.7z.001",
                            companionNames: ["maestro-split.7z.002"]
                        )
                    }
                    Button("Split TZAP fixture") {
                        importMaestroFixture(
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
                        importMaestroFixture(
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
                        importMaestroFixture(named: "maestro-files.deb")
                    }
                    Button("CAB fixture") {
                        importMaestroFixture(named: "maestro-files.cab")
                    }
                    Button("CPIO fixture") {
                        importMaestroFixture(named: "maestro-files.cpio")
                    }
                    Button("XAR fixture") {
                        importMaestroFixture(named: "maestro-files.xar")
                    }
                    Button("ISO fixture") {
                        importMaestroFixture(named: "maestro-files.iso")
                    }
                    Button("PKG fixture") {
                        importMaestroFixture(named: "maestro-files.pkg")
                    }
                    Button("MSI fixture") {
                        importMaestroFixture(named: "maestro-files.msi")
                    }
                    Button("AR fixture") {
                        importMaestroFixture(named: "maestro-files.ar")
                    }
                    Button("DMG fixture") {
                        importMaestroFixture(named: "maestro-files.dmg")
                    }
                    Button("VHD fixture") {
                        importMaestroFixture(named: "maestro-files.vhd")
                    }
                    Button("VMDK fixture") {
                        importMaestroFixture(named: "maestro-files.vmdk")
                    }
                    Button("UDF fixture") {
                        importMaestroFixture(named: "maestro-files.udf")
                    }
                    Button("RPM fixture") {
                        importMaestroFixture(named: "maestro-files.rpm")
                    }
                    Button("LHA fixture") {
                        importMaestroFixture(named: "maestro-files.lha")
                    }
                    Button("WARC fixture") {
                        importMaestroFixture(named: "maestro-files.warc")
                    }
                    Button("MTREE fixture") {
                        importMaestroFixture(named: "maestro-files.mtree")
                    }
                }
                .disabled(session.isImporting)
#endif
                Button(session.isImporting ? "Importing" : "Open Archive") {
                    isFileImporterPresented = true
                }
                .disabled(session.isImporting)
                .buttonStyle(.borderedProminent)
                Button("Batch extract") {
                    isBatchArchiveImporterPresented = true
                }
                .disabled(batchExtraction.batchExtractionState.isBusy)
                .buttonStyle(.bordered)
            }
        }
    }
        .frame(maxWidth: 1100)
        .padding(24)
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: ArchiveImportStore.allowedContentTypes,
            allowsMultipleSelection: true
        ) { result in
            session.handleFileImporterResult(
                result,
                onImportStarted: onListingLoadStarted,
                onAutomationExtract: onAutomationExtract,
                onAutomationVerify: onAutomationVerify
            )
        }
        .fileImporter(
            isPresented: $isDestinationPickerPresented,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                let destination = ExtractionDestination.folder(url)
                session.setDefaultExtractionDestination(destination)
                extraction.planExtraction(selectedEntries: listing.currentSelectedEntries, destination: destination)
            }
        }
        .fileImporter(
            isPresented: $isCreationFilesImporterPresented,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            creation.handleCreationFilesResult(result)
        }
        .fileImporter(
            isPresented: $isCreationFolderImporterPresented,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            creation.handleCreationFolderResult(result)
        }
        .fileImporter(
            isPresented: $isBatchArchiveImporterPresented,
            allowedContentTypes: ArchiveImportStore.allowedContentTypes,
            allowsMultipleSelection: true
        ) { result in
            batchExtraction.handleBatchArchiveResult(result)
        }
        .fileImporter(
            isPresented: $isLocalSendFilesImporterPresented,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            localSend.handleLocalSendFilesResult(result)
        }
        .fileImporter(
            isPresented: $isLocalSendReceiveDestinationPickerPresented,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            localSend.handleLocalSendReceiveDestinationResult(result)
        }
        .onOpenURL { url in
            handleAutomationURL(url)
        }
        .alert(
            "Confirm local transfer",
            isPresented: Binding(
                get: { localSend.pendingLocalSendDevice != nil },
                set: { if !$0 { localSend.pendingLocalSendDevice = nil } }
            )
        ) {
            Button("Send") {
                guard let device = localSend.pendingLocalSendDevice else { return }
                localSend.pendingLocalSendDevice = nil
                localSend.sendSelectedFiles(to: device)
            }
            Button("Trust and Send") {
                guard let device = localSend.pendingLocalSendDevice else { return }
                localSendTrustStore.remember(device)
                localSendTrustVersion += 1
                localSend.pendingLocalSendDevice = nil
                localSend.sendSelectedFiles(to: device)
            }
            Button("Cancel", role: .cancel) {
                localSend.pendingLocalSendDevice = nil
            }
        } message: {
            if let device = localSend.pendingLocalSendDevice {
                let fingerprint = device.fingerprint ?? "Unavailable"
                let message = "Send the selected archive or files to \(device.alias)?\n" +
                    "Address: \(device.address)\n" +
                    "Fingerprint: \(fingerprint)\n" +
                    (localSendTrustStore.isTrusted(device)
                        ? "This fingerprint is already trusted.\n"
                        : "") +
                    "Only continue if you recognize this device and fingerprint."
                Text(message)
            } else {
                Text("")
            }
        }
        .onChange(of: scenePhase) { phase in
            // `.inactive` is also emitted while iOS presents the keyboard or
            // password/autofill UI. Keep transient credentials available for
            // the active retry flow; clear them once the app actually enters
            // the background.
            if phase == .background {
                handleSceneBackground()
            }
        }
        .sheet(
            item: $listing.previewDocument,
            onDismiss: listing.cleanupActivePreview
        ) { document in
            QuickLookPreview(url: document.url)
        }
        .sheet(isPresented: Binding(
            get: { !recoveryShareURLs.isEmpty },
            set: { if !$0 { recoveryShareURLs = [] } }
        )) {
            RecoveryShareSheet(urls: recoveryShareURLs)
        }
        .sheet(isPresented: Binding(
            get: { !createdShareURLs.isEmpty },
            set: { if !$0 { createdShareURLs = [] } }
        )) {
            RecoveryShareSheet(urls: createdShareURLs)
        }
        .sheet(isPresented: $isHelpPresented) {
            NavigationView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("ZManager keeps archive listing, extraction, verification, and creation in the Rust core.")
                        Text("Choose an archive to inspect it, select entries to extract or repackage, and use Share on local network for LocalSend-compatible transfers.")
                        Text("Passwords are transient and are not included in operation reports.")
                    }
                    .frame(maxWidth: 700, alignment: .leading)
                    .padding()
                }
                .navigationTitle("About ZManager")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Close") { isHelpPresented = false }
                    }
                }
            }
            .accessibilityIdentifier("aboutAndHelpSheet")
        }
    }
}

