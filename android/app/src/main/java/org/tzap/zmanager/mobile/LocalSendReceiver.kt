package org.tzap.zmanager.mobile

import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.File
import java.io.IOException
import java.net.DatagramPacket
import java.net.InetAddress
import java.net.MulticastSocket
import java.net.ServerSocket
import java.net.Socket
import java.net.URLDecoder
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

data class LocalSendReceivedFile(
    val fileId: String,
    val displayName: String,
    val path: File,
    val bytes: Long
)

data class LocalSendReceiverSession(val port: Int, val destinationRoot: File)

class LocalSendChecksumMismatchException : IOException("Received checksum does not match the request.")

/**
 * Small, app-owned LocalSend upload receiver. It accepts only the v2 upload
 * endpoints and never writes outside the selected app-owned destination.
 */
class LocalSendReceiver(
    private val alias: String = "ZManager Mobile",
    private val fingerprint: String = UUID.randomUUID().toString(),
    private val requestedPort: Int = LocalSendProtocol.defaultPort,
    private val worker: ExecutorService = Executors.newCachedThreadPool(),
    private val onFileCommitted: (LocalSendReceivedFile) -> Unit = {}
) {
    private data class ExpectedFile(
        val id: String,
        val displayName: String,
        val expectedBytes: Long,
        val expectedSha256: String?,
        val token: String
    )

    private data class Session(
        val id: String,
        val root: File,
        val destinationRoot: File,
        val files: Map<String, ExpectedFile>,
        val completed: MutableSet<String> = ConcurrentHashMap.newKeySet()
    )

    private val running = AtomicBoolean(false)
    private val sessions = ConcurrentHashMap<String, Session>()
    private var server: ServerSocket? = null
    private var announceSocket: MulticastSocket? = null
    private var acceptThread: Thread? = null
    private var announceThread: Thread? = null

    @Synchronized
    fun start(destinationRoot: File): LocalSendReceiverSession {
        check(running.compareAndSet(false, true)) { "LocalSend receiver is already running." }
        check(destinationRoot.mkdirs() || destinationRoot.isDirectory) {
            running.set(false)
            "Unable to prepare the receive destination."
        }
        return try {
            val socket = ServerSocket(requestedPort)
            server = socket
            acceptThread = thread("localsend-receiver-accept") {
                while (running.get()) {
                    runCatching { socket.accept() }.onSuccess { client ->
                        worker.execute { handle(client, destinationRoot) }
                    }
                }
            }
            announceThread = thread("localsend-receiver-announce") {
                announceLoop(socket.localPort)
            }
            LocalSendReceiverSession(socket.localPort, destinationRoot)
        } catch (error: Throwable) {
            stop()
            throw error
        }
    }

    @Synchronized
    fun stop() {
        running.set(false)
        runCatching { server?.close() }
        server = null
        runCatching { announceSocket?.close() }
        announceSocket = null
        sessions.values.forEach { it.root.deleteRecursively() }
        sessions.clear()
    }

    private fun handle(client: Socket, destinationRoot: File) {
        client.use { socket ->
            val input = BufferedInputStream(socket.getInputStream())
            val output = BufferedOutputStream(socket.getOutputStream())
            val requestLine = readLine(input) ?: return
            val request = requestLine.split(' ', limit = 3)
            if (request.size != 3) {
                respond(output, 400, "Invalid HTTP request")
                return
            }
            val headers = buildMap {
                while (true) {
                    val line = readLine(input) ?: return@buildMap
                    if (line.isEmpty()) break
                    val separator = line.indexOf(':')
                    if (separator > 0) put(line.substring(0, separator).lowercase(), line.substring(separator + 1).trim())
                }
            }
            val length = headers["content-length"]?.toLongOrNull() ?: 0L
            if (length < 0 ||
                (targetHasBoundedBody(request[1]) && length > MAX_REQUEST_BYTES)
            ) {
                respond(output, 413, "Request too large")
                return
            }
            val target = request[1]
            when {
                request[0] != "POST" -> respond(output, 405, "POST required")
                target.substringBefore('?') == "/api/localsend/v2/register" -> {
                    readExactly(input, length)
                    register(output)
                }
                target.substringBefore('?') == "/api/localsend/v2/prepare-upload" -> {
                    val body = readExactly(input, length)
                    prepare(output, body, destinationRoot)
                }
                target.substringBefore('?') == "/api/localsend/v2/upload" -> {
                    upload(output, input, length, query(target))
                }
                target.substringBefore('?') == "/api/localsend/v2/cancel" -> {
                    cancel(output, query(target))
                }
                else -> respond(output, 404, "Not found")
            }
        }
    }

    private fun prepare(output: BufferedOutputStream, body: ByteArray, destinationRoot: File) {
        runCatching {
            val json = JSONObject(String(body, Charsets.UTF_8))
            val files = json.optJSONObject("files") ?: throw IOException("Missing files")
            val sessionId = UUID.randomUUID().toString()
            val sessionRoot = File(destinationRoot, ".localsend/$sessionId")
            check(sessionRoot.mkdirs()) { "Unable to prepare receive staging." }
            val expected = buildMap {
                files.keys().forEach { key ->
                    val file = files.getJSONObject(key)
                    val id = file.optString("id", key)
                    put(id, ExpectedFile(
                        id = id,
                        displayName = sanitizeIncomingName(file.optString("fileName", id)),
                        expectedBytes = file.optLong("size", -1L),
                        expectedSha256 = file.optString("sha256").takeIf { it.isNotEmpty() },
                        token = UUID.randomUUID().toString()
                    ))
                }
            }
            check(expected.isNotEmpty()) { "No files requested." }
            sessions[sessionId] = Session(sessionId, sessionRoot, destinationRoot, expected)
            val responseFiles = JSONObject()
            expected.values.forEach { responseFiles.put(it.id, it.token) }
            respondJson(output, 200, JSONObject().put("sessionId", sessionId).put("files", responseFiles))
        }.onFailure { respond(output, 400, it.message ?: "Invalid upload request") }
    }

    private fun upload(output: BufferedOutputStream, input: BufferedInputStream, length: Long, params: Map<String, String>) {
        val session = sessions[params["sessionId"]]
        val expected = session?.files?.get(params["fileId"])
        if (session == null || expected == null || expected.token != params["token"]) {
            respond(output, 403, "Invalid upload token")
            return
        }
        val part = File(session.root, "${expected.id}.part")
        runCatching {
            val digest = MessageDigest.getInstance("SHA-256")
            var remaining = length
            var written = 0L
            part.outputStream().use { file ->
                val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                while (remaining > 0) {
                    val count = input.read(buffer, 0, minOf(buffer.size.toLong(), remaining).toInt())
                    check(count > 0) { "Unexpected end of upload." }
                    file.write(buffer, 0, count)
                    digest.update(buffer, 0, count)
                    written += count
                    remaining -= count
                }
            }
            check(expected.expectedBytes < 0 || expected.expectedBytes == written) { "Received size does not match the request." }
            if (expected.expectedSha256 != null &&
                !expected.expectedSha256.equals(digest.hex(), ignoreCase = true)
            ) {
                throw LocalSendChecksumMismatchException()
            }
            val target = uniqueTarget(session.destinationRoot, expected.displayName)
            check(part.renameTo(target)) { "Unable to commit received file." }
            runCatching {
                onFileCommitted(LocalSendReceivedFile(expected.id, expected.displayName, target, written))
            }
            if (session.completed.add(expected.id) && session.completed.containsAll(session.files.keys)) {
                sessions.remove(session.id, session)
                session.root.deleteRecursively()
            }
            respond(output, 200, "OK")
        }.onFailure { error ->
            part.delete()
            sessions.remove(session.id, session)
            session.root.deleteRecursively()
            respond(
                output,
                if (error is LocalSendChecksumMismatchException) 422 else 400,
                error.message ?: "Upload rejected"
            )
        }
    }

    private fun cancel(output: BufferedOutputStream, params: Map<String, String>) {
        sessions.remove(params["sessionId"])?.root?.deleteRecursively()
        respond(output, 200, "OK")
    }

    private fun register(output: BufferedOutputStream) {
        respondJson(
            output,
            200,
            LocalSendProtocol.announcement(
                alias = alias,
                fingerprint = fingerprint,
                port = server?.localPort ?: requestedPort,
                download = true,
                announce = false
            )
        )
    }

    private fun announceLoop(port: Int) {
        runCatching {
            MulticastSocket(LocalSendProtocol.defaultPort).use { socket ->
                announceSocket = socket
                socket.reuseAddress = true
                val target = InetAddress.getByName(LocalSendProtocol.multicastAddress)
                socket.joinGroup(target)
                socket.soTimeout = 1_000
                while (running.get()) {
                    val payload = LocalSendProtocol.announcement(alias, fingerprint, port, download = true).toString().toByteArray()
                    socket.send(DatagramPacket(payload, payload.size, target, LocalSendProtocol.defaultPort))
                    val deadline = System.nanoTime() + 1_000_000_000L
                    while (running.get() && System.nanoTime() < deadline) {
                        try {
                            val packet = DatagramPacket(ByteArray(16 * 1024), 16 * 1024)
                            socket.receive(packet)
                            val json = runCatching { JSONObject(String(packet.data, 0, packet.length)) }.getOrNull()
                            if (json?.optString("fingerprint") != fingerprint && json?.optBoolean("announce", true) == true) {
                                val response = LocalSendProtocol.announcement(
                                    alias = alias,
                                    fingerprint = fingerprint,
                                    port = port,
                                    download = true,
                                    announce = false
                                ).toString().toByteArray()
                                socket.send(DatagramPacket(response, response.size, packet.address, packet.port))
                            }
                        } catch (_: java.net.SocketTimeoutException) {
                            break
                        }
                    }
                }
                runCatching { socket.leaveGroup(target) }
            }
        }
    }

    private fun respond(output: BufferedOutputStream, status: Int, body: String) {
        respondBytes(output, status, "text/plain; charset=utf-8", body.toByteArray())
    }

    private fun respondJson(output: BufferedOutputStream, status: Int, body: JSONObject) {
        respondBytes(output, status, "application/json", body.toString().toByteArray())
    }

    private fun respondBytes(output: BufferedOutputStream, status: Int, type: String, body: ByteArray) {
        output.write("HTTP/1.1 $status ${if (status in 200..299) "OK" else "Error"}\r\n".toByteArray())
        output.write("Content-Type: $type\r\nContent-Length: ${body.size}\r\nConnection: close\r\n\r\n".toByteArray())
        output.write(body)
        output.flush()
    }

    private fun readLine(input: BufferedInputStream): String? {
        val bytes = ArrayList<Byte>()
        while (bytes.size < MAX_HEADER_LINE) {
            val value = input.read()
            if (value < 0) return null
            if (value == '\n'.code) break
            if (value != '\r'.code) bytes += value.toByte()
        }
        return bytes.toByteArray().toString(Charsets.ISO_8859_1)
    }

    private fun readExactly(input: BufferedInputStream, length: Long): ByteArray {
        require(length <= MAX_REQUEST_BYTES)
        val result = ByteArray(length.toInt())
        var offset = 0
        while (offset < result.size) {
            val count = input.read(result, offset, result.size - offset)
            check(count > 0) { "Unexpected end of request." }
            offset += count
        }
        return result
    }

    private fun query(target: String): Map<String, String> = target.substringAfter('?', "")
        .split('&')
        .filter { it.isNotEmpty() }
        .associate {
            val parts = it.split('=', limit = 2)
            URLDecoder.decode(parts[0], Charsets.UTF_8.name()) to URLDecoder.decode(parts.getOrElse(1) { "" }, Charsets.UTF_8.name())
        }

    private fun targetHasBoundedBody(target: String): Boolean =
        target.substringBefore('?') in setOf(
            "/api/localsend/v2/register",
            "/api/localsend/v2/prepare-upload"
        )

    private fun thread(name: String, body: () -> Unit) = Thread(body, name).also { it.isDaemon = true; it.start() }

    companion object {
        private const val MAX_HEADER_LINE = 16 * 1024
        private const val MAX_REQUEST_BYTES = 4L * 1024L * 1024L

        fun sanitizeIncomingName(raw: String): String {
            val name = raw.substringAfterLast('/').substringAfterLast('\\')
                .replace(Regex("[\\\\/:*?\"<>|]"), "_")
                .filterNot(Char::isISOControl)
                .trim().trim('.')
            return name.ifBlank { "received-file" }
        }

        private fun uniqueTarget(root: File, displayName: String): File {
            val safe = sanitizeIncomingName(displayName)
            var target = File(root, safe)
            var index = 1
            while (target.exists()) {
                val base = safe.substringBeforeLast('.', safe)
                val extension = safe.substringAfterLast('.', "").takeIf { it != safe }
                target = File(root, if (extension == null) "$base ($index)" else "$base ($index).$extension")
                index += 1
            }
            return target
        }

        private fun MessageDigest.hex(): String = digest().joinToString("") { "%02x".format(it) }
    }
}
