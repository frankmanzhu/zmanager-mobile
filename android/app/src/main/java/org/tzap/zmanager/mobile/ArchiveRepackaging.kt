package org.tzap.zmanager.mobile

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.tzap.zmanager.mobile.bridge.generated.ExtractionCollisionPolicy
import org.tzap.zmanager.mobile.bridge.generated.CreateArchiveFormat
import java.io.File
import java.util.UUID

data class ArchiveRepackagingRequest(
    val sourceArchive: ImportedArchive,
    val selectedPaths: List<String>,
    val destinationArchivePath: String,
    val format: CreateArchiveFormat,
    val sourcePassword: String? = null,
    val destinationPassword: String? = null,
    val verifyAfterCreate: Boolean = true
)

data class ArchiveRepackagingReview(
    val id: String,
    val request: ArchiveRepackagingRequest,
    val extractionReview: ExtractionReview
)

sealed interface ArchiveRepackagingOutcome {
    data class Completed(val outputPath: String, val verified: Boolean) : ArchiveRepackagingOutcome
    data object Cancelled : ArchiveRepackagingOutcome
    data class Failed(val message: String) : ArchiveRepackagingOutcome
}

sealed interface ArchiveRepackagingUiState {
    data object Idle : ArchiveRepackagingUiState
    data object Planning : ArchiveRepackagingUiState
    data class Running(val review: ArchiveRepackagingReview, val message: String) : ArchiveRepackagingUiState
    data class Completed(val outcome: ArchiveRepackagingOutcome.Completed) : ArchiveRepackagingUiState
    data object Cancelled : ArchiveRepackagingUiState
    data class Failed(val message: String) : ArchiveRepackagingUiState
}

/**
 * Composes the existing Rust extraction and creation jobs. The intermediate tree
 * is private app storage and is never presented as the user's final destination.
 */
class ArchiveRepackagingCoordinator(
    private val context: android.content.Context,
    private val extraction: ArchiveExtractionCoordinator = ArchiveExtractionCoordinator(context),
    private val creation: ArchiveCreationCoordinator = ArchiveCreationCoordinator(context)
) {
    private data class Session(
        val request: ArchiveRepackagingRequest,
        val stagingRoot: File,
        @Volatile var activeJobId: String? = null,
        @Volatile var cancelRequested: Boolean = false
    )
    private val sessions = mutableMapOf<String, Session>()

    fun plan(request: ArchiveRepackagingRequest): ArchiveRepackagingReview {
        require(request.selectedPaths.isNotEmpty()) { "Select a folder or entries to repackage." }
        val id = UUID.randomUUID().toString()
        val stagingRoot = File(context.cacheDir, "repackaging/$id/input")
        val extractionReview = extraction.plan(
            archive = request.sourceArchive,
            selectedPaths = request.selectedPaths,
            destination = ExtractionDestination.AppStorage(stagingRoot),
            password = request.sourcePassword,
            collisionPolicy = ExtractionCollisionPolicy.REFUSE
        )
        sessions[id] = Session(request, stagingRoot)
        return ArchiveRepackagingReview(id, request, extractionReview)
    }

    suspend fun run(
        review: ArchiveRepackagingReview,
        onProgress: (String) -> Unit = {}
    ): ArchiveRepackagingOutcome = withContext(Dispatchers.IO) {
        val session = sessions[review.id] ?: return@withContext ArchiveRepackagingOutcome.Failed("The repackaging review expired.")
        try {
            val extractJob = extraction.start(review.extractionReview)
            session.activeJobId = extractJob
            onProgress("Extracting selected archive folder")
            when (val extracted = extraction.awaitCompletion(review.extractionReview, extractJob) { onProgress(it.message) }) {
                ExtractionOutcome.Cancelled -> return@withContext finish(review.id, ArchiveRepackagingOutcome.Cancelled)
                is ExtractionOutcome.Failed -> return@withContext finish(review.id, ArchiveRepackagingOutcome.Failed(extracted.message))
                is ExtractionOutcome.Completed -> Unit
            }
            if (session.cancelRequested) return@withContext finish(review.id, ArchiveRepackagingOutcome.Cancelled)

            val createReview = creation.plan(
                ArchiveCreationRequest(
                    sourcePaths = listOf(session.stagingRoot.absolutePath),
                    destinationArchivePath = session.request.destinationArchivePath,
                    format = session.request.format,
                    password = session.request.destinationPassword,
                    verifyAfterCreate = session.request.verifyAfterCreate
                )
            )
            if (!createReview.plan.canStart) {
                return@withContext finish(
                    review.id,
                    ArchiveRepackagingOutcome.Failed(
                        createReview.plan.warnings.firstOrNull()?.message ?: "The output archive cannot be created."
                    )
                )
            }
            val createJob = creation.start(createReview)
            session.activeJobId = createJob
            onProgress("Creating output archive")
            when (val created = creation.awaitCompletion(createReview, createJob) { onProgress(it.message) }) {
                is ArchiveCreationOutcome.Completed -> finish(
                    review.id,
                    ArchiveRepackagingOutcome.Completed(created.outputPath, created.verified)
                )
                ArchiveCreationOutcome.Cancelled -> finish(review.id, ArchiveRepackagingOutcome.Cancelled)
                is ArchiveCreationOutcome.Failed -> finish(review.id, ArchiveRepackagingOutcome.Failed(created.message))
            }
        } catch (error: Throwable) {
            finish(review.id, ArchiveRepackagingOutcome.Failed(error.message ?: "Archive repackaging failed."))
        }
    }

    fun discard(review: ArchiveRepackagingReview) {
        extraction.discard(review.extractionReview)
        finish(review.id, null)
    }

    fun cancel(review: ArchiveRepackagingReview) {
        val session = sessions[review.id] ?: return
        session.cancelRequested = true
        session.activeJobId?.let { jobId ->
            runCatching { extraction.cancel(jobId) }
        }
    }

    private fun finish(id: String, outcome: ArchiveRepackagingOutcome?): ArchiveRepackagingOutcome {
        val session = sessions.remove(id)
        session?.stagingRoot?.parentFile?.deleteRecursively()
        return outcome ?: ArchiveRepackagingOutcome.Cancelled
    }
}
