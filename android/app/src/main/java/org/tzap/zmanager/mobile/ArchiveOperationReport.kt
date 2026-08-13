package org.tzap.zmanager.mobile

import android.content.Context
import org.json.JSONObject
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

data class ArchiveOperationReport(
    val operation: String,
    val subject: String,
    val status: String,
    val message: String,
    val destination: String? = null,
    val entries: ULong? = null,
    val verified: Boolean? = null
)

/** Explicit user-save action for a redacted, durable operation summary. */
object ArchiveOperationReportStore {
    fun save(context: Context, report: ArchiveOperationReport): File {
        val root = File(context.filesDir, "OperationReports")
        check(root.mkdirs() || root.isDirectory) { "Unable to prepare operation reports." }
        val timestamp = SimpleDateFormat("yyyyMMdd-HHmmss-SSS", Locale.ROOT).format(Date())
        val file = File(root, "$timestamp-${safe(report.operation)}.json")
        val json = JSONObject().apply {
            put("operation", report.operation)
            put("subject", report.subject)
            put("status", report.status)
            put("message", report.message)
            report.destination?.let { put("destination", it) }
            report.entries?.let { put("entries", it.toString()) }
            report.verified?.let { put("verified", it) }
            put("redaction", "Passwords, transfer tokens, and provider credentials are never included.")
        }
        file.writeText(json.toString(2))
        return file
    }

    private fun safe(value: String): String = value
        .replace(Regex("[^A-Za-z0-9._-]"), "_")
        .trim('_')
        .ifBlank { "operation" }
}
