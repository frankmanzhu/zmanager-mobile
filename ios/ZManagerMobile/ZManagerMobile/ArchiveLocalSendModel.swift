import Foundation

/// LocalSend transfer state. On Android this state stays as local Compose
/// state rather than a ViewModel (Track 1 defers LocalSend's actual
/// consolidation into Rust); on iOS it was already class-owned `@Published`
/// state before this track, so keeping it as its own `ObservableObject` is
/// the equivalent low-risk move rather than a bigger rewrite forcing it into
/// SwiftUI `@State` primitives. See Track 1 and Track 7 in
/// docs/mobile-code-health-remediation-plan.md.
@MainActor
final class ArchiveLocalSendModel: ObservableObject {
    @Published var localSendState: LocalSendUIState = .idle
    @Published var localSendPinInput = ""
    @Published var pendingLocalSendDevice: LocalSendDevice?

    let localSendClient: LocalSendClient
    let localSendReceiver: LocalSendReceiver
    private let localSendSourceStager: LocalSendSourceStager
    private unowned let session: ArchiveSessionModel
    private var activeLocalSendDevice: LocalSendDevice?
    private var activeLocalSendSessionID: String?
    private var stagedLocalSendSources: StagedCreationSources?
    private var localSendReceiveDestination: URL?
    private var localSendReceiveDestinationAccess = false
    private var localSendReceiveStagingRoot: URL?

    init(
        session: ArchiveSessionModel,
        localSendSourceStager: LocalSendSourceStager = LocalSendSourceStager(),
        localSendClient: LocalSendClient = LocalSendClient(),
        localSendReceiver: LocalSendReceiver = LocalSendReceiver()
    ) {
        self.session = session
        self.localSendSourceStager = localSendSourceStager
        self.localSendClient = localSendClient
        self.localSendReceiver = localSendReceiver
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
        } else if let archive = session.importedArchive {
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

    /// Called from the scene-background coordinator in `ContentView`. This is
    /// the original `handleSceneBackground`'s LocalSend-specific block,
    /// unchanged, plus the password/pending-device clearing that belonged to
    /// no single feature and lived at the top of the original function.
    func handleSceneBackground() {
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
        if let activeDevice, let activeSessionID {
            Task {
                try? await localSendClient.cancel(to: activeDevice, sessionID: activeSessionID)
            }
        }
        clearLocalSendSelection()
    }
}
