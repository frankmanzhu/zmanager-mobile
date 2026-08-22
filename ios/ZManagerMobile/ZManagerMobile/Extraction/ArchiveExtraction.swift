import QuickLook
import CryptoKit
import Network
import PhotosUI
import Security
import SwiftUI
import UIKit
import UniformTypeIdentifiers

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
    let pacer: any JobPacer
}

/// Converts a staged file to a safe relative path before native commit. Rust
/// owns archive path policy; this boundary also rejects symlinks or malformed
/// staged paths that escape the private staging root.
enum ExtractionPathSafety {
    static func relativePath(for file: URL, under root: URL) throws -> String {
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        // Standardize the final path lexically without resolving its final
        // component. Safe staged symlinks must retain their archive path.
        let normalizedFile = file.standardizedFileURL
        let rootPath = resolvedRoot.path.hasSuffix("/") ? resolvedRoot.path : resolvedRoot.path + "/"
        guard normalizedFile.path.hasPrefix(rootPath) else {
            throw ArchiveExtractionError.unsafePath
        }
        let parent = normalizedFile.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        guard parent.path == resolvedRoot.path || parent.path.hasPrefix(rootPath) else {
            throw ArchiveExtractionError.unsafePath
        }
        let relative = String(normalizedFile.path.dropFirst(rootPath.count))
        guard !relative.isEmpty,
              relative != ".",
              relative.split(separator: "/", omittingEmptySubsequences: false)
                .allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
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

extension ArchiveExtractionCoordinator.Outcome {
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
        pacer: any JobPacer = NoOpJobPacer()
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
            pacer: pacer
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
        try await JobPollDriver.pollUntilTerminal(
            pacer: review.pacer,
            poll: { cursor in try bridge.pollJob(jobId: jobId, cursor: cursor) },
            onEvent: { event in
                onProgress(ExtractionProgress(message: event.message ?? event.path ?? "Extracting archive"))
            },
            onTerminal: { update in
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
        )
    }

    func cancel(jobId: String) throws {
        try bridge.cancelJob(jobId: jobId)
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
                HStack {
                    Button("Start batch extraction", action: onStart)
                    Button("Cancel", action: onCancel)
                }
                Text("\(review.items.count) archives will be extracted to separate app-storage folders.")
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

