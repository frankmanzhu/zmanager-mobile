import Foundation

/// Archive-folder repackaging state: composes staged extraction with the
/// create planner. Reads the current archive through [session] and the
/// output format/password/volume-size choice through [creation] rather than
/// duplicating them — repackaging always writes using whatever format the
/// create panel currently has selected. See Track 7 in
/// docs/mobile-code-health-remediation-plan.md.
@MainActor
final class ArchiveRepackagingModel: ObservableObject {
    @Published var repackagingState: ArchiveRepackagingState = .idle
    @Published var repackagingPasswordInput = ""

    private unowned let session: ArchiveSessionModel
    private unowned let creation: ArchiveCreationModel
    private let repackagingCoordinator: ArchiveRepackagingCoordinator
    private var repackagingSelectedEntries = [ArchiveEntrySummary]()
    private var repackagingPasswordRetryReview: ArchiveRepackagingReview?

    init(
        session: ArchiveSessionModel,
        creation: ArchiveCreationModel,
        repackagingCoordinator: ArchiveRepackagingCoordinator? = nil
    ) {
        self.session = session
        self.creation = creation
        self.repackagingCoordinator = repackagingCoordinator ?? ArchiveRepackagingCoordinator(
            extraction: session.extractionCoordinator,
            creation: session.creationCoordinator
        )
    }

    func clearTransientSecrets() {
        repackagingPasswordInput = ""
    }

    func startRepackaging(selectedEntries: [ArchiveEntrySummary], sourcePassword: String? = nil) {
        guard let archive = session.importedArchive else { return }
        // Repackaging requires an explicit source selection. An empty list is
        // reserved by extraction for "the whole archive".
        let selectedPaths = selectedEntries.map(\.path)
        let suffix: String
        switch creation.creationFormat {
        case .zip: suffix = ".zip"
        case .sevenZ: suffix = ".7z"
        case .tarZst: suffix = ".tar.zst"
        case .tarGz: suffix = ".tar.gz"
        case .tzap: suffix = ".tzap"
        case .appleArchive: suffix = ".aar"
        }
        let volumeSize: UInt64?
        do {
            volumeSize = try ArchiveVolumeSupport.parseVolumeSize(creation.creationVolumeSizeInput)
        } catch {
            repackagingState = .failed(error.localizedDescription)
            return
        }
        let request = ArchiveRepackagingRequest(
            sourceArchive: archive,
            selectedPaths: selectedPaths,
            destinationArchivePath: creation.creationCoordinator.appStorageOutput(displayName: "repackaged\(suffix)").path,
            format: creation.creationFormat,
            volumeSize: volumeSize,
            sourcePassword: sourcePassword ?? (repackagingPasswordInput.isEmpty ? nil : repackagingPasswordInput),
            destinationPassword: creation.creationPasswordInput.isEmpty ? nil : creation.creationPasswordInput
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
            case .completed(let outputPath, let verified, let outputPaths):
                repackagingState = .completed(outputPath: outputPath, verified: verified, outputPaths: outputPaths)
            case .cancelled:
                repackagingState = .cancelled
            case .passwordRequired(let message):
                repackagingPasswordRetryReview = review
                repackagingState = .passwordRequired(message, repackagingSelectedEntries, review)
            case .failed(let message):
                repackagingState = .failed(message)
            }
            session.passwordInput = ""
            creation.creationPasswordInput = ""
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

    /// Called from the scene-background coordinator in `ContentView`,
    /// alongside every other model's own handleSceneBackground().
    func handleSceneBackground() {
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
}
