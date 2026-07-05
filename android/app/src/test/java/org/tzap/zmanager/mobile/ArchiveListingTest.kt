package org.tzap.zmanager.mobile

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.tzap.zmanager.mobile.bridge.generated.ArchiveEntry
import org.tzap.zmanager.mobile.bridge.generated.ArchiveEntryKind
import org.tzap.zmanager.mobile.bridge.generated.ArchiveFormat
import org.tzap.zmanager.mobile.bridge.generated.BridgeSeverity
import org.tzap.zmanager.mobile.bridge.generated.DetectArchiveResult
import org.tzap.zmanager.mobile.bridge.generated.ListArchiveResult
import org.tzap.zmanager.mobile.bridge.generated.MaterializePreviewResult
import org.tzap.zmanager.mobile.bridge.generated.TestArchiveResult
import org.tzap.zmanager.mobile.bridge.generated.ZmanagerMobileException

class ArchiveListingTest {
    @Test
    fun loadReturnsSummaryForBridgeListing() {
        val repository = ArchiveListingRepository(
            FakeArchiveBridgeGateway(
                listing = ListArchiveResult(
                    archivePath = "/cache/archive.zip",
                    format = ArchiveFormat.ZIP,
                    formatLabel = "ZIP",
                    entries = listOf(
                        ArchiveEntry(
                            path = "readme.txt",
                            kind = ArchiveEntryKind.FILE,
                            isDir = false,
                            size = 12UL,
                            compressedSize = null,
                            modifiedAt = null
                        )
                    ),
                    entryCount = 1UL,
                    totalSize = 12UL,
                    warnings = emptyList()
                )
            )
        )

        val state = repository.load(testImportedArchive(), password = null)

        assertTrue(state is ArchiveListingState.Ready)
        val summary = (state as ArchiveListingState.Ready).summary
        assertEquals("ZIP", summary.formatLabel)
        assertEquals(1UL, summary.entryCount)
        assertEquals("readme.txt", summary.entries.single().path)
        assertEquals("readme.txt", summary.entries.single().displayName)
    }

    @Test
    fun loadMapsPasswordErrorsToPasswordRequiredState() {
        val repository = ArchiveListingRepository(
            FakeArchiveBridgeGateway(
                listError = ZmanagerMobileException.Bridge(
                    code = "password_required",
                    userMessage = "This archive requires a password.",
                    recoveryHint = "Enter the archive password.",
                    severity = BridgeSeverity.WARNING,
                    retryable = true
                )
            )
        )

        val state = repository.load(testImportedArchive(), password = null)

        assertTrue(state is ArchiveListingState.PasswordRequired)
        val error = (state as ArchiveListingState.PasswordRequired).error
        assertEquals("password_required", error.code)
        assertTrue(error.retryable)
    }

    @Test
    fun loadReportsBridgeUnavailableWhenNativeLibraryCannotLoad() {
        val repository = ArchiveListingRepository(
            FakeArchiveBridgeGateway(
                detectError = UnsatisfiedLinkError("missing native library")
            )
        )

        val state = repository.load(testImportedArchive(), password = null)

        assertTrue(state is ArchiveListingState.Failed)
        val error = (state as ArchiveListingState.Failed).error
        assertEquals("bridge_unavailable", error.code)
        assertFalse(error.retryable)
    }

    @Test
    fun visibleGroupsSearchesSortsAndGroupsEntries() {
        val summary = ArchiveListingSummary(
            formatLabel = "ZIP",
            entryCount = 3UL,
            totalSize = null,
            entries = listOf(
                testEntry(id = "1", path = "docs/readme.txt", size = 12UL),
                testEntry(id = "2", path = "images/photo.jpg", size = 200UL),
                testEntry(id = "3", path = "docs/guide.txt", size = 40UL)
            ),
            warnings = emptyList()
        )

        val groups = summary.visibleGroups(
            searchQuery = "docs",
            sort = ArchiveEntrySort.SIZE_DESCENDING,
            viewMode = ArchiveEntryViewMode.FOLDERS
        )

        assertEquals(listOf("docs"), groups.map { it.label })
        assertEquals(listOf("docs/guide.txt", "docs/readme.txt"), groups.single().entries.map { it.path })
    }

