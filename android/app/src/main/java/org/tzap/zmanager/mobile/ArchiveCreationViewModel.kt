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
import java.io.File

/**
 * Archive-creation state, source staging, and the job handoff to the
 * foreground service. Also owns the coordinators
 * [ArchiveRepackagingViewModel] reuses (creation reuses the create planner
 * after staged extraction), which is why they're exposed rather than kept
 * private. See Track 7 in docs/mobile-code-health-remediation-plan.md.
 */
class ArchiveCreationViewModel(context: Context) : ViewModel() {
    val creationCoordinator = ArchiveCreationCoordinator(context)
    val separateCreationCoordinator = ArchiveSeparateCreationCoordinator(creationCoordinator)
    val creationSourceStager = ArchiveCreationSourceStager(context)

    val creationStateState: MutableState<ArchiveCreationUiState> = mutableStateOf(ArchiveCreationUiState.Idle)
    var creationState by creationStateState

    val createFormatState: MutableState<CreateArchiveFormat> = mutableStateOf(CreateArchiveFormat.ZIP)
    var createFormat by createFormatState

    val createPasswordInputState: MutableState<String> = mutableStateOf("")
    var createPasswordInput by createPasswordInputState

    val createVolumeSizeInputState: MutableState<String> = mutableStateOf("")
    var createVolumeSizeInput by createVolumeSizeInputState

    val createSeparateItemsState: MutableState<Boolean> = mutableStateOf(false)
    var createSeparateItems by createSeparateItemsState

    val stagedCreationSourcesState: MutableState<StagedCreationSources?> = mutableStateOf(null)
    var stagedCreationSources by stagedCreationSourcesState

    fun clearTransientSecrets() {
        createPasswordInput = ""
    }

    fun clearCreationState() {
        when (val state = creationState) {
            is ArchiveCreationUiState.Review -> creationCoordinator.discard(state.review)
            is ArchiveCreationUiState.SeparateReview -> separateCreationCoordinator.discard(state.review)
            else -> Unit
        }
        stagedCreationSources?.let(creationSourceStager::discard)
        stagedCreationSources = null
        creationState = ArchiveCreationUiState.Idle
    }

    /** Absolute path for a new output archive named [name] in app storage. */
    fun outputPath(name: String): String = creationCoordinator.appStorageOutput(name).absolutePath

    fun outputName(format: CreateArchiveFormat = createFormat): String = when (format) {
        CreateArchiveFormat.ZIP -> "archive.zip"
        CreateArchiveFormat.SEVEN_Z -> "archive.7z"
        CreateArchiveFormat.TAR_ZST -> "archive.tar.zst"
        CreateArchiveFormat.TAR_GZ -> "archive.tar.gz"
        CreateArchiveFormat.TZAP -> "archive.tzap"
        CreateArchiveFormat.APPLE_ARCHIVE -> "archive.aar"
    }

    fun planCreation(staged: StagedCreationSources) {
        clearCreationState()
        stagedCreationSources = staged
        val outputName = outputName()
        val volumeSize = runCatching { ArchiveVolumeSupport.parseVolumeSize(createVolumeSizeInput) }
            .getOrElse { error ->
                creationState = ArchiveCreationUiState.Failed(error.message ?: "Invalid split volume size.")
                return
            }
        creationState = ArchiveCreationUiState.Planning
        viewModelScope.launch {
            val result = withContext(Dispatchers.IO) {
                runCatching {
                    val password = createPasswordInput.takeIf { it.isNotEmpty() }
                    if (createSeparateItems && staged.sourcePaths.size > 1) {
                        val requests = ArchiveSeparateCreationPlanner.requests(
                            sourcePaths = staged.sourcePaths,
                            destinationDirectory = creationCoordinator.appStorageDirectory().absolutePath,
                            format = createFormat,
                            password = password,
                            volumeSize = volumeSize
                        )
                        separateCreationCoordinator.plan(requests)
                    } else {
                        creationCoordinator.plan(
                            ArchiveCreationRequest(
                                sourcePaths = staged.sourcePaths,
                                destinationArchivePath = creationCoordinator.appStorageOutput(outputName).absolutePath,
                                format = createFormat,
                                password = password,
                                volumeSize = volumeSize
                            )
                        )
                    }
                }
            }
            creationState = result.fold(
                onSuccess = { review ->
                    when (review) {
                        is ArchiveCreationReview -> {
                            if (review.plan.canStart) ArchiveCreationUiState.Review(review)
                            else {
                                creationCoordinator.discard(review)
                                ArchiveCreationUiState.Failed(
                                    review.plan.warnings.firstOrNull()?.message
                                        ?: "This creation plan cannot be started."
                                )
                            }
                        }
                        is ArchiveSeparateCreationReview -> {
                            val blocked = review.items.firstOrNull { !it.plan.canStart }
                            if (blocked == null) ArchiveCreationUiState.SeparateReview(review)
                            else {
                                separateCreationCoordinator.discard(review)
                                ArchiveCreationUiState.Failed(
                                    blocked.plan.warnings.firstOrNull()?.message
                                        ?: "One of the separate creation plans cannot be started."
                                )
                            }
                        }
                        else -> ArchiveCreationUiState.Failed("Unable to prepare archive creation.")
                    }
                },
                onFailure = { error -> ArchiveCreationUiState.Failed(error.message ?: "Unable to plan archive creation.") }
            )
        }
    }

