package org.tzap.zmanager.mobile

import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import android.content.Intent
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class MainActivityInstrumentedTest {
    @Test
    fun launchReachesResumedActivity() {
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            assertNotNull(scenario)
        }
    }

    @Test
    fun interruptedForegroundMarkerRecoversOnDeviceWithoutSecrets() {
        val context = ApplicationProvider.getApplicationContext<android.content.Context>()
        val preferences = context.getSharedPreferences("archive_job_results", 0)
        preferences.edit().clear()
            .putString("active.token", "device-job-token")
            .putString("active.kind", "extract")
            .commit()

        ArchiveJobForegroundService.recoverInterruptedResult(context)
        val result = ArchiveJobForegroundService.takePersistedResults(context).single()

        assertEquals("device-job-token", result.token)
        assertEquals("INTERRUPTED", result.status)
        assertEquals(false, preferences.contains("active.token"))
        assertEquals(false, preferences.all.keys.any { it.contains("password", ignoreCase = true) })
    }

    @Test
    fun timeoutResultIntentPreservesOnlyTerminalStatusFields() {
        val intent = Intent(ArchiveJobForegroundService.ACTION_RESULT)
            .putExtra("token", "timeout-token")
            .putExtra("kind", "extract")
            .putExtra("status", "TIMEOUT")
            .putExtra("message", "The archive job exceeded the Android background time limit.")

        val result = ArchiveJobForegroundService.resultFrom(intent)

        assertEquals("timeout-token", result?.token)
        assertEquals("TIMEOUT", result?.status)
        assertEquals(null, result?.outputPath)
    }

}
