package org.tzap.zmanager.mobile

import android.content.Context
import android.net.Uri
import android.provider.DocumentsContract
import androidx.documentfile.provider.DocumentFile
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.io.File
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import java.util.UUID
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.tzap.zmanager.mobile.bridge.generated.ArchiveEntryKind
import org.tzap.zmanager.mobile.bridge.generated.ArchiveFormat
import org.tzap.zmanager.mobile.bridge.generated.ExtractionCollisionPolicy
import org.tzap.zmanager.mobile.bridge.generated.ExtractionPlanEntry
import org.tzap.zmanager.mobile.bridge.generated.ExtractionPlanEntryStatus
import org.tzap.zmanager.mobile.bridge.generated.ListArchiveResult
import org.tzap.zmanager.mobile.bridge.generated.MaterializePreviewResult
import org.tzap.zmanager.mobile.bridge.generated.DetectArchiveResult
import org.tzap.zmanager.mobile.bridge.generated.MobileJobEvent
import org.tzap.zmanager.mobile.bridge.generated.MobileJobEventKind
import org.tzap.zmanager.mobile.bridge.generated.MobileJobKind
import org.tzap.zmanager.mobile.bridge.generated.MobileJobStatus
import org.tzap.zmanager.mobile.bridge.generated.PlanExtractResult
import org.tzap.zmanager.mobile.bridge.generated.PollJobEventsResult
import org.tzap.zmanager.mobile.bridge.generated.StartJobResult
import org.tzap.zmanager.mobile.bridge.generated.TestArchiveResult

@RunWith(AndroidJUnit4::class)
class ProviderBoundaryInstrumentedTest {
    private val context: Context = ApplicationProvider.getApplicationContext()
    private val resolver = context.contentResolver

    @Test
    fun archiveImporterReadsARealContentUriAndCleansItsCacheCopy() {
        val name = "provider-import-${UUID.randomUUID()}.zip"
        val source = createDocument(name, "provider archive".toByteArray())
        val imported = ArchiveImporter(context).importUri(source)

        assertEquals("provider archive", File(imported.localPath).readText())
        assertTrue(imported.localPath.startsWith(context.cacheDir.path))
        File(imported.localPath).parentFile?.deleteRecursively()
        DocumentsContract.deleteDocument(resolver, source)
    }

    @Test
    fun pinnedNativeBridgeListsAndVerifiesARealArchive() {
        val archive = File.createTempFile("bridge-health-", ".zip", context.cacheDir)
        ZipOutputStream(archive.outputStream()).use { zip ->
            zip.putNextEntry(ZipEntry("hello.txt"))
            zip.write("hello from the native bridge".toByteArray())
            zip.closeEntry()
        }

        try {
            val bridge = GeneratedArchiveBridgeGateway()
            val listing = bridge.listArchive(archive.absolutePath, null)
            assertEquals(1UL, listing.entryCount)
            val verification = bridge.testArchive(archive.absolutePath, emptyList(), null)
            assertEquals(true, verification.verified)
        } finally {
            archive.delete()
        }
    }

