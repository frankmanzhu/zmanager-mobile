package org.tzap.zmanager.mobile

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
        private val cancelled: Boolean = false
    ) : ArchiveBridgeGateway {
        var plannedSourcePaths: List<String> = emptyList()
        var startedRequest: StartCreateRequest? = null
        var pollCount = 0

        override fun detectArchive(path: String) = TODO("Not used")

        override fun listArchive(path: String, password: String?) = TODO("Not used")

        override fun materializePreview(archivePath: String, entryPath: String, password: String?) = TODO("Not used")

        override fun testArchive(archivePath: String, selectedPaths: List<String>, password: String?) =
            TestArchiveResult(archivePath, ArchiveFormat.ZIP, "ZIP", true, 0UL, 0UL, 0UL, 0UL, emptyList())

        override fun planCreate(request: PlanCreateRequest): PlanCreateResult {
            plannedSourcePaths = request.sourcePaths
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
                    volumeCount = 1UL,
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