    fun stageDebugCreationFixture() {
        if (!BuildConfig.DEBUG) return
        viewModelScope.launch {
            withContext(Dispatchers.IO) {
                runCatching { creationSourceStager.stageDebugFixture() }
            }.onSuccess(::planCreation)
                .onFailure { creationState = ArchiveCreationUiState.Failed(it.message ?: "Unable to stage creation fixture.") }
        }
    }

    fun stageDebugSplitCreationFixture() {
        if (!BuildConfig.DEBUG) return
        createVolumeSizeInput = "64k"
        viewModelScope.launch {
            withContext(Dispatchers.IO) {
                runCatching { creationSourceStager.stageDebugSplitFixture() }
            }.onSuccess(::planCreation)
                .onFailure { creationState = ArchiveCreationUiState.Failed(it.message ?: "Unable to stage split creation fixture.") }
        }
    }

    fun stageDebugSeparateCreationFixture() {
        if (!BuildConfig.DEBUG) return
        createSeparateItems = true
        viewModelScope.launch {
            withContext(Dispatchers.IO) {
                runCatching { creationSourceStager.stageDebugSeparateFixture() }
            }.onSuccess { staged ->
                // The debug fixture is intentionally repeatable. Remove only
                // the fixed outputs owned by this fixture so a second E2E run
                // cannot inherit an unverified archive from an earlier run.
                listOf("one.zip", "two.zip").forEach { outputName ->
                    File(creationCoordinator.appStorageDirectory(), outputName).delete()
                }
                planCreation(staged)
            }
                .onFailure { creationState = ArchiveCreationUiState.Failed(it.message ?: "Unable to stage separate creation fixture.") }
        }
    }

    fun startCreation(review: ArchiveCreationReview, context: Context) {
        createPasswordInput = ""
        creationState = ArchiveCreationUiState.Starting(review)
        runCatching {
            val token = ArchiveJobForegroundService.submit(
                context,
                ArchiveForegroundRequest.Create(review.request)
            )
            creationCoordinator.discard(review)
            // Keep the password out of long-lived state once the foreground
            // service owns the request.
            val stateReview = review.copy(request = review.request.copy(password = null))
            creationState = ArchiveCreationUiState.Running(stateReview, token, "Creating archive")
        }.onFailure { error ->
            creationCoordinator.discard(review)
            stagedCreationSources?.let(creationSourceStager::discard)
            stagedCreationSources = null
            creationState = ArchiveCreationUiState.Failed(error.message ?: "Unable to create archive.")
        }
    }

    fun startSeparateCreation(review: ArchiveSeparateCreationReview, context: Context) {
        createPasswordInput = ""
        creationState = ArchiveCreationUiState.StartingSeparate(review)
        runCatching {
            val token = ArchiveJobForegroundService.submit(
                context,
                ArchiveForegroundRequest.CreateSeparately(review.items.map { it.request })
            )
            separateCreationCoordinator.discard(review)
            val stateReview = ArchiveSeparateCreationReview(
                review.items.map { it.copy(request = it.request.copy(password = null)) }
            )
            creationState = ArchiveCreationUiState.RunningSeparate(stateReview, token, "Creating separate archives")
        }.onFailure { error ->
            separateCreationCoordinator.discard(review)
            stagedCreationSources?.let(creationSourceStager::discard)
            stagedCreationSources = null
            creationState = ArchiveCreationUiState.Failed(error.message ?: "Unable to create separate archives.")
        }
    }

    class Factory(private val context: Context) : ViewModelProvider.Factory {
        @Suppress("UNCHECKED_CAST")
        override fun <T : ViewModel> create(modelClass: Class<T>): T =
            ArchiveCreationViewModel(context) as T
    }
}