    @Test
    fun previewableSelectedEntryRequiresExactlyOneSelectedFile() {
        val file = testEntry(id = "file", path = "readme.txt", kind = ArchiveEntryKind.FILE)
        val directory = testEntry(id = "dir", path = "docs", kind = ArchiveEntryKind.DIRECTORY)
        val summary = ArchiveListingSummary(
            formatLabel = "ZIP",
            entryCount = 2UL,
            totalSize = null,
            entries = listOf(file, directory),
            warnings = emptyList()
        )

        assertEquals(file, summary.previewableSelectedEntry(setOf(file.id)))
        assertEquals(null, summary.previewableSelectedEntry(setOf(directory.id)))
        assertEquals(null, summary.previewableSelectedEntry(setOf(file.id, directory.id)))
    }

    @Test
    fun materializePreviewReturnsReadyState() {
        val entry = testEntry(id = "file", path = "readme.txt")
        val repository = ArchiveListingRepository(
            FakeArchiveBridgeGateway(
                preview = MaterializePreviewResult(
                    archivePath = "/cache/archive.zip",
                    entryPath = "readme.txt",
                    cleanupRoot = "/cache/previews/preview-id",
                    previewPath = "/cache/previews/preview-id/readme.txt",
                    writtenBytes = 12UL,
                    warnings = emptyList()
                )
            )
        )

        val state = repository.materializePreview(testImportedArchive(), entry, password = null)

        assertTrue(state is ArchivePreviewState.Ready)
        val summary = (state as ArchivePreviewState.Ready).summary
        assertEquals(entry, summary.entry)
        assertEquals("/cache/previews/preview-id/readme.txt", summary.previewPath)
    }

    @Test
    fun materializePreviewMapsPasswordErrorsToPasswordRequiredState() {
        val entry = testEntry(id = "file", path = "readme.txt")
        val repository = ArchiveListingRepository(
            FakeArchiveBridgeGateway(
                previewError = ZmanagerMobileException.Bridge(
                    code = "password_required",
                    userMessage = "This archive requires a password.",
                    recoveryHint = "Enter the archive password.",
                    severity = BridgeSeverity.WARNING,
                    retryable = true
                )
            )
        )

        val state = repository.materializePreview(testImportedArchive(), entry, password = null)

        assertTrue(state is ArchivePreviewState.PasswordRequired)
        val error = (state as ArchivePreviewState.PasswordRequired).error
        assertEquals("password_required", error.code)
        assertTrue(error.retryable)
    }

    @Test
    fun testArchiveReturnsReadyStateAndPassesSelectedPaths() {
        val entry = testEntry(id = "file", path = "readme.txt")
        val gateway = FakeArchiveBridgeGateway(
            testResult = TestArchiveResult(
                archivePath = "/cache/archive.zip",
                format = ArchiveFormat.ZIP,
                formatLabel = "ZIP",
                verified = true,
                testedEntries = 1UL,
                skippedEntries = 0UL,
                totalEntries = 1UL,
                testedBytes = 12UL,
                warnings = emptyList()
            )
        )
        val repository = ArchiveListingRepository(gateway)

        val state = repository.testArchive(testImportedArchive(), listOf(entry), password = null)

        assertTrue(state is ArchiveTestState.Ready)
        val summary = (state as ArchiveTestState.Ready).summary
        assertTrue(summary.verified)
        assertEquals(1UL, summary.testedEntries)
        assertEquals(listOf("readme.txt"), gateway.testedSelectedPaths)
    }

