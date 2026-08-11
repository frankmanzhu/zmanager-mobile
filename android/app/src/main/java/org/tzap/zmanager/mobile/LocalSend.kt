package org.tzap.zmanager.mobile

import android.os.Build
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.HttpURLConnection
import java.net.InetAddress
import java.net.URL
import java.net.URLEncoder
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean

data class LocalSendDevice(
    val address: String,
    val port: Int,
    val protocol: String,
    val alias: String,
    val version: String,
    val deviceModel: String?,
    val deviceType: String?,
    val fingerprint: String?,
    val download: Boolean
) {
    val baseUrl: String get() = "$protocol://$address:$port"
}

data class LocalSendFile(
    val id: String = UUID.randomUUID().toString(),
    val file: File,
    val displayName: String = file.name,
    val mimeType: String = "application/octet-stream"
)

data class LocalSendUploadSession(val sessionId: String, val tokens: Map<String, String>)

sealed interface LocalSendUiState {
    data object Idle : LocalSendUiState
    data class Receiving(val port: Int) : LocalSendUiState
    data object Discovering : LocalSendUiState
    data class Devices(val devices: List<LocalSendDevice>) : LocalSendUiState
    data class Sending(val device: LocalSendDevice, val message: String) : LocalSendUiState
    data class Completed(val device: LocalSendDevice) : LocalSendUiState
    data class Failed(val message: String) : LocalSendUiState
}

object LocalSendProtocol {
    const val multicastAddress = "224.0.0.167"
    const val defaultPort = 53317
    const val protocolVersion = "2.0"

    fun announcement(
        alias: String,
        fingerprint: String,
        port: Int = defaultPort,
        download: Boolean = false,
        announce: Boolean = true
    ): JSONObject =
        JSONObject().apply {
            put("alias", alias)
            put("version", protocolVersion)
            put("deviceModel", Build.MODEL)
            put("deviceType", "mobile")
            put("fingerprint", fingerprint)
            put("port", port)
            put("protocol", "http")
            put("download", download)
            put("announce", announce)
        }

    fun prepareUploadBody(
        sender: JSONObject,
        files: List<LocalSendFile>,
        hashes: Map<String, String>
    ): JSONObject = JSONObject().apply {
        put("info", sender)
        put("files", JSONObject().apply {
            files.forEach { item ->
                put(item.id, JSONObject().apply {
                    put("id", item.id)
                    put("fileName", item.displayName)
                    put("size", item.file.length())
                    put("fileType", item.mimeType)
                    hashes[item.id]?.let { put("sha256", it) }
                })
            }
        })
    }
}

