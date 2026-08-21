package org.tzap.zmanager.mobile

import org.json.JSONObject
import android.net.Uri
import java.io.File
import java.nio.file.Files
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
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
    fun stagedRelativePathsRejectTraversalAndAcceptOnlyDescendants() {
        val root = java.io.File("/tmp/zmanager-staging-root")
        assertEquals("docs/readme.txt", ExtractionPathSafety.relativePath(
            java.io.File(root, "docs/readme.txt"),
            root
        ))
        assertThrows(IllegalArgumentException::class.java) {
            ExtractionPathSafety.relativePath(java.io.File(root, "../outside.txt"), root)
        }
        assertThrows(IllegalArgumentException::class.java) {
            ExtractionPathSafety.relativePath(java.io.File("/tmp/outside.txt"), root)
        }
    }

    @Test
    fun stagedRelativePathsPreserveSymlinkLeafName() {
        val root = Files.createTempDirectory("zmanager-staging-root").toFile()
        try {
            val payload = File(root, "payload").apply { mkdirs() }
            File(payload, "README.txt").writeText("readme")
            Files.createSymbolicLink(File(payload, "readme-link.txt").toPath(), java.nio.file.Path.of("README.txt"))

            assertEquals(
                "payload/readme-link.txt",
                ExtractionPathSafety.relativePath(File(payload, "readme-link.txt"), root)
            )
        } finally {
            root.deleteRecursively()
        }
    }
    @Test
    fun failedCommitRecoveryIsRedactedAndDiscardable() {
        val context = RuntimeEnvironment.getApplication()
        val root = File(context.cacheDir, "recovery-test-${System.nanoTime()}")
        root.mkdirs()
        File(root, "docs/readme.txt").apply {
            parentFile!!.mkdirs()
            writeText("retained")
        }
        val store = ArchiveRecoveryStore(context)
        val record = store.save(
            archive = ImportedArchive("archive", "archive.zip", "/cache/archive.zip", 1L, "application/zip", 0L),
            selectedPaths = listOf("docs/readme.txt"),
            stagingRoot = root,
            destinationLabel = "Selected folder",
            message = "Provider failed"
        )

        assertEquals(1, store.files(record.id).size)
        val json = File(context.filesDir, "ArchiveRecovery/${record.id}.json").readText()
        assertTrue(json.contains("never included"))
        val fields = JSONObject(json)
        assertTrue(!fields.has("password"))
        assertTrue(!fields.has("token"))

        store.discard(record.id)
        assertTrue(!root.exists())
    }

    @Test
    fun defaultExtractionDestinationFallsBackToPrivateAppStorage() {
        val context = RuntimeEnvironment.getApplication()
        val preferences = ArchiveDestinationPreferences(context)
        preferences.resetExtractionDestination()

        val destination = preferences.defaultExtractionDestination()

        assertEquals("App storage", destination.label)
        assertTrue((destination as ExtractionDestination.AppStorage).root().path.startsWith(context.filesDir.path))
    }

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

    @Test
    fun failedDocumentTreeCommitRetainsRecoveryRecord() = runBlocking {
        val context = RuntimeEnvironment.getApplication()
        val coordinator = ArchiveExtractionCoordinator(context, ExtractionGateway())
        val review = coordinator.plan(
            archive = ImportedArchive("recovery-archive", "archive.zip", "/cache/archive.zip", 9L, "application/zip", 0L),
            selectedPaths = listOf("docs/readme.txt"),
            destination = ExtractionDestination.DocumentTree(Uri.parse("content://missing.provider/tree/output")),
            password = null
        )

        val outcome = coordinator.awaitCompletion(review, coordinator.start(review)) {}

        assertTrue(outcome is ExtractionOutcome.RecoveryAvailable)
        val recoveryId = (outcome as ExtractionOutcome.RecoveryAvailable).recoveryId
        assertEquals(1, coordinator.recoveryFiles(recoveryId).size)
        coordinator.discardRecovery(recoveryId)
        Unit
    }

    @Test
    fun batchExtractionRunsEachArchiveAndCleansReviews() = runBlocking {
        val context = RuntimeEnvironment.getApplication()
        val root = File(context.cacheDir, "batch-extraction-test-output")
        root.deleteRecursively()
        val extraction = ArchiveExtractionCoordinator(context, ExtractionGateway())
        val batch = BatchExtractionCoordinator(extraction)
        val first = ImportedArchive("first", "first.zip", "/cache/first.zip", 9L, "application/zip", 0L)
        val second = ImportedArchive("second", "second.zip", "/cache/second.zip", 9L, "application/zip", 0L)
        val review = batch.plan(
            listOf(
                BatchExtractionItem(first, listOf("docs/readme.txt"), ExtractionDestination.AppStorage(File(root, "first"))),
                BatchExtractionItem(second, listOf("docs/readme.txt"), ExtractionDestination.AppStorage(File(root, "second")))
            )
        )

        val outcome = batch.run(review)

        assertTrue(outcome is BatchExtractionOutcome.Completed)
        val results = (outcome as BatchExtractionOutcome.Completed).results
        assertEquals(2, results.size)
        assertTrue(results.all { it.status == BatchExtractionItemResult.Status.COMPLETED })
        assertEquals("extracted", File(root, "second/docs/readme.txt").readText())
        batch.discard(review)
        root.deleteRecursively()
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
