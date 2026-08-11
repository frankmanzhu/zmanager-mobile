package org.tzap.zmanager.mobile

import java.io.File
import java.net.HttpURLConnection
import java.net.URL
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

    @Test
    fun receiverStagesAndCommitsAValidatedUpload() {
        val root = createTempDir(prefix = "localsend-receiver")
        val receiver = LocalSendReceiver(requestedPort = 0)
        try {
            val session = receiver.start(root)
            val fileId = "file-1"
            val payload = "received archive".toByteArray()
            val digest = java.security.MessageDigest.getInstance("SHA-256")
                .digest(payload).joinToString("") { "%02x".format(it) }
            val prepare = postJson(
                session.port,
                "/api/localsend/v2/prepare-upload",
                JSONObject().put("files", JSONObject().put(fileId, JSONObject()
                    .put("id", fileId)
                    .put("fileName", "../archive.zip")
                    .put("size", payload.size)
                    .put("sha256", digest)))
            )
            assertEquals(200, prepare.code)
            val prepareJson = JSONObject(prepare.body)
            val token = prepareJson.getJSONObject("files").getString(fileId)
            val uploaded = postBytes(
                session.port,
                "/api/localsend/v2/upload?sessionId=${prepareJson.getString("sessionId")}&fileId=$fileId&token=$token",
                payload
            )
            assertEquals(200, uploaded.code)
            val committed = root.listFiles()?.firstOrNull { it.name == "archive.zip" }
            assertTrue(committed?.isFile == true)
            assertEquals("received archive", committed?.readText())
            assertTrue(root.resolve(".localsend").walkTopDown().none { it.isFile })
        } finally {
            receiver.stop()
            root.deleteRecursively()
        }
    }

    @Test
    fun receiverRejectsTraversalNamesBeforeWriting() {
        assertEquals("evil.zip", LocalSendReceiver.sanitizeIncomingName("../../evil.zip"))
        assertEquals("received-file", LocalSendReceiver.sanitizeIncomingName("../"))
    }

    private fun postJson(port: Int, path: String, body: JSONObject): HttpResult =
        postBytes(port, path, body.toString().toByteArray())

    private fun postBytes(port: Int, path: String, body: ByteArray): HttpResult {
        val connection = (URL("http://127.0.0.1:$port$path").openConnection() as HttpURLConnection).apply {
            requestMethod = "POST"
            doOutput = true
            setRequestProperty("Content-Type", "application/json")
            setFixedLengthStreamingMode(body.size)
        }
        connection.outputStream.use { it.write(body) }
        val responseBody = (if (connection.responseCode in 200..299) connection.inputStream else connection.errorStream)
            ?.bufferedReader()?.use { it.readText() }.orEmpty()
        return HttpResult(connection.responseCode, responseBody)
    }

    private data class HttpResult(val code: Int, val body: String)
}
