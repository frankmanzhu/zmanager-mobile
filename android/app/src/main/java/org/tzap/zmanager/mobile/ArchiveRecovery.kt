package org.tzap.zmanager.mobile

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.UUID

/**
 * Native-only recovery metadata for a failed destination commit. It contains
 * no password, bridge token, provider credential, or raw provider URI.
 */
data class ArchiveRecoveryRecord(
    val id: String,
    val archivePath: String,
    val archiveDisplayName: String,
    val selectedPaths: List<String>,
    val stagingRoot: String,
    val destinationLabel: String,
    val message: String,
    val createdAtMillis: Long
)

class ArchiveRecoveryStore(private val context: Context) {
    private val recordsRoot = File(context.filesDir, "ArchiveRecovery")

    fun save(
        archive: ImportedArchive,
        selectedPaths: List<String>,
        stagingRoot: File,
        destinationLabel: String,
        message: String
    ): ArchiveRecoveryRecord {
        require(isInside(context.cacheDir, stagingRoot)) { "Recovery staging must remain app-owned." }
        check(recordsRoot.mkdirs() || recordsRoot.isDirectory) { "Unable to prepare recovery records." }
        val record = ArchiveRecoveryRecord(
            id = UUID.randomUUID().toString(),
            archivePath = archive.localPath,
            archiveDisplayName = archive.displayName,
            selectedPaths = selectedPaths,
            stagingRoot = stagingRoot.canonicalPath,
            destinationLabel = destinationLabel,
            message = message,
            createdAtMillis = System.currentTimeMillis()
        )
        fileFor(record.id).writeText(JSONObject().apply {
            put("id", record.id)
            put("archivePath", record.archivePath)
            put("archiveDisplayName", record.archiveDisplayName)
            put("selectedPaths", JSONArray(record.selectedPaths))
            put("stagingRoot", record.stagingRoot)
            put("destinationLabel", record.destinationLabel)
            put("message", record.message)
            put("createdAtMillis", record.createdAtMillis)
            put("redaction", "Passwords, bridge tokens, and provider credentials are never included.")
        }.toString(2))
        return record
    }

    fun records(nowMillis: Long = System.currentTimeMillis()): List<ArchiveRecoveryRecord> {
        cleanupExpired(nowMillis)
        return recordsRoot.listFiles { file -> file.extension == "json" }
            ?.mapNotNull(::read)
            ?.sortedByDescending { it.createdAtMillis }
            ?: emptyList()
    }

    fun discard(id: String) {
        val record = read(fileFor(id)) ?: return
        val staging = File(record.stagingRoot)
        if (isInside(context.cacheDir, staging)) staging.deleteRecursively()
        fileFor(id).delete()
    }

    fun files(id: String): List<File> {
        val record = read(fileFor(id)) ?: return emptyList()
        val root = File(record.stagingRoot)
        if (!isInside(context.cacheDir, root) || !root.isDirectory) return emptyList()
        return root.walkTopDown().filter { it.isFile }.toList()
    }

    fun cleanupExpired(nowMillis: Long = System.currentTimeMillis()) {
        recordsRoot.listFiles { file -> file.extension == "json" }
            ?.mapNotNull(::read)
            ?.filter { nowMillis - it.createdAtMillis > RETENTION_MILLIS }
            ?.forEach { discard(it.id) }
    }

    private fun fileFor(id: String): File {
        require(id.matches(Regex("[A-Za-z0-9-]{8,}"))) { "Invalid recovery id." }
        return File(recordsRoot, "$id.json")
    }

    private fun read(file: File): ArchiveRecoveryRecord? = runCatching {
        val json = JSONObject(file.readText())
        val paths = json.getJSONArray("selectedPaths")
        ArchiveRecoveryRecord(
            id = json.getString("id"),
            archivePath = json.getString("archivePath"),
            archiveDisplayName = json.getString("archiveDisplayName"),
            selectedPaths = List(paths.length()) { paths.getString(it) },
            stagingRoot = json.getString("stagingRoot"),
            destinationLabel = json.getString("destinationLabel"),
            message = json.getString("message"),
            createdAtMillis = json.getLong("createdAtMillis")
        )
    }.getOrNull()

    private fun isInside(root: File, child: File): Boolean {
        val rootPath = root.canonicalFile.toPath()
        return child.canonicalFile.toPath().startsWith(rootPath)
    }

    companion object {
        private const val RETENTION_MILLIS = 7L * 24L * 60L * 60L * 1000L
    }
}
