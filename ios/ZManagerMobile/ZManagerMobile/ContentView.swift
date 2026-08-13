import QuickLook
import CryptoKit
import Network
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// A UIKit-backed secure field keeps its responder identity stable while the
/// transient password binding changes. This matters for automation and for
/// hardware-keyboard input: recreating a SwiftUI SecureField after the first
/// character can drop focus and silently truncate the password.
struct StableSecureInputField: UIViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let contentType: UITextContentType?
    let onSubmit: (String) -> Void
    let onTextChanged: (String) -> Void
    let onFieldReady: (UITextField) -> Void

    init(
        _ placeholder: String,
        text: Binding<String>,
        contentType: UITextContentType? = nil,
        onSubmit: @escaping (String) -> Void = { _ in },
        onTextChanged: @escaping (String) -> Void = { _ in },
        onFieldReady: @escaping (UITextField) -> Void = { _ in }
    ) {
        self._text = text
        self.placeholder = placeholder
        self.contentType = contentType
        self.onSubmit = onSubmit
        self.onTextChanged = onTextChanged
        self.onFieldReady = onFieldReady
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit, onTextChanged: onTextChanged)
    }

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField(frame: .zero)
        field.borderStyle = .roundedRect
        field.placeholder = placeholder
        field.isSecureTextEntry = true
        field.textContentType = contentType
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.returnKeyType = .done
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.valueChanged(_:)), for: .editingChanged)
        field.accessibilityLabel = placeholder
        field.text = text
        context.coordinator.inputValue = text
        onFieldReady(field)
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onSubmit = onSubmit
        context.coordinator.onTextChanged = onTextChanged
        // UIKit remains the source of truth after makeUIView. SwiftUI may
        // render a frame behind the latest editingChanged event; copying the
        // stale binding back would truncate automation and hardware-keyboard
        // input after the first character.
        field.placeholder = placeholder
        field.accessibilityLabel = placeholder
        onFieldReady(field)
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var text: Binding<String>
        var onSubmit: (String) -> Void
        var onTextChanged: (String) -> Void
        var inputValue = ""

        init(
            text: Binding<String>,
            onSubmit: @escaping (String) -> Void,
            onTextChanged: @escaping (String) -> Void
        ) {
            self.text = text
            self.onSubmit = onSubmit
            self.onTextChanged = onTextChanged
        }

        @objc func valueChanged(_ sender: UITextField) {
            let value = sender.text ?? ""
            inputValue = value
            text.wrappedValue = value
            onTextChanged(value)
        }

        func textField(
            _ textField: UITextField,
            shouldChangeCharactersIn range: NSRange,
            replacementString string: String
        ) -> Bool {
            let current = inputValue as NSString
            guard range.location <= current.length,
                  range.location + range.length <= current.length else {
                return false
            }
            inputValue = current.replacingCharacters(in: range, with: string)
            textField.text = inputValue
            text.wrappedValue = inputValue
            onTextChanged(inputValue)
            return false
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            text.wrappedValue = textField.text ?? ""
            onSubmit(textField.text ?? "")
            return true
        }
    }
}

final class StableInputBuffer: ObservableObject {
    @Published var value = ""
    weak var field: UITextField?
}

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
    @StateObject private var importModel = ArchiveImportModel()
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("ZManager")
                    .font(.largeTitle.weight(.semibold))

                Text("Open an archive, inspect its contents, then extract safely.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                Text("Default extraction destination: \(importModel.defaultExtractionDestinationLabel)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Reset default destination") {
                    importModel.resetDefaultExtractionDestination()
                }
#if DEBUG
                Button("Load nested fixture") {
                    importModel.importMaestroFixture(named: "maestro-nested.zip")
                }
                Button("Load encrypted fixture") {
                    importModel.importMaestroFixture(named: "maestro-encrypted.zip")
                }
                Button("Create debug folder archive") {
                    importModel.createDebugFixture()
                }
                Button("Run debug batch extraction") {
                    importModel.startDebugBatchFixture()
                }
                Button("Run cancellable extraction") {
                    importModel.startDebugCancellableExtraction()
                }
                Button("Load DEB fixture") {
                    importModel.importMaestroFixture(named: "maestro-files.deb")
                }
                Button("Load CAB fixture") {
                    importModel.importMaestroFixture(named: "maestro-files.cab")
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
            if let message = importModel.operationReportMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(importModel.recoveryRecords) { record in
                VStack(alignment: .leading, spacing: 6) {
                    Text("Recovery available for \(record.archiveDisplayName)")
                        .font(.headline)
                    Text(record.message)
                        .foregroundStyle(.red)
                    Text("Retained output: \(record.destinationLabel)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Retry") { importModel.retryRecovery(record) }
                        Button("Export") {
                            recoveryShareURLs = importModel.exportRecovery(record)
                        }
                        Button("Discard") { importModel.discardRecovery(record) }
                    }
                }
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
                onExtractEntries: { importModel.planExtraction(
                    selectedEntries: $0,
                    destination: importModel.defaultExtractionDestination()
                ) },
                onChooseDestination: { isDestinationPickerPresented = true },
                onStartExtraction: importModel.startExtraction,
                onCancelExtraction: importModel.cancelExtraction,
                onRetryExtractionPassword: { importModel.retryExtractionWithPassword(selectedEntries: $0) },
                repackagingState: importModel.repackagingState,
                repackagingPassword: $importModel.repackagingPasswordInput,
                onRepackageEntries: { importModel.startRepackaging(selectedEntries: $0) },
                onRetryRepackagingWithPassword: { entries, password in
                    importModel.retryRepackagingWithPassword(selectedEntries: entries, password: password)
                },
                onStartRepackaging: importModel.runRepackaging,
                onCancelRepackaging: importModel.cancelRepackaging
            )
            if case .completed(let entries, let destination) = importModel.extractionState {
                Button("Save operation report") {
                    importModel.saveExtractionReport(entries: entries, destination: destination)
                }
            }
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
                onDropFiles: importModel.handleDroppedCreationFiles,
                onStart: importModel.startCreation,
                onCancel: importModel.cancelCreation
            )
            if case .completed(let outcome) = importModel.creationState,
               case .completed(let outputPath, let verified) = outcome {
                Button("Save operation report") {
                    importModel.saveCreationReport(outputPath: outputPath, verified: verified)
                }
            }
            ArchiveBatchExtractionPanel(
                state: importModel.batchExtractionState,
                onStart: importModel.startBatchExtraction,
                onCancel: importModel.cancelBatchExtraction
            )
#if !os(macOS)
            if #available(iOS 16.0, *) {
                PhotoCreationPicker { items in importModel.handlePhotosPickerItems(items) }
            }
