package org.tzap.zmanager.mobile

import java.io.File
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.tzap.zmanager.mobile.bridge.generated.ArchiveEntryKind
import org.tzap.zmanager.mobile.bridge.generated.ArchiveFormat
import org.tzap.zmanager.mobile.bridge.generated.DetectArchiveResult
import org.tzap.zmanager.mobile.bridge.generated.ExtractionCollisionPolicy
import org.tzap.zmanager.mobile.bridge.generated.ExtractionPlanEntry
import org.tzap.zmanager.mobile.bridge.generated.ExtractionPlanEntryStatus
import org.tzap.zmanager.mobile.bridge.generated.ListArchiveResult
import org.tzap.zmanager.mobile.bridge.generated.MaterializePreviewResult
import org.tzap.zmanager.mobile.bridge.generated.MobileJobEvent
import org.tzap.zmanager.mobile.bridge.generated.MobileJobEventKind
import org.tzap.zmanager.mobile.bridge.generated.MobileJobKind
import org.tzap.zmanager.mobile.bridge.generated.MobileJobStatus
import org.tzap.zmanager.mobile.bridge.generated.PlanExtractResult
import org.tzap.zmanager.mobile.bridge.generated.PollJobEventsResult
import org.tzap.zmanager.mobile.bridge.generated.StartJobResult
import org.tzap.zmanager.mobile.bridge.generated.TestArchiveResult

@RunWith(RobolectricTestRunner::class)
class ArchiveExtractionTest {
    @Test
    fun completedExtractionCommitsStagedFilesToAppStorage() = runBlocking {
        val context = RuntimeEnvironment.getApplication()
        val destinationRoot = File(context.cacheDir, "extraction-test-output")
        destinationRoot.deleteRecursively()
        val coordinator = ArchiveExtractionCoordinator(context, ExtractionGateway())
        val review = coordinator.plan(
            archive = ImportedArchive(
                id = "archive-id",
                displayName = "archive.zip",
                localPath = "/cache/archive.zip",
                byteSize = 9L,
                sourceMimeType = "application/zip",
                importedAtEpochMillis = 0L
            ),
            selectedPaths = listOf("docs/readme.txt"),
            destination = ExtractionDestination.AppStorage(destinationRoot),
            password = null
        )

        val jobId = coordinator.start(review)
        val outcome = coordinator.awaitCompletion(review, jobId) {}

        assertTrue(outcome is ExtractionOutcome.Completed)
        assertEquals("extracted", File(destinationRoot, "docs/readme.txt").readText())
        destinationRoot.deleteRecursively()
        Unit
    }

    private class ExtractionGateway : ArchiveBridgeGateway {
        override fun detectArchive(path: String) = DetectArchiveResult(
            path, ArchiveFormat.ZIP, "ZIP", true, true, true, true, false, emptyList()
        )

        override fun listArchive(path: String, password: String?) = ListArchiveResult(
            path, ArchiveFormat.ZIP, "ZIP", emptyList(), 0UL, null, emptyList()
        )

        override fun materializePreview(archivePath: String, entryPath: String, password: String?) =
            MaterializePreviewResult(archivePath, entryPath, "", "", 0UL, emptyList())

        override fun testArchive(archivePath: String, selectedPaths: List<String>, password: String?) =
            TestArchiveResult(archivePath, ArchiveFormat.ZIP, "ZIP", true, 0UL, 0UL, 0UL, 0UL, emptyList())

        override fun planExtract(
            archivePath: String,
            destinationRoot: String,
            selectedPaths: List<String>,
            password: String?,
            collisionPolicy: ExtractionCollisionPolicy
        ) = PlanExtractResult(
            archivePath, destinationRoot, ArchiveFormat.ZIP, "ZIP",
            listOf(
                ExtractionPlanEntry(
                    "docs/readme.txt", "docs/readme.txt", "docs/readme.txt", ArchiveEntryKind.FILE,
                    ExtractionPlanEntryStatus.WRITE, null, 9UL, null, false
                )
            ),
            1UL, 1UL, 0UL, 0UL, 9UL, true, emptyList(), "review-token"
        )

        override fun startExtract(
            archivePath: String,
            destinationRoot: String,
            selectedPaths: List<String>,
            password: String?,
            collisionPolicy: ExtractionCollisionPolicy,
            planToken: String
        ): StartJobResult {
            val output = File(destinationRoot, "docs/readme.txt")
            output.parentFile!!.mkdirs()
            output.writeText("extracted")
            return StartJobResult("job-id", MobileJobKind.ZIP_EXTRACT, MobileJobStatus.RUNNING)
        }

        override fun pollJob(jobId: String, cursor: ULong) = PollJobEventsResult(
            jobId, MobileJobKind.ZIP_EXTRACT, MobileJobStatus.COMPLETED,
            listOf(
                MobileJobEvent(
                    1UL, MobileJobEventKind.COMPLETED, MobileJobKind.ZIP_EXTRACT, null,
                    null, 9UL, 9UL, 1UL, 1UL, "Complete", null
                )
            ),
            1UL, 1UL, true, null
        )
    }
}
