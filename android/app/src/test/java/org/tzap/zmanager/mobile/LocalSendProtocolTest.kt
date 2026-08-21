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
import org.robolectric.RuntimeEnvironment

@RunWith(RobolectricTestRunner::class)
class LocalSendProtocolTest {
    @Test
    fun inboundAndOutboundSessionsUseTheSameStableInstallationFingerprint() {
        val context = RuntimeEnvironment.getApplication()
        val first = LocalSendIdentity.fingerprint(context)
        val second = LocalSendIdentity.fingerprint(context)

        assertTrue(first.isNotBlank())
        assertEquals(first, second)
        assertEquals(first, LocalSendClient(context).let { LocalSendIdentity.fingerprint(context) })
    }

    @Test
    fun trustStorePersistsOnlyExplicitFingerprints() {
        val context = RuntimeEnvironment.getApplication()
        val store = LocalSendTrustStore(context)
        val device = LocalSendDevice(
            address = "192.0.2.1",
            port = 53317,
            protocol = "http",
            alias = "Receiver",
            version = "2.0",
            deviceModel = "test",
            deviceType = "mobile",
            fingerprint = "trusted-fingerprint",
            download = false
        )
        store.forget(device)
        assertTrue(!store.isTrusted(device))
        store.remember(device)
        assertTrue(store.isTrusted(device))
        assertEquals(listOf("trusted-fingerprint"), store.fingerprints())
        store.forgetFingerprint("trusted-fingerprint")
        assertTrue(store.fingerprints().isEmpty())
        store.forget(device)
        assertTrue(!store.isTrusted(device))
    }

    @Test
    fun selectedProviderFilesAreStagedForSharingAndCleanedUp() {
        val context = RuntimeEnvironment.getApplication()
        val source = File.createTempFile("localsend-source", ".txt")
        source.writeText("share me")
        var staged: StagedLocalSendFiles? = null
        try {
            staged = LocalSendSourceStager(context).stageUris(listOf(android.net.Uri.fromFile(source)))
            assertEquals("share me", staged.files.single().file.readText())
            assertTrue(staged.root.path.startsWith(context.cacheDir.path))
            assertEquals(source.name, staged.files.single().displayName)
        } finally {
            staged?.let(LocalSendSourceStager(context)::discard)
            source.delete()
        }
        assertTrue(!staged!!.root.exists())
    }

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
    fun httpsPeersUseCertificateFingerprintNormalization() {
        val device = LocalSendDevice(
            address = "192.0.2.1",
            port = 53317,
            protocol = "https",
            alias = "LocalSend",
            version = "2.1",
            deviceModel = "macOS",
            deviceType = "desktop",
            fingerprint = "AA:bb-cc dd",
            download = false
        )

        assertEquals("https://192.0.2.1:53317", device.baseUrl)
        assertEquals("AABBCCDD", LocalSendTls.normalizeFingerprint(device.fingerprint!!))
    }

    @Test
    fun pinRequiredUsesLocalSendUnauthorizedStatus() {
        assertTrue(LocalSendProtocol.isPinRequiredStatus(401))
        assertTrue(!LocalSendProtocol.isPinRequiredStatus(403))
    }

    @Test
    fun receiverStagesAndCommitsAValidatedUpload() {
        val root = createTempDir(prefix = "localsend-receiver")
        var callbackFile: LocalSendReceivedFile? = null
        val receiver = LocalSendReceiver(requestedPort = 0, onFileCommitted = { callbackFile = it })
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
            assertEquals("archive.zip", callbackFile?.displayName)
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

    @Test
    fun receiverStreamsAndChecksumsLargeUploadsWithoutBuffering() {
        val root = createTempDir(prefix = "localsend-large")
        val receiver = LocalSendReceiver(requestedPort = 0)
        try {
            val session = receiver.start(root)
            val payload = ByteArray(8 * 1024 * 1024) { (it % 251).toByte() }
            val digest = java.security.MessageDigest.getInstance("SHA-256")
                .digest(payload).joinToString("") { "%02x".format(it) }
            val fileId = "large-file"
            val prepare = postJson(
                session.port,
                "/api/localsend/v2/prepare-upload",
                JSONObject().put("files", JSONObject().put(fileId, JSONObject()
                    .put("id", fileId)
                    .put("fileName", "large.bin")
                    .put("size", payload.size)
                    .put("sha256", digest)))
            )
            val prepareJson = JSONObject(prepare.body)
            val token = prepareJson.getJSONObject("files").getString(fileId)
            val uploaded = postBytes(
                session.port,
                "/api/localsend/v2/upload?sessionId=${prepareJson.getString("sessionId")}&fileId=$fileId&token=$token",
                payload
            )
            assertEquals(200, uploaded.code)
            assertEquals(payload.toList(), root.resolve("large.bin").readBytes().toList())
            assertTrue(root.resolve(".localsend").walkTopDown().none { it.isFile })
        } finally {
            receiver.stop()
            root.deleteRecursively()
        }
    }

    @Test
    fun receiverReturnsChecksumMismatchAndCleansPartialUpload() {
        val root = createTempDir(prefix = "localsend-checksum")
        val receiver = LocalSendReceiver(requestedPort = 0)
        try {
            val session = receiver.start(root)
            val fileId = "checksum-file"
            val payload = "actual".toByteArray()
            val prepare = postJson(
                session.port,
                "/api/localsend/v2/prepare-upload",
                JSONObject().put("files", JSONObject().put(fileId, JSONObject()
                    .put("id", fileId)
                    .put("fileName", "checksum.bin")
                    .put("size", payload.size)
                    .put("sha256", "00".repeat(32))))
            )
            val prepareJson = JSONObject(prepare.body)
            val token = prepareJson.getJSONObject("files").getString(fileId)
            val response = postBytes(
                session.port,
                "/api/localsend/v2/upload?sessionId=${prepareJson.getString("sessionId")}&fileId=$fileId&token=$token",
                payload
            )

            assertEquals(422, response.code)
            assertTrue(!root.resolve("checksum.bin").exists())
            assertTrue(root.resolve(".localsend").walkTopDown().none { it.isFile })
        } finally {
            receiver.stop()
            root.deleteRecursively()
        }
    }

    @Test
    fun receiverAnswersHttpRegistrationWithItsReachablePort() {
        val root = createTempDir(prefix = "localsend-register")
        val receiver = LocalSendReceiver(requestedPort = 0, fingerprint = "receiver-fingerprint")
        try {
            val session = receiver.start(root)
            val response = postJson(
                session.port,
                "/api/localsend/v2/register",
                LocalSendProtocol.announcement("Sender", "sender-fingerprint").put("announce", false)
            )
            assertEquals(200, response.code)
            val announcement = JSONObject(response.body)
            assertEquals("receiver-fingerprint", announcement.getString("fingerprint"))
            assertEquals(session.port, announcement.getInt("port"))
            assertEquals(false, announcement.getBoolean("announce"))
            assertTrue(announcement.getBoolean("download"))
        } finally {
            receiver.stop()
            root.deleteRecursively()
        }
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
