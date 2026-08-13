package org.tzap.zmanager.mobile

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.tzap.zmanager.mobile.bridge.generated.ExtractionCollisionPolicy

data class BatchExtractionItem(
    val archive: ImportedArchive,
    val selectedPaths: List<String>,
    val destination: ExtractionDestination,
    val password: String? = null
)

data class BatchExtractionReview(
    val items: List<BatchExtractionItem>,
    val reviews: List<ExtractionReview>
)

data class ArchiveBatchExtractionRequest(val items: List<BatchExtractionItem>)

sealed interface BatchExtractionUiState {
    data object Idle : BatchExtractionUiState
    data object Planning : BatchExtractionUiState
    data class Review(val review: BatchExtractionReview) : BatchExtractionUiState
    data class Running(val token: String) : BatchExtractionUiState
    data class Completed(val message: String) : BatchExtractionUiState
    data object Cancelled : BatchExtractionUiState
    data class Failed(val message: String) : BatchExtractionUiState
}

data class BatchExtractionItemResult(
    val archive: ImportedArchive,
    val status: Status,
    val writtenEntries: ULong = 0u,
    val message: String? = null
) {
    enum class Status { COMPLETED, FAILED, CANCELLED }
}

sealed interface BatchExtractionOutcome {
    data class Completed(val results: List<BatchExtractionItemResult>) : BatchExtractionOutcome
    data class Cancelled(val results: List<BatchExtractionItemResult>) : BatchExtractionOutcome
}

/** Plans and runs multiple independent extraction jobs using the single-job Rust bridge. */
class BatchExtractionCoordinator(
    private val extraction: ArchiveExtractionCoordinator
) {
    private var activeJob: Pair<ExtractionReview, String>? = null
    @Volatile private var cancelRequested = false

    fun plan(items: List<BatchExtractionItem>): BatchExtractionReview {
        require(items.isNotEmpty()) { "Select at least one archive." }
        val reviews = mutableListOf<ExtractionReview>()
        return try {
            items.forEach { item ->
                reviews += extraction.plan(
                    archive = item.archive,
                    selectedPaths = item.selectedPaths,
                    destination = item.destination,
                    password = item.password,
                    collisionPolicy = ExtractionCollisionPolicy.REFUSE
                )
            }
            BatchExtractionReview(items, reviews)
        } catch (error: Throwable) {
            reviews.forEach(extraction::discard)
            throw error
        }
    }

    suspend fun run(
        review: BatchExtractionReview,
        onProgress: (archive: ImportedArchive, message: String) -> Unit = { _, _ -> }
    ): BatchExtractionOutcome = withContext(Dispatchers.IO) {
        cancelRequested = false
        val results = mutableListOf<BatchExtractionItemResult>()
        review.reviews.zip(review.items).forEachIndexed { index, (extractionReview, item) ->
            if (cancelRequested) {
                review.reviews.drop(index).forEach(extraction::discard)
                return@withContext BatchExtractionOutcome.Cancelled(results)
            }
            try {
                val jobId = extraction.start(extractionReview)
                activeJob = extractionReview to jobId
                when (val outcome = extraction.awaitCompletion(extractionReview, jobId) { progress ->
                    onProgress(item.archive, progress.message)
                }) {
                    is ExtractionOutcome.Completed -> results += BatchExtractionItemResult(
                        item.archive,
                        BatchExtractionItemResult.Status.COMPLETED,
                        outcome.writtenEntries
                    )
                    is ExtractionOutcome.Failed -> results += BatchExtractionItemResult(
                        item.archive,
                        BatchExtractionItemResult.Status.FAILED,
                        message = outcome.message
                    )
                    is ExtractionOutcome.RecoveryAvailable -> results += BatchExtractionItemResult(
                        item.archive,
                        BatchExtractionItemResult.Status.FAILED,
                        message = outcome.message
                    )
                    ExtractionOutcome.Cancelled -> {
                        results += BatchExtractionItemResult(item.archive, BatchExtractionItemResult.Status.CANCELLED)
                        review.reviews.drop(index + 1).forEach(extraction::discard)
                        return@withContext BatchExtractionOutcome.Cancelled(results)
                    }
                }
            } catch (error: Throwable) {
                extraction.discard(extractionReview)
                results += BatchExtractionItemResult(
                    item.archive,
                    BatchExtractionItemResult.Status.FAILED,
                    message = error.message ?: "Archive extraction failed."
                )
            } finally {
                activeJob = null
            }
        }
        BatchExtractionOutcome.Completed(results)
    }

    fun cancel() {
        cancelRequested = true
        activeJob?.second?.let(extraction::cancel)
    }

    fun discard(review: BatchExtractionReview) {
        review.reviews.forEach(extraction::discard)
    }
}
