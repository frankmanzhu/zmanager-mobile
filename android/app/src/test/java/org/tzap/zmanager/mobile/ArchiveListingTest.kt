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
        private val detectError: Throwable? = null,
        private val listError: Throwable? = null
    ) : ArchiveBridgeGateway {
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
    }
}
