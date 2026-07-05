import XCTest
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
    }

    func testArchiveListingLoaderMapsPasswordRequired() {
        let loader = ArchiveListingLoader(
            bridge: FakeArchiveBridgeClient(
                listError: ZmanagerMobileError.Bridge(
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

    private func testImportedArchive() -> ImportedArchive {
        ImportedArchive(
            id: UUID(),
            displayName: "archive.zip",
            localPath: "/cache/archive.zip",
            byteSize: 12,
            importedAt: Date(timeIntervalSince1970: 0)
        )
    }
}

private struct FakeArchiveBridgeClient: ArchiveBridgeClient {
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
    var detectError: Error?
    var listError: Error?

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
}
