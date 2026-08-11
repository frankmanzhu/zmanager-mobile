package org.tzap.zmanager.mobile

import java.io.File
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class LocalSendProtocolTest {
    @Test
    fun prepareUploadUsesLocalSendV2MetadataShape() {
        val file = File.createTempFile("localsend", ".zip")
        file.writeText("archive")
        try {
            val item = LocalSendFile(id = "file-1", file = file, displayName = "archive.zip", mimeType = "application/zip")
            val body = LocalSendProtocol.prepareUploadBody(
                LocalSendProtocol.announcement("ZManager", "fingerprint").put("announce", false),
                listOf(item),
                mapOf("file-1" to "abc123")
            )
            val metadata = body.getJSONObject("files").getJSONObject("file-1")
            assertEquals("2.0", body.getJSONObject("info").getString("version"))
            assertEquals("archive.zip", metadata.getString("fileName"))
            assertEquals(7, metadata.getLong("size"))
            assertEquals("abc123", metadata.getString("sha256"))
        } finally {
            file.delete()
        }
    }

    @Test
    fun deviceAnnouncementUsesDefaultDiscoveryValues() {
        val json: JSONObject = LocalSendProtocol.announcement("ZManager", "fingerprint")
        assertEquals(LocalSendProtocol.defaultPort, json.getInt("port"))
        assertEquals(LocalSendProtocol.multicastAddress, "224.0.0.167")
        assertTrue(json.getBoolean("announce"))
    }
}
