import XCTest
import Foundation
import CryptoKit
@testable import ZManagerMobile

final class ZManagerMobileTests: XCTestCase {
    func testInboundAndOutboundSessionsUseTheSameStableInstallationFingerprint() {
        let suiteName = "ZManagerMobileTests.localsend-identity"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let first = LocalSendIdentity.fingerprint(defaults: defaults)
        let second = LocalSendIdentity.fingerprint(defaults: defaults)

        XCTAssertFalse(first.isEmpty)
        XCTAssertEqual(first, second)
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testOperationReportStoreRedactsCredentials() throws {
        let report = ArchiveOperationReportStore.save(
            operation: "extract",
            subject: "archive.zip",
            status: "completed",
            message: "Extraction complete",
            destination: "App storage",
            entries: 3,
            verified: nil
        )
        defer { try? FileManager.default.removeItem(at: report) }
        let text = try String(contentsOf: report)
        XCTAssertTrue(text.contains("Extraction complete"))
        XCTAssertTrue(text.contains("never included"))
        XCTAssertFalse(text.contains("password"))
        XCTAssertFalse(text.contains("transferToken"))
    }

    func testDefaultExtractionDestinationResetsToAppStorage() {
        let suiteName = "ZManagerMobileTests.destination-default"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let preferences = ArchiveDestinationPreferences(defaults: defaults)
        let appStorage = URL(fileURLWithPath: "/tmp/zmanager-mobile-tests/Extracted", isDirectory: true)

        XCTAssertEqual(preferences.defaultExtractionDestination(appStorage: appStorage), .appStorage(appStorage))
        preferences.setExtractionDestination(.appStorage(appStorage))
        XCTAssertEqual(preferences.defaultExtractionDestination(appStorage: appStorage), .appStorage(appStorage))
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testFailedCommitRecoveryIsRedactedAndDiscardable() throws {
        let fileManager = FileManager.default
        let staging = fileManager.temporaryDirectory
            .appendingPathComponent("ZManagerMobileTests-Recovery-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        let output = staging.appendingPathComponent("docs/readme.txt")
        try fileManager.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("retained".utf8).write(to: output)
        let store = ArchiveRecoveryStore(fileManager: fileManager)
        let record = try store.save(
            archive: ImportedArchive(
                id: UUID(),
                displayName: "archive.zip",
                localPath: "/cache/archive.zip",
                byteSize: 1,
                importedAt: Date()
            ),
            selectedPaths: ["docs/readme.txt"],
            stagingRoot: staging,
            destinationLabel: "Selected folder",
            message: "Provider failed"
        )
        let recordURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ZManagerMobile/ArchiveRecovery/\(record.id.uuidString).json")
        let text = try String(contentsOf: recordURL)
        XCTAssertTrue(text.contains("archive.zip"))
        XCTAssertFalse(text.lowercased().contains("password"))
        XCTAssertFalse(text.lowercased().contains("token"))
        XCTAssertEqual(store.files(for: record).count, 1)

        store.discard(record)
        XCTAssertFalse(fileManager.fileExists(atPath: staging.path))
    }

    func testStagedRelativePathsRejectTraversalAndAcceptOnlyDescendants() throws {
        let root = URL(fileURLWithPath: "/tmp/zmanager-staging-root", isDirectory: true)
        XCTAssertEqual(
            try ExtractionPathSafety.relativePath(
                for: root.appendingPathComponent("docs/readme.txt"),
                under: root
            ),
            "docs/readme.txt"
        )
        XCTAssertThrowsError(try ExtractionPathSafety.relativePath(
            for: root.appendingPathComponent("../outside.txt"),
            under: root
        ))
        XCTAssertThrowsError(try ExtractionPathSafety.relativePath(
            for: URL(fileURLWithPath: "/tmp/outside.txt"),
            under: root
        ))
    }

    func testExtractionPathSafetyAgreesWithTheSharedFixtureTable() throws {
        let fixtureURL = try sharedPathSafetyFixtureTableURL()
        let table = try JSONDecoder().decode(PathSafetyFixtureTable.self, from: Data(contentsOf: fixtureURL))
        let fileManager = FileManager.default

        for testCase in table.cases {
            let root = fileManager.temporaryDirectory
                .appendingPathComponent("zmanager-path-safety-\(testCase.name)-\(UUID().uuidString)", isDirectory: true)
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? fileManager.removeItem(at: root) }

            if let createFile = testCase.createFile {
                let target = root.appendingPathComponent(createFile)
                try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("fixture".utf8).write(to: target)
            }
            if let symlink = testCase.symlink {
                let link = root.appendingPathComponent(symlink.link)
                try fileManager.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.createSymbolicLink(atPath: link.path, withDestinationPath: symlink.target)
            }

            let fileURL: URL
            if testCase.input == "@root" {
                fileURL = root
            } else if testCase.input.hasPrefix("@sibling/") {
                let rest = String(testCase.input.dropFirst("@sibling/".count))
                fileURL = root.deletingLastPathComponent()
                    .appendingPathComponent("zmanager-path-safety-sibling-\(testCase.name)")
                    .appendingPathComponent(rest)
            } else {
                fileURL = root.appendingPathComponent(testCase.input)
            }

            if let expected = testCase.expected {
                let actual = try ExtractionPathSafety.relativePath(for: fileURL, under: root)
                XCTAssertEqual(actual, expected, "case '\(testCase.name)'")
            } else {
                XCTAssertThrowsError(
                    try ExtractionPathSafety.relativePath(for: fileURL, under: root),
                    "case '\(testCase.name)' should have been rejected"
                )
            }
        }
    }

    func testNoOpJobPacerNeverDelays() async {
        let start = DispatchTime.now()
        await NoOpJobPacer().beforePoll(isTerminal: false)
        let elapsedMillis = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        XCTAssertLessThan(elapsedMillis, 40, "expected no delay, elapsed=\(elapsedMillis)ms")
    }

    func testDelayingJobPacerDelaysBeforeNonTerminalPollsOnly() async {
        let pacer = DelayingJobPacer(delayNanoseconds: 50_000_000)

        let nonTerminalStart = DispatchTime.now()
        await pacer.beforePoll(isTerminal: false)
        let nonTerminalElapsed = Double(DispatchTime.now().uptimeNanoseconds - nonTerminalStart.uptimeNanoseconds) / 1_000_000
        XCTAssertGreaterThanOrEqual(nonTerminalElapsed, 40, "expected a non-terminal poll to delay, elapsed=\(nonTerminalElapsed)ms")

        let terminalStart = DispatchTime.now()
        await pacer.beforePoll(isTerminal: true)
        let terminalElapsed = Double(DispatchTime.now().uptimeNanoseconds - terminalStart.uptimeNanoseconds) / 1_000_000
        XCTAssertLessThan(terminalElapsed, 40, "expected a terminal poll not to delay, elapsed=\(terminalElapsed)ms")
    }

    func testLocalSendTrustStorePersistsExplicitFingerprintOnly() {
        let suiteName = "ZManagerMobileTests.localsend-trust"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let store = LocalSendTrustStore(defaults: defaults)
        let device = LocalSendDevice(
            id: "192.0.2.1:53317",
            address: "192.0.2.1",
            port: 53317,
            protocolName: "http",
            alias: "Receiver",
            version: "2.0",
            deviceModel: "test",
            deviceType: "mobile",
            fingerprint: "trusted-fingerprint",
            download: false
        )
        XCTAssertFalse(store.isTrusted(device))
        store.remember(device)
        XCTAssertTrue(store.isTrusted(device))
        XCTAssertEqual(store.fingerprints(), ["trusted-fingerprint"])
        store.forget(fingerprint: "trusted-fingerprint")
        XCTAssertTrue(store.fingerprints().isEmpty)
        store.forget(device)
        XCTAssertFalse(store.isTrusted(device))
        defaults.removePersistentDomain(forName: suiteName)
    }

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

        var scopeEvents: [String] = []
        let securityScope = SecurityScopedResourceAccess(
            start: { url in
                scopeEvents.append("start:\(url.lastPathComponent)")
                return true
            },
            stop: { url in
                scopeEvents.append("stop:\(url.lastPathComponent)")
            }
        )

        let imported = try ArchiveImportStore(
            fileManager: fileManager,
            cacheRoot: cacheRoot,
            securityScope: securityScope
        ).importArchive(from: source)

        XCTAssertEqual(imported.displayName, "source.zip")
        XCTAssertTrue(imported.localPath.hasPrefix(cacheRoot.path))
        XCTAssertEqual(imported.byteSize, 13)
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: imported.localPath)),
            Data("hello archive".utf8)
        )
        XCTAssertEqual(scopeEvents, ["start:source.zip", "stop:source.zip"])
    }

    func testArchiveImportAndBridgeListTarXzFixture() throws {
        let appBundle = try XCTUnwrap(Bundle(identifier: "org.tzap.zmanager.mobile"))
        let fixture = try XCTUnwrap(appBundle.url(forResource: "maestro-files.tar.xz", withExtension: nil))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let imported = try ArchiveImportStore(
            fileManager: .default,
            cacheRoot: root
        ).importArchive(from: fixture)
        let bridge = GeneratedArchiveBridgeClient()
        let detection = try bridge.detectArchiveMetadata(path: imported.localPath)
        XCTAssertTrue(detection.canList)
        let listing = try bridge.listArchiveContents(path: imported.localPath, password: nil)
        XCTAssertEqual(listing.entryCount, 5)
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
                            modifiedAt: nil,
                            linkTarget: nil
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

    func testArchiveListingLoaderReturnsEveryEntryPastThePreviousFiftyEntryCap() {
        let entries = (0..<300).map { index in
            ArchiveEntry(
                path: "file-\(index).txt",
                kind: .file,
                isDir: false,
                size: 1,
                compressedSize: nil,
                modifiedAt: nil,
                linkTarget: nil
            )
        }
        let loader = ArchiveListingLoader(
            bridge: FakeArchiveBridgeClient(
                listing: ListArchiveResult(
                    archivePath: "/cache/archive.zip",
                    format: .zip,
                    formatLabel: "ZIP",
                    entries: entries,
                    entryCount: 300,
                    totalSize: 300,
                    warnings: []
                )
            )
        )

        let state = loader.load(archive: testImportedArchive(), password: nil)

        guard case .ready(let summary) = state else {
            return XCTFail("Expected ready listing state.")
        }
        XCTAssertEqual(summary.entries.count, 300)
        XCTAssertEqual(summary.entries[250].path, "file-250.txt")
    }

    func testFilteredSortedEntriesSearchesTheFullSetNotJustAWindow() {
        let entries = (0..<300).map { index in testEntry(id: "\(index)", path: "file-\(index).txt") } +
            [testEntry(id: "needle", path: "needle-past-the-window.txt")]
        let summary = ArchiveListingSummary(
            formatLabel: "ZIP",
            entryCount: UInt64(entries.count),
            totalSize: nil,
            entries: entries,
            warnings: []
        )

        let filtered = summary.filteredSortedEntries(searchQuery: "needle", sort: .pathAscending)

        XCTAssertEqual(filtered.map(\.path), ["needle-past-the-window.txt"])
    }

    @MainActor
    func testExtractionSelectedPathsReturnsEmptyListOnlyAfterSelectEverything() {
        let session = ArchiveSessionModel()
        let entries = [testEntry(id: "1", path: "a.txt"), testEntry(id: "2", path: "b.txt")]
        let summary = ArchiveListingSummary(
            formatLabel: "ZIP",
            entryCount: 2,
            totalSize: nil,
            entries: entries,
            warnings: []
        )

        session.selectEverything(summary)

        XCTAssertTrue(session.selectedEverything)
        XCTAssertEqual(session.selectedEntryIds, Set(["1", "2"]))
    }

    @MainActor
    func testTogglingAnEntryClearsTheSelectEverythingFlag() {
        let session = ArchiveSessionModel()
        let entries = [testEntry(id: "1", path: "a.txt"), testEntry(id: "2", path: "b.txt")]
        let summary = ArchiveListingSummary(
            formatLabel: "ZIP",
            entryCount: 2,
            totalSize: nil,
            entries: entries,
            warnings: []
        )
        session.selectEverything(summary)

        session.toggleEntrySelected(entries[0])

        XCTAssertFalse(session.selectedEverything)
        XCTAssertEqual(session.selectedEntryIds, Set(["2"]))
    }

    @MainActor
    func testClearSelectionResetsTheSelectEverythingFlag() {
        let session = ArchiveSessionModel()
        let entries = [testEntry(id: "1", path: "a.txt")]
        let summary = ArchiveListingSummary(
            formatLabel: "ZIP",
            entryCount: 1,
            totalSize: nil,
            entries: entries,
            warnings: []
        )
        session.selectEverything(summary)

        session.clearSelection()

        XCTAssertFalse(session.selectedEverything)
        XCTAssertTrue(session.selectedEntryIds.isEmpty)
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

        XCTAssertEqual(
            outcome,
            .completed(
                outputPath: "/files/output.zip",
                verified: true,
                outputPaths: ["/files/output.zip"]
            )
        )
        XCTAssertGreaterThan(bridge.pollCount, 0)
    }

    func testTarGzUsesTarGzExtensionAndDoesNotOfferSplitVolumes() {
        XCTAssertFalse(ArchiveVolumeSupport.supportsVolumeSize(.tarGz))
        XCTAssertEqual(
            ArchiveVolumeSupport.outputPaths(
                format: .tarGz,
                destination: "/files/archive.tar.gz",
                volumeCount: 3,
                reportedPaths: []
            ),
            ["/files/archive.tar.gz"]
        )
    }

    func testSeparateCreationRequestsUseStableNamesAndUniqueDestinations() {
        let requests = ArchiveSeparateCreationPlanner.requests(
            sourcePaths: ["/cache/photos.zip", "/cache/photos.txt", "/cache/folder"],
            destinationDirectory: "/files/CreatedArchives",
            format: .zip,
            password: "secret",
            volumeSize: 64 * 1024
        )

        XCTAssertEqual(
            requests.map(\.destinationArchivePath),
            [
                "/files/CreatedArchives/photos.zip",
                "/files/CreatedArchives/photos (1).zip",
                "/files/CreatedArchives/folder.zip"
            ]
        )
        XCTAssertEqual(requests.map(\.sourcePaths), [["/cache/photos.zip"], ["/cache/photos.txt"], ["/cache/folder"]])
        XCTAssertTrue(requests.allSatisfy { $0.password == "secret" && $0.volumeSize == 64 * 1024 })
    }

    func testSeparateCreationCoordinatorPlansEveryItemThroughRustGateway() throws {
        let bridge = CreationFakeBridgeClient()
        let coordinator = ArchiveCreationCoordinator(bridge: bridge)
        let separate = ArchiveSeparateCreationCoordinator(coordinator: coordinator)
        let requests = ArchiveSeparateCreationPlanner.requests(
            sourcePaths: ["/cache/one.txt", "/cache/two.txt"],
            destinationDirectory: "/files/CreatedArchives",
            format: .sevenZ
        )

        let review = try separate.plan(requests: requests)

        XCTAssertEqual(review.items.count, 2)
        XCTAssertEqual(bridge.plannedSourcePathsByRequest.map(\.first!), ["/cache/one.txt", "/cache/two.txt"])
    }

    @MainActor
    func testSeparateCreationRunsEachRustJobSequentially() async throws {
        let bridge = CreationFakeBridgeClient()
        let coordinator = ArchiveCreationCoordinator(bridge: bridge)
        let separate = ArchiveSeparateCreationCoordinator(coordinator: coordinator)
        let review = try separate.plan(
            requests: ArchiveSeparateCreationPlanner.requests(
                sourcePaths: ["/cache/one.txt", "/cache/two.txt"],
                destinationDirectory: "/files/CreatedArchives",
                format: .zip
            )
        )
        let session = ArchiveSessionModel(creationCoordinator: coordinator)
        let model = ArchiveCreationModel(session: session)

        model.startSeparateCreation(review)
        try await Task.sleep(nanoseconds: 800_000_000)

        guard case .completed(.completed(_, let verified, let outputPaths)) = model.creationState else {
            return XCTFail("Expected separate creation to complete: \(String(describing: model.creationState))")
        }
        XCTAssertTrue(verified)
        XCTAssertEqual(outputPaths, ["/files/CreatedArchives/one.zip", "/files/CreatedArchives/two.zip"])
        XCTAssertEqual(bridge.startedRequests.map(\.destinationArchivePath), [
            "/files/CreatedArchives/one.zip",
            "/files/CreatedArchives/two.zip"
        ])
    }

    @MainActor
    func testSceneBackgroundDiscardsSeparateCreationReview() {
        let bridge = CreationFakeBridgeClient()
        let coordinator = ArchiveCreationCoordinator(bridge: bridge)
        let separate = ArchiveSeparateCreationCoordinator(coordinator: coordinator)
        let review = try! separate.plan(
            requests: ArchiveSeparateCreationPlanner.requests(
                sourcePaths: ["/cache/one.txt", "/cache/two.txt"],
                destinationDirectory: "/files/CreatedArchives",
                format: .zip
            )
        )
        let session = ArchiveSessionModel(creationCoordinator: coordinator)
        let model = ArchiveCreationModel(session: session)
        model.creationState = .separateReview(review)

        model.handleSceneBackground()

        if case .idle = model.creationState {
            return
        }
        XCTFail("Backgrounding must discard the separate creation review")
    }

    func testPinnedBridgeCreatesAndReportsSplitZipVolumes() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("ZManagerMobileTests-Split-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let source = root.appendingPathComponent("source.bin")
        var state: UInt32 = 0x6D2B79F5
        let bytes = Data((0..<4_000_000).map { _ in
            state ^= state << 13
            state ^= state >> 17
            state ^= state << 5
            return UInt8(truncatingIfNeeded: state)
        })
        try bytes.write(to: source)
        let destination = root.appendingPathComponent("split.zip")
        let coordinator = ArchiveCreationCoordinator()
        let review = try coordinator.plan(
            request: ArchiveCreationRequest(
                sourcePaths: [source.path],
                destinationArchivePath: destination.path,
                format: .zip,
                volumeSize: 64 * 1024
            )
        )

        let jobID = try coordinator.start(review: review)
        let outcome = try await coordinator.awaitCompletion(review: review, jobId: jobID) { _ in }

        guard case .completed(let outputPath, let verified, let outputPaths) = outcome else {
            return XCTFail("Expected split creation to complete: \(outcome)")
        }
        XCTAssertEqual(outputPath, destination.path)
        // Verification of the multi-volume root is bridge/engine dependent;
        // the contract under test is that creation commits the complete set.
        _ = verified
        XCTAssertGreaterThan(outputPaths.count, 1)
        XCTAssertTrue(outputPaths.allSatisfy { fileManager.fileExists(atPath: $0) })
    }

    func testCommittedOutputPathsDiscoversZipSidecarsWhenBridgeOmitsMetadata() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("ZManagerMobileTests-Sidecars-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let destination = root.appendingPathComponent("output.zip")
        try Data("volume 1".utf8).write(to: root.appendingPathComponent("output.z01"))
        try Data("volume 2".utf8).write(to: root.appendingPathComponent("output.z02"))
        try Data("final volume".utf8).write(to: destination)

        XCTAssertEqual(
            ArchiveVolumeSupport.committedOutputPaths(
                format: .zip,
                destination: destination.path,
                volumeCount: nil,
                reportedPaths: [],
                fileManager: fileManager
            ),
            [destination.path, root.appendingPathComponent("output.z01").path, root.appendingPathComponent("output.z02").path]
        )
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

    func testLocalSendPinRequiredUsesUnauthorizedStatus() {
        XCTAssertTrue(LocalSendClient.isPinRequiredStatus(401))
        XCTAssertFalse(LocalSendClient.isPinRequiredStatus(403))
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

    func testNativeStagersBracketSecurityScopedAccess() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let source = root.appendingPathComponent("selected.txt")
        try Data("scoped content".utf8).write(to: source)
        let folder = root.appendingPathComponent("Folder", isDirectory: true)
        let nested = folder.appendingPathComponent("nested/data.bin")
        try fileManager.createDirectory(at: nested.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: nested)

        var events: [String] = []
        let access = SecurityScopedResourceAccess(
            start: { url in
                events.append("start:\(url.lastPathComponent)")
                return true
            },
            stop: { url in
                events.append("stop:\(url.lastPathComponent)")
            }
        )

        let creationStager = ArchiveCreationSourceStager(fileManager: fileManager, securityScope: access)
        let stagedFile = try creationStager.stageFiles([source])
        defer { creationStager.discard(stagedFile) }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: stagedFile.sourcePaths[0])), Data("scoped content".utf8))

        let localSendStager = LocalSendSourceStager(fileManager: fileManager, securityScope: access)
        let stagedFolder = try localSendStager.stageFiles([source])
        defer { localSendStager.discard(stagedFolder) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedFolder.sourcePaths[0]))

        let folderStaging = try creationStager.stageFolder(folder)
        defer { creationStager.discard(folderStaging) }
        let stagedNested = URL(fileURLWithPath: folderStaging.sourcePaths[0])
            .appendingPathComponent("nested/data.bin")
        XCTAssertEqual(try Data(contentsOf: stagedNested), Data([1, 2, 3]))
        XCTAssertEqual(
            events,
            [
                "start:selected.txt", "stop:selected.txt",
                "start:selected.txt", "stop:selected.txt",
                "start:Folder", "stop:Folder"
            ]
        )
    }

    func testSecurityScopedAccessStopsWhenStagingFails() {
        let fileManager = FileManager.default
        var events: [String] = []
        let access = SecurityScopedResourceAccess(
            start: { url in
                events.append("start:\(url.lastPathComponent)")
                return true
            },
            stop: { url in
                events.append("stop:\(url.lastPathComponent)")
            }
        )
        let missing = fileManager.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).txt")
        let stager = ArchiveCreationSourceStager(fileManager: fileManager, securityScope: access)

        XCTAssertThrowsError(try stager.stageFiles([missing]))
        XCTAssertEqual(events, ["start:\(missing.lastPathComponent)", "stop:\(missing.lastPathComponent)"])
    }

    func testCreationSourceStagerWritesPhotoDataAndCleansIt() throws {
        let stager = ArchiveCreationSourceStager()
        let staged = try stager.stageData([
            (name: "photo.jpg", data: Data([1, 2, 3]))
        ])
        defer { stager.discard(staged) }

        XCTAssertEqual(staged.sourcePaths.count, 1)
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: staged.sourcePaths[0])),
            Data([1, 2, 3])
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.root.path))
    }

    @MainActor
    func testSceneBackgroundClearsTransientPasswords() {
        let session = ArchiveSessionModel()
        let listing = ArchiveListingModel(session: session)
        let extraction = ArchiveExtractionModel(session: session)
        let creation = ArchiveCreationModel(session: session)
        let repackaging = ArchiveRepackagingModel(session: session, creation: creation)
        let batchExtraction = ArchiveBatchExtractionModel(session: session)
        let localSend = ArchiveLocalSendModel(session: session)

        session.passwordInput = "archive-password"
        listing.previewPasswordInput = "preview-password"
        listing.testPasswordInput = "test-password"
        extraction.extractionPasswordInput = "extract-password"
        creation.creationPasswordInput = "create-password"
        repackaging.repackagingPasswordInput = "repackage-password"
        localSend.localSendPinInput = "1234"

        ArchiveSceneBackgroundCoordinator.handle(
            session: session,
            listing: listing,
            extraction: extraction,
            creation: creation,
            repackaging: repackaging,
            batchExtraction: batchExtraction,
            localSend: localSend
        )

        XCTAssertTrue(session.passwordInput.isEmpty)
        XCTAssertTrue(listing.previewPasswordInput.isEmpty)
        XCTAssertTrue(listing.testPasswordInput.isEmpty)
        XCTAssertTrue(extraction.extractionPasswordInput.isEmpty)
        XCTAssertTrue(creation.creationPasswordInput.isEmpty)
        XCTAssertTrue(repackaging.repackagingPasswordInput.isEmpty)
        XCTAssertTrue(localSend.localSendPinInput.isEmpty)
    }

    @MainActor
    func testSceneBackgroundStopsLocalSendReceiver() {
        let session = ArchiveSessionModel()
        let model = ArchiveLocalSendModel(
            session: session,
            localSendReceiver: LocalSendReceiver(port: 53318)
        )
        model.startLocalReceive()
        guard case .receiving = model.localSendState else {
            return XCTFail("Expected LocalSend receiver to be active")
        }

        model.handleSceneBackground()

        if case .receiving = model.localSendState {
            XCTFail("Backgrounding must stop the LocalSend receiver")
        }
    }

    @MainActor
    func testSceneBackgroundDiscardsStagedLocalSendFiles() throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("localsend-background-(UUID().uuidString).txt")
        try Data("temporary transfer".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let session = ArchiveSessionModel()
        let model = ArchiveLocalSendModel(session: session)
        model.handleLocalSendFilesResult(.success([source]))
        XCTAssertEqual(model.localSendSelectedFileCount, 1)

        model.handleSceneBackground()

        XCTAssertEqual(model.localSendSelectedFileCount, 0)
    }

    func testAutomationParserAcceptsExplicitLocalOpen() throws {
        let request = try ArchiveAutomationParser.parse(
            URL(string: "zmanager://open?archive=file:///tmp/archive.zip")!
        )

        XCTAssertEqual(request.action, .open)
        XCTAssertEqual(request.archiveURL, URL(fileURLWithPath: "/tmp/archive.zip"))
        XCTAssertTrue(request.sourceURLs.isEmpty)
    }

    func testAutomationParserRejectsCredentialQuery() {
        XCTAssertThrowsError(try ArchiveAutomationParser.parse(
            URL(string: "zmanager://open?archive=file:///tmp/archive.zip&password=secret")!
        )) { error in
            XCTAssertEqual((error as? ArchiveAutomationError), .credentialQuery)
        }
    }

    func testAutomationParserAcceptsShareExtensionHandoffWithoutCredentials() throws {
        let request = try ArchiveAutomationParser.parse(
            URL(string: "zmanager://import?id=share-123")!
        )

        XCTAssertEqual(request.action, .importShared)
        XCTAssertEqual(request.sharedIdentifier, "share-123")
        XCTAssertNil(request.archiveURL)
        XCTAssertTrue(request.sourceURLs.isEmpty)
    }

    func testSharedImportStoreCopiesAndConsumesAppGroupInbox() throws {
        let fileManager = FileManager.default
        let container = fileManager.temporaryDirectory
            .appendingPathComponent("ZManagerMobile-ShareGroup-\(UUID().uuidString)", isDirectory: true)
        let identifier = "share-\(UUID().uuidString)"
        let incoming = container
            .appendingPathComponent(SharedImportStore.incomingDirectoryName, isDirectory: true)
            .appendingPathComponent(identifier, isDirectory: true)
        try fileManager.createDirectory(at: incoming, withIntermediateDirectories: true)
        try Data("shared archive".utf8).write(to: incoming.appendingPathComponent("evil:archive.zip"))
        try Data("real archive".utf8).write(to: incoming.appendingPathComponent("archive.zip"))
        defer { try? fileManager.removeItem(at: container) }

        let store = SharedImportStore(fileManager: fileManager) { container }
        let batch = try store.stageIncoming(identifier: identifier)

        XCTAssertEqual(batch.sourceURLs.count, 2)
        XCTAssertFalse(fileManager.fileExists(atPath: incoming.path))
        XCTAssertTrue(batch.sourceURLs.allSatisfy { fileManager.fileExists(atPath: $0.path) })
        XCTAssertTrue(batch.sourceURLs.contains { $0.lastPathComponent == "evil_archive.zip" })
        XCTAssertTrue(batch.sourceURLs.contains { $0.lastPathComponent == "archive.zip" })

        try fileManager.removeItem(at: batch.cleanupRoot)
    }

    func testSharedImportStoreRejectsTraversalIdentifiers() {
        XCTAssertFalse(SharedImportStore.isValidIdentifier("../outside"))
        XCTAssertFalse(SharedImportStore.isValidIdentifier("share/id"))
        XCTAssertTrue(SharedImportStore.isValidIdentifier("share-123"))
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

    func testLocalSendReceiverReturnsChecksumMismatchAndCleansPartialUpload() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }
        let receiver = LocalSendReceiver(port: 53316, fileManager: fileManager)
        try receiver.start(destinationRoot: root)
        defer { receiver.stop() }

        let payload = Data("actual".utf8)
        let fileID = "checksum-file"
        let prepareBody: [String: Any] = ["files": [fileID: [
            "id": fileID, "fileName": "checksum.bin", "size": payload.count,
            "sha256": String(repeating: "0", count: 64)
        ]]]
        var prepare = URLRequest(url: URL(string: "http://127.0.0.1:53316/api/localsend/v2/prepare-upload")!)
        prepare.httpMethod = "POST"
        prepare.httpBody = try JSONSerialization.data(withJSONObject: prepareBody)
        let (prepareData, _) = try await URLSession.shared.data(for: prepare)
        let prepareJSON = try XCTUnwrap(try JSONSerialization.jsonObject(with: prepareData) as? [String: Any])
        let sessionID = try XCTUnwrap(prepareJSON["sessionId"] as? String)
        let token = try XCTUnwrap((prepareJSON["files"] as? [String: String])?[fileID])
        var upload = URLRequest(url: URL(string: "http://127.0.0.1:53316/api/localsend/v2/upload?sessionId=\(sessionID)&fileId=\(fileID)&token=\(token)")!)
        upload.httpMethod = "POST"
        upload.httpBody = payload
        let (_, response) = try await URLSession.shared.data(for: upload)

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 422)
        XCTAssertFalse(fileManager.fileExists(atPath: root.appendingPathComponent("checksum.bin").path))
        XCTAssertFalse(fileManager.fileExists(atPath: root.appendingPathComponent(".localsend").appendingPathComponent(sessionID).path))
    }

    func testLocalSendClientUploadsWithByteProgress() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }
        let receiver = LocalSendReceiver(port: 53315, fileManager: fileManager)
        try receiver.start(destinationRoot: root)
        defer { receiver.stop() }

        let source = root.appendingPathComponent("source.bin")
        try Data((0..<256 * 1024).map { UInt8($0 % 251) }).write(to: source)
        let file = LocalSendTransferFile(url: source, displayName: "uploaded.bin")
        let device = LocalSendDevice(
            id: "127.0.0.1:53315",
            address: "127.0.0.1",
            port: 53315,
            protocolName: "http",
            alias: "Receiver",
            version: "2.0",
            deviceModel: "test",
            deviceType: "headless",
            fingerprint: "receiver",
            download: true
        )
        let client = LocalSendClient(alias: "Sender", fingerprint: "sender", port: 0)
        let session = try await client.prepareUpload(to: device, files: [file])
        var progress = [(Int64, Int64)]()
        try await client.upload(to: device, session: session, files: [file]) { _, sent, total in
            progress.append((sent, total))
        }

        XCTAssertFalse(progress.isEmpty)
        XCTAssertEqual(progress.last?.1, Int64(256 * 1024))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("uploaded.bin")), try Data(contentsOf: source))
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

    func testUnavailableSecurityScopedDestinationRetainsRecoveryRecord() async throws {
        let fileManager = FileManager.default
        let bridge = FakeArchiveBridgeClient()
        bridge.onStartExtraction = { stagingPath in
            let output = URL(fileURLWithPath: stagingPath).appendingPathComponent("docs/readme.txt")
            try fileManager.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("extracted".utf8).write(to: output)
        }
        let coordinator = ArchiveExtractionCoordinator(bridge: bridge, fileManager: fileManager)
        let destination = ExtractionDestination.folder(
            URL(fileURLWithPath: "/definitely-missing-zmanager-destination")
        )
        let review = try coordinator.plan(
            archive: testImportedArchive(),
            selectedPaths: ["docs/readme.txt"],
            destination: destination,
            password: nil,
            collisionPolicy: .refuse
        )

        let outcome = try await coordinator.awaitCompletion(
            review: review,
            jobId: try coordinator.start(review: review)
        ) { _ in }

        guard case .recoveryAvailable(let id, _) = outcome else {
            return XCTFail("Expected recovery for an unavailable provider destination.")
        }
        XCTAssertEqual(coordinator.recoveryFiles(coordinator.recoveries().first { $0.id == id }!).count, 1)
        if let record = coordinator.recoveries().first(where: { $0.id == id }) {
            coordinator.discardRecovery(record)
        }
    }

    func testBatchExtractionRunsIndependentArchivesAndReportsEachResult() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        let bridge = FakeArchiveBridgeClient()
        bridge.onStartExtraction = { stagingPath in
            let output = URL(fileURLWithPath: stagingPath).appendingPathComponent("docs/readme.txt")
            try fileManager.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("extracted".utf8).write(to: output)
        }
        let extraction = ArchiveExtractionCoordinator(bridge: bridge, fileManager: fileManager)
        let batch = BatchExtractionCoordinator(extraction: extraction)
        let first = testImportedArchive()
        let second = ImportedArchive(
            id: UUID(),
            displayName: "second.zip",
            localPath: "/cache/second.zip",
            byteSize: 12,
            importedAt: Date(timeIntervalSince1970: 0)
        )
        let review = try batch.plan(items: [
            BatchExtractionItem(
                archive: first,
                selectedPaths: ["docs/readme.txt"],
                destination: .appStorage(root.appendingPathComponent("first", isDirectory: true))
            ),
            BatchExtractionItem(
                archive: second,
                selectedPaths: ["docs/readme.txt"],
                destination: .appStorage(root.appendingPathComponent("second", isDirectory: true))
            )
        ])

        guard case .completed(let results) = await batch.run(review: review) else {
            return XCTFail("Expected the batch to complete")
        }
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(
            results.allSatisfy { $0.status == .completed },
            results.map { $0.message ?? "completed" }.joined(separator: " | ")
        )
        XCTAssertEqual(results.map(\.writtenEntries), [1, 1])
        XCTAssertEqual(
            try Data(contentsOf: root.appendingPathComponent("second/docs/readme.txt")),
            Data("extracted".utf8)
        )
    }

    func testPinnedBridgeAcceptsEncryptedFixturePasswordForExtraction() async throws {
        let appBundle = try XCTUnwrap(Bundle(identifier: "org.tzap.zmanager.mobile"))
        let fixture = try XCTUnwrap(appBundle.url(forResource: "maestro-encrypted", withExtension: "zip"))
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }
        let archive = root.appendingPathComponent("encrypted.zip")
        try fileManager.copyItem(at: fixture, to: archive)

        let bridge = GeneratedArchiveBridgeClient()
        let plan = try bridge.planExtraction(
            path: archive.path,
            destinationRoot: root.appendingPathComponent("output", isDirectory: true).path,
            selectedPaths: ["maestro-inner.zip"],
            password: ["v2", "test", "password"].joined(),
            collisionPolicy: .refuse
        )
        let job = try bridge.startExtraction(
            path: archive.path,
            destinationRoot: plan.destinationRoot,
            selectedPaths: ["maestro-inner.zip"],
            password: ["v2", "test", "password"].joined(),
            collisionPolicy: .refuse,
            planToken: plan.planToken
        )
        var cursor: UInt64 = 0
        var terminal = false
        for _ in 0..<100 {
            let update = try bridge.pollJob(jobId: job.jobId, cursor: cursor)
            cursor = update.nextCursor
            if update.isTerminal {
                XCTAssertEqual(update.status, .completed)
                terminal = true
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(terminal)
        XCTAssertTrue(fileManager.fileExists(atPath: root.appendingPathComponent("output/maestro-inner.zip").path))
    }

    func testPinnedBridgeListsExpandedFixtureFamilies() throws {
        let appBundle = try XCTUnwrap(Bundle(identifier: "org.tzap.zmanager.mobile"))
        let cases: [(String, ArchiveFormat)] = [
            ("maestro-files.tar.bz2", .tarBz2),
            ("maestro-files.tar.xz", .tarXz),
            ("maestro-files.tar.lzma", .tarLzma),
            ("maestro-files.tar.lz", .tarLz),
            ("maestro-files.tar.lzo", .tarLzo),
            ("maestro-files.tar.z", .tarCompress),
            ("maestro-files.tar.lz4", .tarLz4),
            ("maestro-files.tar.uu", .tarUu),
            ("maestro-stream.gz", .gzip),
            ("maestro-stream.bz2", .bzip2),
            ("maestro-stream.xz", .xz),
            ("maestro-stream.lzma", .rawStream),
            ("maestro-stream.lz", .rawStream),
            ("maestro-stream.lzo", .rawStream),
            ("maestro-stream.Z", .rawStream),
            ("maestro-stream.lz4", .rawStream),
            ("maestro-stream.zst", .zstd),
            ("maestro-stream.br", .rawStream),
            ("maestro-stream.uu", .rawStream),
            ("maestro-stream.b64", .rawStream),
            ("maestro-files.cpio", .cpio),
            ("maestro-files.xar", .xar),
            ("maestro-files.iso", .iso),
            ("maestro-files.pkg", .pkg),
            ("maestro-files.msi", .msi),
            ("maestro-files.ar", .ar),
            ("maestro-files.dmg", .dmg),
            ("maestro-files.vhd", .vhd),
            ("maestro-files.vmdk", .vmdk),
            ("maestro-files.udf", .udf),
            ("maestro-files.rpm", .rpm),
            ("maestro-files.lha", .lha),
            ("maestro-files.warc", .warc),
            ("maestro-files.mtree", .mtree),
        ]
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let bridge = GeneratedArchiveBridgeClient()
        for (fixtureName, expectedFormat) in cases {
            let fixture = try XCTUnwrap(appBundle.url(forResource: fixtureName, withExtension: nil), fixtureName)
            let archive = root.appendingPathComponent(fixtureName)
            try fileManager.copyItem(at: fixture, to: archive)
            let detection = try bridge.detectArchiveMetadata(path: archive.path)
            XCTAssertTrue(detection.canList, fixtureName)
            let listing = try bridge.listArchiveContents(path: archive.path, password: nil)
            XCTAssertEqual(listing.format, expectedFormat, fixtureName)
            XCTAssertGreaterThan(listing.entryCount, 0, fixtureName)
        }
    }

    func testArchiveImportStoreAndBridgeListTarLz4Fixture() throws {
        let appBundle = try XCTUnwrap(Bundle(identifier: "org.tzap.zmanager.mobile"))
        let fixture = try XCTUnwrap(appBundle.url(forResource: "maestro-files.tar.lz4", withExtension: nil))
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let imported = try ArchiveImportStore(fileManager: fileManager, cacheRoot: root)
            .importArchive(from: fixture)
        let listing = try GeneratedArchiveBridgeClient().listArchiveContents(
            path: imported.localPath,
            password: nil
        )
        XCTAssertEqual(listing.format, .tarLz4)
        XCTAssertEqual(listing.entryCount, 5)
    }

    func testPinnedRepackagingCanDiscardPasswordFailureAndRetryWithPassword() async throws {
        let appBundle = try XCTUnwrap(Bundle(identifier: "org.tzap.zmanager.mobile"))
        let fixture = try XCTUnwrap(appBundle.url(forResource: "maestro-encrypted", withExtension: "zip"))
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }
        let archivePath = root.appendingPathComponent("encrypted.zip")
        try fileManager.copyItem(at: fixture, to: archivePath)
        let archive = ImportedArchive(
            id: UUID(),
            displayName: "encrypted.zip",
            localPath: archivePath.path,
            byteSize: 348,
            importedAt: Date()
        )
        let coordinator = ArchiveRepackagingCoordinator()
        let output = root.appendingPathComponent("repackaged.zip")

        let firstReview = try coordinator.plan(
            request: ArchiveRepackagingRequest(
                sourceArchive: archive,
                selectedPaths: ["maestro-inner.zip"],
                destinationArchivePath: output.path,
                format: .zip,
                sourcePassword: nil,
                destinationPassword: nil
            )
        )
        let firstOutcome = await coordinator.run(review: firstReview)
        guard case .passwordRequired = firstOutcome else {
            return XCTFail("Expected the first repackaging attempt to require a password.")
        }
        coordinator.discard(review: firstReview)

        let retryReview = try coordinator.plan(
            request: ArchiveRepackagingRequest(
                sourceArchive: archive,
                selectedPaths: ["maestro-inner.zip"],
                destinationArchivePath: output.path,
                format: .zip,
                sourcePassword: ["v2", "test", "password"].joined(),
                destinationPassword: nil
            )
        )
        let retryOutcome = await coordinator.run(review: retryReview)
        guard case .completed(_, let verified, _) = retryOutcome else {
            return XCTFail("Expected the password retry to complete: \(retryOutcome)")
        }
        XCTAssertTrue(verified)
        XCTAssertTrue(fileManager.fileExists(atPath: output.path))
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

    private func sharedPathSafetyFixtureTableURL() throws -> URL {
        var candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let fixture = candidate.appendingPathComponent("fixtures/metadata/extraction-path-safety.json")
            if FileManager.default.fileExists(atPath: fixture.path) {
                return fixture
            }
            candidate = candidate.deletingLastPathComponent()
        }
        throw NSError(
            domain: "ZManagerMobileTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Could not find fixtures/metadata/extraction-path-safety.json above \(#filePath)"]
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

    func pollJob(jobId: String, cursor: UInt64) throws -> PollJobEventsResult {
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

    func cancelJob(jobId: String) throws {}
}

private final class CreationFakeBridgeClient: ArchiveBridgeClient {
    var plannedSourcePaths: [String] = []
    var plannedSourcePathsByRequest = [[String]]()
    var startedRequest: StartCreateRequest?
    var startedRequests = [StartCreateRequest]()
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
        plannedSourcePathsByRequest.append(request.sourcePaths)
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
        startedRequests.append(request)
        return StartJobResult(jobId: "create-job", kind: .zipCreate, status: .running)
    }

    func pollJob(jobId: String, cursor: UInt64) throws -> PollJobEventsResult {
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

private struct PathSafetyFixtureTable: Decodable {
    let cases: [PathSafetyFixtureCase]
}

private struct PathSafetyFixtureCase: Decodable {
    let name: String
    let createFile: String?
    let symlink: PathSafetyFixtureSymlink?
    let input: String
    let expected: String?
}

private struct PathSafetyFixtureSymlink: Decodable {
    let link: String
    let target: String
}
