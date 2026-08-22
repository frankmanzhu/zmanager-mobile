package org.tzap.zmanager.mobile

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.webkit.MimeTypeMap
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.core.content.FileProvider
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.util.Locale

/**
 * Listing browser state: search/sort/view-mode, selection, and the preview
 * and test panels. Reads the current archive and listing through
 * [session] rather than duplicating them. See Track 7 in
 * docs/mobile-code-health-remediation-plan.md.
 */
class ArchiveListingViewModel(private val session: ArchiveSessionViewModel) : ViewModel() {
    val entrySortState: MutableState<ArchiveEntrySort> = mutableStateOf(ArchiveEntrySort.PATH_ASCENDING)
    var entrySort by entrySortState

    val entryViewModeState: MutableState<ArchiveEntryViewMode> = mutableStateOf(ArchiveEntryViewMode.FOLDERS)
    var entryViewMode by entryViewModeState

    val previewStateState: MutableState<ArchivePreviewState> = mutableStateOf(ArchivePreviewState.Idle)
    var previewState by previewStateState

    val previewPasswordInputState: MutableState<String> = mutableStateOf("")
    var previewPasswordInput by previewPasswordInputState
    private var previewRequestId by mutableStateOf(0L)

    val testStateState: MutableState<ArchiveTestState> = mutableStateOf(ArchiveTestState.Idle)
    var testState by testStateState

    val testPasswordInputState: MutableState<String> = mutableStateOf("")
    var testPasswordInput by testPasswordInputState
    private var testRequestId by mutableStateOf(0L)

    // How many of the filtered/sorted entries are rendered. Raised by
    // "Load more"; reset whenever a new listing loads or the search settles
    // on a new value, so a stale huge window doesn't carry over into an
    // unrelated view. See Track 3 in docs/mobile-code-health-remediation-plan.md.
    val listingWindowSizeState: MutableState<Int> = mutableStateOf(DEFAULT_LISTING_WINDOW_SIZE)
    var listingWindowSize by listingWindowSizeState

    fun loadMoreListingEntries() {
        listingWindowSize += LISTING_WINDOW_PAGE_SIZE
    }

    fun resetListingWindow() {
        listingWindowSize = DEFAULT_LISTING_WINDOW_SIZE
    }

    fun clearTransientSecrets() {
        previewPasswordInput = ""
        testPasswordInput = ""
    }

    fun clearPreviewState() {
        cleanupPreview(previewState)
        previewState = ArchivePreviewState.Idle
        previewPasswordInput = ""
        previewRequestId += 1
    }

    fun clearTestState() {
        testState = ArchiveTestState.Idle
        testPasswordInput = ""
        testRequestId += 1
    }

    fun onListingLoadStarted() {
        clearPreviewState()
        clearTestState()
        resetListingWindow()
    }

    fun startPreview(archive: ImportedArchive, entry: ArchiveEntrySummary, password: String?, context: Context) {
        previewRequestId += 1
        val currentPreviewRequestId = previewRequestId
        cleanupPreview(previewState)
        previewState = ArchivePreviewState.Loading(entry)
        previewPasswordInput = ""
        viewModelScope.launch {
            val result = withContext(Dispatchers.IO) {
                session.listingRepository.materializePreview(archive, entry, password)
            }
            if (currentPreviewRequestId == previewRequestId && session.importedArchive?.id == archive.id) {
                previewState = result
                if (result is ArchivePreviewState.Ready) {
                    openPreview(context, result.summary)?.let { error ->
                        previewState = ArchivePreviewState.Failed(result.summary.entry, error)
                    }
                }
            }
        }
    }

    fun startArchiveTest(
        archive: ImportedArchive,
        selectedEntries: List<ArchiveEntrySummary>,
        password: String?
    ) {
        testRequestId += 1
        val currentTestRequestId = testRequestId
        testState = ArchiveTestState.Loading(selectedEntries.size)
        testPasswordInput = ""
        viewModelScope.launch {
            val result = withContext(Dispatchers.IO) {
                session.listingRepository.testArchive(archive, selectedEntries, password)
            }
            if (currentTestRequestId == testRequestId && session.importedArchive?.id == archive.id) {
                testState = result
            }
        }
    }

    class Factory(private val session: ArchiveSessionViewModel) : ViewModelProvider.Factory {
        @Suppress("UNCHECKED_CAST")
        override fun <T : ViewModel> create(modelClass: Class<T>): T =
            ArchiveListingViewModel(session) as T
    }
}

private fun openPreview(
    context: Context,
    preview: ArchivePreviewSummary
): ArchiveListingError? {
    return try {
        val file = File(preview.previewPath)
        if (!file.isFile) {
            return ArchiveListingError(
                code = "preview_unavailable",
                message = "The preview file is not available.",
                recoveryHint = null,
                retryable = false
            )
        }
        val uri = FileProvider.getUriForFile(
            context,
            "${context.packageName}.fileprovider",
            file
        )
        val intent = Intent(Intent.ACTION_VIEW)
            .setDataAndType(uri, preview.entry.path.previewMimeType())
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        context.startActivity(Intent.createChooser(intent, "Preview ${preview.entry.displayName}"))
        null
    } catch (error: ActivityNotFoundException) {
        ArchiveListingError(
            code = "preview_unavailable",
            message = "No installed app can preview that file.",
            recoveryHint = null,
            retryable = false
        )
    } catch (error: IllegalArgumentException) {
        ArchiveListingError(
            code = "preview_unavailable",
            message = "Unable to share the preview file with another app.",
            recoveryHint = null,
            retryable = false
        )
    } catch (error: RuntimeException) {
        ArchiveListingError(
            code = "preview_unavailable",
            message = "Unable to open that preview.",
            recoveryHint = null,
            retryable = false
        )
    }
}

private const val DEFAULT_LISTING_WINDOW_SIZE = 200
private const val LISTING_WINDOW_PAGE_SIZE = 200

private fun String.previewMimeType(): String {
    val extension = substringAfterLast('.', missingDelimiterValue = "")
        .lowercase(Locale.ROOT)
    return MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension)
        ?: "application/octet-stream"
}

private fun cleanupPreview(state: ArchivePreviewState) {
    val cleanupRoot = (state as? ArchivePreviewState.Ready)?.summary?.cleanupRoot ?: return
    runCatching {
        File(cleanupRoot).deleteRecursively()
    }
}
