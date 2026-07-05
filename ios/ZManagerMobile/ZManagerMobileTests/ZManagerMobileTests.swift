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
        XCTAssertEqual(summary.entries.first?.displayName, "readme.txt")
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
                previewError: ZmanagerMobileError.Bridge(
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
    var preview = MaterializePreviewResult(
        archivePath: "/cache/archive.zip",
        entryPath: "readme.txt",
        cleanupRoot: "/cache/previews/preview-id",
        previewPath: "/cache/previews/preview-id/readme.txt",
        writtenBytes: 0,
        warnings: []
    )
    var detectError: Error?
    var listError: Error?
    var previewError: Error?

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
}
