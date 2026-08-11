package org.tzap.zmanager.mobile

import java.io.File
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.tzap.zmanager.mobile.bridge.generated.ArchiveFormat
import org.tzap.zmanager.mobile.bridge.generated.ArchiveEntryKind
import org.tzap.zmanager.mobile.bridge.generated.ExtractionCollisionPolicy
import org.tzap.zmanager.mobile.bridge.generated.ExtractionPlanEntry
import org.tzap.zmanager.mobile.bridge.generated.ExtractionPlanEntryStatus
import org.tzap.zmanager.mobile.bridge.generated.PlanCreateRequest
import org.tzap.zmanager.mobile.bridge.generated.PlanCreateResult
import org.tzap.zmanager.mobile.bridge.generated.PlanExtractResult
import org.tzap.zmanager.mobile.bridge.generated.PollJobEventsResult
import org.tzap.zmanager.mobile.bridge.generated.StartCreateRequest
import org.tzap.zmanager.mobile.bridge.generated.StartJobResult
import org.tzap.zmanager.mobile.bridge.generated.TestArchiveResult
import org.tzap.zmanager.mobile.bridge.generated.DetectArchiveResult
import org.tzap.zmanager.mobile.bridge.generated.ListArchiveResult
import org.tzap.zmanager.mobile.bridge.generated.MaterializePreviewResult
import org.tzap.zmanager.mobile.bridge.generated.MobileJobEvent
import org.tzap.zmanager.mobile.bridge.generated.MobileJobEventKind
import org.tzap.zmanager.mobile.bridge.generated.MobileJobKind
import org.tzap.zmanager.mobile.bridge.generated.MobileJobStatus
import org.tzap.zmanager.mobile.bridge.generated.JobTerminalSummary

@RunWith(RobolectricTestRunner::class)
class ArchiveRepackagingTest {
    @Test
    fun extractionOutputIsFedIntoRustCreatePlanAndCleanedAfterCompletion() = runBlocking {
        val gateway = RepackagingGateway()
        val context = RuntimeEnvironment.getApplication()
        val extraction = ArchiveExtractionCoordinator(context, gateway)
        val creation = ArchiveCreationCoordinator(context, gateway)
        val coordinator = ArchiveRepackagingCoordinator(context, extraction, creation)
        val review = coordinator.plan(
            ArchiveRepackagingRequest(
                sourceArchive = ImportedArchive("archive", "outer.zip", "/cache/outer.zip", 10L, null, 0L),
                selectedPaths = listOf("docs"),
                destinationArchivePath = File(context.filesDir, "repacked.zip").absolutePath,
                format = org.tzap.zmanager.mobile.bridge.generated.CreateArchiveFormat.ZIP
            )
        )

        val outcome = coordinator.run(review) {}

        assertEquals(
            ArchiveRepackagingOutcome.Completed(File(context.filesDir, "repacked.zip").absolutePath, true),
            outcome
        )
        assertTrue(gateway.plannedCreateSource.endsWith("/input"))
        assertTrue(gateway.createSawExtractedFile)
        assertTrue(!File(gateway.plannedCreateSource).exists())
    }

    private class RepackagingGateway : ArchiveBridgeGateway {
        var plannedCreateSource = ""
        var createSawExtractedFile = false

        override fun detectArchive(path: String) = DetectArchiveResult(path, ArchiveFormat.ZIP, "ZIP", true, true, true, true, false, emptyList())
        override fun listArchive(path: String, password: String?) = ListArchiveResult(path, ArchiveFormat.ZIP, "ZIP", emptyList(), 0UL, null, emptyList())
        override fun materializePreview(archivePath: String, entryPath: String, password: String?) = MaterializePreviewResult(archivePath, entryPath, "", "", 0UL, emptyList())
        override fun testArchive(archivePath: String, selectedPaths: List<String>, password: String?) = TestArchiveResult(archivePath, ArchiveFormat.ZIP, "ZIP", true, 0UL, 0UL, 0UL, 0UL, emptyList())

        override fun planExtract(archivePath: String, destinationRoot: String, selectedPaths: List<String>, password: String?, collisionPolicy: ExtractionCollisionPolicy) = PlanExtractResult(
            archivePath, destinationRoot, ArchiveFormat.ZIP, "ZIP",
            listOf(ExtractionPlanEntry("docs/readme.txt", "docs/readme.txt", "docs/readme.txt", ArchiveEntryKind.FILE, ExtractionPlanEntryStatus.WRITE, null, 9UL, null, false)),
            1UL, 1UL, 0UL, 0UL, 9UL, true, emptyList(), "extract-token"
        )

        override fun startExtract(archivePath: String, destinationRoot: String, selectedPaths: List<String>, password: String?, collisionPolicy: ExtractionCollisionPolicy, planToken: String): StartJobResult {
            val file = File(destinationRoot, "docs/readme.txt")
            file.parentFile!!.mkdirs()
            file.writeText("extracted")
            return StartJobResult("extract-job", MobileJobKind.ZIP_EXTRACT, MobileJobStatus.RUNNING)
        }

        override fun planCreate(request: PlanCreateRequest): PlanCreateResult {
            plannedCreateSource = request.sourcePaths.single()
            return PlanCreateResult(request.sourcePaths, request.destinationArchivePath, request.format, "ZIP", emptyList(), 1UL, 9UL, 0UL, 0UL, false, false, false, true, false, request.verifyAfterCreate, true, true, emptyList())
        }

        override fun startCreate(request: StartCreateRequest): StartJobResult {
            createSawExtractedFile = File(request.sourcePaths.single(), "docs/readme.txt").isFile
            return StartJobResult("create-job", MobileJobKind.ZIP_CREATE, MobileJobStatus.RUNNING)
        }

        override fun pollJob(jobId: String, cursor: ULong) = PollJobEventsResult(
            jobId,
            if (jobId == "extract-job") MobileJobKind.ZIP_EXTRACT else MobileJobKind.ZIP_CREATE,
            MobileJobStatus.COMPLETED,
            listOf(MobileJobEvent(1UL, MobileJobEventKind.COMPLETED, if (jobId == "extract-job") MobileJobKind.ZIP_EXTRACT else MobileJobKind.ZIP_CREATE, null, 9UL, 9UL, 9UL, 1UL, 1UL, "Complete", null)),
            1UL, 1UL, true,
            if (jobId == "create-job") JobTerminalSummary(1UL, 0UL, 9UL, false, null, 1UL, listOf("repacked.zip"), true, 1UL, 9UL, emptyList()) else null
        )
    }
}
