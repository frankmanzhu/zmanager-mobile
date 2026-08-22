import Foundation
import PhotosUI
import SwiftUI

/// Archive-creation state, source staging, and its Rust job lifecycle. Also
/// owns the `ArchiveCreationCoordinator` shared with `ArchiveSessionModel`
/// (via `session.creationCoordinator`) and exposes it so
/// `ArchiveRepackagingModel` can compose it into repackaging. See Track 7 in
/// docs/mobile-code-health-remediation-plan.md.
@MainActor
final class ArchiveCreationModel: ObservableObject {
    @Published var creationState: ArchiveCreationState = .idle
    @Published var creationFormat: CreateArchiveFormat = .zip
    @Published var creationPasswordInput = ""
    @Published var creationVolumeSizeInput = ""
    @Published var creationSeparateItems = false

    let creationSourceStager: ArchiveCreationSourceStager
    let separateCreationCoordinator: ArchiveSeparateCreationCoordinator
    private unowned let session: ArchiveSessionModel
    private var stagedCreationSources: StagedCreationSources?

    // Copied from session at init rather than read through a computed
    // property: a `let` of a Sendable type is exempt from this MainActor
    // class's actor isolation and can be captured into Task.detached
    // directly, but a computed property forwarding to another actor-isolated
    // object's storage is not (see ArchiveExtractionModel for the same note).
    let creationCoordinator: ArchiveCreationCoordinator

    init(
        session: ArchiveSessionModel,
        creationSourceStager: ArchiveCreationSourceStager = ArchiveCreationSourceStager(),
        separateCreationCoordinator: ArchiveSeparateCreationCoordinator? = nil
    ) {
        self.session = session
        self.creationCoordinator = session.creationCoordinator
        self.creationSourceStager = creationSourceStager
        self.separateCreationCoordinator = separateCreationCoordinator
            ?? ArchiveSeparateCreationCoordinator(coordinator: session.creationCoordinator)
    }

