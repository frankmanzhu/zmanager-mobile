package org.tzap.zmanager.mobile

import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.Direction
import androidx.test.uiautomator.Until
import android.content.Intent
import android.provider.DocumentsContract
import java.util.UUID
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
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
    fun viewIntentImportsAProviderBackedArchive() {
        val context = ApplicationProvider.getApplicationContext<android.content.Context>()
        val resolver = context.contentResolver
        val source = TestDocumentsProvider.documentUri("${TestDocumentsProvider.ROOT_ID}/intent-${UUID.randomUUID()}.zip")
        resolver.openOutputStream(source, "wt")!!.use { output ->
            ZipOutputStream(output).use { zip ->
                zip.putNextEntry(ZipEntry("hello.txt"))
                zip.write("hello from provider".toByteArray())
                zip.closeEntry()
            }
        }

        try {
            val intent = Intent(Intent.ACTION_VIEW)
                .setClass(context, MainActivity::class.java)
                .setDataAndType(source, "application/zip")
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            ActivityScenario.launch<MainActivity>(intent).use {
                val device = androidx.test.uiautomator.UiDevice.getInstance(
                    InstrumentationRegistry.getInstrumentation()
                )
                assertNotNull(device.wait(Until.findObject(By.textContains("Imported")), 10_000))
            }
        } finally {
            DocumentsContract.deleteDocument(resolver, source)
        }
    }

    @Test
    fun primaryControlsExposeStableAccessibilityDescriptions() {
        ActivityScenario.launch(MainActivity::class.java).use {
            val device = androidx.test.uiautomator.UiDevice.getInstance(
                InstrumentationRegistry.getInstrumentation()
            )
            val scrollable = device.findObject(By.scrollable(true))
            assertNotNull(scrollable)
            assertNotNull(device.wait(Until.findObject(By.desc("About and help")), 5_000))
            device.findObject(By.desc("About and help")).click()
            assertNotNull(device.wait(Until.findObject(By.text("About ZManager")), 5_000))
            device.findObject(By.text("Close")).click()
            repeat(6) {
                if (device.findObject(By.desc("Open Archive")) == null ||
                    device.findObject(By.desc("Batch extract")) == null
                ) {
                    scrollable?.scroll(Direction.DOWN, 1.0f)
                }
            }
            assertNotNull(device.wait(Until.findObject(By.desc("Open Archive")), 5_000))
            assertNotNull(device.wait(Until.findObject(By.desc("Batch extract")), 5_000))
            assertNotNull(device.wait(Until.findObject(By.desc("LocalSend sharing panel")), 5_000))
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
