package org.tzap.zmanager.mobile

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.util.UUID

data class ImportedArchive(
    val id: String,
    val displayName: String,
    val localPath: String,
    val byteSize: Long?,
    val sourceMimeType: String?,
    val importedAtEpochMillis: Long
)

class ArchiveImporter(context: Context) {
    private val appContext = context.applicationContext

    @Throws(IOException::class)
    fun importUri(uri: Uri): ImportedArchive {
        val resolver = appContext.contentResolver
        val metadata = ArchiveImportMetadata.fromUri(appContext, uri)
        val displayName = ArchiveImportNames.sanitizedDisplayName(metadata.displayName ?: uri.lastPathSegment)
        val importRoot = File(appContext.cacheDir, "imported-archives").also { root ->
            if (!root.exists() && !root.mkdirs()) {
                throw IOException("Unable to create archive import cache.")
            }
        }
        val destination = File(importRoot, "${UUID.randomUUID()}-$displayName")

        try {
            resolver.openInputStream(uri)?.use { input ->
                FileOutputStream(destination).use { output ->
                    input.copyTo(output)
                }
            } ?: throw IOException("Unable to open selected archive.")
        } catch (error: IOException) {
            destination.delete()
            throw error
        }

        return ImportedArchive(
            id = UUID.randomUUID().toString(),
            displayName = displayName,
            localPath = destination.absolutePath,
            byteSize = destination.length().takeIf { it >= 0 },
            sourceMimeType = metadata.mimeType,
            importedAtEpochMillis = System.currentTimeMillis()
        )
    }
}

object ArchiveImportIntents {
    fun firstArchiveUri(intent: Intent): Uri? {
        return when (intent.action) {
            Intent.ACTION_VIEW -> intent.data ?: intent.firstClipUri()
            Intent.ACTION_SEND -> intent.streamUri() ?: intent.data ?: intent.firstClipUri()
            else -> null
        }
    }

    private fun Intent.streamUri(): Uri? {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            @Suppress("DEPRECATION")
            getParcelableExtra(Intent.EXTRA_STREAM) as? Uri
        }
    }

    private fun Intent.firstClipUri(): Uri? = clipData?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.uri
}

object ArchiveImportNames {
    private val unsafeCharacters = Regex("""[\\/:*?"<>|]""")
    private val whitespace = Regex("""\s+""")

    fun sanitizedDisplayName(rawName: String?): String {
        val leafName = rawName
            ?.substringAfterLast('/')
            ?.substringAfterLast('\\')
            .orEmpty()
        val cleaned = leafName
            .replace(unsafeCharacters, "_")
            .filterNot { it.isISOControl() }
            .replace(whitespace, " ")
            .trim()
            .trim('.')
            .take(120)

        return cleaned.takeUnless { it.isBlank() || it == "." || it == ".." } ?: "archive"
    }
}

private data class ArchiveImportMetadata(
    val displayName: String?,
    val mimeType: String?
) {
    companion object {
        fun fromUri(context: Context, uri: Uri): ArchiveImportMetadata {
            var displayName: String? = null
            context.contentResolver.query(
                uri,
                arrayOf(OpenableColumns.DISPLAY_NAME),
                null,
                null,
                null
            )?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (nameIndex >= 0 && !cursor.isNull(nameIndex)) {
                        displayName = cursor.getString(nameIndex)
                    }
                }
            }

            return ArchiveImportMetadata(
                displayName = displayName,
                mimeType = context.contentResolver.getType(uri)
            )
        }
    }
}
