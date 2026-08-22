import Foundation

/// Batch (multi-archive) extraction state and its Rust job lifecycle. See
/// Track 7 in docs/mobile-code-health-remediation-plan.md.
@MainActor
final class ArchiveBatchExtractionModel: ObservableObject {
    @Published var batchExtractionState: BatchExtractionUIState = .idle

    private unowned let session: ArchiveSessionModel
    private let batchExtractionCoordinator: BatchExtractionCoordinator

    init(session: ArchiveSessionModel) {
        self.session = session
        self.batchExtractionCoordinator = BatchExtractionCoordinator(extraction: session.extractionCoordinator)
    }

    func handleBatchArchiveResult(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, !urls.isEmpty else {
            if case .failure(let error) = result { batchExtractionState = .failed(error.localizedDescription) }
            return
        }
        batchExtractionState = .planning
        let importStore = session.importStore
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
        let importStore = session.importStore
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

    func handleSceneBackground() {
        if case .running = batchExtractionState {
            batchExtractionCoordinator.cancel()
        }
    }
}