    func clearTransientSecrets() {
        creationPasswordInput = ""
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

#if DEBUG
    func createDebugFixture() {
        do {
            try planCreation(staged: creationSourceStager.stageDebugFixture())
        } catch {
            creationState = .failed(error.localizedDescription)
        }
    }

    func createDebugSplitFixture() {
        do {
            creationVolumeSizeInput = "64k"
            try planCreation(staged: creationSourceStager.stageDebugSplitFixture())
        } catch {
            creationState = .failed(error.localizedDescription)
        }
    }

    func createDebugSeparateFixture() {
        do {
            creationSeparateItems = true
            try planCreation(staged: creationSourceStager.stageDebugSeparateFixture())
        } catch {
            creationState = .failed(error.localizedDescription)
        }
    }
#endif

    private func planCreation(staged: StagedCreationSources) throws {
        discardCreationSources()
        stagedCreationSources = staged
        let suffix: String
        switch creationFormat {
        case .zip: suffix = ".zip"
        case .sevenZ: suffix = ".7z"
        case .tarZst: suffix = ".tar.zst"
        case .tarGz: suffix = ".tar.gz"
        case .tzap: suffix = ".tzap"
        case .appleArchive: suffix = ".aar"
        }
        let volumeSize = try ArchiveVolumeSupport.parseVolumeSize(creationVolumeSizeInput)
        creationState = .planning
        Task {
            do {
                let password = creationPasswordInput.isEmpty ? nil : creationPasswordInput
                if creationSeparateItems && staged.sourcePaths.count > 1 {
                    let requests = ArchiveSeparateCreationPlanner.requests(
                        sourcePaths: staged.sourcePaths,
                        destinationDirectory: creationCoordinator.appStorageOutput(displayName: "archive\(suffix)")
                            .deletingLastPathComponent().path,
                        format: creationFormat,
                        password: password,
                        volumeSize: volumeSize
                    )
                    let review = try await Task.detached(priority: .userInitiated) {
                        try self.separateCreationCoordinator.plan(requests: requests)
                    }.value
                    let blocked = review.items.first { !$0.plan.canStart }
                    if let blocked {
                        separateCreationCoordinator.discard(review: review)
                        creationState = .failed(
                            blocked.plan.warnings.first?.message ?? "One of the separate creation plans cannot be started."
                        )
                    } else {
                        creationState = .separateReview(review)
                    }
                } else {
                    let request = ArchiveCreationRequest(
                        sourcePaths: staged.sourcePaths,
                        destinationArchivePath: creationCoordinator.appStorageOutput(displayName: "archive\(suffix)").path,
                        format: creationFormat,
                        password: password,
                        volumeSize: volumeSize
                    )
                    let review = try await Task.detached(priority: .userInitiated) {
                        try self.creationCoordinator.plan(request: request)
                    }.value
                    creationState = review.plan.canStart
                        ? .review(review)
                        : .failed(review.plan.warnings.first?.message ?? "This creation plan cannot be started.")
                }
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

    func startSeparateCreation(_ review: ArchiveSeparateCreationReview) {
        creationPasswordInput = ""
        creationState = .startingSeparate(review)
        Task {
            var completedOutputs = [String]()
            var verified = true
            do {
                for (index, item) in review.items.enumerated() {
                    let jobID = try await Task.detached(priority: .userInitiated) {
                        try self.creationCoordinator.start(review: item)
                    }.value
                    creationState = .runningSeparate(review, jobID, "Creating archive \(index + 1) of \(review.items.count)")
                    let outcome = try await creationCoordinator.awaitCompletion(review: item, jobId: jobID) { progress in
                        Task { @MainActor in
                            self.creationState = .runningSeparate(review, jobID, progress.message)
                        }
                    }
                    switch outcome {
                    case .completed(let outputPath, let itemVerified, let outputPaths):
                        completedOutputs.append(contentsOf: outputPaths)
                        verified = verified && itemVerified
                        if index == review.items.count - 1 {
                            creationState = .completed(
                                .completed(
                                    outputPath: completedOutputs.first ?? outputPath,
                                    verified: verified,
                                    outputPaths: completedOutputs
                                )
                            )
                        }
                    case .cancelled:
                        separateCreationCoordinator.discard(review: review)
                        creationState = .cancelled
                        discardCreationSources()
                        return
                    case .failed(let message):
                        separateCreationCoordinator.discard(review: review)
                        creationState = .failed(message)
                        discardCreationSources()
                        return
                    }
                }
                discardCreationSources()
            } catch {
                separateCreationCoordinator.discard(review: review)
                discardCreationSources()
                creationState = .failed(error.localizedDescription)
            }
        }
    }

    /// Creation-only half of the original `cancelCreation()`. The repackaging
    /// half is now `ArchiveRepackagingModel.cancelRepackaging()`, called
    /// alongside this one from `ContentView`'s cancel handler — see the note
    /// there and in the plan doc's Track 7 write-up for why these two split.
    func cancelCreation() {
        switch creationState {
        case .running(_, let jobID, _):
            Task.detached { try? self.creationCoordinator.cancel(jobId: jobID) }
        case .runningSeparate(_, let jobID, _):
            Task.detached { try? self.creationCoordinator.cancel(jobId: jobID) }
        case .review(let review):
            creationCoordinator.discard(review: review)
            discardCreationSources()
            creationState = .idle
        case .separateReview(let review):
            separateCreationCoordinator.discard(review: review)
            discardCreationSources()
            creationState = .idle
        default:
            break
        }
    }

    func handleSceneBackground() {
        switch creationState {
        case .running(_, let jobID, _):
            Task.detached { try? self.creationCoordinator.cancel(jobId: jobID) }
        case .runningSeparate(_, let jobID, _):
            Task.detached { try? self.creationCoordinator.cancel(jobId: jobID) }
        case .review(let review):
            creationCoordinator.discard(review: review)
            discardCreationSources()
            creationState = .idle
        case .separateReview(let review):
            separateCreationCoordinator.discard(review: review)
            discardCreationSources()
            creationState = .idle
        default:
            break
        }
    }
}