/** Outbound LocalSend v2.2 client. Archive work remains entirely outside this subsystem. */
class LocalSendClient(
    private val alias: String = "ZManager Mobile",
    private val fingerprint: String = UUID.randomUUID().toString(),
    private val port: Int = LocalSendProtocol.defaultPort
) {
    private val cancelled = AtomicBoolean(false)

    fun cancel() { cancelled.set(true) }

    fun discover(timeoutMillis: Int = 1_500): List<LocalSendDevice> {
        cancelled.set(false)
        val found = linkedMapOf<String, LocalSendDevice>()
        DatagramSocket().use { socket ->
            socket.broadcast = true
            socket.soTimeout = timeoutMillis
            val payload = LocalSendProtocol.announcement(alias, fingerprint, port).toString().toByteArray()
            val target = InetAddress.getByName(LocalSendProtocol.multicastAddress)
            socket.send(DatagramPacket(payload, payload.size, target, LocalSendProtocol.defaultPort))
            val buffer = ByteArray(16 * 1024)
            while (!cancelled.get()) {
                try {
                    val packet = DatagramPacket(buffer, buffer.size)
                    socket.receive(packet)
                    parseDevice(packet.address.hostAddress ?: continue, packet.data, packet.length)?.let {
                        if (it.fingerprint != fingerprint) found["${it.address}:${it.port}"] = it
                    }
                } catch (_: java.net.SocketTimeoutException) {
                    break
                }
            }
        }
        return found.values.toList()
    }

    /** HTTP registration fallback for networks where multicast is unavailable. */
    fun discoverHttp(hosts: Iterable<String>): List<LocalSendDevice> {
        val found = linkedMapOf<String, LocalSendDevice>()
        hosts.forEach { host ->
            runCatching {
                val response = request(
                    LocalSendDevice(host, port, "http", "", "", null, null, null, false),
                    "POST",
                    "/api/localsend/v2/register",
                    LocalSendProtocol.announcement(alias, fingerprint, port).put("announce", false).toString().toByteArray()
                )
                parseDevice(host, response.toByteArray(), response.length)?.let { device ->
                    if (device.fingerprint != fingerprint) found["${device.address}:${device.port}"] = device
                }
            }
        }
        return found.values.toList()
    }

    fun prepareUpload(device: LocalSendDevice, files: List<LocalSendFile>, pin: String? = null): LocalSendUploadSession {
        require(files.isNotEmpty()) { "Select at least one file." }
        val hashes = files.associate { it.id to sha256(it.file) }
        val body = LocalSendProtocol.prepareUploadBody(
            LocalSendProtocol.announcement(alias, fingerprint, port).put("announce", false),
            files,
            hashes
        )
        val suffix = pin?.let { "?pin=${encode(it)}" }.orEmpty()
        val response = request(device, "POST", "/api/localsend/v2/prepare-upload$suffix", body.toString().toByteArray())
        val json = JSONObject(response)
        val tokens = mutableMapOf<String, String>()
        val tokenObject = json.optJSONObject("files") ?: JSONObject()
        files.forEach { tokens[it.id] = tokenObject.getString(it.id) }
        return LocalSendUploadSession(json.getString("sessionId"), tokens)
    }

    fun upload(
        device: LocalSendDevice,
        session: LocalSendUploadSession,
        files: List<LocalSendFile>,
        onProgress: (file: LocalSendFile, sent: Long, total: Long) -> Unit = { _, _, _ -> }
    ) {
        cancelled.set(false)
        files.forEach { item ->
            if (cancelled.get()) throw LocalSendCancelledException()
            val query = "?sessionId=${encode(session.sessionId)}&fileId=${encode(item.id)}&token=${encode(session.tokens.getValue(item.id))}"
            uploadFile(device, "/api/localsend/v2/upload$query", item, onProgress)
        }
    }

    fun cancel(device: LocalSendDevice, sessionId: String) {
        request(device, "POST", "/api/localsend/v2/cancel?sessionId=${encode(sessionId)}", ByteArray(0))
    }

    private fun uploadFile(device: LocalSendDevice, path: String, item: LocalSendFile, onProgress: (LocalSendFile, Long, Long) -> Unit) {
        val connection = open(device, path, "POST")
        connection.doOutput = true
        connection.setFixedLengthStreamingMode(item.file.length())
        try {
            item.file.inputStream().use { input -> connection.outputStream.use { output ->
                val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                var sent = 0L
                while (true) {
                    if (cancelled.get()) throw LocalSendCancelledException()
                    val count = input.read(buffer)
                    if (count < 0) break
                    output.write(buffer, 0, count)
                    sent += count
                    onProgress(item, sent, item.file.length())
                }
            } }
            check(connection.responseCode in 200..299) { "LocalSend upload was rejected (${connection.responseCode})." }
        } finally {
            connection.disconnect()
        }
    }

    private fun request(device: LocalSendDevice, method: String, path: String, body: ByteArray): String {
        val connection = open(device, path, method)
        try {
            connection.doOutput = body.isNotEmpty()
            if (body.isNotEmpty()) {
                connection.setRequestProperty("Content-Type", "application/json")
                connection.outputStream.use { it.write(body) }
            }
            val response = if (connection.responseCode in 200..299) connection.inputStream else connection.errorStream
            if (connection.responseCode !in 200..299) throw IOException("LocalSend request was rejected (${connection.responseCode}).")
            return response?.bufferedReader()?.use { it.readText() }.orEmpty()
        } finally {
            connection.disconnect()
        }
    }

    private fun open(device: LocalSendDevice, path: String, method: String): HttpURLConnection {
        return (URL(device.baseUrl + path).openConnection() as HttpURLConnection).apply {
            requestMethod = method
            connectTimeout = 5_000
            readTimeout = 30_000
            setRequestProperty("Accept", "application/json")
        }
    }

    private fun sha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                digest.update(buffer, 0, count)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    private fun parseDevice(address: String, data: ByteArray, length: Int): LocalSendDevice? = runCatching {
        val json = JSONObject(String(data, 0, length))
        LocalSendDevice(
            address = address,
            port = json.optInt("port", LocalSendProtocol.defaultPort),
            protocol = json.optString("protocol", "http"),
            alias = json.getString("alias"),
            version = json.optString("version", LocalSendProtocol.protocolVersion),
            deviceModel = json.optString("deviceModel").takeIf { it.isNotEmpty() },
            deviceType = json.optString("deviceType").takeIf { it.isNotEmpty() },
            fingerprint = json.optString("fingerprint").takeIf { it.isNotEmpty() },
            download = json.optBoolean("download", false)
        )
    }.getOrNull()

    private fun encode(value: String) = URLEncoder.encode(value, Charsets.UTF_8.name())
}

class LocalSendCancelledException : IOException("LocalSend transfer cancelled.")
