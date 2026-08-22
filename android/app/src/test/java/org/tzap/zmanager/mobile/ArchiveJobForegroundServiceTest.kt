package org.tzap.zmanager.mobile

import android.content.Intent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.json.JSONObject
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.tzap.zmanager.mobile.bridge.generated.ExtractionCollisionPolicy

@RunWith(RobolectricTestRunner::class)
class ArchiveJobForegroundServiceTest {

    private fun sampleExtractRequest() = ArchiveForegroundRequest.Extract(
        ArchiveExtractionRequest(
            archive = ImportedArchive("archive", "archive.zip", "/cache/archive.zip", 1L, "application/zip", 0L),
            selectedPaths = emptyList(),
            destination = ExtractionDestination.AppStorage(java.io.File("/cache/out")),
            password = "super-secret",
            collisionPolicy = ExtractionCollisionPolicy.REFUSE
        )
    )

    @Test
    fun submitRemovesPendingRequestWhenServiceFailsToStart() {
        val context = RuntimeEnvironment.getApplication()
        var capturedToken: String? = null

        val error = assertThrows(IllegalStateException::class.java) {
            ArchiveJobForegroundService.submit(context, sampleExtractRequest()) { _, intent ->
                capturedToken = intent.getStringExtra("requestToken")
                throw IllegalStateException("Foreground service starts not allowed.")
            }
        }

        assertEquals("Foreground service starts not allowed.", error.message)
        assertNotNull("submit should have attempted to start the service", capturedToken)
        assertNull(
            "a request whose service failed to start must not remain retrievable",
            ArchiveJobForegroundService.takeRequest(capturedToken!!)
        )
    }

    @Test
    fun sweepStalePendingRequestsRemovesAnEntryWhoseServiceNeverStarted() {
        val context = RuntimeEnvironment.getApplication()
        // startService returns normally without ever calling takeRequest,
        // simulating onStartCommand silently never running (the process was
        // killed between the call and the callback, or the platform dropped
        // it) rather than the synchronous-throw case submitRemovesPendingRequestWhenServiceFailsToStart
        // already covers.
        val token = ArchiveJobForegroundService.submit(context, sampleExtractRequest()) { _, _ -> }

        org.robolectric.shadows.ShadowSystemClock.advanceBy(java.time.Duration.ofSeconds(31))
        ArchiveJobForegroundService.sweepStalePendingRequests()

        assertNull(
            "a request whose service never started must not remain retrievable once stale",
            ArchiveJobForegroundService.takeRequest(token)
        )
    }

    @Test
    fun submitReturnsRetrievableTokenWhenServiceStarts() {
        val context = RuntimeEnvironment.getApplication()
        val request = sampleExtractRequest()

        val token = ArchiveJobForegroundService.submit(context, request) { _, _ -> }

        assertEquals(request, ArchiveJobForegroundService.takeRequest(token))
        assertNull(
            "takeRequest must remove the entry so it cannot be retrieved twice",
            ArchiveJobForegroundService.takeRequest(token)
        )
    }
    @Test
    fun savedOperationReportContainsNoCredentialFields() {
        val context = RuntimeEnvironment.getApplication()
        val report = ArchiveOperationReportStore.save(
            context,
            ArchiveOperationReport(
                operation = "extract",
                subject = "archive.zip",
                status = "completed",
                message = "Extraction complete",
                destination = "App storage",
                entries = 3UL,
                verified = true
            )
        )

        val json = JSONObject(report.readText())
        assertEquals("extract", json.getString("operation"))
        assertEquals("3", json.getString("entries"))
        assertTrue(!json.has("password"))
        assertTrue(!json.has("token"))
        assertTrue(report.readText().contains("Passwords"))
        assertTrue(report.readText().lowercase().contains("never included"))
        report.delete()
    }

    @Test
    fun processDeathMarkerBecomesInterruptedResultWithoutPersistingRequestSecrets() {
        val context = RuntimeEnvironment.getApplication()
        val preferences = context.getSharedPreferences("archive_job_results", 0)
        preferences.edit()
            .putString("active.token", "job-token")
            .putString("active.kind", "extract")
            .commit()

        ArchiveJobForegroundService.recoverInterruptedResult(context)
        val result = ArchiveJobForegroundService.takePersistedResults(context).single()

        assertEquals("job-token", result.token)
        assertEquals("extract", result.kind)
        assertEquals("INTERRUPTED", result.status)
        assertTrue(result.message!!.contains("interrupted"))
        assertFalse(preferences.contains("active.token"))
        assertTrue(preferences.all.keys.none { it.contains("password", ignoreCase = true) })
    }

    @Test
    fun recoveryResultCarriesOnlyRecoveryIdentifier() {
        val intent = Intent(ArchiveJobForegroundService.ACTION_RESULT)
            .putExtra("token", "recovery-token")
            .putExtra("kind", "extract")
            .putExtra("status", "RECOVERY")
            .putExtra("message", "Provider failed")
            .putExtra("recoveryId", "recovery-id-1234")

        val result = ArchiveJobForegroundService.resultFrom(intent)

        assertEquals("RECOVERY", result?.status)
        assertEquals("recovery-id-1234", result?.recoveryId)
        assertFalse(result!!.message!!.contains("password", ignoreCase = true))
    }

    @Test
    fun separateCreationResultRoundTripsAllCommittedOutputs() {
        val result = ArchiveForegroundResult(
            token = "create-separate-token",
            kind = "create-separately",
            status = "COMPLETED",
            outputPath = "/files/one.zip",
            outputPaths = listOf("/files/one.zip", "/files/two.zip"),
            verified = true
        )
        val intent = Intent(ArchiveJobForegroundService.ACTION_RESULT)
            .putExtra("token", result.token)
            .putExtra("kind", result.kind)
            .putExtra("status", result.status)
            .putExtra("outputPath", result.outputPath)
            .putStringArrayListExtra("outputPaths", ArrayList(result.outputPaths))
            .putExtra("verified", true)

        val parsed = ArchiveJobForegroundService.resultFrom(intent)

        assertEquals(result.outputPath, parsed?.outputPath)
        assertEquals(result.outputPaths, parsed?.outputPaths)
        assertTrue(parsed?.verified == true)
    }
}
