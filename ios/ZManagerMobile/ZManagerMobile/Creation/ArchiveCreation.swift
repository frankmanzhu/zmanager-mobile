import QuickLook
import CryptoKit
import Network
import PhotosUI
import Security
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct StagedCreationSources {
    let root: URL
    let sourcePaths: [String]
}

/// Copies security-scoped document-provider URLs into app-owned temporary storage
/// before the Rust create bridge is called.
struct ArchiveCreationSourceStager {
    let fileManager: FileManager
    let securityScope: SecurityScopedResourceAccess

    init(
        fileManager: FileManager = .default,
        securityScope: SecurityScopedResourceAccess = .system
    ) {
        self.fileManager = fileManager
        self.securityScope = securityScope
    }

    func stageFiles(_ urls: [URL]) throws -> StagedCreationSources {
        guard !urls.isEmpty else { throw ArchiveImportError.emptySelection }
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("ZManagerMobile/CreationSources/\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            var paths: [String] = []
            for url in urls {
                try securityScope.withAccess(url) {
                    let target = uniqueTarget(root: root, name: ArchiveImportStore.sanitizedDisplayName(url.lastPathComponent))
                    try fileManager.copyItem(at: url, to: target)
                    paths.append(target.path)
                }
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
        try securityScope.withAccess(url) {
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

    /// Deterministic incompressible source used by split-volume device E2E only.
    func stageDebugSplitFixture() throws -> StagedCreationSources {
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("ZManagerMobile/CreationSources/\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("split-fixture-folder", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            try Data("ZManager Mobile split creation fixture\n".utf8)
                .write(to: folder.appendingPathComponent("readme.txt"))
            var state: UInt32 = 0x6D2B79F5
            let bytes = Data((0..<4_000_000).map { _ in
                state ^= state << 13
                state ^= state >> 17
                state ^= state << 5
                return UInt8(truncatingIfNeeded: state)
            })
            try bytes.write(to: folder.appendingPathComponent("payload.bin"))
            return StagedCreationSources(root: root, sourcePaths: [folder.path])
        } catch {
            try? fileManager.removeItem(at: root)
            throw error
        }
    }

    /// Two top-level files used by separate-archive device E2E only.
    func stageDebugSeparateFixture() throws -> StagedCreationSources {
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("ZManagerMobile/CreationSources/\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            let first = root.appendingPathComponent("one.txt")
            let second = root.appendingPathComponent("two.txt")
            try Data("first separate archive\n".utf8).write(to: first)
            try Data("second separate archive\n".utf8).write(to: second)
            return StagedCreationSources(root: root, sourcePaths: [first.path, second.path])
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
enum ArchiveCreationState {
    case idle
    case planning
    case review(ArchiveCreationReview)
    case separateReview(ArchiveSeparateCreationReview)
    case starting(ArchiveCreationReview)
    case startingSeparate(ArchiveSeparateCreationReview)
    case running(ArchiveCreationReview, String, String)
    case runningSeparate(ArchiveSeparateCreationReview, String, String)
    case completed(ArchiveCreationOutcome)
    case cancelled
    case failed(String)
}

extension ArchiveCreationOutcome {
    var creationState: ArchiveCreationState {
        switch self {
        case .completed(let outputPath, let verified, let outputPaths):
            return .completed(.completed(outputPath: outputPath, verified: verified, outputPaths: outputPaths))
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
    let volumeSizeInput: String
    let separateItems: Bool
    let onPasswordChanged: (String) -> Void
    let onVolumeSizeChanged: (String) -> Void
    let onSeparateItemsChanged: (Bool) -> Void
    let onFormatChanged: (CreateArchiveFormat) -> Void
    let onChooseFiles: () -> Void
    let onChooseFolder: () -> Void
    let onDropFiles: ([URL]) -> Void
    let onStart: (ArchiveCreationReview) -> Void
    let onStartSeparate: (ArchiveSeparateCreationReview) -> Void
    let onShareOutput: ([String]) -> Void
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
                Text("TAR.GZ").tag(CreateArchiveFormat.tarGz)
                Text("TZAP").tag(CreateArchiveFormat.tzap)
                Text("AAR").tag(CreateArchiveFormat.appleArchive)
            }
            .pickerStyle(.segmented)
            StableSecureInputField("Optional password", text: Binding(
                get: { password },
                set: onPasswordChanged
            ))
            if ArchiveVolumeSupport.supportsVolumeSize(format) {
                TextField("Optional split volume size (for example 4m)", text: Binding(
                    get: { volumeSizeInput },
                    set: onVolumeSizeChanged
                ))
                .textFieldStyle(.roundedBorder)
                Text("Leave blank for one archive; split output is committed as a volume set.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Toggle("Archive each selected item separately", isOn: Binding(
                get: { separateItems },
                set: onSeparateItemsChanged
            ))
            switch state {
            case .idle, .failed, .completed, .cancelled:
                HStack {
                    Button("Choose files", action: onChooseFiles)
                    Button("Choose folder", action: onChooseFolder)
                }
                if case .failed(let message) = state { Text(message).foregroundStyle(.red) }
                if case .completed(let outcome) = state,
                   case .completed(let outputPath, let verified, let outputPaths) = outcome {
                    Text("Created \(URL(fileURLWithPath: outputPath).lastPathComponent)")
                    if outputPaths.count > 1 {
                        Text("\(outputPaths.count) output files committed")
                    }
                    Text(verified ? "Verified" : "Created without verification")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Share output") {
                        onShareOutput(outputPaths.isEmpty ? [outputPath] : outputPaths)
                    }
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
                        .accessibilityIdentifier("startCreation")
                }
            case .separateReview(let review):
                Text("\(review.items.count) archives will be created")
                HStack {
                    Button("Cancel", action: onCancel)
                    Button("Start creation") { onStartSeparate(review) }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("startCreation")
                }
                ForEach(review.items, id: \.id) { item in
                    Text(URL(fileURLWithPath: item.request.destinationArchivePath).lastPathComponent)
                        .font(.caption)
                }
            case .starting:
                Text("Starting archive creation")
            case .startingSeparate:
                Text("Starting separate archive creation")
            case .running(_, _, let message):
                Text(message)
                Button("Cancel creation", action: onCancel)
            case .runningSeparate(_, _, let message):
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

enum ArchiveSeparateCreationPlanner {
    static func requests(
        sourcePaths: [String],
        destinationDirectory: String,
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
    ) -> [ArchiveCreationRequest] {
        precondition(!sourcePaths.isEmpty, "Select at least one file or folder.")
        let names = uniqueOutputNames(sourcePaths: sourcePaths, format: format)
        return zip(sourcePaths, names).map { sourcePath, name in
            ArchiveCreationRequest(
                sourcePaths: [sourcePath],
                destinationArchivePath: URL(fileURLWithPath: destinationDirectory)
                    .appendingPathComponent(name).path,
                format: format,
                password: password,
                preserveMetadata: preserveMetadata,
                replaceExisting: replaceExisting,
                cleanSource: cleanSource,
                verifyAfterCreate: verifyAfterCreate,
                level: level,
                encryptFileNames: encryptFileNames,
                volumeSize: volumeSize,
                recoveryPercentage: recoveryPercentage,
                volumeLossTolerance: volumeLossTolerance
            )
        }
    }

    private static func uniqueOutputNames(sourcePaths: [String], format: CreateArchiveFormat) -> [String] {
        let suffix: String
        switch format {
        case .zip: suffix = ".zip"
        case .sevenZ: suffix = ".7z"
        case .tarZst: suffix = ".tar.zst"
        case .tarGz: suffix = ".tar.gz"
        case .tzap: suffix = ".tzap"
        case .appleArchive: suffix = ".aar"
        }
        var used = Set<String>()
        return sourcePaths.map { sourcePath in
            let sourceName = URL(fileURLWithPath: sourcePath).lastPathComponent
            var base = URL(fileURLWithPath: sourceName).deletingPathExtension().lastPathComponent
            base = base
                .replacingOccurrences(of: "[\\\\/:*?\"<>|]", with: "_", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if base.isEmpty { base = "archive" }
            var candidate = "\(base)\(suffix)"
            var index = 1
            while used.contains(candidate) {
                candidate = "\(base) (\(index))\(suffix)"
                index += 1
            }
            used.insert(candidate)
            return candidate
        }
    }
}

struct ArchiveCreationReview {
    let id: UUID
    let request: ArchiveCreationRequest
    let plan: PlanCreateResult
}

struct ArchiveSeparateCreationReview {
    let items: [ArchiveCreationReview]
}

struct ArchiveCreationProgress {
    let message: String
    let processedBytes: UInt64?
    let totalBytes: UInt64?
    let processedEntries: UInt64?
    let totalEntries: UInt64?
}

enum ArchiveCreationOutcome: Equatable {
    case completed(outputPath: String, verified: Bool, outputPaths: [String])
    case cancelled
    case failed(String)
}

enum ArchiveVolumeSupport {
    static func supportsVolumeSize(_ format: CreateArchiveFormat) -> Bool {
        switch format {
        case .zip, .sevenZ, .tzap:
            return true
        case .tarZst, .tarGz, .appleArchive:
            return false
        }
    }

    static func parseVolumeSize(_ raw: String) throws -> UInt64? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.isEmpty { return nil }
        let suffixes: [(String, UInt64)] = [
            ("tib", 1024 * 1024 * 1024 * 1024), ("tb", 1024 * 1024 * 1024 * 1024),
            ("ti", 1024 * 1024 * 1024 * 1024), ("t", 1024 * 1024 * 1024 * 1024),
            ("gib", 1024 * 1024 * 1024), ("gb", 1024 * 1024 * 1024),
            ("gi", 1024 * 1024 * 1024), ("g", 1024 * 1024 * 1024),
            ("mib", 1024 * 1024), ("mb", 1024 * 1024),
            ("mi", 1024 * 1024), ("m", 1024 * 1024),
            ("kib", 1024), ("kb", 1024), ("ki", 1024), ("k", 1024),
            ("b", 1)
        ]
        let suffix = suffixes.first(where: { value.hasSuffix($0.0) })
        let number = suffix.map { String(value.dropLast($0.0.count)) } ?? value
        guard let amount = UInt64(number), !number.isEmpty else {
            throw ArchiveVolumeSizeError.invalid
        }
        let (result, overflow) = amount.multipliedReportingOverflow(by: suffix?.1 ?? 1)
        guard !overflow else { throw ArchiveVolumeSizeError.invalid }
        return result
    }

    static func outputPaths(
        format: CreateArchiveFormat,
        destination: String,
        volumeCount: UInt64?,
        reportedPaths: [String]
    ) -> [String] {
        guard let count = volumeCount, count > 1, count <= UInt64(Int.max) else {
            return [destination]
        }
        let destinationURL = URL(fileURLWithPath: destination)
        let parent = destinationURL.deletingLastPathComponent()
        let stem = destinationURL.deletingPathExtension().lastPathComponent
        switch format {
        case .zip:
            return (1..<Int(count)).map { index in
                parent.appendingPathComponent("\(stem).z\(String(format: "%02d", index))").path
            } + [destination]
        case .sevenZ:
            return (1...Int(count)).map { index in
                "\(destination).\(String(format: "%03d", index))"
            }
        case .tzap:
            let extensionName = destinationURL.pathExtension.isEmpty ? "tzap" : destinationURL.pathExtension
            return (0..<Int(count)).map { index in
                parent.appendingPathComponent("\(stem).vol\(String(format: "%03d", index)).\(extensionName)").path
            }
        case .tarZst, .tarGz, .appleArchive:
            return reportedPaths.isEmpty ? [destination] : reportedPaths
        }
    }

    /// Older bridge revisions may omit volume metadata even though the engine
    /// committed sidecar volumes. Recover the committed set from the
    /// app-owned output directory before presenting or sharing it.
    static func committedOutputPaths(
        format: CreateArchiveFormat,
        destination: String,
        volumeCount: UInt64?,
        reportedPaths: [String],
        fileManager: FileManager = .default
    ) -> [String] {
        var paths = outputPaths(
            format: format,
            destination: destination,
            volumeCount: volumeCount,
            reportedPaths: reportedPaths
        )
        if volumeCount.map({ $0 > 1 }) == true || !reportedPaths.isEmpty {
            return paths
        }
        let destinationURL = URL(fileURLWithPath: destination)
        let parent = destinationURL.deletingLastPathComponent()
        let baseName = destinationURL.lastPathComponent
        let stem = destinationURL.deletingPathExtension().lastPathComponent
        let extensionName = destinationURL.pathExtension
        let sidecars: [String]
        if let contents = try? fileManager.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            sidecars = contents.filter { url in
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                    return false
                }
                let name = url.lastPathComponent
                switch format {
                case .zip:
                    return name.hasPrefix("\(stem).z") &&
                        name.count == stem.count + 4 &&
                        name.dropFirst(stem.count + 2).allSatisfy(\.isNumber)
                case .sevenZ:
                    return name.hasPrefix("\(baseName).") &&
                        name.count == baseName.count + 4 &&
                        name.dropFirst(baseName.count + 1).allSatisfy(\.isNumber)
                case .tzap:
                    return name.hasPrefix("\(stem).vol") &&
                        name.hasSuffix(".\(extensionName)")
                case .tarZst, .tarGz, .appleArchive:
                    return false
                }
            }.map(\.path)
        } else {
            sidecars = []
        }
        for path in sidecars.sorted() where !paths.contains(path) {
            paths.append(path)
        }
        let existing = paths.filter { fileManager.fileExists(atPath: $0) }
        return existing.isEmpty ? [destination] : existing
    }
}

enum ArchiveVolumeSizeError: LocalizedError {
    case invalid

    var errorDescription: String? {
        "Volume size must look like 64k, 1m, or 1g."
    }
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
        return try await JobPollDriver.pollUntilTerminal(
            poll: { cursor in try bridge.pollJob(jobId: jobId, cursor: cursor) },
            onEvent: { event in
                onProgress(
                    ArchiveCreationProgress(
                        message: event.message ?? event.path ?? "Creating archive",
                        processedBytes: event.totalBytesProcessed ?? event.bytes,
                        totalBytes: event.totalBytes,
                        processedEntries: event.entries,
                        totalEntries: event.totalEntries
                    )
                )
            },
            onTerminal: { update in
                switch update.status {
                case .completed:
                    let verified = request.verifyAfterCreate && update.terminalSummary?.verified == true
                    let outputPaths = ArchiveVolumeSupport.committedOutputPaths(
                        format: request.format,
                        destination: request.destinationArchivePath,
                        volumeCount: update.terminalSummary?.volumeCount,
                        reportedPaths: update.terminalSummary?.outputPaths ?? []
                    )
                    discard(review: review)
                    return .completed(
                        outputPath: request.destinationArchivePath,
                        verified: verified,
                        outputPaths: outputPaths
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
        )
    }

    func cancel(jobId: String) throws {
        try bridge.cancelJob(jobId: jobId)
    }

    func discard(review: ArchiveCreationReview) {
        lock.lock()
        sessions.removeValue(forKey: review.id)
        lock.unlock()
    }
}

/// Plans separate outputs while delegating every archive operation to the
/// existing Rust-backed creation coordinator.
final class ArchiveSeparateCreationCoordinator: @unchecked Sendable {
    private let coordinator: ArchiveCreationCoordinator

    init(coordinator: ArchiveCreationCoordinator) {
        self.coordinator = coordinator
    }

    func plan(requests: [ArchiveCreationRequest]) throws -> ArchiveSeparateCreationReview {
        guard !requests.isEmpty else { throw ArchiveCreationError.expiredReview }
        var reviews = [ArchiveCreationReview]()
        do {
            for request in requests {
                reviews.append(try coordinator.plan(request: request))
            }
            return ArchiveSeparateCreationReview(items: reviews)
        } catch {
            reviews.forEach(coordinator.discard)
            throw error
        }
    }

    func discard(review: ArchiveSeparateCreationReview) {
        review.items.forEach(coordinator.discard)
    }
}