    @Test
    fun sequentialNativeCreationJobsRemainVerified() = runBlocking {
        val root = File(context.cacheDir, "sequential-create-${UUID.randomUUID()}")
        check(root.mkdirs())
        val sourcePaths = listOf("one", "two").map { name ->
            File(root, "$name.txt").also { it.writeText("$name archive") }
        }
        val coordinator = ArchiveCreationCoordinator(context)

        try {
            sourcePaths.forEach { source ->
                val destination = File(root, "${source.nameWithoutExtension}.zip")
                val review = coordinator.plan(
                    ArchiveCreationRequest(
                        sourcePaths = listOf(source.absolutePath),
                        destinationArchivePath = destination.absolutePath,
                        format = org.tzap.zmanager.mobile.bridge.generated.CreateArchiveFormat.ZIP
                    )
                )
                val outcome = coordinator.awaitCompletion(review, coordinator.start(review)) {}
                assertTrue("${source.name} should be verified; outcome=$outcome", outcome is ArchiveCreationOutcome.Completed && outcome.verified)
            }
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun creationSourceStagerCopiesSingleAndTreeDocumentsThroughDocumentFile() {
        val single = createDocument(
            "provider-single-${UUID.randomUUID()}.txt",
            "single provider file".toByteArray()
        )
        val folder = DocumentsContract.createDocument(
            resolver,
            TestDocumentsProvider.documentUri(TestDocumentsProvider.ROOT_ID),
            DocumentsContract.Document.MIME_TYPE_DIR,
            "provider-folder-${UUID.randomUUID()}"
        )!!
        val child = DocumentsContract.createDocument(
            resolver,
            folder,
            "text/plain",
            "nested.txt"
        )!!
        resolver.openOutputStream(child, "wt")!!.use { it.write("nested provider file".toByteArray()) }
        val tree = DocumentsContract.buildTreeDocumentUri(
            TestDocumentsProvider.AUTHORITY,
            DocumentsContract.getDocumentId(folder)
        )

        val sourceTree = DocumentFile.fromTreeUri(
            context,
            tree
        )
        assertNotNull("provider folder must be visible as a tree", sourceTree)
        assertNotNull("provider child must be visible through DocumentFile", sourceTree!!.findFile("nested.txt"))

        val stager = ArchiveCreationSourceStager(context)
        val stagedFile = stager.stageFiles(listOf(single))
        val stagedTree = stager.stageTree(
            tree
        )

        try {
            assertEquals("single provider file", File(stagedFile.sourcePaths.single()).readText())
            val stagedFolder = File(stagedTree.sourcePaths.single())
            assertEquals("nested provider file", File(stagedFolder, "nested.txt").readText())
        } finally {
            stager.discard(stagedFile)
            stager.discard(stagedTree)
            DocumentsContract.deleteDocument(resolver, single)
            DocumentsContract.deleteDocument(resolver, folder)
        }
    }

    @Test
    fun extractionCommitsThroughARealDocumentTreeWithCollisionRename() = runBlocking {
        val destinationName = "provider-output-${UUID.randomUUID()}"
        val destination = DocumentsContract.createDocument(
            resolver,
            TestDocumentsProvider.documentUri(TestDocumentsProvider.ROOT_ID),
            DocumentsContract.Document.MIME_TYPE_DIR,
            destinationName
        )!!
        val destinationTree = DocumentsContract.buildTreeDocumentUri(
            TestDocumentsProvider.AUTHORITY,
            DocumentsContract.getDocumentId(destination)
        )
        val existing = DocumentsContract.createDocument(resolver, destination, "text/plain", "readme.txt")!!
        resolver.openOutputStream(existing, "wt")!!.use { it.write("existing".toByteArray()) }

        val coordinator = ArchiveExtractionCoordinator(context, ProviderExtractionGateway())
        val review = coordinator.plan(
            archive = ImportedArchive("provider-archive", "archive.zip", "/cache/archive.zip", 9L, "application/zip", 0L),
            selectedPaths = listOf("docs/readme.txt"),
            destination = ExtractionDestination.DocumentTree(destinationTree),
            password = null,
            collisionPolicy = ExtractionCollisionPolicy.RENAME
        )

        try {
            val outcome = coordinator.awaitCompletion(review, coordinator.start(review)) {}
            assertTrue(outcome is ExtractionOutcome.Completed)
            val outputRoot = DocumentFile.fromTreeUri(context, destinationTree)
            val docs = outputRoot?.findFile("docs")
            val extracted = docs?.findFile("readme.txt")
            assertNotNull(extracted)
            resolver.openInputStream(extracted!!.uri).use { input ->
                assertEquals("extracted", input!!.bufferedReader().readText())
            }
        } finally {
            coordinator.discard(review)
            DocumentsContract.deleteDocument(resolver, destination)
        }
    }

    private fun createDocument(name: String, contents: ByteArray): Uri {
        val uri = TestDocumentsProvider.documentUri("${TestDocumentsProvider.ROOT_ID}/$name")
        resolver.openOutputStream(uri, "wt")!!.use { it.write(contents) }
        return uri
    }

    private class ProviderExtractionGateway : ArchiveBridgeGateway {
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
            archivePath,
            destinationRoot,
            ArchiveFormat.ZIP,
            "ZIP",
            listOf(
                ExtractionPlanEntry(
                    "docs/readme.txt",
                    "docs/readme.txt",
                    "docs/readme.txt",
                    ArchiveEntryKind.FILE,
                    ExtractionPlanEntryStatus.WRITE,
                    null,
                    9UL,
                    null,
                    false
                )
            ),
            1UL,
            1UL,
            0UL,
            0UL,
            9UL,
            true,
            emptyList(),
            "provider-review-token"
        )

        override fun startExtract(
            archivePath: String,
            destinationRoot: String,
            selectedPaths: List<String>,
            password: String?,
            collisionPolicy: ExtractionCollisionPolicy,
            planToken: String
        ): StartJobResult {
            File(destinationRoot, "docs/readme.txt").apply {
                parentFile!!.mkdirs()
                writeText("extracted")
            }
            return StartJobResult("provider-job", MobileJobKind.ZIP_EXTRACT, MobileJobStatus.RUNNING)
        }

        override fun pollJob(jobId: String, cursor: ULong) = PollJobEventsResult(
            jobId,
            MobileJobKind.ZIP_EXTRACT,
            MobileJobStatus.COMPLETED,
            listOf(
                MobileJobEvent(
                    1UL,
                    MobileJobEventKind.COMPLETED,
                    MobileJobKind.ZIP_EXTRACT,
                    null,
                    null,
                    9UL,
                    9UL,
                    1UL,
                    1UL,
                    "Complete",
                    null
                )
            ),
            1UL,
            1UL,
            true,
            null
        )
    }
}