    @Test
    fun testArchiveMapsPasswordErrorsToPasswordRequiredState() {
        val repository = ArchiveListingRepository(
            FakeArchiveBridgeGateway(
                testError = ZmanagerMobileException.Bridge(
                    code = "password_required",
                    userMessage = "This archive requires a password.",
                    recoveryHint = "Enter the archive password.",
                    severity = BridgeSeverity.WARNING,
                    retryable = true
                )
            )
        )

        val state = repository.testArchive(testImportedArchive(), selectedEntries = emptyList(), password = null)

        assertTrue(state is ArchiveTestState.PasswordRequired)
        val error = (state as ArchiveTestState.PasswordRequired).error
        assertEquals("password_required", error.code)
        assertTrue(error.retryable)
    }

    private fun testImportedArchive(): ImportedArchive {
        return ImportedArchive(
            id = "archive-id",
            displayName = "archive.zip",
            localPath = "/cache/archive.zip",
            byteSize = 12L,
            sourceMimeType = "application/zip",
            importedAtEpochMillis = 0
        )
    }

    private fun testEntry(
        id: String,
        path: String,
        kind: ArchiveEntryKind = ArchiveEntryKind.FILE,
        size: ULong? = 12UL
    ): ArchiveEntrySummary {
        val displayName = path.substringAfterLast('/')
        val parentPath = path.substringBeforeLast('/', missingDelimiterValue = "")
        return ArchiveEntrySummary(
            id = id,
            path = path,
            displayName = displayName,
            parentPath = parentPath,
            kind = kind,
            size = size
        )
    }

    private class FakeArchiveBridgeGateway(
        private val detection: DetectArchiveResult = DetectArchiveResult(
            archivePath = "/cache/archive.zip",
            format = ArchiveFormat.ZIP,
            formatLabel = "ZIP",
            exists = true,
            isFile = true,
            canList = true,
            canExtract = true,
            canCreate = false,
            warnings = emptyList()
        ),
        private val listing: ListArchiveResult? = null,
        private val preview: MaterializePreviewResult? = null,
        private val testResult: TestArchiveResult? = null,
        private val detectError: Throwable? = null,
        private val listError: Throwable? = null,
        private val previewError: Throwable? = null,
        private val testError: Throwable? = null
    ) : ArchiveBridgeGateway {
        var testedSelectedPaths: List<String> = emptyList()
            private set

        override fun detectArchive(path: String): DetectArchiveResult {
            detectError?.let { throw it }
            return detection
        }

        override fun listArchive(path: String, password: String?): ListArchiveResult {
            listError?.let { throw it }
            return listing ?: ListArchiveResult(
                archivePath = path,
                format = ArchiveFormat.ZIP,
                formatLabel = "ZIP",
                entries = emptyList(),
                entryCount = 0UL,
                totalSize = null,
                warnings = emptyList()
            )
        }

        override fun materializePreview(
            archivePath: String,
            entryPath: String,
            password: String?
        ): MaterializePreviewResult {
            previewError?.let { throw it }
            return preview ?: MaterializePreviewResult(
                archivePath = archivePath,
                entryPath = entryPath,
                cleanupRoot = "/cache/previews/preview-id",
                previewPath = "/cache/previews/preview-id/$entryPath",
                writtenBytes = 0UL,
                warnings = emptyList()
            )
        }

        override fun testArchive(
            archivePath: String,
            selectedPaths: List<String>,
            password: String?
        ): TestArchiveResult {
            testError?.let { throw it }
            testedSelectedPaths = selectedPaths
            return testResult ?: TestArchiveResult(
                archivePath = archivePath,
                format = ArchiveFormat.ZIP,
                formatLabel = "ZIP",
                verified = true,
                testedEntries = 0UL,
                skippedEntries = 0UL,
                totalEntries = 0UL,
                testedBytes = 0UL,
                warnings = emptyList()
            )
        }
    }
}
