package org.tzap.zmanager.mobile

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
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
        return importUris(listOf(uri))
    }

    @Throws(IOException::class)
    fun importUris(uris: List<Uri>): ImportedArchive {
        val resolver = appContext.contentResolver
        val inputs = uris.map { uri ->
            val metadata = ArchiveImportMetadata.fromUri(appContext, uri)
            ArchiveImportInput(
                displayName = metadata.displayName ?: uri.lastPathSegment,
                sourceMimeType = metadata.mimeType
            ) {
                resolver.openInputStream(uri) ?: throw IOException("Unable to open selected archive.")
            }
        }
        return importGroup(inputs)
    }

    @Throws(IOException::class)
    fun importAsset(assetName: String): ImportedArchive {
        return importAssets(assetName, listOf(assetName))
    }

    @Throws(IOException::class)
    fun importAssets(
        primaryAssetName: String,
        assetNames: List<String>,
        displayNames: List<String> = assetNames
    ): ImportedArchive {
        require(assetNames.size == displayNames.size) { "Asset and display name counts must match." }
        val inputs = assetNames.zip(displayNames).map { (assetName, displayName) ->
            ArchiveImportInput(displayName, null) {
                appContext.assets.open(assetName)
            }
        }
        return importGroup(inputs, primaryName = displayNames.first())
    }

    @Throws(IOException::class)
    private fun importGroup(
        inputs: List<ArchiveImportInput>,
        primaryName: String? = null
    ): ImportedArchive {
        if (inputs.isEmpty()) {
            throw IOException("Select an archive before importing.")
        }
        val sanitizedNames = inputs.map { ArchiveImportNames.sanitizedDisplayName(it.displayName) }
        if (sanitizedNames.toSet().size != sanitizedNames.size) {
            throw IOException("Selected archive volumes have conflicting names.")
        }
        val selectedPrimaryName = primaryName?.let(ArchiveImportNames::sanitizedDisplayName)
            ?: ArchiveImportNames.primaryArchiveName(sanitizedNames)
            ?: sanitizedNames.first()
        val primaryIndex = sanitizedNames.indexOf(selectedPrimaryName)
        if (primaryIndex < 0) {
            throw IOException("The selected primary archive volume is missing.")
        }
        val importRoot = File(appContext.cacheDir, "imported-archives").also { root ->
            if (!root.exists() && !root.mkdirs()) {
                throw IOException("Unable to create archive import cache.")
            }
        }
        val importGroup = File(importRoot, UUID.randomUUID().toString())
        if (!importGroup.mkdirs()) {
            throw IOException("Unable to create archive import cache.")
        }

        try {
            inputs.zip(sanitizedNames).forEach { (input, name) ->
                FileOutputStream(File(importGroup, name)).use { output ->
                    input.openInputStream().use { stream ->
                        stream.copyTo(output)
                    }
                }
            }
        } catch (error: IOException) {
            importGroup.deleteRecursively()
            throw error
        }
        val destination = File(importGroup, sanitizedNames[primaryIndex])

        return ImportedArchive(
            id = UUID.randomUUID().toString(),
            displayName = sanitizedNames[primaryIndex],
            localPath = destination.absolutePath,
            byteSize = destination.length().takeIf { it >= 0 },
            sourceMimeType = inputs[primaryIndex].sourceMimeType,
            importedAtEpochMillis = System.currentTimeMillis()
        )
    }
}

private data class ArchiveImportInput(
    val displayName: String?,
    val sourceMimeType: String?,
    val openInputStream: () -> InputStream
)

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

enum class ArchiveAutomationAction { OPEN, EXTRACT, CREATE, VERIFY }

data class ArchiveAutomationRequest(
    val action: ArchiveAutomationAction,
    val archiveUri: Uri? = null,
    val sourceUris: List<Uri> = emptyList()
)

/** Parses only explicit, password-free automation requests. */
object ArchiveAutomationIntents {
    fun parse(intent: Intent): ArchiveAutomationRequest? = intent.data?.let(::parse)

    fun parse(uri: Uri): ArchiveAutomationRequest {
        require(uri.scheme.equals("zmanager", ignoreCase = true)) { "Unsupported automation scheme." }
        val action = when (uri.host?.lowercase()) {
            "open" -> ArchiveAutomationAction.OPEN
            "extract" -> ArchiveAutomationAction.EXTRACT
            "create" -> ArchiveAutomationAction.CREATE
            "verify" -> ArchiveAutomationAction.VERIFY
            else -> throw IllegalArgumentException("Unsupported automation action.")
        }
        uri.queryParameterNames.forEach { key ->
            require(key.lowercase() !in setOf("password", "pass", "secret", "token", "pin")) {
                "Passwords and credentials are not accepted by automation."
            }
        }
        return when (action) {
            ArchiveAutomationAction.CREATE -> {
                val files = uri.getQueryParameter("files")
                    ?.split('|')
                    ?.filter(String::isNotBlank)
                    ?.map(Uri::parse)
                    .orEmpty()
                require(files.isNotEmpty()) { "Create automation requires files." }
                require(files.all { it.scheme in setOf("content", "file") }) {
                    "Create automation accepts only local provider URIs."
                }
                ArchiveAutomationRequest(action, sourceUris = files)
            }
            else -> {
                val archive = uri.getQueryParameter("archive")?.let(Uri::parse)
                require(archive != null && archive.scheme in setOf("content", "file")) {
                    "Archive automation requires a local archive URI."
                }
                ArchiveAutomationRequest(action, archiveUri = archive)
            }
        }
    }
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

    fun primaryArchiveName(names: List<String>): String? {
        return names.firstOrNull { it.endsWith(".vol000.tzap", ignoreCase = true) }
            ?: names.firstOrNull { it.matches(Regex("(?i).+\\.part1\\.rar")) }
            ?: names.firstOrNull { it.matches(Regex("(?i).+\\.7z\\.001")) }
            ?: names.firstOrNull { it.endsWith(".zip", ignoreCase = true) }
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