#endif
            LocalSendPanel(
                archive: importModel.importedArchive,
                selectedFileCount: importModel.localSendSelectedFileCount,
                state: importModel.localSendState,
                onDiscover: importModel.discoverLocalSendDevices,
                onChooseFiles: { isLocalSendFilesImporterPresented = true },
                onClearFiles: importModel.clearLocalSendSelection,
                onSend: { importModel.pendingLocalSendDevice = $0 },
                pinInput: $importModel.localSendPinInput,
                onSubmitPin: { device, pin in importModel.sendSelectedFiles(to: device, pin: pin) },
                onCancelSend: importModel.cancelLocalSend,
                receiveDestinationLabel: importModel.localSendReceiveDestinationLabel,
                onChooseReceiveDestination: { isLocalSendReceiveDestinationPickerPresented = true },
                onStartReceive: importModel.startLocalReceive,
                onStopReceive: importModel.stopLocalReceive,
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
                    Button("Encrypted ZIP fixture") {
                        importModel.importMaestroFixture(named: "maestro-encrypted.zip")
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
                Button("Batch extract") {
                    isBatchArchiveImporterPresented = true
                }
                .disabled(importModel.batchExtractionState.isBusy)
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
            importModel.handleFileImporterResult(result)
        }
        .fileImporter(
            isPresented: $isDestinationPickerPresented,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                let destination = ExtractionDestination.folder(url)
                importModel.setDefaultExtractionDestination(destination)
                importModel.planExtraction(selectedEntries: importModel.currentSelectedEntries, destination: destination)
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
        .fileImporter(
            isPresented: $isBatchArchiveImporterPresented,
            allowedContentTypes: ArchiveImportStore.allowedContentTypes,
            allowsMultipleSelection: true
        ) { result in
            importModel.handleBatchArchiveResult(result)
        }
        .fileImporter(
            isPresented: $isLocalSendFilesImporterPresented,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            importModel.handleLocalSendFilesResult(result)
        }
        .fileImporter(
            isPresented: $isLocalSendReceiveDestinationPickerPresented,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            importModel.handleLocalSendReceiveDestinationResult(result)
        }
        .onOpenURL { url in
            importModel.handleAutomationURL(url)
        }
        .alert(
            "Confirm local transfer",
            isPresented: Binding(
                get: { importModel.pendingLocalSendDevice != nil },
                set: { if !$0 { importModel.pendingLocalSendDevice = nil } }
            )
        ) {
            Button("Send") {
                guard let device = importModel.pendingLocalSendDevice else { return }
                importModel.pendingLocalSendDevice = nil
                importModel.sendSelectedFiles(to: device)
            }
            Button("Trust and Send") {
                guard let device = importModel.pendingLocalSendDevice else { return }
                localSendTrustStore.remember(device)
                localSendTrustVersion += 1
                importModel.pendingLocalSendDevice = nil
                importModel.sendSelectedFiles(to: device)
            }
            Button("Cancel", role: .cancel) {
                importModel.pendingLocalSendDevice = nil
            }
        } message: {
            if let device = importModel.pendingLocalSendDevice {
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
                importModel.handleSceneBackground()
            }
        }
        .sheet(
            item: $importModel.previewDocument,
            onDismiss: importModel.cleanupActivePreview
        ) { document in
            QuickLookPreview(url: document.url)
        }
        .sheet(isPresented: Binding(
            get: { !recoveryShareURLs.isEmpty },
            set: { if !$0 { recoveryShareURLs = [] } }
        )) {
            RecoveryShareSheet(urls: recoveryShareURLs)
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

struct RecoveryShareSheet: UIViewControllerRepresentable {
    let urls: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: urls, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

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
}

struct ArchiveAutomationRequest: Equatable {
    let action: ArchiveAutomationAction
    let archiveURL: URL?
    let sourceURLs: [URL]
}

enum ArchiveAutomationError: LocalizedError, Equatable {
    case unsupportedScheme
    case unsupportedAction
    case credentialQuery
    case missingArchive
    case missingFiles
    case nonLocalURL

    var errorDescription: String? {
        switch self {
        case .unsupportedScheme: return "Unsupported automation scheme."
        case .unsupportedAction: return "Unsupported automation action."
        case .credentialQuery: return "Passwords and credentials are not accepted by automation."
        case .missingArchive: return "Automation requires a local archive URL."
        case .missingFiles: return "Create automation requires local files."
        case .nonLocalURL: return "Automation accepts only local file URLs."
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

    func stageData(_ items: [(name: String, data: Data)]) throws -> StagedCreationSources {
        guard !items.isEmpty else { throw ArchiveImportError.emptySelection }
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("ZManagerMobile/CreationSources/\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            var paths: [String] = []
            for item in items {
                let target = uniqueTarget(root: root, name: ArchiveImportStore.sanitizedDisplayName(item.name))
                try item.data.write(to: target, options: .atomic)
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

/// Copies security-scoped selections into private files before LocalSend reads them.
struct LocalSendSourceStager {
    let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func stageFiles(_ urls: [URL]) throws -> StagedCreationSources {
        guard !urls.isEmpty else { throw ArchiveImportError.emptySelection }
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("ZManagerMobile/LocalSendSources/\(UUID().uuidString)", isDirectory: true)
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

    func discard(_ staged: StagedCreationSources) {
        try? fileManager.removeItem(at: staged.root)
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
    @Binding var repackagingPassword: String
    let onRepackageEntries: ([ArchiveEntrySummary]) -> Void
    let onRetryRepackagingWithPassword: ([ArchiveEntrySummary], String) -> Void
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
                repackagingPassword: $repackagingPassword,
                onRepackageEntries: onRepackageEntries,
                onRetryRepackagingWithPassword: onRetryRepackagingWithPassword,
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
    @Binding var repackagingPassword: String
    let onRepackageEntries: ([ArchiveEntrySummary]) -> Void
    let onRetryRepackagingWithPassword: ([ArchiveEntrySummary], String) -> Void
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
            VStack(alignment: .leading, spacing: 8) {
                Text("\(selectedEntries.count) selected")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
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
    @Binding var password: String
    let onRetryWithPassword: ([ArchiveEntrySummary], String) -> Void
    let onStart: () -> Void
    let onCancel: () -> Void
    @State private var draftPassword = ""
    @StateObject private var passwordBuffer = StableInputBuffer()

    var body: some View {
        Group {
            switch state {
    case .idle:
            EmptyView()
        case .planning:
            Text("Preparing repackaging plan")
                .font(.subheadline)
        case .passwordRequired(let message, let selectedEntries, _):
            VStack(alignment: .leading, spacing: 8) {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.red)
                HStack {
                    Button("Retry") {
                        submitPassword(
                            selectedEntries,
                            password: passwordBuffer.value
                        )
                    }
                    .disabled(passwordBuffer.value.isEmpty)
                    Button("Cancel", action: onCancel)
                }
                StableSecureInputField(
                    "Archive password",
                    text: $draftPassword,
                    onSubmit: { submittedPassword in
                        submitPassword(selectedEntries, password: submittedPassword)
                    },
                    onTextChanged: { value in
                        passwordBuffer.value = value
                    },
                    onFieldReady: { field in
                        passwordBuffer.field = field
                    }
                )
            }
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
        .onChange(of: stateIdentity) { _ in
        if case .passwordRequired = state {
            draftPassword = password
        } else {
            draftPassword = ""
        }
    }
        .onAppear {
        if case .passwordRequired = state {
            draftPassword = password
        }
    }
    }

    private var stateIdentity: String {
        switch state {
        case .passwordRequired: return "password-required"
        case .idle: return "idle"
        case .planning: return "planning"
        case .review: return "review"
        case .running: return "running"
        case .completed: return "completed"
        case .cancelled: return "cancelled"
        case .failed: return "failed"
        }
    }

    private func submitPassword(_ selectedEntries: [ArchiveEntrySummary], password submittedPassword: String) {
        password = submittedPassword
        onRetryWithPassword(selectedEntries, submittedPassword)
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
    case passwordRequired(String, [ArchiveEntrySummary], ArchiveRepackagingReview?)
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
    @Published var batchExtractionState: BatchExtractionUIState = .idle
    @Published var repackagingState: ArchiveRepackagingState = .idle
    @Published var repackagingPasswordInput = ""
    private var repackagingSelectedEntries = [ArchiveEntrySummary]()
    private var repackagingPasswordRetryReview: ArchiveRepackagingReview?
    @Published var previewDocument: PreviewDocument?
    @Published var creationState: ArchiveCreationState = .idle
    @Published var creationFormat: CreateArchiveFormat = .zip
    @Published var creationPasswordInput = ""
    @Published var localSendState: LocalSendUIState = .idle
    @Published var localSendPinInput = ""
    @Published var pendingLocalSendDevice: LocalSendDevice?
    @Published var operationReportMessage: String?
    @Published var defaultExtractionDestinationLabel = "App storage"
    @Published var recoveryRecords = [ArchiveRecoveryRecord]()
    private var debugExtractionDelayNanoseconds: UInt64 = 0
    private var cancellationRequestedExtractionJobIDs = Set<String>()

    private let importStore: ArchiveImportStore
    private let listingLoader: ArchiveListingLoader
    private let previewLoader: ArchivePreviewLoader
    private let testLoader: ArchiveTestLoader
    private let extractionCoordinator: ArchiveExtractionCoordinator
    private let batchExtractionCoordinator: BatchExtractionCoordinator
    private let creationCoordinator: ArchiveCreationCoordinator
    private let creationSourceStager: ArchiveCreationSourceStager
    private let localSendSourceStager: LocalSendSourceStager
    private let repackagingCoordinator: ArchiveRepackagingCoordinator
    private let localSendClient: LocalSendClient
    private let localSendReceiver: LocalSendReceiver
    private let destinationPreferences: ArchiveDestinationPreferences
    private var activeLocalSendDevice: LocalSendDevice?
    private var activeLocalSendSessionID: String?
    private var stagedCreationSources: StagedCreationSources?
    private var stagedLocalSendSources: StagedCreationSources?
    private var localSendReceiveDestination: URL?
    private var localSendReceiveDestinationAccess = false
    private var localSendReceiveStagingRoot: URL?
    private var pendingAutomationAction: ArchiveAutomationAction?
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
        localSendSourceStager: LocalSendSourceStager = LocalSendSourceStager(),
        repackagingCoordinator: ArchiveRepackagingCoordinator? = nil,
        localSendClient: LocalSendClient = LocalSendClient(),
        localSendReceiver: LocalSendReceiver = LocalSendReceiver(),
        destinationPreferences: ArchiveDestinationPreferences = ArchiveDestinationPreferences()
    ) {
        self.importStore = importStore
        self.listingLoader = listingLoader
        self.previewLoader = previewLoader
        self.testLoader = testLoader
        self.extractionCoordinator = extractionCoordinator
        self.batchExtractionCoordinator = BatchExtractionCoordinator(extraction: extractionCoordinator)
        self.creationCoordinator = creationCoordinator
        self.creationSourceStager = creationSourceStager
        self.localSendSourceStager = localSendSourceStager
        self.repackagingCoordinator = repackagingCoordinator ?? ArchiveRepackagingCoordinator(
            extraction: extractionCoordinator,
            creation: creationCoordinator
        )
        self.localSendClient = localSendClient
        self.localSendReceiver = localSendReceiver
        self.destinationPreferences = destinationPreferences
        self.defaultExtractionDestinationLabel = defaultExtractionDestination().label
        self.recoveryRecords = extractionCoordinator.recoveries()
        self.localSendReceiver.onFileCommitted = { [weak self] file, displayName in
            Task { @MainActor in
                self?.exportReceivedLocalSendFile(file, displayName: displayName)
            }
        }
    }

    deinit {
        localSendReceiver.stop()
        if localSendReceiveDestinationAccess, let localSendReceiveDestination {
            localSendReceiveDestination.stopAccessingSecurityScopedResource()
        }
        if let localSendReceiveStagingRoot {
            try? FileManager.default.removeItem(at: localSendReceiveStagingRoot)
        }
        if let stagedLocalSendSources {
            localSendSourceStager.discard(stagedLocalSendSources)
        }
    }

    var localSendSelectedFileCount: Int {
        stagedLocalSendSources?.sourcePaths.count ?? 0
    }

    var localSendReceiveDestinationLabel: String {
        localSendReceiveDestination?.lastPathComponent ?? "App storage"
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

    func discardRecovery(_ record: ArchiveRecoveryRecord) {
        extractionCoordinator.discardRecovery(record)
        refreshRecoveryRecords()
        if case .recoveryAvailable(let id, _) = extractionState, id == record.id {
            extractionState = .idle
        }
    }

    func retryRecovery(_ record: ArchiveRecoveryRecord) {
        guard let archive = importedArchive,
              archive.localPath == record.archivePath,
              case .ready(let summary) = listingState else {
            errorMessage = "Import (record.archiveDisplayName) again to retry the retained extraction."
            return
        }
        let selectedEntries = record.selectedPaths.isEmpty
            ? summary.entries
            : summary.entries.filter { record.selectedPaths.contains($0.path) }
        discardRecovery(record)
        planExtraction(selectedEntries: selectedEntries, destination: defaultExtractionDestination())
    }

    func exportRecovery(_ record: ArchiveRecoveryRecord) -> [URL] {
        extractionCoordinator.recoveryFiles(record)
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

    func handleAutomationURL(_ url: URL) {
        guard url.scheme?.lowercased() == "zmanager" else {
            importExternalURL(url)
            return
        }
        do {
            let request = try ArchiveAutomationParser.parse(url)
            switch request.action {
            case .create:
                handleCreationFilesResult(.success(request.sourceURLs))
            case .open, .extract, .verify:
                if let archiveURL = request.archiveURL {
                    importExternalURLs(
                        [archiveURL],
                        pendingAction: request.action == .open ? nil : request.action
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
        pendingAction: ArchiveAutomationAction? = nil
    ) {
        if pendingAction != .extract {
            debugExtractionDelayNanoseconds = 0
        }
        importGeneration += 1
        listingGeneration += 1
        pendingAutomationAction = pendingAction
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
        clearLocalSendSelection()

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

    func importMaestroFixture(
        named fixtureName: String,
        companionNames: [String] = [],
        pendingAction: ArchiveAutomationAction? = nil
    ) {
        if pendingAction != .extract {
            debugExtractionDelayNanoseconds = 0
        }
        let fixtureURLs = ([fixtureName] + companionNames).compactMap {
            Bundle.main.url(forResource: $0, withExtension: nil)
        }
        guard fixtureURLs.count == companionNames.count + 1 else {
            errorMessage = "The Maestro fixture is not available in this build."
            return
        }
        importExternalURLs(fixtureURLs, pendingAction: pendingAction)
    }

    func startDebugCancellableExtraction() {
#if DEBUG
        // Keep the simulator job alive long enough for Maestro and manual
        // cancellation to observe the running state after a cold launch.
        debugExtractionDelayNanoseconds = 60_000_000_000
        importMaestroFixture(
            named: "maestro-split.zip",
            companionNames: ["maestro-split.z01"],
            pendingAction: .extract
        )
#endif
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

    func startRepackaging(selectedEntries: [ArchiveEntrySummary], sourcePassword: String? = nil) {
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
            sourcePassword: sourcePassword ?? (repackagingPasswordInput.isEmpty ? nil : repackagingPasswordInput),
            destinationPassword: creationPasswordInput.isEmpty ? nil : creationPasswordInput
        )
        repackagingSelectedEntries = selectedEntries
        repackagingState = .planning
        Task {
            do {
                let review = try await Task.detached(priority: .userInitiated) {
                    return try self.repackagingCoordinator.plan(request: request)
                }.value
                repackagingPasswordRetryReview = review
                repackagingState = .review(review)
            } catch let ZmanagerGuiError.Bridge(code, userMessage, _, _, _)
                where code == "password_required" || code == "invalid_password" {
                repackagingState = .passwordRequired(userMessage, selectedEntries, nil)
            } catch {
                repackagingState = .failed(error.localizedDescription)
            }
        }
    }

    func retryRepackagingWithPassword(selectedEntries: [ArchiveEntrySummary], password: String) {
        let password = password.isEmpty ? nil : password
        repackagingState = .planning
        repackagingPasswordInput = ""
        if let review = repackagingPasswordRetryReview {
            // Re-plan with the new transient password. A failed Rust job may
            // retain a completed/failed extraction handle, and re-planning
            // guarantees the retry starts a fresh Rust operation with the
            // updated request rather than mutating a stale job session.
            repackagingCoordinator.discard(review: review)
            repackagingPasswordRetryReview = nil
            startRepackaging(selectedEntries: selectedEntries, sourcePassword: password)
            return
        }
        startRepackaging(selectedEntries: selectedEntries, sourcePassword: password)
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
            case .passwordRequired(let message):
                repackagingPasswordRetryReview = review
                repackagingState = .passwordRequired(message, repackagingSelectedEntries, review)
            case .failed(let message):
                repackagingState = .failed(message)
            }
            passwordInput = ""
            creationPasswordInput = ""
            repackagingPasswordInput = ""
        }
    }

    func cancelRepackaging() {
        if case .review(let review) = repackagingState {
            repackagingCoordinator.discard(review: review)
            repackagingState = .idle
        } else if case .running(let review, _) = repackagingState {
            repackagingCoordinator.cancel(review: review)
        } else if case .passwordRequired(_, _, let review?) = repackagingState {
            repackagingCoordinator.discard(review: review)
            repackagingPasswordRetryReview = nil
            repackagingState = .idle
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
        password: String? = nil,
        debugDelayNanoseconds: UInt64? = nil
    ) {
        guard let archive = importedArchive else { return }
        clearExtractionState()
        let destination = destination ?? extractionCoordinator.appStorageDestination()
        let selectedPaths = extractionSelectedPaths(for: selectedEntries)
        let extractionDebugDelay = debugDelayNanoseconds ?? self.debugExtractionDelayNanoseconds
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
                        collisionPolicy: .refuse,
                        debugDelayNanoseconds: extractionDebugDelay
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

    func handleDroppedCreationFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        do { try planCreation(staged: creationSourceStager.stageFiles(urls)) }
        catch { creationState = .failed(error.localizedDescription) }
    }

    @available(iOS 16.0, *)
    func handlePhotosPickerItems(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        creationState = .planning
        Task {
            do {
                var stagedItems: [(name: String, data: Data)] = []
                for (index, item) in items.enumerated() {
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        throw ArchiveImportError.cacheUnavailable
                    }
                    let extensionName = item.supportedContentTypes.first?.preferredFilenameExtension ?? "dat"
                    stagedItems.append(("photo-\(index + 1).\(extensionName)", data))
                }
                try planCreation(staged: creationSourceStager.stageData(stagedItems))
            } catch {
                creationState = .failed(error.localizedDescription)
            }
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

    func handleBatchArchiveResult(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, !urls.isEmpty else {
            if case .failure(let error) = result { batchExtractionState = .failed(error.localizedDescription) }
            return
        }
        batchExtractionState = .planning
        let importStore = self.importStore
        Task {
            do {
                let items = try await Task.detached(priority: .userInitiated) {
                    let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                        .appendingPathComponent("ZManagerMobile/BatchExtracted", isDirectory: true)
                    return try urls.enumerated().map { index, url in
                        let archive = try importStore.importArchive(from: url)
                        let displayName = ArchiveImportStore.sanitizedDisplayName(archive.displayName)
                        let baseName = URL(fileURLWithPath: displayName)
                            .deletingPathExtension()
                            .lastPathComponent
                        return BatchExtractionItem(
                            archive: archive,
                            selectedPaths: [],
                            destination: .appStorage(
                                root.appendingPathComponent("\(baseName.isEmpty ? "archive" : baseName)-\(index)", isDirectory: true)
                            )
                        )
                    }
                }.value
                let review = try batchExtractionCoordinator.plan(items: items)
                batchExtractionState = .review(review)
            } catch {
                batchExtractionState = .failed(error.localizedDescription)
            }
        }
    }

    func startDebugBatchFixture() {
        guard let fixtureURL = Bundle.main.url(forResource: "maestro-nested.zip", withExtension: nil) else {
            batchExtractionState = .failed("The batch fixture is not available in this build.")
            return
        }
        batchExtractionState = .planning
        let importStore = self.importStore
        Task {
            do {
                let items = try await Task.detached(priority: .userInitiated) {
                    let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                        .appendingPathComponent("ZManagerMobile/BatchExtracted", isDirectory: true)
                    return try (0..<2).map { index in
                        let archive = try importStore.importArchive(from: fixtureURL)
                        return BatchExtractionItem(
                            archive: archive,
                            selectedPaths: [],
                            destination: .appStorage(root.appendingPathComponent("fixture-\(index)", isDirectory: true))
                        )
                    }
                }.value
                batchExtractionState = .review(try batchExtractionCoordinator.plan(items: items))
            } catch {
                batchExtractionState = .failed("Unable to prepare batch fixture.")
            }
        }
    }

    func startBatchExtraction() {
        guard case .review(let review) = batchExtractionState else { return }
        batchExtractionState = .running
        Task {
            let outcome = await batchExtractionCoordinator.run(review: review) { archive, message in
                _ = archive
                _ = message
            }
            switch outcome {
            case .completed(let results):
                let completed = results.filter { $0.status == .completed }.count
                let failed = results.filter { $0.status == .failed }.count
                batchExtractionState = .completed(
                    "Batch extraction complete: \(completed) completed, \(failed) failed."
                )
            case .cancelled:
                batchExtractionState = .cancelled
            }
        }
    }

    func cancelBatchExtraction() {
        switch batchExtractionState {
        case .review(let review):
            batchExtractionCoordinator.discard(review: review)
            batchExtractionState = .idle
        case .running:
            batchExtractionCoordinator.cancel()
        default:
            break
        }
    }

    func handleLocalSendFilesResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            do {
                let staged = try localSendSourceStager.stageFiles(urls)
                clearLocalSendSelection()
                stagedLocalSendSources = staged
                localSendState = .idle
            } catch {
                localSendState = .failed(error.localizedDescription)
            }
        case .failure(let error):
            localSendState = .failed(error.localizedDescription)
        }
    }

    func clearLocalSendSelection() {
        if let stagedLocalSendSources {
            localSendSourceStager.discard(stagedLocalSendSources)
            self.stagedLocalSendSources = nil
        }
    }

    func handleLocalSendReceiveDestinationResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            stopLocalSendReceiveDestinationAccess()
            localSendReceiveDestinationAccess = url.startAccessingSecurityScopedResource()
            localSendReceiveDestination = url
            localSendState = .idle
        case .failure(let error):
            localSendState = .failed(error.localizedDescription)
        }
    }

    /// Clears transient secrets and closes local-network listeners when the
    /// app leaves the foreground. Archive jobs retain only their Rust-owned
    /// request state; no password remains in the Swift UI model.
    func handleSceneBackground() {
        passwordInput = ""
        previewPasswordInput = ""
        testPasswordInput = ""
        extractionPasswordInput = ""
        creationPasswordInput = ""
        repackagingPasswordInput = ""
        localSendPinInput = ""
        pendingLocalSendDevice = nil
        let activeDevice = activeLocalSendDevice
        let activeSessionID = activeLocalSendSessionID
        localSendClient.cancelActiveUpload()
        activeLocalSendDevice = nil
        activeLocalSendSessionID = nil
        localSendReceiver.stop()
        if let localSendReceiveStagingRoot {
            try? FileManager.default.removeItem(at: localSendReceiveStagingRoot)
            self.localSendReceiveStagingRoot = nil
        }
        stopLocalSendReceiveDestinationAccess()
        if case .sending = localSendState {
            localSendState = .failed("LocalSend transfer cancelled while the app entered the background.")
        } else if case .receiving = localSendState {
            localSendState = .idle
        }
        switch extractionState {
        case .running(_, let jobID, _):
            Task.detached { try? self.extractionCoordinator.cancel(jobId: jobID) }
        case .review(let review):
            extractionCoordinator.discard(review: review)
            extractionState = .idle
        default:
            break
        }
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
        switch repackagingState {
        case .running(let review, _):
            repackagingCoordinator.cancel(review: review)
        case .review(let review):
            repackagingCoordinator.discard(review: review)
            repackagingState = .idle
        default:
            break
        }
        if case .running = batchExtractionState {
            batchExtractionCoordinator.cancel()
        }
        if let activeDevice, let activeSessionID {
            Task {
                try? await localSendClient.cancel(to: activeDevice, sessionID: activeSessionID)
            }
        }
        clearLocalSendSelection()
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
        switch repackagingState {
        case .running(let review, _):
            repackagingCoordinator.cancel(review: review)
        case .review(let review):
            repackagingCoordinator.discard(review: review)
            repackagingState = .idle
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

    func sendSelectedFiles(to device: LocalSendDevice, pin: String? = nil) {
        let files: [LocalSendTransferFile]
        if let stagedLocalSendSources {
            files = stagedLocalSendSources.sourcePaths.map {
                LocalSendTransferFile(url: URL(fileURLWithPath: $0))
            }
        } else if let archive = importedArchive {
            files = [LocalSendTransferFile(url: URL(fileURLWithPath: archive.localPath), displayName: archive.displayName)]
        } else {
            return
        }
        localSendState = .sending(device, "Preparing transfer")
        Task {
            do {
                let session = try await localSendClient.prepareUpload(to: device, files: files, pin: pin)
                activeLocalSendDevice = device
                activeLocalSendSessionID = session.sessionID
                localSendState = .sending(device, "Uploading \(files.count) file(s)")
                try await localSendClient.upload(to: device, session: session, files: files) { file, sent, total in
                    Task { @MainActor in
                        self.localSendState = .sending(
                            device,
                            "Uploading \(file.displayName): \(sent)/\(total) bytes"
                        )
                    }
                }
                activeLocalSendDevice = nil
                activeLocalSendSessionID = nil
                localSendPinInput = ""
                clearLocalSendSelection()
                localSendState = .completed(device)
            } catch is CancellationError {
                activeLocalSendDevice = nil
                activeLocalSendSessionID = nil
                localSendState = .failed("LocalSend transfer cancelled.")
            } catch LocalSendTransferError.pinRequired {
                activeLocalSendDevice = nil
                activeLocalSendSessionID = nil
                localSendPinInput = ""
                localSendState = .pinRequired(device)
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
        if let destination = localSendReceiveDestination, !localSendReceiveDestinationAccess {
            localSendReceiveDestinationAccess = destination.startAccessingSecurityScopedResource()
        }
        let root: URL
        if localSendReceiveDestination == nil {
            root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ZManagerMobile/ReceivedFiles", isDirectory: true)
        } else {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("ZManagerMobile/LocalSendReceive/\(UUID().uuidString)", isDirectory: true)
            localSendReceiveStagingRoot = root
        }
        do {
            let port = try localSendReceiver.start(destinationRoot: root)
            localSendState = .receiving(port)
        } catch {
            localSendReceiveStagingRoot = nil
            try? FileManager.default.removeItem(at: root)
            localSendState = .failed("Unable to receive LocalSend files.")
        }
    }

    func stopLocalReceive() {
        localSendReceiver.stop()
        if let localSendReceiveStagingRoot {
            try? FileManager.default.removeItem(at: localSendReceiveStagingRoot)
            self.localSendReceiveStagingRoot = nil
        }
        stopLocalSendReceiveDestinationAccess()
        localSendState = .idle
    }

    private func stopLocalSendReceiveDestinationAccess() {
        if localSendReceiveDestinationAccess, let localSendReceiveDestination {
            localSendReceiveDestination.stopAccessingSecurityScopedResource()
        }
        localSendReceiveDestinationAccess = false
    }

    private func exportReceivedLocalSendFile(_ source: URL, displayName: String) {
        guard let destination = localSendReceiveDestination else { return }
        do {
            let target = uniqueReceiveDestination(destination, name: displayName)
            try FileManager.default.copyItem(at: source, to: target)
            try FileManager.default.removeItem(at: source)
        } catch {
            localSendState = .failed("Unable to export received file.")
        }
    }

    private func uniqueReceiveDestination(_ root: URL, name: String) -> URL {
        var candidate = root.appendingPathComponent(LocalSendReceiver.sanitizeIncomingName(name))
        var index = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            let base = candidate.deletingPathExtension().lastPathComponent
            let ext = candidate.pathExtension
            candidate = root.appendingPathComponent(ext.isEmpty ? "\(base) (\(index))" : "\(base) (\(index)).\(ext)")
            index += 1
        }
        return candidate
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
        debugExtractionDelayNanoseconds = 0
        Task {
            do {
                let jobId = try await Task.detached(priority: .userInitiated) {
                    try self.extractionCoordinator.start(review: review)
                }.value
                extractionState = .running(review, jobId, "Extracting archive")
                let outcome = try await extractionCoordinator.awaitCompletion(review: review, jobId: jobId) { progress in
                    Task { @MainActor in
                        guard !self.cancellationRequestedExtractionJobIDs.contains(jobId) else {
                            return
                        }
                        self.extractionState = .running(review, jobId, progress.message)
                    }
                }
                if cancellationRequestedExtractionJobIDs.remove(jobId) != nil {
                    extractionCoordinator.discard(review: review)
                    extractionState = .cancelled
                } else {
                    extractionState = outcome.state
                }
                refreshRecoveryRecords()
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
        cancellationRequestedExtractionJobIDs.insert(jobId)
        extractionState = .cancelled
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
            if case .ready(let summary) = state {
                let action = pendingAutomationAction
                pendingAutomationAction = nil
                switch action {
                case .extract:
                    planExtraction(
                        selectedEntries: summary.entries,
                        destination: defaultExtractionDestination()
                    )
                case .verify:
                    startTest(selectedEntries: summary.entries)
                default:
                    break
                }
            }
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
    let onDropFiles: ([URL]) -> Void
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
            StableSecureInputField("Optional password", text: Binding(
                get: { password },
                set: onPasswordChanged
            ))
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
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in
            let group = DispatchGroup()
            let lock = NSLock()
            var urls = [URL]()
            for provider in providers {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    defer { group.leave() }
                    let url: URL?
                    if let data = item as? Data {
                        url = URL(dataRepresentation: data, relativeTo: nil)
                    } else if let nsURL = item as? NSURL {
                        url = nsURL as URL
                    } else {
                        url = nil
                    }
                    if let url {
                        lock.lock()
                        urls.append(url)
                        lock.unlock()
                    }
                }
            }
            group.notify(queue: .main) {
                lock.lock()
                let dropped = urls
                lock.unlock()
                onDropFiles(dropped)
            }
            return true
        }
    }
}

struct LocalSendPanel: View {
    let archive: ImportedArchive?
    let selectedFileCount: Int
    let state: LocalSendUIState
    let onDiscover: () -> Void
    let onChooseFiles: () -> Void
    let onClearFiles: () -> Void
    let onSend: (LocalSendDevice) -> Void
    @Binding var pinInput: String
    let onSubmitPin: (LocalSendDevice, String) -> Void
    let onCancelSend: () -> Void
    let receiveDestinationLabel: String
    let onChooseReceiveDestination: () -> Void
    let onStartReceive: () -> Void
    let onStopReceive: () -> Void
    let trustedFingerprints: [String]
    let onForgetTrustedFingerprint: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Share on local network")
                .font(.headline)
                .accessibilityIdentifier("localSendPanel")
            Text("Only send to devices you recognize on this local network.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Choose files", action: onChooseFiles)
                if selectedFileCount > 0 {
                    Button("Clear", action: onClearFiles)
                }
            }
            if selectedFileCount > 0 {
                Text("\(selectedFileCount) file(s) selected for sharing")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !trustedFingerprints.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Trusted devices").font(.subheadline.weight(.semibold))
                    ForEach(trustedFingerprints, id: \.self) { fingerprint in
                        HStack {
                            Text(fingerprint)
                                .font(.caption)
                                .lineLimit(1)
                                .textSelection(.enabled)
                            Spacer()
                            Button("Forget") { onForgetTrustedFingerprint(fingerprint) }
                                .accessibilityLabel("Forget trusted device \(fingerprint)")
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Trusted devices")
            }
            Button(state.isDiscovering ? "Discovering" : "Find LocalSend devices", action: onDiscover)
                .accessibilityIdentifier("localSendDiscover")
                .disabled((archive == nil && selectedFileCount == 0) || state.isDiscovering)
            if case .receiving(let port) = state {
                Button("Stop receiving", action: onStopReceive)
                Text("Receiving LocalSend files on port \(port) into \(receiveDestinationLabel).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button("Receive to: \(receiveDestinationLabel)", action: onChooseReceiveDestination)
                Button("Receive files", action: onStartReceive)
            }
            switch state {
            case .idle, .receiving, .discovering:
                EmptyView()
            case .devices(let devices):
                if devices.isEmpty { Text("No compatible devices found.") }
                ForEach(devices) { device in
                    HStack {
                        VStack(alignment: .leading) {
                            Text("\(device.alias) (\(device.address))")
                            if let fingerprint = device.fingerprint {
                                Text("Fingerprint: \(fingerprint)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button(selectedFileCount > 0 ? "Send files" : "Send archive") { onSend(device) }
                    }
                }
            case .sending(let device, let message):
                HStack {
                    Text("\(message) to \(device.alias)")
                    Spacer()
                    Button("Cancel", action: onCancelSend)
                }
            case .pinRequired(let device):
                Text("\(device.alias) requires a PIN before receiving this transfer.")
                StableSecureInputField("LocalSend PIN", text: $pinInput, contentType: .oneTimeCode)
                HStack {
                    Button("Retry with PIN") {
                        let pin = pinInput
                        pinInput = ""
                        onSubmitPin(device, pin)
                    }
                    .disabled(pinInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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

enum ArchiveExtractionError: LocalizedError {
    case unavailable
    case expiredReview
    case unavailableStaging
    case unavailableDestination
    case unsafePath

    var errorDescription: String? {
        switch self {
        case .unavailable: return "Archive extraction is unavailable in this build."
        case .expiredReview: return "The extraction review expired. Review the archive again."
        case .unavailableStaging: return "The staged extraction is unavailable."
        case .unavailableDestination: return "The selected extraction folder is no longer available."
        case .unsafePath: return "The staged extraction contains an unsafe path."
        }
    }
}

final class ArchiveDestinationPreferences {
    private static let extractionBookmarkKey = "defaultExtractionDestinationBookmark"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func defaultExtractionDestination(appStorage: URL) -> ExtractionDestination {
        guard let data = defaults.data(forKey: Self.extractionBookmarkKey) else {
            return .appStorage(appStorage)
        }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            // iOS does not expose the macOS security-scope bookmark option;
            // access is started explicitly around each native commit.
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ), !isStale else {
            resetExtractionDestination()
            return .appStorage(appStorage)
        }
        return .folder(url)
    }

    func setExtractionDestination(_ destination: ExtractionDestination) {
        switch destination {
        case .appStorage:
            resetExtractionDestination()
        case .folder(let url):
            if let bookmark = try? url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) {
                defaults.set(bookmark, forKey: Self.extractionBookmarkKey)
            }
        }
    }

    func resetExtractionDestination() {
        defaults.removeObject(forKey: Self.extractionBookmarkKey)
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
    let debugDelayNanoseconds: UInt64
}

/// Converts a staged file to a safe relative path before native commit. Rust
/// owns archive path policy; this boundary also rejects symlinks or malformed
/// staged paths that escape the private staging root.
enum ExtractionPathSafety {
    static func relativePath(for file: URL, under root: URL) throws -> String {
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let resolvedFile = file.resolvingSymlinksInPath().standardizedFileURL
        let rootPath = resolvedRoot.path.hasSuffix("/") ? resolvedRoot.path : resolvedRoot.path + "/"
        guard resolvedFile.path.hasPrefix(rootPath) else {
            throw ArchiveExtractionError.unsafePath
        }
        let relative = String(resolvedFile.path.dropFirst(rootPath.count))
        guard !relative.isEmpty,
              relative != ".",
              relative.split(separator: "/", omittingEmptySubsequences: false)
                .allSatisfy({ $0 != "." && $0 != ".." }) else {
            throw ArchiveExtractionError.unsafePath
        }
        return relative
    }
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
    case recoveryAvailable(UUID, String)

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
        case .failed(let message, _): return .failed(message)
        case .recoveryAvailable(let id, let message): return .recoveryAvailable(id, message)
        }
    }
}

final class ArchiveExtractionCoordinator: @unchecked Sendable {
    enum Outcome {
        case completed(UInt64, String)
        case cancelled
        case failed(String, code: String? = nil)
        case recoveryAvailable(UUID, String)
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
    private let recoveryStore: ArchiveRecoveryStore

    init(
        bridge: ArchiveBridgeClient = GeneratedArchiveBridgeClient(),
        fileManager: FileManager = .default,
        recoveryStore: ArchiveRecoveryStore = ArchiveRecoveryStore()
    ) {
        self.bridge = bridge
        self.fileManager = fileManager
        self.recoveryStore = recoveryStore
    }

    func recoveries() -> [ArchiveRecoveryRecord] { recoveryStore.records() }

    func discardRecovery(_ record: ArchiveRecoveryRecord) { recoveryStore.discard(record) }

    func recoveryFiles(_ record: ArchiveRecoveryRecord) -> [URL] { recoveryStore.files(for: record) }

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
        collisionPolicy: ExtractionCollisionPolicy,
        debugDelayNanoseconds: UInt64 = 0
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
        return ExtractionReview(
            id: id,
            destination: destination,
            plan: plan,
            collisionPolicy: collisionPolicy,
            debugDelayNanoseconds: debugDelayNanoseconds
        )
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
        if review.debugDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: min(review.debugDelayNanoseconds, 30_000_000_000))
        }
        while true {
            let update = try bridge.pollExtractionJob(jobId: jobId, cursor: cursor)
            cursor = update.nextCursor
            if let event = update.events.last {
                onProgress(ExtractionProgress(message: event.message ?? event.path ?? "Extracting archive"))
            }
            if !update.isTerminal && review.debugDelayNanoseconds > 0 {
                try await Task.sleep(nanoseconds: min(review.debugDelayNanoseconds, 30_000_000_000))
            }
            if update.isTerminal {
                switch update.status {
                case .completed:
                    return commit(review: review)
                case .cancelled:
                    discard(review: review)
                    return .cancelled
                default:
                    let code = update.events.last?.error?.code
                    let outcome = Outcome.failed(
                        update.events.last?.error?.message ?? update.events.last?.message ?? "Archive extraction failed.",
                        code: code
                    )
                    // Keep the staged session only for password recovery. All
                    // other terminal failures must release staging immediately.
                    if code != "password_required" && code != "invalid_password" {
                        discard(review: review)
                    }
                    return outcome
                }
            }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
    }

    func cancel(jobId: String) throws {
        try bridge.cancelExtractionJob(jobId: jobId)
    }

    func setPassword(review: ExtractionReview, password: String?) throws {
        lock.lock()
        defer { lock.unlock() }
        guard var session = sessions[review.id] else {
            throw ArchiveExtractionError.expiredReview
        }
        session.password = password
        sessions[review.id] = session
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
                    throw ArchiveExtractionError.unavailableDestination
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
            let message = error.localizedDescription
            if let recovery = try? recoveryStore.save(
                archive: session.archive,
                selectedPaths: session.selectedPaths,
                stagingRoot: session.stagingRoot,
                destinationLabel: session.destination.label,
                message: message
            ) {
                lock.lock()
                sessions.removeValue(forKey: review.id)
                lock.unlock()
                return .recoveryAvailable(
                    recovery.id,
                    "\(message) Partial output was retained for recovery."
                )
            }
            discard(review: review)
            return .failed(message)
        }
    }

    private func commit(stagingRoot: URL, to destinationRoot: URL, policy: ExtractionCollisionPolicy) throws {
        guard fileManager.fileExists(atPath: stagingRoot.path) else { throw ArchiveExtractionError.unavailableStaging }
        let files = try fileManager.subpathsOfDirectory(atPath: stagingRoot.path)
        for relativePath in files {
            let source = stagingRoot.appendingPathComponent(relativePath)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            let safeRelativePath = try ExtractionPathSafety.relativePath(for: source, under: stagingRoot)
            let target = destinationRoot.appendingPathComponent(safeRelativePath)
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

struct BatchExtractionItem {
    let archive: ImportedArchive
    let selectedPaths: [String]
    let destination: ExtractionDestination
    let password: String?

    init(
        archive: ImportedArchive,
        selectedPaths: [String],
        destination: ExtractionDestination,
        password: String? = nil
    ) {
        self.archive = archive
        self.selectedPaths = selectedPaths
        self.destination = destination
        self.password = password
    }
}

struct BatchExtractionReview {
    let items: [BatchExtractionItem]
    let reviews: [ExtractionReview]
}

struct BatchExtractionItemResult {
    enum Status { case completed, failed, cancelled }
    let archive: ImportedArchive
    let status: Status
    let writtenEntries: UInt64
    let message: String?
}

enum BatchExtractionOutcome {
    case completed([BatchExtractionItemResult])
    case cancelled([BatchExtractionItemResult])
}

enum BatchExtractionUIState {
    case idle
    case planning
    case review(BatchExtractionReview)
    case running
    case completed(String)
    case cancelled
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .planning, .running: return true
        default: return false
        }
    }
}

/// Runs a batch as independent Rust extraction jobs so one damaged archive
/// does not invalidate successful outputs from the rest of the queue.
final class BatchExtractionCoordinator: @unchecked Sendable {
    private let extraction: ArchiveExtractionCoordinator
    private let lock = NSLock()
    private var activeJob: (ExtractionReview, String)?
    private var cancelRequested = false

    init(extraction: ArchiveExtractionCoordinator) {
        self.extraction = extraction
    }

    func plan(items: [BatchExtractionItem]) throws -> BatchExtractionReview {
        guard !items.isEmpty else { throw ArchiveExtractionError.expiredReview }
        var reviews = [ExtractionReview]()
        do {
            for item in items {
                reviews.append(try extraction.plan(
                    archive: item.archive,
                    selectedPaths: item.selectedPaths,
                    destination: item.destination,
                    password: item.password,
                    collisionPolicy: .refuse
                ))
            }
            return BatchExtractionReview(items: items, reviews: reviews)
        } catch {
            reviews.forEach(extraction.discard)
            throw error
        }
    }

    func run(
        review: BatchExtractionReview,
        onProgress: @escaping (ImportedArchive, String) -> Void = { _, _ in }
    ) async -> BatchExtractionOutcome {
        lock.lock()
        cancelRequested = false
        lock.unlock()
        var results = [BatchExtractionItemResult]()
        for index in review.reviews.indices {
            lock.lock()
            let shouldCancel = cancelRequested
            lock.unlock()
            if shouldCancel {
                review.reviews[index...].forEach(extraction.discard)
                return .cancelled(results)
            }
            let extractionReview = review.reviews[index]
            let item = review.items[index]
            do {
                let jobID = try extraction.start(review: extractionReview)
                lock.lock()
                activeJob = (extractionReview, jobID)
                lock.unlock()
                let outcome = try await extraction.awaitCompletion(review: extractionReview, jobId: jobID) { progress in
                    onProgress(item.archive, progress.message)
                }
                switch outcome {
                case .completed(let entries, _):
                    results.append(BatchExtractionItemResult(
                        archive: item.archive,
                        status: .completed,
                        writtenEntries: entries,
                        message: nil
                    ))
                case .failed(let message, _):
                    results.append(BatchExtractionItemResult(
                        archive: item.archive,
                        status: .failed,
                        writtenEntries: 0,
                        message: message
                    ))
                case .recoveryAvailable(_, let message):
                    results.append(BatchExtractionItemResult(
                        archive: item.archive,
                        status: .failed,
                        writtenEntries: 0,
                        message: message
                    ))
                case .cancelled:
                    results.append(BatchExtractionItemResult(
                        archive: item.archive,
                        status: .cancelled,
                        writtenEntries: 0,
                        message: nil
                    ))
                    review.reviews.dropFirst(index + 1).forEach(extraction.discard)
                    return .cancelled(results)
                }
            } catch {
                extraction.discard(review: extractionReview)
                results.append(BatchExtractionItemResult(
                    archive: item.archive,
                    status: .failed,
                    writtenEntries: 0,
                    message: error.localizedDescription
                ))
            }
            lock.lock()
            activeJob = nil
            lock.unlock()
        }
        return .completed(results)
    }

    func cancel() {
        lock.lock()
        cancelRequested = true
        let activeJob = activeJob
        lock.unlock()
        if let activeJob { try? extraction.cancel(jobId: activeJob.1) }
    }

    func discard(review: BatchExtractionReview) {
        review.reviews.forEach(extraction.discard)
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
                VStack(alignment: .leading, spacing: 8) {
                    Button("Start extraction") { onStart(review) }
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Choose folder", action: onChooseDestination)
                    Button("Cancel", action: onCancel)
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
                StableSecureInputField("Password", text: $password)
                Button("Retry extraction") { onRetryWithPassword(selectedEntries) }.disabled(password.isEmpty)
            }
        case .failed(let message): Text(message).foregroundStyle(.red)
        case .recoveryAvailable(_, let message): Text(message).foregroundStyle(.red)
        }
    }
}

struct ArchiveBatchExtractionPanel: View {
    let state: BatchExtractionUIState
    let onStart: () -> Void
    let onCancel: () -> Void

    var body: some View {
        switch state {
        case .idle:
            EmptyView()
        case .planning:
            Text("Preparing batch extraction plans")
                .font(.subheadline)
        case .review(let review):
            VStack(alignment: .leading, spacing: 6) {
                Text("Review batch extraction").font(.headline)
                Text("\(review.items.count) archives will be extracted to separate app-storage folders.")
                HStack {
                    Button("Start batch extraction", action: onStart)
                    Button("Cancel", action: onCancel)
                }
            }
        case .running:
            HStack {
                Text("Batch extraction running").font(.subheadline)
                Spacer()
                Button("Cancel", action: onCancel)
            }
        case .completed(let message):
            Text(message).font(.subheadline)
        case .cancelled:
            Text("Batch extraction cancelled").font(.subheadline)
        case .failed(let message):
            Text(message).font(.subheadline).foregroundStyle(.red)
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
    case passwordRequired(String)
    case failed(String)
}

final class ArchiveRepackagingCoordinator: @unchecked Sendable {
    private final class Session {
        let request: ArchiveRepackagingRequest
        let stagingRoot: URL
        var activeJobID: String?
        var activePhase: ActivePhase?
        var cancelRequested = false

        init(request: ArchiveRepackagingRequest, stagingRoot: URL) {
            self.request = request
            self.stagingRoot = stagingRoot
            self.activePhase = nil
        }
    }
    private enum ActivePhase { case extraction, creation }

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
            lock.lock()
            session.activePhase = .extraction
            lock.unlock()
            session.activeJobID = extractionJob
            onProgress("Extracting selected archive folder")
            switch try await extraction.awaitCompletion(review: review.extractionReview, jobId: extractionJob) { progress in
                onProgress(progress.message)
            } {
            case .cancelled:
                return finish(review.id, outcome: .cancelled)
            case .failed(let message, let code):
                if code == "password_required" || code == "invalid_password" {
                    return .passwordRequired(message)
                }
                return finish(review.id, outcome: .failed(message))
            case .recoveryAvailable(_, let message):
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
            lock.lock()
            session.activePhase = .creation
            lock.unlock()
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
        if let activeJobID {
            switch session?.activePhase {
            case .creation: try? creation.cancel(jobId: activeJobID)
            case .extraction, .none: try? extraction.cancel(jobId: activeJobID)
            }
        }
    }

    func setSourcePassword(review: ArchiveRepackagingReview, password: String) throws {
        try extraction.setPassword(review: review.extractionReview, password: password)
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
    // Nested-archive browsing is a UI capability over registry-listable
    // formats; the set is pinned by the conformance test against the FFI
    // format registry. XIP is intentionally absent: the FFI reports
    // canList=false for it, so nesting into an .xip always fails.
    static let archiveExtensions: Set<String> = [
        "zip", "7z", "rar", "tar", "gz", "tgz", "bz2", "tbz2", "xz", "txz",
        "zst", "tzst", "tzap", "aar", "cab", "deb", "jar", "apk", "ipa"
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
    case pinRequired(LocalSendDevice)
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
final class LocalSendTrustStore {
    private let defaults: UserDefaults
    private let prefix = "org.tzap.zmanager.localsend.trusted."

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func isTrusted(_ device: LocalSendDevice) -> Bool {
        guard let fingerprint = device.fingerprint else { return false }
        return defaults.bool(forKey: prefix + fingerprint)
    }

    func remember(_ device: LocalSendDevice) {
        guard let fingerprint = device.fingerprint else { return }
        defaults.set(true, forKey: prefix + fingerprint)
    }

    func forget(_ device: LocalSendDevice) {
        guard let fingerprint = device.fingerprint else { return }
        forget(fingerprint: fingerprint)
    }

    func forget(fingerprint: String) {
        defaults.removeObject(forKey: prefix + fingerprint)
    }

    func fingerprints() -> [String] {
        defaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(prefix) && defaults.bool(forKey: $0) }
            .map { String($0.dropFirst(prefix.count)) }
            .sorted()
    }
}

/// LocalSend v2.2 outbound HTTP transfer subsystem. It intentionally has no
/// dependency on archive parsing or creation.
final class LocalSendClient: @unchecked Sendable {
    static let multicastAddress = "224.0.0.167"
    static let defaultPort = 53317

    static func isPinRequiredStatus(_ statusCode: Int) -> Bool { statusCode == 401 }

    private let alias: String
    private let fingerprint: String
    private let port: Int
    private var activeTask: URLSessionTask?

    init(alias: String = "ZManager Mobile", fingerprint: String? = nil, port: Int = LocalSendClient.defaultPort) {
        self.alias = alias
        let identityKey = "org.tzap.zmanager.localsend.fingerprint"
        if let fingerprint {
            self.fingerprint = fingerprint
        } else if let stored = UserDefaults.standard.string(forKey: identityKey) {
            self.fingerprint = stored
        } else {
            let generated = UUID().uuidString
            UserDefaults.standard.set(generated, forKey: identityKey)
            self.fingerprint = generated
        }
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
        files: [LocalSendTransferFile],
        onProgress: @escaping (_ file: LocalSendTransferFile, _ sent: Int64, _ total: Int64) -> Void = { _, _, _ in }
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
            let delegate = LocalSendUploadDelegate(file: file, onProgress: onProgress)
            let sessionConfiguration = URLSessionConfiguration.default
            let delegateSession = URLSession(configuration: sessionConfiguration, delegate: delegate, delegateQueue: nil)
            let uploadTask = delegateSession.uploadTask(with: request, fromFile: file.url)
            self.activeTask = uploadTask
            defer {
                delegateSession.invalidateAndCancel()
                self.activeTask = nil
            }
            try await delegate.start(task: uploadTask)
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
        guard let http = response as? HTTPURLResponse else {
            throw LocalSendTransferError.rejected
        }
        if Self.isPinRequiredStatus(http.statusCode) { throw LocalSendTransferError.pinRequired }
        guard (200..<300).contains(http.statusCode) else {
            throw LocalSendTransferError.rejected
        }
    }

    private func string(_ json: [String: Any], key: String) throws -> String {
        guard let value = json[key] as? String else { throw LocalSendTransferError.invalidResponse }
        return value
    }
}

private final class LocalSendUploadDelegate: NSObject, URLSessionTaskDelegate {
    private let file: LocalSendTransferFile
    private let onProgress: (LocalSendTransferFile, Int64, Int64) -> Void
    private var continuation: CheckedContinuation<Void, Error>?

    init(
        file: LocalSendTransferFile,
        onProgress: @escaping (LocalSendTransferFile, Int64, Int64) -> Void
    ) {
        self.file = file
        self.onProgress = onProgress
    }

    func start(task: URLSessionTask) async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            task.resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        onProgress(file, totalBytesSent, totalBytesExpectedToSend)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            if let urlError = error as? URLError, urlError.code == .cancelled {
                continuation?.resume(throwing: CancellationError())
            } else {
                continuation?.resume(throwing: error)
            }
            continuation = nil
            return
        }
        guard let response = task.response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else {
            continuation?.resume(throwing: LocalSendTransferError.rejected)
            continuation = nil
            return
        }
        continuation?.resume()
        continuation = nil
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
    var onFileCommitted: ((URL, String) -> Void)?
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
            } else if request.path.hasPrefix("/api/localsend/v2/register") {
                respond(connection, status: 200, json: registrationAnnouncement())
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
            if let session = request.session, let sessionID = request.sessionID {
                sessions.removeValue(forKey: sessionID)
                try? fileManager.removeItem(at: session.root)
            }
            let status = (error as? LocalSendTransferError)?.localSendHTTPStatus ?? 400
            respond(connection, status: status, body: error.localizedDescription)
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

    private func registrationAnnouncement() -> [String: Any] {
        [
            "alias": alias,
            "version": "2.0",
            "deviceModel": UIDevice.current.model,
            "deviceType": "mobile",
            "fingerprint": fingerprint,
            "port": Int(port),
            "protocol": "http",
            "download": true,
            "announce": false
        ]
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
            guard actual.caseInsensitiveCompare(sha256) == .orderedSame else {
                throw LocalSendTransferError.checksumMismatch
            }
        }
        let target = Self.uniqueTarget(root: session.destinationRoot, name: expected.displayName, fileManager: fileManager)
        try fileManager.moveItem(at: temporary, to: target)
        onFileCommitted?(target, expected.displayName)
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
    case pinRequired
    case rejected
    case checksumMismatch
    case invalidResponse
    case receiverAlreadyRunning

    var localSendHTTPStatus: Int {
        switch self {
        case .checksumMismatch: return 422
        default: return 400
        }
    }

    var errorDescription: String? {
        switch self {
        case .missingToken: return "The LocalSend device did not provide an upload token."
        case .pinRequired: return "The LocalSend device requires a PIN."
        case .rejected: return "The LocalSend device rejected the transfer."
        case .checksumMismatch: return "Received checksum does not match the request."
        case .invalidResponse: return "The LocalSend device returned an invalid response."
        case .receiverAlreadyRunning: return "LocalSend receiving is already enabled."
        }
    }
}
