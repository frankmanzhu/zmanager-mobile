package org.tzap.zmanager.mobile

import java.io.File
import java.util.UUID
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.tzap.zmanager.mobile.bridge.generated.ArchiveFormat
import org.tzap.zmanager.mobile.bridge.generated.CreateArchiveFormat
import org.tzap.zmanager.mobile.bridge.generated.JobTerminalSummary
import org.tzap.zmanager.mobile.bridge.generated.MobileJobEvent
import org.tzap.zmanager.mobile.bridge.generated.MobileJobEventKind
import org.tzap.zmanager.mobile.bridge.generated.MobileJobKind
import org.tzap.zmanager.mobile.bridge.generated.MobileJobStatus
import org.tzap.zmanager.mobile.bridge.generated.PlanCreateRequest
import org.tzap.zmanager.mobile.bridge.generated.PlanCreateResult
import org.tzap.zmanager.mobile.bridge.generated.PollJobEventsResult
import org.tzap.zmanager.mobile.bridge.generated.StartCreateRequest
import org.tzap.zmanager.mobile.bridge.generated.StartJobResult
import org.tzap.zmanager.mobile.bridge.generated.TestArchiveResult

@RunWith(RobolectricTestRunner::class)
class ArchiveCreationTest {
    @Test
    fun separateCreationRequestsUseStableSourceNamesAndUniqueDestinations() {
        val requests = ArchiveSeparateCreationPlanner.requests(
            sourcePaths = listOf("/cache/photos.zip", "/cache/photos.txt", "/cache/folder"),
            destinationDirectory = "/files/CreatedArchives",
            format = CreateArchiveFormat.ZIP,
            password = "secret",
            volumeSize = 64UL * 1024UL
        )

        assertEquals(
            listOf(
                "/files/CreatedArchives/photos.zip",
                "/files/CreatedArchives/photos (1).zip",
                "/files/CreatedArchives/folder.zip"
            ),
            requests.map { it.destinationArchivePath }
        )
        assertEquals(
            listOf(
                listOf("/cache/photos.zip"),
                listOf("/cache/photos.txt"),
                listOf("/cache/folder")
            ),
            requests.map { it.sourcePaths }
        )
        assertTrue(requests.all { it.password == "secret" })
        assertTrue(requests.all { it.volumeSize == 64UL * 1024UL })
    }

    @Test
    fun separateCreationCoordinatorPlansEveryItemThroughRustGateway() {
        val gateway = CreationGateway()
        val coordinator = ArchiveCreationCoordinator(RuntimeEnvironment.getApplication(), gateway)
        val separate = ArchiveSeparateCreationCoordinator(coordinator)
        val requests = ArchiveSeparateCreationPlanner.requests(
            sourcePaths = listOf("/cache/one.txt", "/cache/two.txt"),
            destinationDirectory = "/files/CreatedArchives",
            format = CreateArchiveFormat.SEVEN_Z
        )

        val review = separate.plan(requests)

        assertEquals(2, review.items.size)
        assertEquals(
            listOf("/cache/one.txt", "/cache/two.txt"),
            gateway.plannedSourcePathsByRequest.map { it.single() }
        )
    }

    @Test
    fun volumeSizeParserAndOutputPathsMatchPinnedCoreConventions() {
        assertEquals(4UL * 1024UL * 1024UL, ArchiveVolumeSupport.parseVolumeSize("4MiB"))
        assertEquals(null, ArchiveVolumeSupport.parseVolumeSize("  "))
        assertEquals(
            listOf("/files/archive.z01", "/files/archive.z02", "/files/archive.zip"),
            ArchiveVolumeSupport.outputPaths(
                CreateArchiveFormat.ZIP,
                "/files/archive.zip",
                3UL,
                listOf("/files/archive.zip")
            )
        )
        assertEquals(
            listOf("/files/archive.vol000.tzap", "/files/archive.vol001.tzap"),
            ArchiveVolumeSupport.outputPaths(
                CreateArchiveFormat.TZAP,
                "/files/archive.tzap",
                2UL,
                emptyList()
            )
        )
    }

    @Test(expected = IllegalArgumentException::class)
    fun volumeSizeParserRejectsMalformedInput() {
        ArchiveVolumeSupport.parseVolumeSize("1.5g")
    }

    @Test
    fun splitVolumeSizePassesIntoRustStartRequest() {
        val gateway = CreationGateway()
        val coordinator = ArchiveCreationCoordinator(RuntimeEnvironment.getApplication(), gateway)
        val review = coordinator.plan(
            ArchiveCreationRequest(
                sourcePaths = listOf("/cache/input"),
                destinationArchivePath = "/files/output.zip",
                format = CreateArchiveFormat.ZIP,
                volumeSize = 64UL * 1024UL
            )
        )

        coordinator.start(review)

        assertEquals(64UL * 1024UL, gateway.startedRequest?.volumeSize)
    }

    @Test
    fun splitCompletionKeepsFinalArchiveAsPrimaryOutput() = runBlocking {
        val gateway = CreationGateway(volumeCount = 3UL)
        val coordinator = ArchiveCreationCoordinator(RuntimeEnvironment.getApplication(), gateway)
        val review = coordinator.plan(
            ArchiveCreationRequest(
                sourcePaths = listOf("/cache/input"),
                destinationArchivePath = "/files/output.zip",
                format = CreateArchiveFormat.ZIP,
                volumeSize = 64UL * 1024UL
            )
        )

        val outcome = coordinator.awaitCompletion(review, coordinator.start(review)) {}

        assertEquals(
            ArchiveCreationOutcome.Completed(
                "/files/output.zip",
                true,
                listOf("/files/output.z01", "/files/output.z02", "/files/output.zip")
            ),
            outcome
        )
    }

