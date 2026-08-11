package org.tzap.zmanager.mobile

import android.content.Intent
import android.net.Uri
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class ArchiveImportTest {
    @Test
    fun sanitizedDisplayNameKeepsOnlySafeLeafName() {
        assertEquals(
            "evil_archive.zip",
            ArchiveImportNames.sanitizedDisplayName("../nested/evil:archive.zip")
        )
        assertEquals("archive", ArchiveImportNames.sanitizedDisplayName(".."))
        assertEquals("archive", ArchiveImportNames.sanitizedDisplayName(null))
    }

    @Test
    fun firstArchiveUriUsesShareStreamBeforeIntentData() {
        val streamUri = Uri.parse("content://provider/shared.zip")
        val dataUri = Uri.parse("content://provider/data.zip")
        val intent = Intent(Intent.ACTION_SEND)
            .setData(dataUri)
            .putExtra(Intent.EXTRA_STREAM, streamUri)

        assertEquals(streamUri, ArchiveImportIntents.firstArchiveUri(intent))
    }

    @Test
    fun firstArchiveUriIgnoresLauncherIntent() {
        assertNull(ArchiveImportIntents.firstArchiveUri(Intent(Intent.ACTION_MAIN)))
    }

    @Test
    fun primaryArchiveNamePrefersTheFirstMultipartVolume() {
        assertEquals(
            "payload.vol000.tzap",
            ArchiveImportNames.primaryArchiveName(listOf("payload.vol002.tzap", "payload.vol000.tzap"))
        )
        assertEquals(
            "payload.part1.rar",
            ArchiveImportNames.primaryArchiveName(listOf("payload.part2.rar", "payload.part1.rar"))
        )
        assertEquals(
            "payload.7z.001",
            ArchiveImportNames.primaryArchiveName(listOf("payload.7z.002", "payload.7z.001"))
        )
        assertEquals(
            "payload.zip",
            ArchiveImportNames.primaryArchiveName(listOf("payload.z01", "payload.zip"))
        )
    }
}
