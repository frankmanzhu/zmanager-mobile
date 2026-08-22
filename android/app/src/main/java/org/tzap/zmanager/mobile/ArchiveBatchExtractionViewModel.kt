package org.tzap.zmanager.mobile

import android.content.Context
import android.net.Uri
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

/**
 * Batch (multi-archive) extraction state and the job handoff to the
 * foreground service. See Track 7 in
 * docs/mobile-code-health-remediation-plan.md.
 */
class ArchiveBatchExtractionViewModel(
    context: Context,
    private val importer: ArchiveImporter,
    extractionCoordinator: ArchiveExtractionCoordinator
) : ViewModel() {
    private val appContext = context.applicationContext
    val batchExtractionCoordinator = BatchExtractionCoordinator(extractionCoordinator)

    val batchExtractionStateState: MutableState<BatchExtractionUiState> = mutableStateOf(BatchExtractionUiState.Idle)
    var batchExtractionState by batchExtractionStateState

    fun startBatchImport(uris: List<Uri>) {
        if (uris.isEmpty()) return
        batchExtractionState = BatchExtractionUiState.Planning
        viewModelScope.launch {
            val result = withContext(Dispatchers.IO) {
                runCatching {
                    val root = File(appContext.filesDir, "BatchExtracted")
                    uris.mapIndexed { index, uri ->
                        val archive = importer.importUri(uri)
                        val safeName = archive.displayName
                            .replace(Regex("[\\\\/:*?\"<>|]"), "_")
                            .substringBeforeLast('.', archive.displayName)
                            .ifBlank { "archive-$index" }
                        BatchExtractionItem(
                            archive = archive,
                            selectedPaths = emptyList(),
                            destination = ExtractionDestination.AppStorage(File(root, "$safeName-$index"))
                        )
                    }.let(batchExtractionCoordinator::plan)
                }
            }
            result.onSuccess { review -> batchExtractionState = BatchExtractionUiState.Review(review) }
                .onFailure { error ->
                    batchExtractionState = BatchExtractionUiState.Failed(
                        error.message ?: "Unable to prepare batch extraction."
                    )
                }
        }
    }

    fun startDebugBatchImport() {
        if (!BuildConfig.DEBUG) return
        batchExtractionState = BatchExtractionUiState.Planning
        viewModelScope.launch {
            val result = withContext(Dispatchers.IO) {
                runCatching {
                    val root = File(appContext.filesDir, "BatchExtracted")
                    val archives = listOf(
                        importer.importAsset("maestro-nested.zip"),
                        importer.importAsset("maestro-nested.zip")
                    )
                    batchExtractionCoordinator.plan(
                        archives.mapIndexed { index, archive ->
                            BatchExtractionItem(
                                archive,
                                emptyList(),
                                ExtractionDestination.AppStorage(File(root, "fixture-$index"))
                            )
                        }
                    )
                }
            }
            result.onSuccess { batchExtractionState = BatchExtractionUiState.Review(it) }
                .onFailure { batchExtractionState = BatchExtractionUiState.Failed("Unable to prepare batch fixture.") }
        }
    }

    fun startBatchExtraction(review: BatchExtractionReview, context: Context) {
        runCatching {
            val token = ArchiveJobForegroundService.submit(
                context,
                ArchiveForegroundRequest.BatchExtract(
                    ArchiveBatchExtractionRequest(review.items)
                )
            )
            batchExtractionCoordinator.discard(review)
            batchExtractionState = BatchExtractionUiState.Running(token)
        }.onFailure { error ->
            batchExtractionCoordinator.discard(review)
            batchExtractionState = BatchExtractionUiState.Failed(
                error.message ?: "Unable to start batch extraction."
            )
        }
    }

    class Factory(
        private val context: Context,
        private val importer: ArchiveImporter,
        private val extractionCoordinator: ArchiveExtractionCoordinator
    ) : ViewModelProvider.Factory {
        @Suppress("UNCHECKED_CAST")
        override fun <T : ViewModel> create(modelClass: Class<T>): T =
            ArchiveBatchExtractionViewModel(context, importer, extractionCoordinator) as T
    }
}
