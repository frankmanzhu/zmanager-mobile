import XCTest
import Foundation
import CryptoKit
@testable import ZManagerMobile

final class ZManagerMobileTests: XCTestCase {
    func testArchiveImportSanitizesDisplayName() {
        XCTAssertEqual(
            ArchiveImportStore.sanitizedDisplayName("../nested/evil:archive.zip"),
            "evil_archive.zip"
        )
        XCTAssertEqual(ArchiveImportStore.sanitizedDisplayName(".."), "archive")
        XCTAssertEqual(ArchiveImportStore.sanitizedDisplayName(nil), "archive")
    }

    func testArchiveImportCopiesFileIntoCacheRoot() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = root.appendingPathComponent("source.zip")
        let cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true, attributes: nil)
        defer {
            try? fileManager.removeItem(at: root)
        }
        try Data("hello archive".utf8).write(to: source)

        let imported = try ArchiveImportStore(
            fileManager: fileManager,
            cacheRoot: cacheRoot
        ).importArchive(from: source)

        XCTAssertEqual(imported.displayName, "source.zip")
        XCTAssertTrue(imported.localPath.hasPrefix(cacheRoot.path))
        XCTAssertEqual(imported.byteSize, 13)
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: imported.localPath)),
            Data("hello archive".utf8)
        )
    }

    func testArchiveImportChoosesTheFirstMultipartVolume() {
        XCTAssertEqual(
            ArchiveImportStore.primaryArchiveName(["payload.vol002.tzap", "payload.vol000.tzap"]),
            "payload.vol000.tzap"
        )
        XCTAssertEqual(
            ArchiveImportStore.primaryArchiveName(["payload.part2.rar", "payload.part1.rar"]),
            "payload.part1.rar"
        )
        XCTAssertEqual(
            ArchiveImportStore.primaryArchiveName(["payload.7z.002", "payload.7z.001"]),
            "payload.7z.001"
        )
        XCTAssertEqual(
            ArchiveImportStore.primaryArchiveName(["payload.z01", "payload.zip"]), "payload.zip")
    }

    func testArchiveListingLoaderReturnsSummary() {
        let loader = ArchiveListingLoader(
            bridge: FakeArchiveBridgeClient(
                listing: ListArchiveResult(
                    archivePath: "/cache/archive.zip",
                    format: .zip,
                    formatLabel: "ZIP",
                    entries: [
                        ArchiveEntry(
                            path: "readme.txt",
                            kind: .file,
                            isDir: false,
                            size: 12,
                            compressedSize: nil,
                            modifiedAt: nil
                        )
                    ],
                    entryCount: 1,
                    totalSize: 12,
                    warnings: []
                )
            )
        )

        let state = loader.load(archive: testImportedArchive(), password: nil)

        guard case .ready(let summary) = state else {
            return XCTFail("Expected ready listing state.")
        }
        XCTAssertEqual(summary.formatLabel, "ZIP")
        XCTAssertEqual(summary.entryCount, 1)
        XCTAssertEqual(summary.entries.first?.path, "readme.txt")
        XCTAssertEqual(summary.entries.first?.displayName, "readme.txt")
    }

    func testArchiveListingLoaderMapsPasswordRequired() {
        let loader = ArchiveListingLoader(
            bridge: FakeArchiveBridgeClient(
                listError: ZmanagerGuiError.Bridge(
                    code: "password_required",
                    userMessage: "This archive requires a password.",
                    recoveryHint: "Enter the archive password.",
                    severity: .warning,
                    retryable: true
                )
            )
        )

        let state = loader.load(archive: testImportedArchive(), password: nil)

        guard case .passwordRequired(let error) = state else {
            return XCTFail("Expected password-required listing state.")
        }
        XCTAssertEqual(error.code, "password_required")
        XCTAssertTrue(error.retryable)
    }

    func testVisibleGroupsSearchesSortsAndGroupsEntries() {
        let summary = ArchiveListingSummary(
            formatLabel: "ZIP",
            entryCount: 3,
            totalSize: nil,
            entries: [
                testEntry(id: "1", path: "docs/readme.txt", size: 12),
                testEntry(id: "2", path: "images/photo.jpg", size: 200),
                testEntry(id: "3", path: "docs/guide.txt", size: 40)
            ],
            warnings: []
        )

        let groups = summary.visibleGroups(
            searchQuery: "docs",
            sort: .sizeDescending,
            viewMode: .folders
        )

        XCTAssertEqual(groups.map(\.label), ["docs"])
        XCTAssertEqual(groups.first?.entries.map(\.path), ["docs/guide.txt", "docs/readme.txt"])
    }

    func testPreviewableSelectedEntryRequiresExactlyOneSelectedFile() {
        let file = testEntry(id: "file", path: "readme.txt", kind: .file)
        let directory = testEntry(id: "dir", path: "docs", kind: .directory)
        let summary = ArchiveListingSummary(
            formatLabel: "ZIP",
            entryCount: 2,
            totalSize: nil,
            entries: [file, directory],
            warnings: []
        )

        XCTAssertEqual(summary.previewableSelectedEntry(selectedEntryIds: [file.id]), file)
        XCTAssertNil(summary.previewableSelectedEntry(selectedEntryIds: [directory.id]))
        XCTAssertNil(summary.previewableSelectedEntry(selectedEntryIds: [file.id, directory.id]))
    }

    func testArchivePreviewLoaderReturnsReadyState() {
        let entry = testEntry(id: "file", path: "readme.txt")
        let loader = ArchivePreviewLoader(
            bridge: FakeArchiveBridgeClient(
                preview: MaterializePreviewResult(
                    archivePath: "/cache/archive.zip",
                    entryPath: "readme.txt",
                    cleanupRoot: "/cache/previews/preview-id",
                    previewPath: "/cache/previews/preview-id/readme.txt",
                    writtenBytes: 12,
                    warnings: []
                )
            )
        )

        let state = loader.materialize(archive: testImportedArchive(), entry: entry, password: nil)

        guard case .ready(let summary) = state else {
            return XCTFail("Expected ready preview state.")
        }
        XCTAssertEqual(summary.entry, entry)
        XCTAssertEqual(summary.previewPath, "/cache/previews/preview-id/readme.txt")
    }

    func testArchivePreviewLoaderMapsPasswordRequired() {
        let entry = testEntry(id: "file", path: "readme.txt")
        let loader = ArchivePreviewLoader(
            bridge: FakeArchiveBridgeClient(
                previewError: ZmanagerGuiError.Bridge(
                    code: "password_required",
                    userMessage: "This archive requires a password.",
                    recoveryHint: "Enter the archive password.",
                    severity: .warning,
                    retryable: true
                )
            )
        )

        let state = loader.materialize(archive: testImportedArchive(), entry: entry, password: nil)

        guard case .passwordRequired(_, let error) = state else {
            return XCTFail("Expected password-required preview state.")
        }
        XCTAssertEqual(error.code, "password_required")
        XCTAssertTrue(error.retryable)
    }

    func testArchiveTestLoaderReturnsReadyStateAndPassesSelectedPaths() {
        let entry = testEntry(id: "file", path: "readme.txt")
        let bridge = FakeArchiveBridgeClient(
            testResult: TestArchiveResult(
                archivePath: "/cache/archive.zip",
                format: .zip,
                formatLabel: "ZIP",
                verified: true,
                testedEntries: 1,
                skippedEntries: 0,
                totalEntries: 1,
                testedBytes: 12,
                warnings: []
            )
        )
        let loader = ArchiveTestLoader(bridge: bridge)

        let state = loader.test(archive: testImportedArchive(), selectedEntries: [entry], password: nil)

        guard case .ready(let summary) = state else {
            return XCTFail("Expected ready test state.")
        }
        XCTAssertTrue(summary.verified)
        XCTAssertEqual(summary.testedEntries, 1)
        XCTAssertEqual(bridge.testedSelectedPaths, ["readme.txt"])
    }

    func testArchiveTestLoaderMapsPasswordRequired() {
        let loader = ArchiveTestLoader(
            bridge: FakeArchiveBridgeClient(
                testError: ZmanagerGuiError.Bridge(
                    code: "password_required",
                    userMessage: "This archive requires a password.",
                    recoveryHint: "Enter the archive password.",
                    severity: .warning,
                    retryable: true
                )
            )
        )

        let state = loader.test(archive: testImportedArchive(), selectedEntries: [], password: nil)

        guard case .passwordRequired(let error) = state else {
            return XCTFail("Expected password-required test state.")
        }
        XCTAssertEqual(error.code, "password_required")
        XCTAssertTrue(error.retryable)
    }

    func testArchiveCreationCoordinatorPassesOptionsAndReportsVerification() async throws {
        let bridge = CreationFakeBridgeClient()
        let coordinator = ArchiveCreationCoordinator(bridge: bridge)
        let review = try coordinator.plan(
            request: ArchiveCreationRequest(
                sourcePaths: ["/cache/input"],
                destinationArchivePath: "/files/output.zip",
                format: .zip,
                password: "test-password",
                verifyAfterCreate: true
            )
        )

        XCTAssertTrue(review.plan.canStart)
        XCTAssertEqual(bridge.plannedSourcePaths, ["/cache/input"])

        let jobId = try coordinator.start(review: review)
        XCTAssertEqual(bridge.startedRequest?.password, "test-password")
        let outcome = try await coordinator.awaitCompletion(review: review, jobId: jobId) { _ in }

        XCTAssertEqual(outcome, .completed(outputPath: "/files/output.zip", verified: true))
        XCTAssertGreaterThan(bridge.pollCount, 0)
    }

    func testNestedArchiveSessionPopCleansMaterializedRoot() {
        let cleanupRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: cleanupRoot, withIntermediateDirectories: true)
        let stack = ArchiveSessionStack()
        stack.push(
            archive: testImportedArchive(),
            cleanupRoot: cleanupRoot
        )

        _ = stack.pop()

        XCTAssertFalse(FileManager.default.fileExists(atPath: cleanupRoot.path))
    }

    func testLocalSendAnnouncementUsesProtocolFields() throws {
        let announcement = LocalSendAnnouncement(
            alias: "ZManager Mobile",
            version: "2.0",
            deviceModel: "iPhone",
            deviceType: "mobile",
            fingerprint: "test-fingerprint",
            port: LocalSendClient.defaultPort,
            protocol: "http",
            download: false,
            announce: true
        )
        let data = try JSONEncoder().encode(announcement)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["version"] as? String, "2.0")
        XCTAssertEqual(json["port"] as? Int, LocalSendClient.defaultPort)
        XCTAssertEqual(json["announce"] as? Bool, true)
    }

    func testLocalSendSourceStagerCopiesAndCleansSelectedFiles() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }
        let source = root.appendingPathComponent("selected.txt")
        try Data("share me".utf8).write(to: source)

        let stager = LocalSendSourceStager(fileManager: fileManager)
        let staged = try stager.stageFiles([source])

        XCTAssertEqual(staged.sourcePaths.count, 1)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: staged.sourcePaths[0])), Data("share me".utf8))
        XCTAssertTrue(staged.root.path.contains("LocalSendSources"))

        stager.discard(staged)
        XCTAssertFalse(fileManager.fileExists(atPath: staged.root.path))
    }

    @MainActor
    func testSceneBackgroundClearsTransientPasswords() {
        let model = ArchiveImportModel()
        model.passwordInput = "archive-password"
        model.previewPasswordInput = "preview-password"
        model.testPasswordInput = "test-password"
        model.extractionPasswordInput = "extract-password"
        model.creationPasswordInput = "create-password"

        model.handleSceneBackground()

        XCTAssertTrue(model.passwordInput.isEmpty)
        XCTAssertTrue(model.previewPasswordInput.isEmpty)
        XCTAssertTrue(model.testPasswordInput.isEmpty)
        XCTAssertTrue(model.extractionPasswordInput.isEmpty)
        XCTAssertTrue(model.creationPasswordInput.isEmpty)
    }

    func testLocalSendReceiverSanitizesIncomingNames() {
        XCTAssertEqual(LocalSendReceiver.sanitizeIncomingName("../../evil.zip"), "evil.zip")
        XCTAssertEqual(LocalSendReceiver.sanitizeIncomingName(".."), "received-file")
        XCTAssertEqual(LocalSendReceiver.sanitizeIncomingName("nested\\archive.zip"), "archive.zip")
    }

    func testLocalSendReceiverAnswersHttpRegistration() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }
        let receiver = LocalSendReceiver(alias: "Receiver", fingerprint: "receiver-fingerprint", port: 53320, fileManager: fileManager)
        try receiver.start(destinationRoot: root)
        defer { receiver.stop() }

        var request = URLRequest(url: URL(string: "http://127.0.0.1:53320/api/localsend/v2/register")!)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["fingerprint"] as? String, "receiver-fingerprint")
        XCTAssertEqual(json["port"] as? Int, 53320)
        XCTAssertEqual(json["announce"] as? Bool, false)
    }

    func testLocalSendReceiverAcceptsAndCommitsValidatedUpload() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }
        var callbackFile: URL?
        let receiver = LocalSendReceiver(port: 53319, fileManager: fileManager)
        receiver.onFileCommitted = { file, _ in callbackFile = file }
        try receiver.start(destinationRoot: root)
        defer { receiver.stop() }

        let payload = Data("controlled LocalSend peer payload\n".utf8)
        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let fileID = "file-1"
        let prepareBody: [String: Any] = [
            "files": [fileID: [
                "id": fileID,
                "fileName": "../controlled-peer.txt",
                "size": payload.count,
                "sha256": digest
            ]]
        ]
        var prepare = URLRequest(url: URL(string: "http://127.0.0.1:53319/api/localsend/v2/prepare-upload")!)
        prepare.httpMethod = "POST"
        prepare.httpBody = try JSONSerialization.data(withJSONObject: prepareBody)
        prepare.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (prepareData, prepareResponse) = try await URLSession.shared.data(for: prepare)
        XCTAssertEqual((prepareResponse as? HTTPURLResponse)?.statusCode, 200, String(data: prepareData, encoding: .utf8) ?? "<empty>")
        let prepareJSON = try XCTUnwrap(try JSONSerialization.jsonObject(with: prepareData) as? [String: Any])
        let sessionID = try XCTUnwrap(prepareJSON["sessionId"] as? String)
        let files = try XCTUnwrap(prepareJSON["files"] as? [String: String])
        let token = try XCTUnwrap(files[fileID])
        var upload = URLRequest(url: URL(string: "http://127.0.0.1:53319/api/localsend/v2/upload?sessionId=\(sessionID)&fileId=\(fileID)&token=\(token)")!)
        upload.httpMethod = "POST"
        upload.httpBody = payload
        let (_, uploadResponse) = try await URLSession.shared.data(for: upload)
        XCTAssertEqual((uploadResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("controlled-peer.txt")), payload)
        XCTAssertEqual(callbackFile?.lastPathComponent, "controlled-peer.txt")
        XCTAssertFalse(fileManager.fileExists(atPath: root.appendingPathComponent(".localsend").appendingPathComponent(sessionID).path))
    }

    func testLocalSendReceiverStreamsAndChecksumsLargeUpload() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }
        let receiver = LocalSendReceiver(port: 53318, fileManager: fileManager)
        try receiver.start(destinationRoot: root)
        defer { receiver.stop() }

        let payload = Data((0..<(8 * 1024 * 1024)).map { UInt8($0 % 251) })
        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let fileID = "large-file"
        let prepareBody: [String: Any] = ["files": [fileID: [
            "id": fileID, "fileName": "large.bin", "size": payload.count, "sha256": digest
        ]]]
        var prepare = URLRequest(url: URL(string: "http://127.0.0.1:53318/api/localsend/v2/prepare-upload")!)
        prepare.httpMethod = "POST"
        prepare.httpBody = try JSONSerialization.data(withJSONObject: prepareBody)
        let (prepareData, _) = try await URLSession.shared.data(for: prepare)
        let prepareJSON = try XCTUnwrap(try JSONSerialization.jsonObject(with: prepareData) as? [String: Any])
        let sessionID = try XCTUnwrap(prepareJSON["sessionId"] as? String)
        let files = try XCTUnwrap(prepareJSON["files"] as? [String: String])
        let token = try XCTUnwrap(files[fileID])
        var upload = URLRequest(url: URL(string: "http://127.0.0.1:53318/api/localsend/v2/upload?sessionId=\(sessionID)&fileId=\(fileID)&token=\(token)")!)
        upload.httpMethod = "POST"
        upload.httpBody = payload
        let (_, response) = try await URLSession.shared.data(for: upload)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("large.bin")), payload)
        XCTAssertFalse(fileManager.fileExists(atPath: root.appendingPathComponent(".localsend").appendingPathComponent(sessionID).path))
    }

    func testExtractionCoordinatorCommitsCompletedStagingOutput() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        let bridge = FakeArchiveBridgeClient()
        bridge.onStartExtraction = { stagingPath in
            let output = URL(fileURLWithPath: stagingPath).appendingPathComponent("docs/readme.txt")
            try fileManager.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("extracted".utf8).write(to: output)
        }
        let coordinator = ArchiveExtractionCoordinator(bridge: bridge, fileManager: fileManager)
        let destination = ExtractionDestination.appStorage(root.appendingPathComponent("output", isDirectory: true))

        let review = try coordinator.plan(
            archive: testImportedArchive(),
            selectedPaths: ["docs/readme.txt"],
            destination: destination,
            password: nil,
            collisionPolicy: .refuse
        )
        let jobId = try coordinator.start(review: review)
        let outcome = try await coordinator.awaitCompletion(review: review, jobId: jobId) { _ in }

        guard case .completed(let entries, _) = outcome else {
            return XCTFail("Expected completed extraction outcome.")
        }
        XCTAssertEqual(entries, 1)
        XCTAssertEqual(
            try Data(contentsOf: root.appendingPathComponent("output/docs/readme.txt")),
            Data("extracted".utf8)
        )
    }

    private func testImportedArchive() -> ImportedArchive {
        ImportedArchive(
            id: UUID(),
            displayName: "archive.zip",
            localPath: "/cache/archive.zip",
            byteSize: 12,
            importedAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func testEntry(
        id: String,
        path: String,
        kind: ArchiveEntryKind = .file,
        size: UInt64? = 12
    ) -> ArchiveEntrySummary {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        let displayName = parts.last.map(String.init).flatMap { $0.isEmpty ? nil : $0 } ?? path
        let parentPath = parts.dropLast().joined(separator: "/")
        return ArchiveEntrySummary(
            id: id,
            path: path,
            displayName: displayName,
            parentPath: parentPath,
            kindLabel: kindDisplayLabel(kind),
            kind: kind,
            size: size
        )
    }

    private func kindDisplayLabel(_ kind: ArchiveEntryKind) -> String {
        switch kind {
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

    // MARK: - Format registry conformance

    func testNestedArchiveExtensionsAreRegistrySubset() {
        let formats = listFormats().formats
        let registrySuffixes = Set(
            formats
                .flatMap { $0.extensions }
                .map { $0.lowercased() }
        )
        XCTAssertGreaterThan(formats.count, 0, "listFormats returned no formats")
        for archiveExtension in NestedArchiveSupport.archiveExtensions {
            if archiveExtension == "tzap" { continue }
            XCTAssertTrue(
                registrySuffixes.contains("." + archiveExtension),
                archiveExtension + " is nested-browsable but missing from the format registry (registry: "
                    + registrySuffixes.sorted().joined(separator: ", ") + ")"
            )
        }
    }

    func testNestedArchiveSetDoesNotContainXip() {
        // The FFI reports canList=false for XIP, so nesting into an .xip
        // would always fail.
        XCTAssertFalse(NestedArchiveSupport.archiveExtensions.contains("xip"))
    }

    func testListingLoaderMapsUnlistableFormatToUnsupported() {
        let loader = ArchiveListingLoader(
            bridge: FakeArchiveBridgeClient(
                detection: DetectArchiveResult(
                    archivePath: "/cache/archive.xip",
                    format: .xip,
                    formatLabel: "XIP",
                    exists: true,
                    isFile: true,
                    canList: false,
                    canExtract: false,
                    canCreate: false,
                    warnings: []
                )
            )
        )

        let state = loader.load(archive: testImportedArchive(), password: nil)

        guard case .failed(let error) = state else {
            return XCTFail("Expected failed listing state.")
        }
        XCTAssertEqual(error.code, "unsupported_format")
        XCTAssertFalse(error.retryable)
    }
}

private final class FakeArchiveBridgeClient: ArchiveBridgeClient {
    var detection = DetectArchiveResult(
        archivePath: "/cache/archive.zip",
        format: .zip,
        formatLabel: "ZIP",
        exists: true,
        isFile: true,
        canList: true,
        canExtract: true,
        canCreate: false,
        warnings: []
    )
    var listing = ListArchiveResult(
        archivePath: "/cache/archive.zip",
        format: .zip,
        formatLabel: "ZIP",
        entries: [],
        entryCount: 0,
        totalSize: nil,
        warnings: []
    )
    var preview = MaterializePreviewResult(
        archivePath: "/cache/archive.zip",
        entryPath: "readme.txt",
        cleanupRoot: "/cache/previews/preview-id",
        previewPath: "/cache/previews/preview-id/readme.txt",
        writtenBytes: 0,
        warnings: []
    )
    var testResult = TestArchiveResult(
        archivePath: "/cache/archive.zip",
        format: .zip,
        formatLabel: "ZIP",
        verified: true,
        testedEntries: 0,
        skippedEntries: 0,
        totalEntries: 0,
        testedBytes: 0,
        warnings: []
    )
    var detectError: Error?
    var listError: Error?
    var previewError: Error?
    var testError: Error?
    private(set) var testedSelectedPaths: [String] = []
    var onStartExtraction: ((String) throws -> Void)?

    init(
        detection: DetectArchiveResult? = nil,
        listing: ListArchiveResult? = nil,
        preview: MaterializePreviewResult? = nil,
        testResult: TestArchiveResult? = nil,
        detectError: Error? = nil,
        listError: Error? = nil,
        previewError: Error? = nil,
        testError: Error? = nil
    ) {
        if let detection = detection {
            self.detection = detection
        }
        if let listing = listing {
            self.listing = listing
        }
        if let preview = preview {
            self.preview = preview
        }
        if let testResult = testResult {
            self.testResult = testResult
        }
        self.detectError = detectError
        self.listError = listError
        self.previewError = previewError
        self.testError = testError
    }

    func detectArchiveMetadata(path: String) throws -> DetectArchiveResult {
        if let detectError = detectError {
            throw detectError
        }
        return detection
    }

    func listArchiveContents(path: String, password: String?) throws -> ListArchiveResult {
        if let listError = listError {
            throw listError
        }
        return listing
    }

    func materializePreviewEntry(
        path: String,
        entryPath: String,
        password: String?
    ) throws -> MaterializePreviewResult {
        if let previewError = previewError {
            throw previewError
        }
        return preview
    }

    func testArchiveContents(
        path: String,
        selectedPaths: [String],
        password: String?
    ) throws -> TestArchiveResult {
        if let testError = testError {
            throw testError
        }
        testedSelectedPaths = selectedPaths
        return testResult
    }

    func planExtraction(
        path: String,
        destinationRoot: String,
        selectedPaths: [String],
        password: String?,
        collisionPolicy: ExtractionCollisionPolicy
    ) throws -> PlanExtractResult {
        PlanExtractResult(
            archivePath: path,
            destinationRoot: destinationRoot,
            format: .zip,
            formatLabel: "ZIP",
            entries: [
                ExtractionPlanEntry(
                    archivePath: "docs/readme.txt",
                    normalizedPath: "docs/readme.txt",
                    destinationPath: "docs/readme.txt",
                    kind: .file,
                    status: .write,
                    reason: nil,
                    size: 9,
                    compressedSize: nil,
                    replaceExisting: false
                )
            ],
            totalEntries: 1,
            writableEntries: 1,
            skippedEntries: 0,
            blockedEntries: 0,
            estimatedBytes: 9,
            canStart: true,
            warnings: [],
            planToken: "review-token"
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
        try onStartExtraction?(destinationRoot)
        return StartJobResult(jobId: "job-id", kind: .zipExtract, status: .running)
    }

    func pollExtractionJob(jobId: String, cursor: UInt64) throws -> PollJobEventsResult {
        PollJobEventsResult(
            jobId: jobId,
            kind: .zipExtract,
            status: .completed,
            events: [
                MobileJobEvent(
                    sequence: 1,
                    eventType: .completed,
                    jobKind: .zipExtract,
                    path: nil,
                    bytes: nil,
                    totalBytes: 9,
                    totalBytesProcessed: 9,
                    entries: 1,
                    totalEntries: 1,
                    message: "Complete",
                    error: nil
                )
            ],
            nextCursor: 1,
            minRetainedSequence: 1,
            isTerminal: true,
            terminalSummary: nil
        )
    }

    func cancelExtractionJob(jobId: String) throws {}
}

private final class CreationFakeBridgeClient: ArchiveBridgeClient {
    var plannedSourcePaths: [String] = []
    var startedRequest: StartCreateRequest?
    var pollCount = 0

    func detectArchiveMetadata(path: String) throws -> DetectArchiveResult {
        fatalError("Not used")
    }

    func listArchiveContents(path: String, password: String?) throws -> ListArchiveResult {
        fatalError("Not used")
    }

    func materializePreviewEntry(path: String, entryPath: String, password: String?) throws -> MaterializePreviewResult {
        fatalError("Not used")
    }

    func testArchiveContents(path: String, selectedPaths: [String], password: String?) throws -> TestArchiveResult {
        fatalError("Not used")
    }

    func planCreation(request: PlanCreateRequest) throws -> PlanCreateResult {
        plannedSourcePaths = request.sourcePaths
        return PlanCreateResult(
            sourcePaths: request.sourcePaths,
            destinationArchivePath: request.destinationArchivePath,
            format: request.format,
            formatLabel: "ZIP",
            entries: [],
            totalEntries: 1,
            totalBytes: 4,
            excludedEntries: 0,
            excludedBytes: 0,
            outputExists: false,
            replaceExisting: request.replaceExisting,
            encrypted: request.password != nil,
            preserveMetadata: request.preserveMetadata,
            cleanSource: request.cleanSource,
            verifyAfterCreate: request.verifyAfterCreate,
            verifySupported: true,
            canStart: true,
            warnings: []
        )
    }

    func startCreation(request: StartCreateRequest) throws -> StartJobResult {
        startedRequest = request
        return StartJobResult(jobId: "create-job", kind: .zipCreate, status: .running)
    }

    func pollExtractionJob(jobId: String, cursor: UInt64) throws -> PollJobEventsResult {
        pollCount += 1
        return PollJobEventsResult(
            jobId: jobId,
            kind: .zipCreate,
            status: .completed,
            events: [
                MobileJobEvent(
                    sequence: 1,
                    eventType: .completed,
                    jobKind: .zipCreate,
                    path: nil,
                    bytes: 4,
                    totalBytes: 4,
                    totalBytesProcessed: 4,
                    entries: 1,
                    totalEntries: 1,
                    message: "Complete",
                    error: nil
                )
            ],
            nextCursor: 1,
            minRetainedSequence: 1,
            isTerminal: true,
            terminalSummary: JobTerminalSummary(
                writtenEntries: 1,
                skippedEntries: 0,
                writtenBytes: 4,
                encrypted: false,
                volumeSize: nil,
                volumeCount: 1,
                outputPaths: ["/files/output.zip"],
                verified: true,
                verifiedEntries: 1,
                verifiedBytes: 4,
                warnings: []
            )
        )
    }
}
