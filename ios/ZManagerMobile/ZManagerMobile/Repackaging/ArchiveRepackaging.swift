import QuickLook
import CryptoKit
import Network
import PhotosUI
import Security
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ArchiveRepackagingPanel: View {
    let state: ArchiveRepackagingState
    @Binding var password: String
    let onRetryWithPassword: ([ArchiveEntrySummary], String) -> Void
    let onShareOutput: ([String]) -> Void
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
        case .completed(let outputPath, let verified, let outputPaths):
            VStack(alignment: .leading, spacing: 2) {
                Text("Created \(outputPath)").font(.subheadline)
                if outputPaths.count > 1 {
                    Text("\(outputPaths.count) volumes committed").font(.caption)
                }
                Text(verified ? "Verified" : "Created without verification")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Share output") {
                    onShareOutput(outputPaths.isEmpty ? [outputPath] : outputPaths)
                }
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

enum ArchiveRepackagingState {
    case idle
    case planning
    case passwordRequired(String, [ArchiveEntrySummary], ArchiveRepackagingReview?)
    case review(ArchiveRepackagingReview)
    case running(ArchiveRepackagingReview, String)
    case completed(outputPath: String, verified: Bool, outputPaths: [String])
    case cancelled
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .planning, .review, .running: return true
        default: return false
        }
    }
}

struct ArchiveRepackagingRequest {
    let sourceArchive: ImportedArchive
    let selectedPaths: [String]
    let destinationArchivePath: String
    let format: CreateArchiveFormat
    let volumeSize: UInt64?
    let sourcePassword: String?
    let destinationPassword: String?
    let verifyAfterCreate: Bool

    init(
        sourceArchive: ImportedArchive,
        selectedPaths: [String],
        destinationArchivePath: String,
        format: CreateArchiveFormat,
        volumeSize: UInt64? = nil,
        sourcePassword: String? = nil,
        destinationPassword: String? = nil,
        verifyAfterCreate: Bool = true
    ) {
        self.sourceArchive = sourceArchive
        self.selectedPaths = selectedPaths
        self.destinationArchivePath = destinationArchivePath
        self.format = format
        self.volumeSize = volumeSize
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
    case completed(outputPath: String, verified: Bool, outputPaths: [String])
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
                    verifyAfterCreate: session.request.verifyAfterCreate,
                    volumeSize: session.request.volumeSize
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
            case .completed(let outputPath, let verified, let outputPaths):
                return finish(review.id, outcome: .completed(outputPath: outputPath, verified: verified, outputPaths: outputPaths))
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

