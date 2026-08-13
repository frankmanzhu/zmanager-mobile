package org.tzap.zmanager.mobile

import android.content.Context
import android.net.Uri
import java.io.File

/** Stores only native destination handles; Rust never receives these values. */
class ArchiveDestinationPreferences(context: Context) {
    private val appContext = context.applicationContext
    private val preferences = appContext.getSharedPreferences(NAME, Context.MODE_PRIVATE)

    fun defaultExtractionDestination(): ExtractionDestination {
        val rawUri = preferences.getString(EXTRACTION_TREE_URI, null)
        if (rawUri != null) {
            val uri = Uri.parse(rawUri)
            val persisted = appContext.contentResolver.persistedUriPermissions.any {
                it.uri == uri && it.isWritePermission
            }
            if (persisted) return ExtractionDestination.DocumentTree(uri)
            resetExtractionDestination()
        }
        return ExtractionDestination.AppStorage(File(appContext.filesDir, "Extracted"))
    }

    fun setExtractionDestination(destination: ExtractionDestination) {
        when (destination) {
            is ExtractionDestination.DocumentTree -> preferences.edit()
                .putString(EXTRACTION_TREE_URI, destination.uri.toString())
                .apply()
            is ExtractionDestination.AppStorage -> resetExtractionDestination()
        }
    }

    fun resetExtractionDestination() {
        preferences.edit().remove(EXTRACTION_TREE_URI).apply()
    }

    companion object {
        private const val NAME = "archive_destination_preferences"
        private const val EXTRACTION_TREE_URI = "default_extraction_tree_uri"
    }
}
