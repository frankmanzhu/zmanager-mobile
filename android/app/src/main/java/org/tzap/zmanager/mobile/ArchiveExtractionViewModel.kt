package org.tzap.zmanager.mobile

import android.content.Context
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
import org.tzap.zmanager.mobile.bridge.generated.ExtractionCollisionPolicy
import org.tzap.zmanager.mobile.bridge.generated.ZmanagerGuiException

sealed interface ArchiveExtractionUiState {
    data object Idle : ArchiveExtractionUiState
    data class Planning(val destination: String) : ArchiveExtractionUiState
    data class Review(val review: ExtractionReview) : ArchiveExtractionUiState
    data class Starting(val review: ExtractionReview) : ArchiveExtractionUiState
    data class Running(val review: ExtractionReview, val jobId: String, val message: String) : ArchiveExtractionUiState
    data class Completed(val outcome: ExtractionOutcome.Completed) : ArchiveExtractionUiState
    data object Cancelled : ArchiveExtractionUiState
    data class PasswordRequired(val message: String) : ArchiveExtractionUiState
    data class Failed(val message: String) : ArchiveExtractionUiState
    data class RecoveryAvailable(val recoveryId: String, val message: String) : ArchiveExtractionUiState
}

/**
 * Single-archive extraction state and the job handoff to the foreground
 * service. Reads the current archive through [session]. See Track 7 in
 * docs/mobile-code-health-remediation-plan.md.
 */
class ArchiveExtractionViewModel(
    context: Context,
    private val session: ArchiveSessionViewModel
) : ViewModel() {
    val extractionCoordinator = ArchiveExtractionCoordinator(context)

    val extractionStateState: MutableState<ArchiveExtractionUiState> = mutableStateOf(ArchiveExtractionUiState.Idle)
    var extractionState by extractionStateState

    val extractionPasswordInputState: MutableState<String> = mutableStateOf("")
    var extractionPasswordInput by extractionPasswordInputState

    fun clearTransientSecrets() {
        extractionPasswordInput = ""
    }

    fun clearExtractionState() {
        (extractionState as? ArchiveExtractionUiState.Review)?.review?.let(extractionCoordinator::discard)
        extractionState = ArchiveExtractionUiState.Idle
        extractionPasswordInput = ""
    }

    fun planExtraction(
        archive: ImportedArchive,
        entries: List<ArchiveEntrySummary>,
        destination: ExtractionDestination,
        password: String?,
        pacer: JobPacer = session.debugJobPacer
    ) {
        clearExtractionState()
        val selectedPaths = session.extractionSelectedPaths(entries)
        extractionState = ArchiveExtractionUiState.Planning(destination.label)
        viewModelScope.launch {
            val result = withContext(Dispatchers.IO) {
                runCatching {
                    extractionCoordinator.plan(
                        archive = archive,
                        // An empty selection means every entry. Preserve that
                        // contract so full extraction uses the engine's
                        // whole-archive operation instead of selected-entry
                        // calls.
                        selectedPaths = selectedPaths,
                        destination = destination,
                        password = password,
                        collisionPolicy = ExtractionCollisionPolicy.REFUSE,
                        pacer = pacer
                    )
                }
            }
            extractionState = result.fold(
                onSuccess = { review ->
                    if (review.plan.canStart) ArchiveExtractionUiState.Review(review)
                    else ArchiveExtractionUiState.Failed(
                        review.plan.warnings.firstOrNull()?.message
                            ?: "This extraction plan cannot be started."
                    )
                },
                onFailure = { it.toExtractionUiState() }
            )
        }
    }

    fun startExtraction(review: ExtractionReview, context: Context) {
        extractionState = ArchiveExtractionUiState.Starting(review)
        session.debugJobPacer = NoOpJobPacer
        val request = review.request
        if (request == null) {
            extractionState = ArchiveExtractionUiState.Failed("This extraction review cannot be resumed.")
            extractionCoordinator.discard(review)
            return
        }
        runCatching {
            val token = ArchiveJobForegroundService.submit(
                context,
                ArchiveForegroundRequest.Extract(request)
            )
            extractionCoordinator.discard(review)
            // Keep the password out of long-lived state once the foreground
            // service owns the request.
            val stateReview = review.copy(request = request.copy(password = null))
            extractionState = ArchiveExtractionUiState.Running(stateReview, token, "Extracting archive")
        }.onFailure { error ->
            extractionCoordinator.discard(review)
            extractionState = error.toExtractionUiState()
        }
    }

    class Factory(
        private val context: Context,
        private val session: ArchiveSessionViewModel
    ) : ViewModelProvider.Factory {
        @Suppress("UNCHECKED_CAST")
        override fun <T : ViewModel> create(modelClass: Class<T>): T =
            ArchiveExtractionViewModel(context, session) as T
    }
}

private fun Throwable.toExtractionUiState(): ArchiveExtractionUiState = when (this) {
    is ZmanagerGuiException.Bridge -> if (code == "password_required" || code == "invalid_password") {
        ArchiveExtractionUiState.PasswordRequired(userMessage)
    } else {
        ArchiveExtractionUiState.Failed(userMessage)
    }
    else -> ArchiveExtractionUiState.Failed(message ?: "Unable to extract that archive.")
}