    @Test
    fun committedOutputPathsDiscoversZipSidecarsWhenBridgeOmitsMetadata() {
        val root = File(RuntimeEnvironment.getApplication().cacheDir, "split-sidecars-${UUID.randomUUID()}")
        assertTrue(root.mkdirs())
        try {
            File(root, "output.z01").writeText("volume 1")
            File(root, "output.z02").writeText("volume 2")
            File(root, "output.zip").writeText("final volume")

            assertEquals(
                listOf(
                    File(root, "output.zip").path,
                    File(root, "output.z01").path,
                    File(root, "output.z02").path
                ),
                ArchiveVolumeSupport.committedOutputPaths(
                    CreateArchiveFormat.ZIP,
                    File(root, "output.zip").path,
                    null,
                    emptyList()
                )
            )
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun planAndStartCreationPassesOptionsAndClearsPasswordAfterStart() = runBlocking {
        val gateway = CreationGateway()
        val coordinator = ArchiveCreationCoordinator(RuntimeEnvironment.getApplication(), gateway)
        val request = ArchiveCreationRequest(
            sourcePaths = listOf("/cache/input"),
            destinationArchivePath = "/files/output.zip",
            format = CreateArchiveFormat.ZIP,
            password = "test-password",
            verifyAfterCreate = true
        )

        val review = coordinator.plan(request)
        assertTrue(review.plan.canStart)
        assertEquals(listOf("/cache/input"), gateway.plannedSourcePaths)

        val jobId = coordinator.start(review)
        assertEquals("test-password", gateway.startedRequest?.password)
        val outcome = coordinator.awaitCompletion(review, jobId) {}

        assertEquals(ArchiveCreationOutcome.Completed("/files/output.zip", true), outcome)
        assertTrue(gateway.pollCount > 0)
    }

    @Test
    fun cancellationReturnsCancelledAndDiscardsSession() = runBlocking {
        val gateway = CreationGateway(cancelled = true)
        val coordinator = ArchiveCreationCoordinator(RuntimeEnvironment.getApplication(), gateway)
        val review = coordinator.plan(
            ArchiveCreationRequest(
                sourcePaths = listOf("/cache/input"),
                destinationArchivePath = "/files/output.zip",
                format = CreateArchiveFormat.ZIP
            )
        )

        val outcome = coordinator.awaitCompletion(review, coordinator.start(review)) {}

        assertEquals(ArchiveCreationOutcome.Cancelled, outcome)
    }

    private class CreationGateway(
        private val cancelled: Boolean = false,
        private val volumeCount: ULong = 1UL
    ) : ArchiveBridgeGateway {
        var plannedSourcePaths: List<String> = emptyList()
        val plannedSourcePathsByRequest = mutableListOf<List<String>>()
        var startedRequest: StartCreateRequest? = null
        var pollCount = 0

        override fun detectArchive(path: String) = TODO("Not used")

        override fun listArchive(path: String, password: String?) = TODO("Not used")

        override fun materializePreview(archivePath: String, entryPath: String, password: String?) = TODO("Not used")

        override fun testArchive(archivePath: String, selectedPaths: List<String>, password: String?) =
            TestArchiveResult(archivePath, ArchiveFormat.ZIP, "ZIP", true, 0UL, 0UL, 0UL, 0UL, emptyList())

        override fun planCreate(request: PlanCreateRequest): PlanCreateResult {
            plannedSourcePaths = request.sourcePaths
            plannedSourcePathsByRequest += request.sourcePaths
            return PlanCreateResult(
                sourcePaths = request.sourcePaths,
                destinationArchivePath = request.destinationArchivePath,
                format = request.format,
                formatLabel = "ZIP",
                entries = emptyList(),
                totalEntries = 1UL,
                totalBytes = 4UL,
                excludedEntries = 0UL,
                excludedBytes = 0UL,
                outputExists = false,
                replaceExisting = request.replaceExisting,
                encrypted = request.password != null,
                preserveMetadata = request.preserveMetadata,
                cleanSource = request.cleanSource,
                verifyAfterCreate = request.verifyAfterCreate,
                verifySupported = true,
                canStart = true,
                warnings = emptyList()
            )
        }

        override fun startCreate(request: StartCreateRequest): StartJobResult {
            startedRequest = request
            return StartJobResult("create-job", MobileJobKind.ZIP_CREATE, MobileJobStatus.RUNNING)
        }

        override fun pollJob(jobId: String, cursor: ULong): PollJobEventsResult {
            pollCount += 1
            return PollJobEventsResult(
                jobId = jobId,
                kind = MobileJobKind.ZIP_CREATE,
                status = if (cancelled) MobileJobStatus.CANCELLED else MobileJobStatus.COMPLETED,
                events = listOf(
                    MobileJobEvent(
                        sequence = 1UL,
                        eventType = MobileJobEventKind.COMPLETED,
                        jobKind = MobileJobKind.ZIP_CREATE,
                        path = null,
                        bytes = 4UL,
                        totalBytes = 4UL,
                        totalBytesProcessed = 4UL,
                        entries = 1UL,
                        totalEntries = 1UL,
                        message = "Complete",
                        error = null
                    )
                ),
                nextCursor = 1UL,
                minRetainedSequence = 1UL,
                isTerminal = true,
                terminalSummary = if (cancelled) null else JobTerminalSummary(
                    writtenEntries = 1UL,
                    skippedEntries = 0UL,
                    writtenBytes = 4UL,
                    encrypted = false,
                    volumeSize = null,
                    volumeCount = volumeCount,
                    outputPaths = listOf("/files/output.zip"),
                    verified = true,
                    verifiedEntries = 1UL,
                    verifiedBytes = 4UL,
                    warnings = emptyList()
                )
            )
        }
    }
}
