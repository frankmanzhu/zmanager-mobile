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
import org.tzap.zmanager.mobile.bridge.generated.CreateArchiveFormat
import org.tzap.zmanager.mobile.bridge.generated.ZmanagerGuiException

/**
 * Archive-folder repackaging state: composes staged extraction with the
 * create planner. Reads the current archive through [session] and the
 * output format/password/volume-size choice through [creation] rather than
 * duplicating them — repackaging always writes using whatever format the
 * create panel currently has selected. See Track 7 in
 * docs/mobile-code-health-remediation-plan.md.
 */
class ArchiveRepackagingViewModel(
    context: Context,
    private val session: ArchiveSessionViewModel,
    private val extraction: ArchiveExtractionViewModel,
    private val creation: ArchiveCreationViewModel
) : ViewModel() {
    val repackagingCoordinator = ArchiveRepackagingCoordinator(
        context,
        extraction.extractionCoordinator,
        creation.creationCoordinator
    )

    val repackagingStateState: MutableState<ArchiveRepackagingUiState> = mutableStateOf(ArchiveRepackagingUiState.Idle)
    var repackagingState by repackagingStateState

    val repackagingPasswordInputState: MutableState<String> = mutableStateOf("")
    var repackagingPasswordInput by repackagingPasswordInputState

    val repackagingSelectedEntriesState: MutableState<List<ArchiveEntrySummary>> = mutableStateOf(emptyList())
    var repackagingSelectedEntries by repackagingSelectedEntriesState

    fun clearTransientSecrets() {
        repackagingPasswordInput = ""
    }

    fun startRepackaging(entries: List<ArchiveEntrySummary>, sourcePassword: String? = null) {
        val archive = session.importedArchive ?: return
        repackagingSelectedEntries = entries
        // Repackaging requires an explicit source selection. An empty list is
        // reserved by extraction for "the whole archive", which would make
        // the repackaging coordinator reject a deliberate whole-archive pick.
        val selectedPaths = entries.map { it.path }
        val outputName = when (creation.createFormat) {
            CreateArchiveFormat.ZIP -> "repackaged.zip"
            CreateArchiveFormat.SEVEN_Z -> "repackaged.7z"
            CreateArchiveFormat.TAR_ZST -> "repackaged.tar.zst"
            CreateArchiveFormat.TAR_GZ -> "repackaged.tar.gz"
            CreateArchiveFormat.TZAP -> "repackaged.tzap"
            CreateArchiveFormat.APPLE_ARCHIVE -> "repackaged.aar"
        }
        repackagingState = ArchiveRepackagingUiState.Planning
        val volumeSize = runCatching { ArchiveVolumeSupport.parseVolumeSize(creation.createVolumeSizeInput) }
            .getOrElse { error ->
                repackagingState = ArchiveRepackagingUiState.Failed(error.message ?: "Invalid split volume size.")
                return
            }
        viewModelScope.launch {
            val planned = withContext(Dispatchers.IO) {
                runCatching {
                    repackagingCoordinator.plan(
                        ArchiveRepackagingRequest(
                            sourceArchive = archive,
                            selectedPaths = selectedPaths,
                            destinationArchivePath = creation.outputPath(outputName),
                            format = creation.createFormat,
                            volumeSize = volumeSize,
                            sourcePassword = sourcePassword ?: repackagingPasswordInput.takeIf { it.isNotEmpty() },
                            destinationPassword = creation.createPasswordInput.takeIf { it.isNotEmpty() }
                        )
                    )
                }
            }
            planned.onSuccess { review ->
                repackagingState = ArchiveRepackagingUiState.Review(review)
            }.onFailure { error ->
                if (error is ZmanagerGuiException.Bridge &&
                    (error.code == "password_required" || error.code == "invalid_password")
                ) {
                    repackagingState = ArchiveRepackagingUiState.PasswordRequired(entries, error.userMessage)
                } else {
                    repackagingState = ArchiveRepackagingUiState.Failed(
                        error.message ?: "Unable to repackage the selection."
                    )
                }
            }
        }
    }

    fun runRepackaging(review: ArchiveRepackagingReview) {
        repackagingState = ArchiveRepackagingUiState.Running(review, "Repackaging selected entries")
        viewModelScope.launch {
            val outcome = withContext(Dispatchers.IO) {
                repackagingCoordinator.run(review) { message ->
                    viewModelScope.launch { repackagingState = ArchiveRepackagingUiState.Running(review, message) }
                }
            }
            repackagingState = when (outcome) {
                is ArchiveRepackagingOutcome.Completed -> ArchiveRepackagingUiState.Completed(outcome)
                ArchiveRepackagingOutcome.Cancelled -> ArchiveRepackagingUiState.Cancelled
                is ArchiveRepackagingOutcome.PasswordRequired -> ArchiveRepackagingUiState.PasswordRequired(
                    repackagingSelectedEntries,
                    outcome.message
                )
                is ArchiveRepackagingOutcome.Failed -> ArchiveRepackagingUiState.Failed(outcome.message)
            }
            session.passwordInput = ""
            creation.createPasswordInput = ""
            repackagingPasswordInput = ""
        }
    }

    class Factory(
        private val context: Context,
        private val session: ArchiveSessionViewModel,
        private val extraction: ArchiveExtractionViewModel,
        private val creation: ArchiveCreationViewModel
    ) : ViewModelProvider.Factory {
        @Suppress("UNCHECKED_CAST")
        override fun <T : ViewModel> create(modelClass: Class<T>): T =
            ArchiveRepackagingViewModel(context, session, extraction, creation) as T
    }
}
