package org.tzap.zmanager.mobile

import android.content.Intent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.json.JSONObject
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment

@RunWith(RobolectricTestRunner::class)
class ArchiveJobForegroundServiceTest {
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
}
