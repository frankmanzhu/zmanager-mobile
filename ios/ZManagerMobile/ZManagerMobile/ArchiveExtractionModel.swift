import Foundation

/// Single-archive extraction state and its Rust job lifecycle. Reads the
/// current archive and listing through [session] and shares its
/// `ArchiveExtractionCoordinator` instance, since recovery on iOS is exposed
/// through the extraction coordinator rather than a separate store. See
/// Track 7 in docs/mobile-code-health-remediation-plan.md.
@MainActor
final class ArchiveExtractionModel: ObservableObject {
    @Published var extractionState: ArchiveExtractionState = .idle
    @Published var extractionPasswordInput = ""

    private unowned let session: ArchiveSessionModel
    private var cancellationRequestedExtractionJobIDs = Set<String>()

    // Copied from session at init rather than read through a computed
    // property: a `let` of a Sendable type is exempt from this MainActor
    // class's actor isolation and can be captured into Task.detached
    // directly, but a computed property forwarding to another actor-isolated
    // object's storage is not.
    private let extractionCoordinator: ArchiveExtractionCoordinator

    init(session: ArchiveSessionModel) {
        self.session = session
        self.extractionCoordinator = session.extractionCoordinator
    }

    func clearTransientSecrets() {
        extractionPasswordInput = ""
    }

    private func extractionSelectedPaths(for selectedEntries: [ArchiveEntrySummary]) -> [String] {
        session.selectedEverything ? [] : selectedEntries.map(\.path)
    }

    func planExtraction(
        selectedEntries: [ArchiveEntrySummary],
        destination: ExtractionDestination? = nil,
        password: String? = nil,
        pacer: (any JobPacer)? = nil
    ) {
        guard let archive = session.importedArchive else { return }
        clearExtractionState()
        let destination = destination ?? extractionCoordinator.appStorageDestination()
        let selectedPaths = extractionSelectedPaths(for: selectedEntries)
        let extractionPacer = pacer ?? session.debugJobPacer
        extractionState = .planning(destination.label)
        Task {
            do {
                let review = try await Task.detached(priority: .userInitiated) {
                    try self.extractionCoordinator.plan(
                        archive: archive,
                        // An empty selection means every entry. Preserve that
                        // bridge contract so full extraction uses the engine's
                        // whole-archive operation rather than selected-entry
                        // I/O.
                        selectedPaths: selectedPaths,
                        destination: destination,
                        password: password,
                        collisionPolicy: .refuse,
                        pacer: extractionPacer
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

    func startExtraction(_ review: ExtractionReview) {
        extractionState = .starting(review)
        session.debugJobPacer = NoOpJobPacer()
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
                session.refreshRecoveryRecords()
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

    func clearExtractionState() {
        if case .review(let review) = extractionState { extractionCoordinator.discard(review: review) }
        extractionState = .idle
        extractionPasswordInput = ""
    }

    /// Called from the scene-background coordinator in `ContentView`.
    func handleSceneBackground() {
        switch extractionState {
        case .running(_, let jobID, _):
            Task.detached { try? self.extractionCoordinator.cancel(jobId: jobID) }
        case .review(let review):
            extractionCoordinator.discard(review: review)
            extractionState = .idle
        default:
            break
        }
    }
}
