package org.tzap.zmanager.mobile

import android.content.ActivityNotFoundException
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.Uri
import android.os.Bundle
import android.webkit.MimeTypeMap
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Button
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Checkbox
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.core.content.FileProvider
import androidx.core.content.ContextCompat
import androidx.documentfile.provider.DocumentFile
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.tzap.zmanager.mobile.bridge.generated.ExtractionCollisionPolicy
import org.tzap.zmanager.mobile.bridge.generated.CreateArchiveFormat
import org.tzap.zmanager.mobile.bridge.generated.ZmanagerGuiException
import java.io.File
import java.io.IOException
import java.util.Locale
import java.util.UUID

class MainActivity : ComponentActivity() {
    private val incomingIntentState = mutableStateOf<Intent?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        incomingIntentState.value = intent
        setContent {
            ZManagerApp(
                incomingIntent = incomingIntentState.value,
                onIncomingIntentHandled = { handledIntent ->
                    if (incomingIntentState.value === handledIntent) {
                        incomingIntentState.value = null
                    }
                }
            )
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        incomingIntentState.value = intent
    }
}

@Composable
private fun ZManagerApp(
    incomingIntent: Intent?,
    onIncomingIntentHandled: (Intent) -> Unit
) {
    val context = LocalContext.current
    val importer = remember(context) { ArchiveImporter(context) }
    val listingRepository = remember { ArchiveListingRepository() }
    val extractionCoordinator = remember(context) { ArchiveExtractionCoordinator(context) }
    val recoveryStore = remember(context) { ArchiveRecoveryStore(context) }
    val destinationPreferences = remember(context) { ArchiveDestinationPreferences(context) }
    val batchExtractionCoordinator = remember(context) { BatchExtractionCoordinator(extractionCoordinator) }
    val creationCoordinator = remember(context) { ArchiveCreationCoordinator(context) }
    val separateCreationCoordinator = remember(context) { ArchiveSeparateCreationCoordinator(creationCoordinator) }
    val repackagingCoordinator = remember(context) { ArchiveRepackagingCoordinator(context, extractionCoordinator, creationCoordinator) }
    val creationSourceStager = remember(context) { ArchiveCreationSourceStager(context) }
    val localSendSourceStager = remember(context) { LocalSendSourceStager(context) }
    val localSendClient = remember(context) { LocalSendClient(context) }
    val localSendTrustStore = remember(context) { LocalSendTrustStore(context) }
    val scope = rememberCoroutineScope()
    var importedArchive by remember { mutableStateOf<ImportedArchive?>(null) }
    var listingState by remember { mutableStateOf<ArchiveListingState>(ArchiveListingState.Idle) }
    var importError by remember { mutableStateOf<String?>(null) }
    var isImporting by remember { mutableStateOf(false) }
    var passwordInput by remember { mutableStateOf("") }
    var previewPasswordInput by remember { mutableStateOf("") }
    var testPasswordInput by remember { mutableStateOf("") }
    var entrySearchQuery by remember { mutableStateOf("") }
    var entrySort by remember { mutableStateOf(ArchiveEntrySort.PATH_ASCENDING) }
    var entryViewMode by remember { mutableStateOf(ArchiveEntryViewMode.FOLDERS) }
    var selectedEntryIds by remember { mutableStateOf(emptySet<String>()) }
    var previewState by remember { mutableStateOf<ArchivePreviewState>(ArchivePreviewState.Idle) }
    var testState by remember { mutableStateOf<ArchiveTestState>(ArchiveTestState.Idle) }
    var extractionState by remember { mutableStateOf<ArchiveExtractionUiState>(ArchiveExtractionUiState.Idle) }
    var batchExtractionState by remember { mutableStateOf<BatchExtractionUiState>(BatchExtractionUiState.Idle) }
    var extractionPasswordInput by remember { mutableStateOf("") }
    var repackagingState by remember { mutableStateOf<ArchiveRepackagingUiState>(ArchiveRepackagingUiState.Idle) }
    var repackagingPasswordInput by remember { mutableStateOf("") }
    var repackagingSelectedEntries by remember { mutableStateOf(emptyList<ArchiveEntrySummary>()) }
    var creationState by remember { mutableStateOf<ArchiveCreationUiState>(ArchiveCreationUiState.Idle) }
    var createFormat by remember { mutableStateOf(CreateArchiveFormat.ZIP) }
    var createPasswordInput by remember { mutableStateOf("") }
    var createVolumeSizeInput by remember { mutableStateOf("") }
    var createSeparateItems by remember { mutableStateOf(false) }
    var stagedCreationSources by remember { mutableStateOf<StagedCreationSources?>(null) }
    var localSendState by remember { mutableStateOf<LocalSendUiState>(LocalSendUiState.Idle) }
    var localSendPinInput by remember { mutableStateOf("") }
    var pendingLocalSendDevice by remember { mutableStateOf<LocalSendDevice?>(null) }
    var rememberLocalSendDevice by remember { mutableStateOf(false) }
    var activeLocalSendSession by remember { mutableStateOf<Pair<LocalSendDevice, String>?>(null) }
    var stagedLocalSendFiles by remember { mutableStateOf<StagedLocalSendFiles?>(null) }
    var receiveSession by remember { mutableStateOf<LocalSendReceiverSession?>(null) }
    var receiveDestinationUri by remember { mutableStateOf<Uri?>(null) }
    var localSendTrustVersion by remember { mutableStateOf(0) }
    val trustedLocalSendFingerprints = remember(localSendTrustVersion) {
        localSendTrustStore.fingerprints()
    }
    val archiveSessions = remember { ArchiveSessionStack() }
    var nestedNavigationVersion by remember { mutableStateOf(0) }
    var nestedOpenError by remember { mutableStateOf<String?>(null) }
    var foregroundRecoveryMessage by remember { mutableStateOf<String?>(null) }
    var operationReportMessage by remember { mutableStateOf<String?>(null) }
    var destinationPreferenceVersion by remember { mutableStateOf(0) }
    var recoveryVersion by remember { mutableStateOf(0) }
    var debugExtractionDelayMillis by remember { mutableStateOf(0L) }
    var debugExtractionTimeoutMillis by remember { mutableStateOf<Long?>(null) }
    val defaultExtractionDestination = remember(destinationPreferenceVersion) {
        destinationPreferences.defaultExtractionDestination()
    }
    val recoveryRecords = remember(recoveryVersion) { recoveryStore.records() }
    var pendingAutomationAction by remember { mutableStateOf<ArchiveAutomationAction?>(null) }
    var importRequestId by remember { mutableStateOf(0L) }
    var listingRequestId by remember { mutableStateOf(0L) }
    var previewRequestId by remember { mutableStateOf(0L) }
    var testRequestId by remember { mutableStateOf(0L) }
    var showFixtureMenu by remember { mutableStateOf(false) }
    var showHelpDialog by remember { mutableStateOf(false) }

    val localSendReceiver = remember {
        LocalSendReceiver(fingerprint = LocalSendIdentity.fingerprint(context), onFileCommitted = { received ->
            val treeUri = receiveDestinationUri ?: return@LocalSendReceiver
            runCatching {
                val tree = DocumentFile.fromTreeUri(context, treeUri)
                    ?: throw IOException("Unable to open the selected receive folder.")
                val target = tree.createFile("application/octet-stream", received.displayName)
                    ?: throw IOException("Unable to create the received file.")
                context.contentResolver.openOutputStream(target.uri)?.use { output ->
                    received.path.inputStream().use { input -> input.copyTo(output) }
                } ?: throw IOException("Unable to write the received file.")
                received.path.delete()
            }.onFailure {
                scope.launch {
                    localSendState = LocalSendUiState.Failed("Unable to export received file.")
                }
            }
        })
    }

    fun clearLocalSendSelection() {
        stagedLocalSendFiles?.let(localSendSourceStager::discard)
        stagedLocalSendFiles = null
    }

    fun stopLocalReceive() {
        val stagingRoot = receiveSession?.destinationRoot
            ?.takeIf { receiveDestinationUri != null }
        scope.launch(Dispatchers.IO) {
            localSendReceiver.stop()
            stagingRoot?.deleteRecursively()
        }
        receiveSession = null
        localSendState = LocalSendUiState.Idle
    }

    fun handleAppBackground() {
        passwordInput = ""
        previewPasswordInput = ""
        testPasswordInput = ""
        extractionPasswordInput = ""
        createPasswordInput = ""
        repackagingPasswordInput = ""
        localSendPinInput = ""
        pendingLocalSendDevice = null

        val activeSession = activeLocalSendSession
        localSendClient.cancel()
        activeLocalSendSession = null
        if (activeSession != null) {
            scope.launch(Dispatchers.IO) {
                runCatching { localSendClient.cancel(activeSession.first, activeSession.second) }
            }
        }
        stopLocalReceive()
        clearLocalSendSelection()
        if (localSendState is LocalSendUiState.Sending || localSendState is LocalSendUiState.Receiving) {
            localSendState = LocalSendUiState.Idle
        }
    }

    val lifecycleOwner = LocalLifecycleOwner.current
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_STOP) handleAppBackground()
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }

    DisposableEffect(localSendReceiver) {
        onDispose {
            localSendReceiver.stop()
            stagedLocalSendFiles?.let(localSendSourceStager::discard)
        }
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

    fun clearExtractionState() {
        (extractionState as? ArchiveExtractionUiState.Review)?.review?.let(extractionCoordinator::discard)
        extractionState = ArchiveExtractionUiState.Idle
        extractionPasswordInput = ""
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

    fun handleForegroundJobResult(result: ArchiveForegroundResult) {
        when {
            result.kind == "extract" && result.recoveryId != null -> {
                extractionState = ArchiveExtractionUiState.RecoveryAvailable(
                    result.recoveryId,
                    result.message ?: "The destination commit needs recovery."
                )
                recoveryVersion += 1
            }
            result.kind == "create" &&
                (creationState as? ArchiveCreationUiState.Running)?.jobId == result.token -> {
                val state = creationState as ArchiveCreationUiState.Running
                creationState = when (result.status) {
                    "COMPLETED" -> ArchiveCreationUiState.Completed(
                        ArchiveCreationOutcome.Completed(
                            outputPath = result.outputPath ?: state.review.request.destinationArchivePath,
                            verified = result.verified == true,
                            outputPaths = result.outputPaths.ifEmpty {
                                result.outputPath?.let(::listOf)
                                    ?: listOf(state.review.request.destinationArchivePath)
                            }
                        )
                    )
                    "CANCELLED" -> ArchiveCreationUiState.Cancelled
                    else -> ArchiveCreationUiState.Failed(result.message ?: "Unable to create archive.")
                }
                stagedCreationSources?.let(creationSourceStager::discard)
                stagedCreationSources = null
            }
            result.kind == "create-separately" &&
                (creationState as? ArchiveCreationUiState.RunningSeparate)?.jobId == result.token -> {
                val state = creationState as ArchiveCreationUiState.RunningSeparate
                creationState = when (result.status) {
                    "COMPLETED" -> ArchiveCreationUiState.Completed(
                        ArchiveCreationOutcome.Completed(
                            outputPath = result.outputPath ?: state.review.items.first().request.destinationArchivePath,
                            verified = result.verified == true,
                            outputPaths = result.outputPaths.ifEmpty { result.outputPath?.let(::listOf).orEmpty() }
                        )
                    )
                    "CANCELLED" -> ArchiveCreationUiState.Cancelled
                    else -> ArchiveCreationUiState.Failed(result.message ?: "Unable to create separate archives.")
                }
                stagedCreationSources?.let(creationSourceStager::discard)
                stagedCreationSources = null
            }
            result.kind == "extract" &&
                (extractionState as? ArchiveExtractionUiState.Running)?.jobId == result.token -> {
                val state = extractionState as ArchiveExtractionUiState.Running
                extractionState = when (result.status) {
                    "COMPLETED" -> ArchiveExtractionUiState.Completed(
                        ExtractionOutcome.Completed(
                            writtenEntries = state.review.plan.writableEntries,
                            destination = state.review.destination.label
                        )
                    )
                    "CANCELLED" -> ArchiveExtractionUiState.Cancelled
                    else -> ArchiveExtractionUiState.Failed(result.message ?: "Unable to extract archive.")
                }
            }
            result.kind == "batch-extract" &&
                (batchExtractionState as? BatchExtractionUiState.Running)?.token == result.token -> {
                batchExtractionState = when (result.status) {
                    "COMPLETED" -> BatchExtractionUiState.Completed(
                        result.message ?: "Batch extraction complete."
                    )
                    "CANCELLED" -> BatchExtractionUiState.Cancelled
                    else -> BatchExtractionUiState.Failed(result.message ?: "Batch extraction failed.")
                }
            }
            else -> {
                foregroundRecoveryMessage = when (result.status) {
                    "COMPLETED" -> if (result.kind == "create" || result.kind == "create-separately") {
                        "Archive job completed${result.outputPath?.let { ": ${File(it).name}" } ?: ""}."
                    } else {
                        "Extraction job completed${result.message?.let { " to $it" } ?: ""}."
                    }
                    "CANCELLED" -> "Archive job cancelled."
                    else -> result.message ?: "Archive job failed."
                }
            }
        }
    }

    DisposableEffect(context) {
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                ArchiveJobForegroundService.resultFrom(intent)?.let(::handleForegroundJobResult)
            }
        }
        ContextCompat.registerReceiver(
            context,
            receiver,
            IntentFilter(ArchiveJobForegroundService.ACTION_RESULT),
            ContextCompat.RECEIVER_NOT_EXPORTED
        )
        onDispose { context.unregisterReceiver(receiver) }
    }

    LaunchedEffect(Unit) {
        ArchiveJobForegroundService.takePersistedResults(context).forEach(::handleForegroundJobResult)
    }

    fun extractionSelectedPaths(entries: List<ArchiveEntrySummary>): List<String> {
        val summaryEntries = (listingState as? ArchiveListingState.Ready)?.summary?.entries
            ?: return entries.map { it.path }
        return if (entries.mapTo(mutableSetOf()) { it.path } == summaryEntries.mapTo(mutableSetOf()) { it.path }) {
            emptyList()
        } else {
            entries.map { it.path }
        }
    }

    fun discardRecovery(id: String) {
        recoveryStore.discard(id)
        recoveryVersion += 1
        if ((extractionState as? ArchiveExtractionUiState.RecoveryAvailable)?.recoveryId == id) {
            extractionState = ArchiveExtractionUiState.Idle
        }
    }

    fun exportRecovery(id: String) {
        val files = recoveryStore.files(id)
        if (files.isEmpty()) {
            foregroundRecoveryMessage = "The retained recovery output is no longer available."
            return
        }
        runCatching {
            val uris = files.map { file ->
                FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
            }
            context.startActivity(Intent.createChooser(
                Intent(Intent.ACTION_SEND_MULTIPLE)
                    .setType("application/octet-stream")
                    .putParcelableArrayListExtra(Intent.EXTRA_STREAM, ArrayList(uris))
                    .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION),
                "Export retained extraction"
            ))
        }.onFailure {
            foregroundRecoveryMessage = "Unable to export the retained extraction."
        }
    }

    fun shareOutputFiles(paths: List<String>, title: String = "Share created archive") {
        val files = paths.map(::File).filter { it.isFile }
        if (files.isEmpty()) {
            foregroundRecoveryMessage = "The created archive is no longer available."
            return
        }
        runCatching {
            val uris = files.map { file ->
                FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
            }
            val intent = if (uris.size == 1) {
                Intent(Intent.ACTION_SEND)
                    .setType("application/octet-stream")
                    .putExtra(Intent.EXTRA_STREAM, uris.single())
            } else {
                Intent(Intent.ACTION_SEND_MULTIPLE)
                    .setType("application/octet-stream")
                    .putParcelableArrayListExtra(Intent.EXTRA_STREAM, ArrayList(uris))
            }
            context.startActivity(Intent.createChooser(
                intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION),
                title
            ))
        }.onFailure {
            foregroundRecoveryMessage = "Unable to share the created archive."
        }
    }

    fun startRepackaging(entries: List<ArchiveEntrySummary>, sourcePassword: String? = null) {
        val archive = importedArchive ?: return
        repackagingSelectedEntries = entries
        // Repackaging requires an explicit source selection. An empty list is
        // reserved by extraction for "the whole archive", which would make
        // the repackaging coordinator reject a deliberate whole-archive pick.
        val selectedPaths = entries.map { it.path }
        val outputName = when (createFormat) {
            CreateArchiveFormat.ZIP -> "repackaged.zip"
            CreateArchiveFormat.SEVEN_Z -> "repackaged.7z"
            CreateArchiveFormat.TAR_ZST -> "repackaged.tar.zst"
            CreateArchiveFormat.TAR_GZ -> "repackaged.tar.gz"
            CreateArchiveFormat.TZAP -> "repackaged.tzap"
            CreateArchiveFormat.APPLE_ARCHIVE -> "repackaged.aar"
        }
        repackagingState = ArchiveRepackagingUiState.Planning
        val volumeSize = runCatching { ArchiveVolumeSupport.parseVolumeSize(createVolumeSizeInput) }
            .getOrElse { error ->
                repackagingState = ArchiveRepackagingUiState.Failed(error.message ?: "Invalid split volume size.")
                return
            }
        scope.launch {
            val planned = withContext(Dispatchers.IO) {
                runCatching {
                    repackagingCoordinator.plan(
                        ArchiveRepackagingRequest(
                            sourceArchive = archive,
                            selectedPaths = selectedPaths,
                            destinationArchivePath = creationCoordinator.appStorageOutput(outputName).absolutePath,
                            format = createFormat,
                            volumeSize = volumeSize,
                            sourcePassword = sourcePassword ?: repackagingPasswordInput.takeIf { it.isNotEmpty() },
                            destinationPassword = createPasswordInput.takeIf { it.isNotEmpty() }
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
        scope.launch {
            val outcome = withContext(Dispatchers.IO) {
                repackagingCoordinator.run(review) { message ->
                    scope.launch { repackagingState = ArchiveRepackagingUiState.Running(review, message) }
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
            passwordInput = ""
            createPasswordInput = ""
            repackagingPasswordInput = ""
        }
    }

    fun planCreation(staged: StagedCreationSources) {
        clearCreationState()
        stagedCreationSources = staged
        val outputName = when (createFormat) {
            CreateArchiveFormat.ZIP -> "archive.zip"
            CreateArchiveFormat.SEVEN_Z -> "archive.7z"
            CreateArchiveFormat.TAR_ZST -> "archive.tar.zst"
            CreateArchiveFormat.TAR_GZ -> "archive.tar.gz"
            CreateArchiveFormat.TZAP -> "archive.tzap"
            CreateArchiveFormat.APPLE_ARCHIVE -> "archive.aar"
        }
        val volumeSize = runCatching { ArchiveVolumeSupport.parseVolumeSize(createVolumeSizeInput) }
            .getOrElse { error ->
                creationState = ArchiveCreationUiState.Failed(error.message ?: "Invalid split volume size.")
                return
            }
        creationState = ArchiveCreationUiState.Planning
        scope.launch {
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
        scope.launch {
            withContext(Dispatchers.IO) {
                runCatching { creationSourceStager.stageDebugFixture() }
            }.onSuccess(::planCreation)
                .onFailure { creationState = ArchiveCreationUiState.Failed(it.message ?: "Unable to stage creation fixture.") }
        }
    }

    fun stageDebugSplitCreationFixture() {
        if (!BuildConfig.DEBUG) return
        createVolumeSizeInput = "64k"
        scope.launch {
            withContext(Dispatchers.IO) {
                runCatching { creationSourceStager.stageDebugSplitFixture() }
            }.onSuccess(::planCreation)
                .onFailure { creationState = ArchiveCreationUiState.Failed(it.message ?: "Unable to stage split creation fixture.") }
        }
    }

    fun stageDebugSeparateCreationFixture() {
        if (!BuildConfig.DEBUG) return
        createSeparateItems = true
        scope.launch {
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

    fun startCreation(review: ArchiveCreationReview) {
        createPasswordInput = ""
        creationState = ArchiveCreationUiState.Starting(review)
        runCatching {
            val token = ArchiveJobForegroundService.submit(
                context,
                ArchiveForegroundRequest.Create(review.request)
            )
            creationCoordinator.discard(review)
            // Keep the password out of long-lived Compose state once the
            // foreground service owns the request.
            val stateReview = review.copy(request = review.request.copy(password = null))
            creationState = ArchiveCreationUiState.Running(stateReview, token, "Creating archive")
        }.onFailure { error ->
            creationCoordinator.discard(review)
            stagedCreationSources?.let(creationSourceStager::discard)
            stagedCreationSources = null
            creationState = ArchiveCreationUiState.Failed(error.message ?: "Unable to create archive.")
        }
    }

    fun startSeparateCreation(review: ArchiveSeparateCreationReview) {
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

    fun planExtraction(
        archive: ImportedArchive,
        entries: List<ArchiveEntrySummary>,
        destination: ExtractionDestination,
        password: String?,
        debugDelayMillis: Long = debugExtractionDelayMillis,
        debugTimeoutMillis: Long? = debugExtractionTimeoutMillis
    ) {
        clearExtractionState()
        val selectedPaths = extractionSelectedPaths(entries)
        extractionState = ArchiveExtractionUiState.Planning(destination.label)
        scope.launch {
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
                        debugDelayMillis = debugDelayMillis,
                        debugTimeoutMillis = debugTimeoutMillis
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

    fun retryRecovery(record: ArchiveRecoveryRecord) {
        val archive = importedArchive
        val summary = (listingState as? ArchiveListingState.Ready)?.summary
        if (archive == null || summary == null || archive.localPath != record.archivePath) {
            foregroundRecoveryMessage = "Import ${record.archiveDisplayName} again to retry the retained extraction."
            return
        }
        val entries = if (record.selectedPaths.isEmpty()) {
            summary.entries
        } else {
            summary.entries.filter { it.path in record.selectedPaths }
        }
        discardRecovery(record.id)
        planExtraction(archive, entries, defaultExtractionDestination, null)
    }

    fun startExtraction(review: ExtractionReview) {
        extractionState = ArchiveExtractionUiState.Starting(review)
        debugExtractionDelayMillis = 0L
        debugExtractionTimeoutMillis = null
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
            // Keep the password out of long-lived Compose state once the
            // foreground service owns the request.
            val stateReview = review.copy(request = request.copy(password = null))
            extractionState = ArchiveExtractionUiState.Running(stateReview, token, "Extracting archive")
        }.onFailure { error ->
            extractionCoordinator.discard(review)
            extractionState = error.toExtractionUiState()
        }
    }

    fun startBatchImport(uris: List<Uri>) {
        if (uris.isEmpty()) return
        batchExtractionState = BatchExtractionUiState.Planning
        scope.launch {
            val result = withContext(Dispatchers.IO) {
                runCatching {
                    val root = File(context.filesDir, "BatchExtracted")
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
        scope.launch {
            val result = withContext(Dispatchers.IO) {
                runCatching {
                    val root = File(context.filesDir, "BatchExtracted")
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

    fun startBatchExtraction(review: BatchExtractionReview) {
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

    fun loadArchiveListing(archive: ImportedArchive, password: String?) {
        listingRequestId += 1
        val currentListingRequestId = listingRequestId
        selectedEntryIds = emptySet()
        clearPreviewState()
        clearTestState()
        clearExtractionState()
        listingState = ArchiveListingState.Loading
        scope.launch {
            val result = withContext(Dispatchers.IO) {
                listingRepository.load(archive, password)
            }
            if (
                currentListingRequestId == listingRequestId &&
                importedArchive?.id == archive.id
            ) {
                listingState = result
            }
        }
    }

    fun startPreview(archive: ImportedArchive, entry: ArchiveEntrySummary, password: String?) {
        previewRequestId += 1
        val currentPreviewRequestId = previewRequestId
        cleanupPreview(previewState)
        previewState = ArchivePreviewState.Loading(entry)
        previewPasswordInput = ""
        scope.launch {
            val result = withContext(Dispatchers.IO) {
                listingRepository.materializePreview(archive, entry, password)
            }
            if (
                currentPreviewRequestId == previewRequestId &&
                importedArchive?.id == archive.id
            ) {
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
        scope.launch {
            val result = withContext(Dispatchers.IO) {
                listingRepository.testArchive(archive, selectedEntries, password)
            }
            if (
                currentTestRequestId == testRequestId &&
                importedArchive?.id == archive.id
            ) {
                testState = result
            }
        }
    }

    LaunchedEffect(listingState, pendingAutomationAction, importedArchive?.id) {
        val action = pendingAutomationAction
        val archive = importedArchive
        val ready = listingState as? ArchiveListingState.Ready
        if (action != null && archive != null && ready != null) {
            pendingAutomationAction = null
            when (action) {
                ArchiveAutomationAction.EXTRACT -> planExtraction(
                    archive,
                    ready.summary.entries,
                    defaultExtractionDestination,
                    null
                )
                ArchiveAutomationAction.VERIFY -> startArchiveTest(
                    archive,
                    ready.summary.entries,
                    null
                )
                else -> Unit
            }
        }
    }

    fun startImport(
        uris: List<Uri>,
        automationAction: ArchiveAutomationAction? = null
    ) {
        debugExtractionDelayMillis = 0L
        debugExtractionTimeoutMillis = null
        pendingAutomationAction = automationAction
        importRequestId += 1
        val currentImportRequestId = importRequestId
        listingRequestId += 1
        clearPreviewState()
        clearTestState()
        clearExtractionState()
        archiveSessions.clear()
        nestedNavigationVersion += 1
        nestedOpenError = null
        isImporting = true
        importError = null
        importedArchive = null
        listingState = ArchiveListingState.Idle
        passwordInput = ""
        entrySearchQuery = ""
        selectedEntryIds = emptySet()
        clearLocalSendSelection()
        scope.launch {
            val result = withContext(Dispatchers.IO) {
                runCatching { importer.importUris(uris) }
            }
            if (currentImportRequestId != importRequestId) {
                return@launch
            }
            result
                .onSuccess { archive ->
                    importedArchive = archive
                    loadArchiveListing(archive, null)
                }
                .onFailure {
                    importError = "Unable to import that archive."
                }
            isImporting = false
        }
    }

    fun startMaestroFixtureImport(
        assetName: String = "maestro-files.zip",
        companionAssetNames: List<String> = emptyList(),
        automationAction: ArchiveAutomationAction? = null,
        displayAssetNames: List<String> = listOf(assetName) + companionAssetNames
    ) {
        if (automationAction != ArchiveAutomationAction.EXTRACT) {
            debugExtractionDelayMillis = 0L
            debugExtractionTimeoutMillis = null
        }
        pendingAutomationAction = automationAction
        importRequestId += 1
        val currentImportRequestId = importRequestId
        listingRequestId += 1
        clearPreviewState()
        clearTestState()
        clearExtractionState()
        archiveSessions.clear()
        nestedNavigationVersion += 1
        nestedOpenError = null
        isImporting = true
        importError = null
        importedArchive = null
        listingState = ArchiveListingState.Idle
        passwordInput = ""
        entrySearchQuery = ""
        selectedEntryIds = emptySet()
        scope.launch {
            val result = withContext(Dispatchers.IO) {
                runCatching {
                    importer.importAssets(
                        assetName,
                        listOf(assetName) + companionAssetNames,
                        displayAssetNames
                    )
                }
            }
            if (currentImportRequestId != importRequestId) {
                return@launch
            }
            result
                .onSuccess { archive ->
                    importedArchive = archive
                    loadArchiveListing(archive, null)
                }
                .onFailure {
                    importError = "Unable to import the test fixture."
                }
            isImporting = false
        }
    }

    fun startDebugCancellableExtraction() {
        if (!BuildConfig.DEBUG) return
        debugExtractionDelayMillis = 15_000L
        startMaestroFixtureImport(
            assetName = "maestro-split.zip",
            companionAssetNames = listOf("maestro-split.z01"),
            automationAction = ArchiveAutomationAction.EXTRACT
        )
    }

    fun startDebugTimedOutExtraction() {
        if (!BuildConfig.DEBUG) return
        debugExtractionDelayMillis = 15_000L
        debugExtractionTimeoutMillis = 1_000L
        startMaestroFixtureImport(
            assetName = "maestro-split.zip",
            companionAssetNames = listOf("maestro-split.z01"),
            automationAction = ArchiveAutomationAction.EXTRACT
        )
    }

    fun openNestedArchive(entry: ArchiveEntrySummary) {
        val parent = importedArchive ?: return
        if (!NestedArchiveSupport.canOpen(entry)) return
        nestedOpenError = null
        scope.launch {
            val result = withContext(Dispatchers.IO) {
                listingRepository.materializePreview(parent, entry, null)
            }
            when (result) {
                is ArchivePreviewState.Ready -> {
                    val preview = result.summary
                    val child = ImportedArchive(
                        id = java.util.UUID.randomUUID().toString(),
                        displayName = entry.displayName,
                        localPath = preview.previewPath,
                        byteSize = preview.writtenBytes.toLong(),
                        sourceMimeType = null,
                        importedAtEpochMillis = System.currentTimeMillis()
                    )
                    if (archiveSessions.current?.archive?.id != parent.id) {
                        archiveSessions.push(parent)
                    }
                    archiveSessions.push(
                        archive = child,
                        parentEntryPath = entry.path,
                        cleanupRoot = preview.cleanupRoot
                    )
                    importedArchive = child
                    nestedNavigationVersion += 1
                    loadArchiveListing(child, null)
                }
                is ArchivePreviewState.PasswordRequired -> {
                    nestedOpenError = result.error.message
                }
                is ArchivePreviewState.Failed -> {
                    nestedOpenError = result.error.message
                }
                else -> nestedOpenError = "Unable to open that nested archive."
            }
        }
    }

    fun navigateBackFromNested() {
        val removed = archiveSessions.pop() ?: return
        val parent = archiveSessions.current?.archive
        if (parent == null) {
            importedArchive = null
            listingState = ArchiveListingState.Idle
        } else {
            importedArchive = parent
            loadArchiveListing(parent, null)
        }
        nestedOpenError = null
        nestedNavigationVersion += 1
    }

    fun discoverLocalSendDevices() {
        localSendState = LocalSendUiState.Discovering
        scope.launch {
            val devices = withContext(Dispatchers.IO) { runCatching { localSendClient.discover() } }
            localSendState = devices.fold(
                onSuccess = { LocalSendUiState.Devices(it) },
                onFailure = { LocalSendUiState.Failed("Unable to discover LocalSend devices.") }
            )
        }
    }

    fun sendSelectedFiles(device: LocalSendDevice, pin: String? = null) {
        val selectedFiles = stagedLocalSendFiles?.files
            ?: importedArchive?.let { listOf(LocalSendFile(file = File(it.localPath), displayName = it.displayName)) }
            ?: return
        localSendState = LocalSendUiState.Sending(device, "Preparing transfer")
        scope.launch {
            val result = withContext(Dispatchers.IO) {
                runCatching {
                    val session = localSendClient.prepareUpload(device, selectedFiles, pin)
                    activeLocalSendSession = device to session.sessionId
                    localSendClient.upload(device, session, selectedFiles) { item, sent, total ->
                        scope.launch {
                            localSendState = LocalSendUiState.Sending(
                                device,
                                "Uploading ${item.displayName}: $sent/$total bytes"
                            )
                        }
                    }
                }
            }
            activeLocalSendSession = null
            localSendState = result.fold(
                onSuccess = {
                    localSendPinInput = ""
                    clearLocalSendSelection()
                    LocalSendUiState.Completed(device)
                },
                onFailure = { error ->
                    if (error is LocalSendPinRequiredException) {
                        localSendPinInput = ""
                        LocalSendUiState.PinRequired(device)
                    } else {
                        LocalSendUiState.Failed(error.message ?: "LocalSend transfer failed.")
                    }
                }
            )
        }
    }

    fun cancelLocalSend() {
        val active = activeLocalSendSession
        localSendClient.cancel()
        activeLocalSendSession = null
        if (active != null) {
            scope.launch(Dispatchers.IO) { runCatching { localSendClient.cancel(active.first, active.second) } }
        }
        localSendState = LocalSendUiState.Failed("LocalSend transfer cancelled.")
    }

    fun startLocalReceive() {
        if (receiveSession != null) return
        val selectedTree = receiveDestinationUri
        val receiveRoot = if (selectedTree == null) {
            File(context.filesDir, "ReceivedFiles")
        } else {
            File(context.cacheDir, "localsend-receive/${UUID.randomUUID()}")
        }
        scope.launch {
            val result = withContext(Dispatchers.IO) {
                runCatching {
                    localSendReceiver.start(receiveRoot)
                }
            }
            result.onSuccess {
                receiveSession = it
                localSendState = LocalSendUiState.Receiving(it.port)
            }.onFailure {
                if (selectedTree != null) receiveRoot.deleteRecursively()
                localSendState = LocalSendUiState.Failed("Unable to receive LocalSend files.")
            }
        }
    }

    val documentPicker = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.OpenMultipleDocuments()
    ) { uris ->
        uris.takeIf { it.isNotEmpty() }?.let(::startImport)
    }
    val batchArchivePicker = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.OpenMultipleDocuments()
    ) { uris ->
        uris.takeIf { it.isNotEmpty() }?.let(::startBatchImport)
    }
    val destinationPicker = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.OpenDocumentTree()
    ) { uri ->
        val readySummary = (listingState as? ArchiveListingState.Ready)?.summary
        val archive = importedArchive
        if (uri != null && readySummary != null && archive != null) {
            runCatching {
                context.contentResolver.takePersistableUriPermission(
                    uri,
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                )
            }
            val entries = readySummary.selectedEntries(selectedEntryIds).ifEmpty { readySummary.entries }
            val destination = ExtractionDestination.DocumentTree(uri)
            destinationPreferences.setExtractionDestination(destination)
            destinationPreferenceVersion += 1
            planExtraction(archive, entries, destination, null)
        }
    }
    val creationFilesPicker = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.OpenMultipleDocuments()
    ) { uris ->
        if (uris.isNotEmpty()) {
            scope.launch {
                withContext(Dispatchers.IO) {
                    runCatching { creationSourceStager.stageFiles(uris) }
                }.onSuccess(::planCreation)
                    .onFailure { creationState = ArchiveCreationUiState.Failed(it.message ?: "Unable to stage selected files.") }
            }
        }
    }
    val creationFolderPicker = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.OpenDocumentTree()
    ) { uri ->
        if (uri != null) {
            runCatching {
                context.contentResolver.takePersistableUriPermission(
                    uri,
                    Intent.FLAG_GRANT_READ_URI_PERMISSION
                )
            }
            scope.launch {
                withContext(Dispatchers.IO) {
                    runCatching { creationSourceStager.stageTree(uri) }
                }.onSuccess(::planCreation)
                    .onFailure { creationState = ArchiveCreationUiState.Failed(it.message ?: "Unable to stage selected folder.") }
            }
        }
    }
    val receiveDestinationPicker = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.OpenDocumentTree()
    ) { uri ->
        if (uri != null) {
            runCatching {
                context.contentResolver.takePersistableUriPermission(
                    uri,
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                )
            }
            receiveDestinationUri = uri
            localSendState = LocalSendUiState.Idle
        }
    }
    val localSendFilesPicker = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.OpenMultipleDocuments()
    ) { uris ->
        if (uris.isNotEmpty()) {
            scope.launch {
                val result = withContext(Dispatchers.IO) {
                    runCatching { localSendSourceStager.stageUris(uris) }
                }
                result.onSuccess {
                    clearLocalSendSelection()
                    stagedLocalSendFiles = it
                    localSendState = LocalSendUiState.Idle
                }.onFailure {
                    localSendState = LocalSendUiState.Failed(it.message ?: "Unable to stage selected files.")
                }
            }
        }
    }

    LaunchedEffect(incomingIntent) {
        incomingIntent?.let { intent ->
            val automation = runCatching { ArchiveAutomationIntents.parse(intent) }.getOrNull()
            if (automation != null) {
                when (automation.action) {
                    ArchiveAutomationAction.CREATE -> scope.launch {
                        runCatching {
                            withContext(Dispatchers.IO) {
                                creationSourceStager.stageFiles(automation.sourceUris)
                            }
                        }.onSuccess(::planCreation)
                            .onFailure { creationState = ArchiveCreationUiState.Failed("Unable to prepare automation input.") }
                    }
                    ArchiveAutomationAction.OPEN -> automation.archiveUri?.let { startImport(listOf(it)) }
                    ArchiveAutomationAction.EXTRACT,
                    ArchiveAutomationAction.VERIFY -> automation.archiveUri?.let {
                        startImport(listOf(it), automation.action)
                    }
                }
            } else {
                ArchiveImportIntents.firstArchiveUri(intent)?.let { uri ->
                    startImport(listOf(uri))
                }
            }
            onIncomingIntentHandled(intent)
        }
    }

    MaterialTheme {
        Surface(modifier = Modifier.fillMaxSize()) {
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .verticalScroll(rememberScrollState())
                    .widthIn(max = 1200.dp)
                    .padding(horizontal = 24.dp, vertical = 32.dp),
                verticalArrangement = Arrangement.SpaceBetween
            ) {
                Column {
                    // Keep this read so Compose invalidates after stack cleanup/pop operations.
                    val currentNavigationVersion = nestedNavigationVersion
                    if (currentNavigationVersion < 0) Text("")
                    Text(
                        text = "ZManager",
                        style = MaterialTheme.typography.headlineMedium
                    )
                    Spacer(modifier = Modifier.height(8.dp))
                    Text(
                        text = "Open an archive, inspect its contents, then extract safely.",
                        style = MaterialTheme.typography.bodyLarge
                    )
                    Text(
                        text = "Default extraction destination: ${defaultExtractionDestination.label}",
                        style = MaterialTheme.typography.bodyMedium
                    )
                    TextButton(onClick = {
                        destinationPreferences.resetExtractionDestination()
                        destinationPreferenceVersion += 1
                    }) {
                        Text("Reset default destination")
                    }
                    TextButton(
                        onClick = { showHelpDialog = true },
                        modifier = Modifier.semantics {
                            contentDescription = "About and help"
                        }
                    ) {
                        Text("About & help")
                    }
                    if (BuildConfig.DEBUG) {
                        OutlinedButton(
                            enabled = !isImporting,
                            onClick = { startMaestroFixtureImport("maestro-nested.zip") }
                        ) {
                            Text("Load nested fixture")
                        }
                        OutlinedButton(
                            enabled = !isImporting,
                            onClick = { startMaestroFixtureImport("maestro-encrypted.zip") }
                        ) {
                            Text("Load encrypted fixture")
                        }
                        OutlinedButton(
                            enabled = creationState !is ArchiveCreationUiState.Planning &&
                                creationState !is ArchiveCreationUiState.Starting &&
                                creationState !is ArchiveCreationUiState.StartingSeparate &&
                                creationState !is ArchiveCreationUiState.Running &&
                                creationState !is ArchiveCreationUiState.RunningSeparate,
                            onClick = ::stageDebugCreationFixture
                        ) {
                            Text("Create debug folder archive")
                        }
                        OutlinedButton(
                            enabled = creationState !is ArchiveCreationUiState.Planning &&
                                creationState !is ArchiveCreationUiState.Starting &&
                                creationState !is ArchiveCreationUiState.StartingSeparate &&
                                creationState !is ArchiveCreationUiState.Running &&
                                creationState !is ArchiveCreationUiState.RunningSeparate,
                            onClick = ::stageDebugSplitCreationFixture
                        ) {
                            Text("Create debug split archive")
                        }
                        OutlinedButton(
                            enabled = creationState !is ArchiveCreationUiState.Planning &&
                                creationState !is ArchiveCreationUiState.Starting &&
                                creationState !is ArchiveCreationUiState.StartingSeparate &&
                                creationState !is ArchiveCreationUiState.Running &&
                                creationState !is ArchiveCreationUiState.RunningSeparate,
                            onClick = ::stageDebugSeparateCreationFixture
                        ) {
                            Text("Create debug separate archives")
                        }
                        OutlinedButton(
                            enabled = batchExtractionState !is BatchExtractionUiState.Planning &&
                                batchExtractionState !is BatchExtractionUiState.Running,
                            onClick = ::startDebugBatchImport
                        ) {
                            Text("Run debug batch extraction")
                        }
                        OutlinedButton(
                            enabled = !isImporting &&
                                extractionState !is ArchiveExtractionUiState.Planning &&
                                extractionState !is ArchiveExtractionUiState.Starting &&
                                extractionState !is ArchiveExtractionUiState.Running,
                            onClick = ::startDebugCancellableExtraction
                        ) {
                            Text("Run cancellable extraction")
                        }
                        OutlinedButton(
                            enabled = !isImporting &&
                                extractionState !is ArchiveExtractionUiState.Planning &&
                                extractionState !is ArchiveExtractionUiState.Starting &&
                                extractionState !is ArchiveExtractionUiState.Running,
                            onClick = ::startDebugTimedOutExtraction
                        ) {
                            Text("Run timed-out extraction")
                        }
                    }
                    Spacer(modifier = Modifier.height(24.dp))
                    importedArchive?.let { archive ->
                        if (archiveSessions.current != null) {
                            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                TextButton(onClick = ::navigateBackFromNested) { Text("Back") }
                                Text(
                                    text = archiveSessions.breadcrumbs.joinToString(" / ") { it.archive.displayName },
                                    style = MaterialTheme.typography.bodySmall
                                )
                            }
                        }
                        Text(
                            text = "Imported ${archive.displayName}",
                            style = MaterialTheme.typography.titleMedium
                        )
                        archive.byteSize?.let { size ->
                            Spacer(modifier = Modifier.height(4.dp))
                            Text(
                                text = "$size bytes copied into app cache",
                                style = MaterialTheme.typography.bodyMedium
                            )
                        }
                    }
                    importError?.let { message ->
                        Text(
                            text = message,
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.error
                        )
                    }
                    nestedOpenError?.let { message ->
                        Text(message, color = MaterialTheme.colorScheme.error)
                    }
                    foregroundRecoveryMessage?.let { message ->
                        Text(message, color = MaterialTheme.colorScheme.secondary)
                    }
                    operationReportMessage?.let { message ->
                        Text(message, color = MaterialTheme.colorScheme.secondary)
                    }
                    recoveryRecords.forEach { record ->
                        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                            Text("Recovery available for ${record.archiveDisplayName}", style = MaterialTheme.typography.titleSmall)
                            Text(record.message, color = MaterialTheme.colorScheme.error)
                            Text("Retained output: ${record.destinationLabel}", style = MaterialTheme.typography.bodySmall)
                            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                Button(onClick = { retryRecovery(record) }) { Text("Retry") }
                                OutlinedButton(onClick = { exportRecovery(record.id) }) { Text("Export") }
                                TextButton(onClick = { discardRecovery(record.id) }) { Text("Discard") }
                            }
                        }
                    }
                    ArchiveBatchExtractionPanel(
                        state = batchExtractionState,
                        onStart = ::startBatchExtraction,
                        onCancel = { state ->
                            when (state) {
                                is BatchExtractionUiState.Review -> {
                                    batchExtractionCoordinator.discard(state.review)
                                    batchExtractionState = BatchExtractionUiState.Idle
                                }
                                is BatchExtractionUiState.Running -> {
                                    ArchiveJobForegroundService.cancel(context, state.token)
                                }
                                else -> Unit
                            }
                        }
                    )
                    ArchiveCreationPanel(
                        state = creationState,
                        format = createFormat,
                        password = createPasswordInput,
                        volumeSizeInput = createVolumeSizeInput,
                        separateItems = createSeparateItems,
                        onPasswordChanged = { createPasswordInput = it },
                        onVolumeSizeChanged = { createVolumeSizeInput = it },
                        onSeparateItemsChanged = { createSeparateItems = it },
                        onFormatChanged = { createFormat = it },
                        onChooseFiles = { creationFilesPicker.launch(arrayOf("*/*")) },
                        onChooseFolder = { creationFolderPicker.launch(null) },
                        onStart = ::startCreation,
                        onStartSeparate = ::startSeparateCreation,
                        onShareOutput = { outcome ->
                            shareOutputFiles(
                                outcome.outputPaths.ifEmpty { listOf(outcome.outputPath) }
                            )
                        },
                        onCancel = { state ->
                            when (state) {
                                is ArchiveCreationUiState.Running -> scope.launch(Dispatchers.IO) {
                                    ArchiveJobForegroundService.cancel(context, state.jobId)
                                }
                                is ArchiveCreationUiState.RunningSeparate -> scope.launch(Dispatchers.IO) {
                                    ArchiveJobForegroundService.cancel(context, state.jobId)
                                }
                                is ArchiveCreationUiState.Review -> clearCreationState()
                                is ArchiveCreationUiState.SeparateReview -> clearCreationState()
                                else -> Unit
                            }
                        }
                    )
                    (creationState as? ArchiveCreationUiState.Completed)?.let { completed ->
                        TextButton(onClick = {
                            val outcome = completed.outcome
                            val report = ArchiveOperationReportStore.save(
                                context,
                                ArchiveOperationReport(
                                    operation = "create",
                                    subject = File(outcome.outputPath).name,
                                    status = "completed",
                                    message = "Archive creation complete",
                                    destination = outcome.outputPath,
                                    verified = outcome.verified
                                )
                            )
                            operationReportMessage = "Saved operation report: ${report.name}"
                        }) { Text("Save operation report") }
                    }
            LocalSendPanel(
                archive = importedArchive,
                selectedFileCount = stagedLocalSendFiles?.files?.size ?: 0,
                state = localSendState,
                onDiscover = ::discoverLocalSendDevices,
                onChooseFiles = { localSendFilesPicker.launch(arrayOf("*/*")) },
                onClearFiles = ::clearLocalSendSelection,
                onSend = {
                    rememberLocalSendDevice = false
                    pendingLocalSendDevice = it
                },
                pinInput = localSendPinInput,
                onPinChanged = { localSendPinInput = it },
                onSubmitPin = { device, pin ->
                    localSendPinInput = ""
                    sendSelectedFiles(device, pin)
                },
                onCancelSend = ::cancelLocalSend,
                receiveDestinationLabel = if (receiveDestinationUri == null) "App storage" else "Selected folder",
                onChooseReceiveDestination = { receiveDestinationPicker.launch(null) },
                onStartReceive = ::startLocalReceive,
                onStopReceive = ::stopLocalReceive,
                trustedFingerprints = trustedLocalSendFingerprints,
                onForgetTrustedFingerprint = { fingerprint ->
                    localSendTrustStore.forgetFingerprint(fingerprint)
                    localSendTrustVersion += 1
                }
            )
                    ArchiveListingPanel(
                        state = listingState,
                        passwordInput = passwordInput,
                        onPasswordInputChanged = { passwordInput = it },
                        onSubmitPassword = {
                            importedArchive?.let { archive ->
                                val password = passwordInput.takeIf { it.isNotEmpty() }
                                passwordInput = ""
                                loadArchiveListing(archive, password)
                            }
                        },
                        searchQuery = entrySearchQuery,
                        onSearchQueryChanged = { entrySearchQuery = it },
                        sort = entrySort,
                        onSortChanged = { entrySort = it },
                        viewMode = entryViewMode,
                        onViewModeChanged = { entryViewMode = it },
                        selectedEntryIds = selectedEntryIds,
                        onToggleEntrySelected = { entry ->
                            selectedEntryIds = if (selectedEntryIds.contains(entry.id)) {
                                selectedEntryIds - entry.id
                            } else {
                                selectedEntryIds + entry.id
                            }
                        },
                        onSelectEntries = { entries ->
                            selectedEntryIds = selectedEntryIds + entries.map { it.id }.toSet()
                        },
                        onClearSelection = {
                            selectedEntryIds = emptySet()
                        },
                        previewState = previewState,
                        previewPasswordInput = previewPasswordInput,
                        onPreviewPasswordInputChanged = { previewPasswordInput = it },
                        onPreviewEntry = { entry ->
                            importedArchive?.let { archive ->
                                startPreview(archive, entry, null)
                            }
                        },
                        onOpenNestedArchive = ::openNestedArchive,
                        onSubmitPreviewPassword = { entry ->
                            importedArchive?.let { archive ->
                                val password = previewPasswordInput.takeIf { it.isNotEmpty() }
                                previewPasswordInput = ""
                                startPreview(archive, entry, password)
                            }
                        },
                        testState = testState,
                        testPasswordInput = testPasswordInput,
                        onTestPasswordInputChanged = { testPasswordInput = it },
                        onTestEntries = { entries ->
                            importedArchive?.let { archive ->
                                startArchiveTest(archive, entries, null)
                            }
                        },
                        onSubmitTestPassword = { entries ->
                            importedArchive?.let { archive ->
                                val password = testPasswordInput.takeIf { it.isNotEmpty() }
                                testPasswordInput = ""
                                startArchiveTest(archive, entries, password)
                            }
                        },
                        extractionState = extractionState,
                        extractionPasswordInput = extractionPasswordInput,
                        onExtractionPasswordInputChanged = { extractionPasswordInput = it },
                        onExtractEntries = { entries ->
                            importedArchive?.let { archive ->
                                planExtraction(archive, entries, defaultExtractionDestination, null)
                            }
                        },
                        onChooseDestination = { destinationPicker.launch(null) },
                        onStartExtraction = ::startExtraction,
                        onCancelExtraction = { state ->
                            when (state) {
                                is ArchiveExtractionUiState.Running -> scope.launch(Dispatchers.IO) {
                                    ArchiveJobForegroundService.cancel(context, state.jobId)
                                }
                                is ArchiveExtractionUiState.Review -> clearExtractionState()
                                else -> Unit
                            }
                        },
                        onRetryExtractionWithPassword = { entries ->
                            importedArchive?.let { archive ->
                                val password = extractionPasswordInput.takeIf { it.isNotEmpty() }
                                extractionPasswordInput = ""
                                planExtraction(archive, entries, defaultExtractionDestination, password)
                            }
                        },
                        repackagingState = repackagingState,
                        repackagingPasswordInput = repackagingPasswordInput,
                        onRepackagingPasswordInputChanged = { repackagingPasswordInput = it },
                        onRepackageEntries = ::startRepackaging,
                        onShareRepackagedOutput = { outputPaths ->
                            shareOutputFiles(outputPaths, "Share repackaged archive")
                        },
                        onRetryRepackagingWithPassword = { entries ->
                            val password = repackagingPasswordInput.takeIf { it.isNotEmpty() }
                            repackagingPasswordInput = ""
                            startRepackaging(entries, password)
                        },
                        onStartRepackaging = { state ->
                            if (state is ArchiveRepackagingUiState.Review) runRepackaging(state.review)
                        },
                        onCancelRepackaging = { state ->
                            when (state) {
                                is ArchiveRepackagingUiState.Review -> {
                                    repackagingCoordinator.discard(state.review)
                                    repackagingState = ArchiveRepackagingUiState.Idle
                                }
                                is ArchiveRepackagingUiState.PasswordRequired -> {
                                    repackagingPasswordInput = ""
                                    repackagingState = ArchiveRepackagingUiState.Idle
                                }
                                is ArchiveRepackagingUiState.Running -> {
                                    scope.launch(Dispatchers.IO) { repackagingCoordinator.cancel(state.review) }
                                }
                                else -> Unit
                            }
                        }
                    )
                    (extractionState as? ArchiveExtractionUiState.Completed)?.let { completed ->
                        TextButton(onClick = {
                            val outcome = completed.outcome
                            val report = ArchiveOperationReportStore.save(
                                context,
                                ArchiveOperationReport(
                                    operation = "extract",
                                    subject = importedArchive?.displayName ?: "archive",
                                    status = "completed",
                                    message = "Extraction complete",
                                    destination = outcome.destination,
                                    entries = outcome.writtenEntries
                                )
                            )
                            operationReportMessage = "Saved operation report: ${report.name}"
                        }) { Text("Save operation report") }
                    }
                }

                Column(
                    modifier = Modifier.fillMaxWidth(),
                    verticalArrangement = Arrangement.spacedBy(12.dp)
                ) {
                    OutlinedButton(
                        enabled = creationState !is ArchiveCreationUiState.Planning &&
                            creationState !is ArchiveCreationUiState.Starting &&
                            creationState !is ArchiveCreationUiState.StartingSeparate &&
                            creationState !is ArchiveCreationUiState.Running &&
                            creationState !is ArchiveCreationUiState.RunningSeparate,
                        onClick = { creationFilesPicker.launch(arrayOf("*/*")) }
                    ) {
                        Text("Create archive")
                    }
                    OutlinedButton(
                        enabled = creationState !is ArchiveCreationUiState.Planning &&
                            creationState !is ArchiveCreationUiState.Starting &&
                            creationState !is ArchiveCreationUiState.StartingSeparate &&
                            creationState !is ArchiveCreationUiState.Running &&
                            creationState !is ArchiveCreationUiState.RunningSeparate,
                        onClick = { creationFolderPicker.launch(null) }
                    ) {
                        Text("Create folder archive")
                    }
                    if (BuildConfig.DEBUG) {
                        Box {
                            OutlinedButton(
                                enabled = !isImporting,
                                onClick = { startMaestroFixtureImport() }
                            ) {
                                Text("Load Maestro fixture")
                            }
                            DropdownMenu(
                                expanded = showFixtureMenu,
                                onDismissRequest = { showFixtureMenu = false }
                            ) {
                                val fixtureOptions = listOf(
                                    MaestroFixture("ZIP fixture", "maestro-files.zip"),
                                    MaestroFixture("7z fixture", "maestro-files.7z"),
                                    MaestroFixture("TGZ fixture", "maestro-files.tgz"),
                                    MaestroFixture("TAR.ZST fixture", "maestro-files.tar.zst"),
                                    MaestroFixture("TZAP fixture", "maestro-files.tzap"),
                                    MaestroFixture("TAR.BZ2 fixture", "maestro-files.tar.bz2"),
                                    MaestroFixture("TAR.XZ fixture", "maestro-files.tar.xz"),
                                    MaestroFixture("TAR.LZMA fixture", "maestro-files.tar.lzma"),
                                    MaestroFixture("TAR.LZ fixture", "maestro-files.tar.lz"),
                                    MaestroFixture("TAR.LZO fixture", "maestro-files.tar.lzo"),
                                    MaestroFixture("TAR.Z fixture", "maestro-files.tar.z"),
                                    MaestroFixture("TAR.LZ4 fixture", "maestro-files.tar.lz4"),
                                    MaestroFixture("TAR.UU fixture", "maestro-files.tar.uu"),
                                    MaestroFixture(
                                        "GZIP stream fixture",
                                        "maestro-stream.gz.fixture",
                                        displayAssetNames = listOf("maestro-stream.gz")
                                    ),
                                    MaestroFixture("BZIP2 stream fixture", "maestro-stream.bz2"),
                                    MaestroFixture("XZ stream fixture", "maestro-stream.xz"),
                                    MaestroFixture("LZMA stream fixture", "maestro-stream.lzma"),
                                    MaestroFixture("Lzip stream fixture", "maestro-stream.lz"),
                                    MaestroFixture("LZO stream fixture", "maestro-stream.lzo"),
                                    MaestroFixture("Unix compress stream fixture", "maestro-stream.Z"),
                                    MaestroFixture("LZ4 stream fixture", "maestro-stream.lz4"),
                                    MaestroFixture("Zstd stream fixture", "maestro-stream.zst"),
                                    MaestroFixture("Brotli stream fixture", "maestro-stream.br"),
                                    MaestroFixture("UU stream fixture", "maestro-stream.uu"),
                                    MaestroFixture("B64 stream fixture", "maestro-stream.b64"),
                                    MaestroFixture("Nested ZIP fixture", "maestro-nested.zip"),
                                    MaestroFixture("Encrypted ZIP fixture", "maestro-encrypted.zip"),
                                    MaestroFixture(
                                        "Split ZIP fixture",
                                        "maestro-split.zip",
                                        listOf("maestro-split.z01")
                                    ),
                                    MaestroFixture(
                                        "Split 7z fixture",
                                        "maestro-split.7z.001",
                                        listOf("maestro-split.7z.002")
                                    ),
                                    MaestroFixture(
                                        "Split TZAP fixture",
                                        "maestro-split.vol000.tzap",
                                        listOf(
                                            "maestro-split.vol001.tzap",
                                            "maestro-split.vol002.tzap",
                                            "maestro-split.vol003.tzap",
                                            "maestro-split.vol004.tzap",
                                            "maestro-split.vol005.tzap"
                                        )
                                    ),
                                    MaestroFixture(
                                        "Multipart RAR fixture",
                                        "maestro-split-rar.part1.rar",
                                        listOf(
                                            "maestro-split-rar.part2.rar",
                                            "maestro-split-rar.part3.rar",
                                            "maestro-split-rar.part4.rar",
                                            "maestro-split-rar.part5.rar"
                                        )
                                    ),
                                    MaestroFixture("DEB fixture", "maestro-files.deb"),
                                    MaestroFixture("CAB fixture", "maestro-files.cab"),
                                    MaestroFixture("CPIO fixture", "maestro-files.cpio"),
                                    MaestroFixture("XAR fixture", "maestro-files.xar"),
                                    MaestroFixture("ISO fixture", "maestro-files.iso"),
                                    MaestroFixture("PKG fixture", "maestro-files.pkg"),
                                    MaestroFixture("MSI fixture", "maestro-files.msi"),
                                    MaestroFixture("AR fixture", "maestro-files.ar"),
                                    MaestroFixture("DMG fixture", "maestro-files.dmg"),
                                    MaestroFixture("VHD fixture", "maestro-files.vhd"),
                                    MaestroFixture("VMDK fixture", "maestro-files.vmdk"),
                                    MaestroFixture("UDF fixture", "maestro-files.udf"),
                                    MaestroFixture("RPM fixture", "maestro-files.rpm"),
                                    MaestroFixture("LHA fixture", "maestro-files.lha"),
                                    MaestroFixture("WARC fixture", "maestro-files.warc"),
                                    MaestroFixture("MTREE fixture", "maestro-files.mtree")
                                )
                                Box(modifier = Modifier.width(360.dp).height(600.dp)) {
                                    Column(modifier = Modifier.verticalScroll(rememberScrollState())) {
                                        fixtureOptions.forEach { fixture ->
                                            DropdownMenuItem(
                                                text = { Text(fixture.label) },
                                                onClick = {
                                                    showFixtureMenu = false
                                                    startMaestroFixtureImport(
                                                        fixture.assetName,
                                                        fixture.companionAssetNames,
                                                        displayAssetNames = fixture.displayAssetNames.ifEmpty {
                                                            listOf(fixture.assetName) + fixture.companionAssetNames
                                                        }
                                                    )
                                                }
                                            )
                                        }
                                    }
                                }
                            }
                        }
                        OutlinedButton(
                            enabled = !isImporting,
                            onClick = { showFixtureMenu = true }
                        ) {
                            Text("Load test fixture")
                        }
                    }
                    Button(
                        enabled = !isImporting,
                        onClick = { documentPicker.launch(arrayOf("*/*")) },
                        modifier = Modifier.semantics {
                            contentDescription = "Open Archive"
                        }
                    ) {
                        Text(if (isImporting) "Importing" else "Open Archive")
                    }
                    OutlinedButton(
                        enabled = batchExtractionState !is BatchExtractionUiState.Planning &&
                            batchExtractionState !is BatchExtractionUiState.Running,
                        onClick = { batchArchivePicker.launch(arrayOf("*/*")) },
                        modifier = Modifier.semantics {
                            contentDescription = "Batch extract"
                        }
                    ) {
                        Text("Batch extract")
                    }
                }
            }
        }
        pendingLocalSendDevice?.let { device ->
            AlertDialog(
                onDismissRequest = { pendingLocalSendDevice = null },
                title = { Text("Confirm local transfer") },
                text = {
                    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        Text("Send the selected archive or files to ${device.alias}?")
                        Text("Address: ${device.address}", style = MaterialTheme.typography.bodySmall)
                        device.fingerprint?.let {
                            Text("Fingerprint: $it", style = MaterialTheme.typography.bodySmall)
                        }
                        if (localSendTrustStore.isTrusted(device)) {
                            Text("Known fingerprint; still confirm before sending.", style = MaterialTheme.typography.bodySmall)
                        } else {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Checkbox(
                                    checked = rememberLocalSendDevice,
                                    onCheckedChange = { rememberLocalSendDevice = it }
                                )
                                Text("Remember this fingerprint for future confirmations.")
                            }
                        }
                        Text(
                            "Only continue if you recognize this device and fingerprint.",
                            style = MaterialTheme.typography.bodySmall
                        )
                    }
                },
                confirmButton = {
                    Button(onClick = {
                        val confirmedDevice = pendingLocalSendDevice
                        pendingLocalSendDevice = null
                        if (rememberLocalSendDevice) {
                            confirmedDevice?.let(localSendTrustStore::remember)
                            localSendTrustVersion += 1
                        }
                        rememberLocalSendDevice = false
                        confirmedDevice?.let(::sendSelectedFiles)
                    }) { Text("Send") }
                },
                dismissButton = {
                    TextButton(onClick = { pendingLocalSendDevice = null }) { Text("Cancel") }
                }
            )
        }
        if (showHelpDialog) {
            AlertDialog(
                onDismissRequest = { showHelpDialog = false },
                title = { Text("About ZManager") },
                text = {
                    Text(
                        "ZManager keeps archive listing, extraction, verification, and creation in the Rust core. " +
                            "Choose an archive to inspect it, select entries to extract or repackage, and use " +
                            "Share on local network for LocalSend-compatible transfers. Passwords are transient " +
                            "and are not included in operation reports."
                    )
                },
                confirmButton = {
                    TextButton(onClick = { showHelpDialog = false }) { Text("Close") }
                }
            )
        }
    }
}

private data class MaestroFixture(
    val label: String,
    val assetName: String,
    val companionAssetNames: List<String> = emptyList(),
    val displayAssetNames: List<String> = emptyList()
)

@Composable
private fun ArchiveCreationPanel(
    state: ArchiveCreationUiState,
    format: CreateArchiveFormat,
    password: String,
    volumeSizeInput: String,
    separateItems: Boolean,
    onPasswordChanged: (String) -> Unit,
    onVolumeSizeChanged: (String) -> Unit,
    onSeparateItemsChanged: (Boolean) -> Unit,
    onFormatChanged: (CreateArchiveFormat) -> Unit,
    onChooseFiles: () -> Unit,
    onChooseFolder: () -> Unit,
    onStart: (ArchiveCreationReview) -> Unit,
    onStartSeparate: (ArchiveSeparateCreationReview) -> Unit,
    onShareOutput: (ArchiveCreationOutcome.Completed) -> Unit,
    onCancel: (ArchiveCreationUiState) -> Unit
) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text("Create archive", style = MaterialTheme.typography.titleMedium)
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            CreateFormatButton("ZIP", CreateArchiveFormat.ZIP, format, onFormatChanged)
            CreateFormatButton("7z", CreateArchiveFormat.SEVEN_Z, format, onFormatChanged)
            CreateFormatButton("TAR.ZST", CreateArchiveFormat.TAR_ZST, format, onFormatChanged)
            CreateFormatButton("TAR.GZ", CreateArchiveFormat.TAR_GZ, format, onFormatChanged)
            CreateFormatButton("TZAP", CreateArchiveFormat.TZAP, format, onFormatChanged)
            CreateFormatButton("AAR", CreateArchiveFormat.APPLE_ARCHIVE, format, onFormatChanged)
        }
        OutlinedTextField(
            value = password,
            onValueChange = onPasswordChanged,
            label = { Text("Optional password") },
            visualTransformation = PasswordVisualTransformation(),
            singleLine = true,
            modifier = Modifier.fillMaxWidth()
        )
        if (ArchiveVolumeSupport.supportsVolumeSize(format)) {
            OutlinedTextField(
                value = volumeSizeInput,
                onValueChange = onVolumeSizeChanged,
                label = { Text("Optional split volume size (for example 4m)") },
                supportingText = { Text("Creates a numbered volume set; leave blank for one archive.") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth()
            )
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            Checkbox(checked = separateItems, onCheckedChange = onSeparateItemsChanged)
            Text("Archive each selected item separately")
        }
        when (state) {
            ArchiveCreationUiState.Idle -> Text("Choose files or a folder to begin.")
            ArchiveCreationUiState.Planning -> Text("Preparing creation plan")
            is ArchiveCreationUiState.Review -> {
                Text("${state.review.plan.totalEntries} entries, ${state.review.plan.totalBytes} bytes")
                state.review.plan.warnings.forEach { warning ->
                    Text(warning.message, color = MaterialTheme.colorScheme.error)
                }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Button(onClick = { onStart(state.review) }) { Text("Start") }
                    TextButton(onClick = { onCancel(state) }) { Text("Cancel") }
                }
            }
            is ArchiveCreationUiState.SeparateReview -> {
                val entries = state.review.items.sumOf { it.plan.totalEntries }
                val bytes = state.review.items.sumOf { it.plan.totalBytes }
                Text("${state.review.items.size} archives, $entries entries, $bytes bytes")
                Text("Each selected item will become its own ${format.name} archive.")
                state.review.items.forEach { item ->
                    Text(File(item.request.destinationArchivePath).name, style = MaterialTheme.typography.bodySmall)
                }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Button(onClick = { onStartSeparate(state.review) }) { Text("Start separate archives") }
                    TextButton(onClick = { onCancel(state) }) { Text("Cancel") }
                }
            }
            is ArchiveCreationUiState.Starting -> Text("Starting archive creation")
            is ArchiveCreationUiState.StartingSeparate -> Text("Starting separate archive creation")
            is ArchiveCreationUiState.Running -> {
                Text(state.message)
                TextButton(onClick = { onCancel(state) }) { Text("Cancel") }
            }
            is ArchiveCreationUiState.RunningSeparate -> {
                Text(state.message)
                TextButton(onClick = { onCancel(state) }) { Text("Cancel") }
            }
            is ArchiveCreationUiState.Completed -> {
                if (state.outcome.outputPaths.size > 1) {
                    Text("${state.outcome.outputPaths.size} output files committed")
                    Text(
                        "Additional output files are stored beside the archive.",
                        style = MaterialTheme.typography.bodySmall
                    )
                }
                Text(if (state.outcome.verified) "Verified" else "Created without verification")
                Text("Created ${File(state.outcome.outputPath).name}")
                OutlinedButton(onClick = { onShareOutput(state.outcome) }) {
                    Text("Share output")
                }
            }
            ArchiveCreationUiState.Cancelled -> Text("Archive creation cancelled")
            is ArchiveCreationUiState.Failed -> Text(state.message, color = MaterialTheme.colorScheme.error)
        }
        if (state is ArchiveCreationUiState.Idle || state is ArchiveCreationUiState.Failed || state is ArchiveCreationUiState.Completed) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton(onClick = onChooseFiles) { Text("Choose files") }
                OutlinedButton(onClick = onChooseFolder) { Text("Choose folder") }
            }
        }
    }
}

@Composable
private fun ArchiveBatchExtractionPanel(
    state: BatchExtractionUiState,
    onStart: (BatchExtractionReview) -> Unit,
    onCancel: (BatchExtractionUiState) -> Unit
) {
    when (state) {
        BatchExtractionUiState.Idle -> Unit
        BatchExtractionUiState.Planning -> Text("Preparing batch extraction plans")
        is BatchExtractionUiState.Review -> Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text("Review batch extraction", style = MaterialTheme.typography.titleMedium)
            Text("${state.review.items.size} archives will be extracted to separate app-storage folders.")
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(onClick = { onStart(state.review) }) { Text("Start batch extraction") }
                TextButton(onClick = { onCancel(state) }) { Text("Cancel") }
            }
        }
        is BatchExtractionUiState.Running -> Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("Batch extraction running")
            TextButton(onClick = { onCancel(state) }) { Text("Cancel") }
        }
        is BatchExtractionUiState.Completed -> Text(state.message)
        BatchExtractionUiState.Cancelled -> Text("Batch extraction cancelled")
        is BatchExtractionUiState.Failed -> Text(state.message, color = MaterialTheme.colorScheme.error)
    }
}

@Composable
private fun CreateFormatButton(
    label: String,
    value: CreateArchiveFormat,
    selected: CreateArchiveFormat,
    onSelected: (CreateArchiveFormat) -> Unit
) {
    if (value == selected) {
        Button(onClick = { onSelected(value) }) { Text(label) }
    } else {
        OutlinedButton(onClick = { onSelected(value) }) { Text(label) }
    }
}

@Composable
private fun LocalSendPanel(
    archive: ImportedArchive?,
    selectedFileCount: Int,
    state: LocalSendUiState,
    onDiscover: () -> Unit,
    onChooseFiles: () -> Unit,
    onClearFiles: () -> Unit,
    onSend: (LocalSendDevice) -> Unit,
    pinInput: String,
    onPinChanged: (String) -> Unit,
    onSubmitPin: (LocalSendDevice, String) -> Unit,
    onCancelSend: () -> Unit,
    receiveDestinationLabel: String,
    onChooseReceiveDestination: () -> Unit,
    onStartReceive: () -> Unit,
    onStopReceive: () -> Unit,
    trustedFingerprints: List<String>,
    onForgetTrustedFingerprint: (String) -> Unit
) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(
            "Share on local network",
            modifier = Modifier.semantics { contentDescription = "LocalSend sharing panel" },
            style = MaterialTheme.typography.titleMedium
        )
        Text(
            "Only send to devices you recognize on this local network.",
            style = MaterialTheme.typography.bodySmall
        )
        val hasSelection = archive != null || selectedFileCount > 0
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedButton(onClick = onChooseFiles) { Text("Choose files") }
            if (selectedFileCount > 0) {
                TextButton(onClick = onClearFiles) { Text("Clear") }
            }
        }
        if (selectedFileCount > 0) {
            Text("$selectedFileCount file(s) selected for sharing")
        }
        if (trustedFingerprints.isNotEmpty()) {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text("Trusted devices", style = MaterialTheme.typography.titleSmall)
                trustedFingerprints.forEach { fingerprint ->
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Text(
                            fingerprint,
                            modifier = Modifier.weight(1f),
                            style = MaterialTheme.typography.bodySmall
                        )
                        TextButton(
                            onClick = { onForgetTrustedFingerprint(fingerprint) },
                            modifier = Modifier.semantics {
                                contentDescription = "Forget trusted device $fingerprint"
                            }
                        ) { Text("Forget") }
                    }
                }
            }
        }
        Button(enabled = hasSelection && state !is LocalSendUiState.Discovering, onClick = onDiscover) {
            Text(if (state is LocalSendUiState.Discovering) "Discovering" else "Find LocalSend devices")
        }
        if (state is LocalSendUiState.Receiving) {
            OutlinedButton(onClick = onStopReceive) { Text("Stop receiving") }
            Text("Receiving LocalSend files on port ${state.port} into $receiveDestinationLabel.")
        } else {
            OutlinedButton(onClick = onChooseReceiveDestination) { Text("Receive to: $receiveDestinationLabel") }
            OutlinedButton(onClick = onStartReceive) { Text("Receive files") }
        }
        when (state) {
            LocalSendUiState.Idle, LocalSendUiState.Discovering -> Unit
            is LocalSendUiState.Receiving -> Unit
            is LocalSendUiState.Devices -> {
                if (state.devices.isEmpty()) Text("No compatible devices found.")
                state.devices.forEach { device ->
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Column(modifier = Modifier.weight(1f)) {
                            Text("${device.alias} (${device.address})")
                            device.fingerprint?.let { Text("Fingerprint: $it", style = MaterialTheme.typography.bodySmall) }
                        }
                        OutlinedButton(onClick = { onSend(device) }) {
                            Text(if (selectedFileCount > 0) "Send files" else "Send archive")
                        }
                    }
                }
            }
            is LocalSendUiState.Sending -> Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("${state.message} to ${state.device.alias}", modifier = Modifier.weight(1f))
                OutlinedButton(onClick = onCancelSend) { Text("Cancel") }
            }
            is LocalSendUiState.PinRequired -> Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text("${state.device.alias} requires a PIN before receiving this transfer.")
                OutlinedTextField(
                    value = pinInput,
                    onValueChange = onPinChanged,
                    label = { Text("LocalSend PIN") },
                    singleLine = true,
                    visualTransformation = PasswordVisualTransformation()
                )
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Button(
                        enabled = pinInput.isNotBlank(),
                        onClick = { onSubmitPin(state.device, pinInput) }
                    ) { Text("Retry with PIN") }
                    TextButton(onClick = onCancelSend) { Text("Cancel") }
                }
            }
            is LocalSendUiState.Completed -> Text("Sent to ${state.device.alias}")
            is LocalSendUiState.Failed -> Text(state.message, color = MaterialTheme.colorScheme.error)
        }
    }
}

@Composable
private fun ArchiveListingPanel(
    state: ArchiveListingState,
    passwordInput: String,
    onPasswordInputChanged: (String) -> Unit,
    onSubmitPassword: () -> Unit,
    searchQuery: String,
    onSearchQueryChanged: (String) -> Unit,
    sort: ArchiveEntrySort,
    onSortChanged: (ArchiveEntrySort) -> Unit,
    viewMode: ArchiveEntryViewMode,
    onViewModeChanged: (ArchiveEntryViewMode) -> Unit,
    selectedEntryIds: Set<String>,
    onToggleEntrySelected: (ArchiveEntrySummary) -> Unit,
    onSelectEntries: (List<ArchiveEntrySummary>) -> Unit,
    onClearSelection: () -> Unit,
    previewState: ArchivePreviewState,
    previewPasswordInput: String,
    onPreviewPasswordInputChanged: (String) -> Unit,
    onPreviewEntry: (ArchiveEntrySummary) -> Unit,
    onOpenNestedArchive: (ArchiveEntrySummary) -> Unit,
    onSubmitPreviewPassword: (ArchiveEntrySummary) -> Unit,
    testState: ArchiveTestState,
    testPasswordInput: String,
    onTestPasswordInputChanged: (String) -> Unit,
    onTestEntries: (List<ArchiveEntrySummary>) -> Unit,
    onSubmitTestPassword: (List<ArchiveEntrySummary>) -> Unit,
    extractionState: ArchiveExtractionUiState,
    extractionPasswordInput: String,
    onExtractionPasswordInputChanged: (String) -> Unit,
    onExtractEntries: (List<ArchiveEntrySummary>) -> Unit,
    onChooseDestination: () -> Unit,
    onStartExtraction: (ExtractionReview) -> Unit,
    onCancelExtraction: (ArchiveExtractionUiState) -> Unit,
    onRetryExtractionWithPassword: (List<ArchiveEntrySummary>) -> Unit,
    repackagingState: ArchiveRepackagingUiState,
    repackagingPasswordInput: String,
    onRepackagingPasswordInputChanged: (String) -> Unit,
    onRepackageEntries: (List<ArchiveEntrySummary>) -> Unit,
    onShareRepackagedOutput: (List<String>) -> Unit,
    onStartRepackaging: (ArchiveRepackagingUiState) -> Unit,
    onRetryRepackagingWithPassword: (List<ArchiveEntrySummary>) -> Unit,
    onCancelRepackaging: (ArchiveRepackagingUiState) -> Unit
) {
    when (state) {
        ArchiveListingState.Idle -> Unit
        ArchiveListingState.Loading -> {
            Text(
                text = "Reading archive",
                style = MaterialTheme.typography.bodyMedium
            )
        }
        is ArchiveListingState.Ready -> ArchiveListingReadyPanel(
            summary = state.summary,
            searchQuery = searchQuery,
            onSearchQueryChanged = onSearchQueryChanged,
            sort = sort,
            onSortChanged = onSortChanged,
            viewMode = viewMode,
            onViewModeChanged = onViewModeChanged,
            selectedEntryIds = selectedEntryIds,
            onToggleEntrySelected = onToggleEntrySelected,
            onSelectEntries = onSelectEntries,
            onClearSelection = onClearSelection,
            previewState = previewState,
            previewPasswordInput = previewPasswordInput,
            onPreviewPasswordInputChanged = onPreviewPasswordInputChanged,
            onPreviewEntry = onPreviewEntry,
            onOpenNestedArchive = onOpenNestedArchive,
            onSubmitPreviewPassword = onSubmitPreviewPassword,
            testState = testState,
            testPasswordInput = testPasswordInput,
            onTestPasswordInputChanged = onTestPasswordInputChanged,
            onTestEntries = onTestEntries,
            onSubmitTestPassword = onSubmitTestPassword,
            extractionState = extractionState,
            extractionPasswordInput = extractionPasswordInput,
            onExtractionPasswordInputChanged = onExtractionPasswordInputChanged,
            onExtractEntries = onExtractEntries,
            onChooseDestination = onChooseDestination,
            onStartExtraction = onStartExtraction,
            onCancelExtraction = onCancelExtraction,
            onRetryExtractionWithPassword = onRetryExtractionWithPassword,
            repackagingState = repackagingState,
            repackagingPasswordInput = repackagingPasswordInput,
            onRepackagingPasswordInputChanged = onRepackagingPasswordInputChanged,
            onRepackageEntries = onRepackageEntries,
            onShareRepackagedOutput = onShareRepackagedOutput,
            onStartRepackaging = onStartRepackaging,
            onRetryRepackagingWithPassword = onRetryRepackagingWithPassword,
            onCancelRepackaging = onCancelRepackaging
        )
        is ArchiveListingState.PasswordRequired -> {
            Spacer(modifier = Modifier.height(8.dp))
            Text(
                text = state.error.message,
                style = MaterialTheme.typography.bodyMedium
            )
            state.error.recoveryHint?.let { hint ->
                Text(
                    text = hint,
                    style = MaterialTheme.typography.bodySmall
                )
            }
            OutlinedTextField(
                value = passwordInput,
                onValueChange = onPasswordInputChanged,
                label = { Text("Password") },
                singleLine = true,
                visualTransformation = PasswordVisualTransformation(),
                modifier = Modifier.fillMaxWidth()
            )
            Button(
                enabled = passwordInput.isNotEmpty(),
                onClick = onSubmitPassword
            ) {
                Text("Retry")
            }
        }
        is ArchiveListingState.Failed -> {
            Spacer(modifier = Modifier.height(8.dp))
            Text(
                text = state.error.message,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.error
            )
            state.error.recoveryHint?.let { hint ->
                Text(
                    text = hint,
                    style = MaterialTheme.typography.bodySmall
                )
            }
        }
    }
}

@Composable
private fun ArchiveListingReadyPanel(
    summary: ArchiveListingSummary,
    searchQuery: String,
    onSearchQueryChanged: (String) -> Unit,
    sort: ArchiveEntrySort,
    onSortChanged: (ArchiveEntrySort) -> Unit,
    viewMode: ArchiveEntryViewMode,
    onViewModeChanged: (ArchiveEntryViewMode) -> Unit,
    selectedEntryIds: Set<String>,
    onToggleEntrySelected: (ArchiveEntrySummary) -> Unit,
    onSelectEntries: (List<ArchiveEntrySummary>) -> Unit,
    onClearSelection: () -> Unit,
    previewState: ArchivePreviewState,
    previewPasswordInput: String,
    onPreviewPasswordInputChanged: (String) -> Unit,
    onPreviewEntry: (ArchiveEntrySummary) -> Unit,
    onOpenNestedArchive: (ArchiveEntrySummary) -> Unit,
    onSubmitPreviewPassword: (ArchiveEntrySummary) -> Unit,
    testState: ArchiveTestState,
    testPasswordInput: String,
    onTestPasswordInputChanged: (String) -> Unit,
    onTestEntries: (List<ArchiveEntrySummary>) -> Unit,
    onSubmitTestPassword: (List<ArchiveEntrySummary>) -> Unit,
    extractionState: ArchiveExtractionUiState,
    extractionPasswordInput: String,
    onExtractionPasswordInputChanged: (String) -> Unit,
    onExtractEntries: (List<ArchiveEntrySummary>) -> Unit,
    onChooseDestination: () -> Unit,
    onStartExtraction: (ExtractionReview) -> Unit,
    onCancelExtraction: (ArchiveExtractionUiState) -> Unit,
    onRetryExtractionWithPassword: (List<ArchiveEntrySummary>) -> Unit,
    repackagingState: ArchiveRepackagingUiState,
    repackagingPasswordInput: String,
    onRepackagingPasswordInputChanged: (String) -> Unit,
    onRepackageEntries: (List<ArchiveEntrySummary>) -> Unit,
    onShareRepackagedOutput: (List<String>) -> Unit,
    onStartRepackaging: (ArchiveRepackagingUiState) -> Unit,
    onRetryRepackagingWithPassword: (List<ArchiveEntrySummary>) -> Unit,
    onCancelRepackaging: (ArchiveRepackagingUiState) -> Unit
) {
    val groups = summary.visibleGroups(searchQuery, sort, viewMode)
    val selectedEntries = summary.selectedEntries(selectedEntryIds)
    val previewEntry = summary.previewableSelectedEntry(selectedEntryIds)

    Spacer(modifier = Modifier.height(8.dp))
    Text(
        text = "${summary.formatLabel} - ${summary.entryCount} entries",
        style = MaterialTheme.typography.titleMedium
    )
    summary.totalSize?.let { totalSize ->
        Text(
            text = "$totalSize bytes total",
            style = MaterialTheme.typography.bodyMedium
        )
    }
    summary.warnings.forEach { warning ->
        Text(
            text = warning,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.error
        )
    }
    OutlinedTextField(
        value = searchQuery,
        onValueChange = onSearchQueryChanged,
        label = { Text("Search") },
        singleLine = true,
        modifier = Modifier.fillMaxWidth()
    )
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        EntrySortButton("Name", ArchiveEntrySort.PATH_ASCENDING, sort, onSortChanged)
        EntrySortButton("Size", ArchiveEntrySort.SIZE_DESCENDING, sort, onSortChanged)
        EntrySortButton("Type", ArchiveEntrySort.KIND_ASCENDING, sort, onSortChanged)
    }
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        EntryViewModeButton("List", ArchiveEntryViewMode.LIST, viewMode, onViewModeChanged)
        EntryViewModeButton("Folders", ArchiveEntryViewMode.FOLDERS, viewMode, onViewModeChanged)
    }
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text(
            text = "${selectedEntries.size} selected",
            style = MaterialTheme.typography.bodyMedium,
            modifier = Modifier.weight(1f)
        )
        TextButton(
            enabled = groups.any { it.entries.isNotEmpty() },
            onClick = { onSelectEntries(groups.flatMap { it.entries }) }
        ) {
            Text("Select visible")
        }
        TextButton(
            enabled = selectedEntries.isNotEmpty(),
            onClick = onClearSelection
        ) {
            Text("Clear")
        }
        Button(
            enabled = previewEntry != null && previewState !is ArchivePreviewState.Loading,
            onClick = { previewEntry?.let(onPreviewEntry) }
        ) {
            Text("Preview")
        }
        Button(
            enabled = testState !is ArchiveTestState.Loading,
            onClick = { onTestEntries(selectedEntries) }
        ) {
            Text("Test")
        }
    }
    Button(
        enabled = extractionState !is ArchiveExtractionUiState.Planning &&
            extractionState !is ArchiveExtractionUiState.Starting &&
            extractionState !is ArchiveExtractionUiState.Running,
        onClick = { onExtractEntries(selectedEntries.ifEmpty { summary.entries }) }
    ) {
        Text("Extract")
    }
    Button(
        enabled = selectedEntries.isNotEmpty() && repackagingState !is ArchiveRepackagingUiState.Planning &&
            repackagingState !is ArchiveRepackagingUiState.Review &&
            repackagingState !is ArchiveRepackagingUiState.Running,
        onClick = { onRepackageEntries(selectedEntries) }
    ) {
        Text("Create archive from selection")
    }
    ArchiveRepackagingPanel(
        state = repackagingState,
        passwordInput = repackagingPasswordInput,
        onPasswordInputChanged = onRepackagingPasswordInputChanged,
        onStart = onStartRepackaging,
        onRetryWithPassword = onRetryRepackagingWithPassword,
        onShareOutput = onShareRepackagedOutput,
        onCancel = onCancelRepackaging
    )
    ArchivePreviewPanel(
        state = previewState,
        passwordInput = previewPasswordInput,
        onPasswordInputChanged = onPreviewPasswordInputChanged,
        onSubmitPassword = onSubmitPreviewPassword
    )
    ArchiveTestPanel(
        state = testState,
        selectedEntries = selectedEntries,
        passwordInput = testPasswordInput,
        onPasswordInputChanged = onTestPasswordInputChanged,
        onSubmitPassword = onSubmitTestPassword
    )
    ArchiveExtractionPanel(
        state = extractionState,
        selectedEntries = selectedEntries.ifEmpty { summary.entries },
        passwordInput = extractionPasswordInput,
        onPasswordInputChanged = onExtractionPasswordInputChanged,
        onChooseDestination = onChooseDestination,
        onStart = onStartExtraction,
        onCancel = onCancelExtraction,
        onRetryWithPassword = onRetryExtractionWithPassword
    )
    LazyColumn(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(max = 240.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp)
    ) {
        if (groups.isEmpty()) {
            item {
                Text(
                    text = "No entries",
                    style = MaterialTheme.typography.bodyMedium
                )
            }
        }
        groups.forEach { group ->
            item(key = "group-${group.id}") {
                Text(
                    text = group.label,
                    style = MaterialTheme.typography.titleSmall
                )
            }
            items(group.entries, key = { it.id }) { entry ->
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Checkbox(
                        checked = selectedEntryIds.contains(entry.id),
                        onCheckedChange = { onToggleEntrySelected(entry) },
                        modifier = Modifier.semantics {
                            contentDescription = "Select ${entry.displayName}"
                        }
                    )
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            text = entry.displayName,
                            style = MaterialTheme.typography.bodyMedium
                        )
                        Text(
                            text = listOfNotNull(
                                entry.path,
                                entry.kind.name.lowercase(Locale.ROOT).replace('_', ' '),
                                entry.size?.let { "$it bytes" }
                            ).joinToString(" - "),
                            style = MaterialTheme.typography.bodySmall
                        )
                    }
                    if (NestedArchiveSupport.canOpen(entry)) {
                        TextButton(onClick = { onOpenNestedArchive(entry) }) {
                            Text("Open")
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun ArchiveRepackagingPanel(
    state: ArchiveRepackagingUiState,
    passwordInput: String,
    onPasswordInputChanged: (String) -> Unit,
    onStart: (ArchiveRepackagingUiState) -> Unit,
    onRetryWithPassword: (List<ArchiveEntrySummary>) -> Unit,
    onShareOutput: (List<String>) -> Unit,
    onCancel: (ArchiveRepackagingUiState) -> Unit
) {
    when (state) {
        ArchiveRepackagingUiState.Idle -> Unit
        ArchiveRepackagingUiState.Planning -> Text("Preparing repackaging plan")
        is ArchiveRepackagingUiState.PasswordRequired -> Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(state.message, color = MaterialTheme.colorScheme.error)
            OutlinedTextField(
                value = passwordInput,
                onValueChange = onPasswordInputChanged,
                label = { Text("Archive password") },
                singleLine = true,
                visualTransformation = PasswordVisualTransformation()
            )
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(
                    enabled = passwordInput.isNotEmpty(),
                    onClick = { onRetryWithPassword(state.entries) }
                ) { Text("Retry") }
                TextButton(onClick = { onCancel(state) }) { Text("Cancel") }
            }
        }
        is ArchiveRepackagingUiState.Review -> Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text("Ready to repackage ${state.review.request.selectedPaths.size} selected path(s)")
            Text("Output: ${state.review.request.destinationArchivePath}", style = MaterialTheme.typography.bodySmall)
            Text("Format: ${state.review.request.format.name}; verification enabled", style = MaterialTheme.typography.bodySmall)
            state.review.extractionReview.plan.warnings.forEach { warning ->
                Text(warning.message, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall)
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(onClick = { onStart(state) }) { Text("Start") }
                OutlinedButton(onClick = { onCancel(state) }) { Text("Cancel") }
            }
        }
        is ArchiveRepackagingUiState.Running -> Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(state.message, modifier = Modifier.weight(1f))
            TextButton(onClick = { onCancel(state) }) { Text("Cancel") }
        }
        is ArchiveRepackagingUiState.Completed -> {
            Text("Created ${state.outcome.outputPath}")
            if (state.outcome.outputPaths.size > 1) {
                Text("${state.outcome.outputPaths.size} volumes committed")
            }
            Text(if (state.outcome.verified) "Verified" else "Created without verification")
            OutlinedButton(onClick = {
                onShareOutput(state.outcome.outputPaths.ifEmpty { listOf(state.outcome.outputPath) })
            }) {
                Text("Share output")
            }
        }
        ArchiveRepackagingUiState.Cancelled -> Text("Repackaging cancelled")
        is ArchiveRepackagingUiState.Failed -> Text(state.message, color = MaterialTheme.colorScheme.error)
    }
}

@Composable
private fun EntrySortButton(
    label: String,
    value: ArchiveEntrySort,
    selected: ArchiveEntrySort,
    onSelected: (ArchiveEntrySort) -> Unit
) {
    if (value == selected) {
        Button(onClick = { onSelected(value) }) {
            Text(label)
        }
    } else {
        OutlinedButton(onClick = { onSelected(value) }) {
            Text(label)
        }
    }
}

@Composable
private fun EntryViewModeButton(
    label: String,
    value: ArchiveEntryViewMode,
    selected: ArchiveEntryViewMode,
    onSelected: (ArchiveEntryViewMode) -> Unit
) {
    if (value == selected) {
        Button(onClick = { onSelected(value) }) {
            Text(label)
        }
    } else {
        OutlinedButton(onClick = { onSelected(value) }) {
            Text(label)
        }
    }
}

private sealed interface ArchiveExtractionUiState {
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

private fun Throwable.toExtractionUiState(): ArchiveExtractionUiState = when (this) {
    is ZmanagerGuiException.Bridge -> if (code == "password_required" || code == "invalid_password") {
        ArchiveExtractionUiState.PasswordRequired(userMessage)
    } else {
        ArchiveExtractionUiState.Failed(userMessage)
    }
    else -> ArchiveExtractionUiState.Failed(message ?: "Unable to extract that archive.")
}

@Composable
private fun ArchiveExtractionPanel(
    state: ArchiveExtractionUiState,
    selectedEntries: List<ArchiveEntrySummary>,
    passwordInput: String,
    onPasswordInputChanged: (String) -> Unit,
    onChooseDestination: () -> Unit,
    onStart: (ExtractionReview) -> Unit,
    onCancel: (ArchiveExtractionUiState) -> Unit,
    onRetryWithPassword: (List<ArchiveEntrySummary>) -> Unit
) {
    when (state) {
        ArchiveExtractionUiState.Idle -> Unit
        is ArchiveExtractionUiState.Planning -> Text("Preparing extraction plan for ${state.destination}")
        is ArchiveExtractionUiState.Review -> Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text("Review extraction", style = MaterialTheme.typography.titleMedium)
            Text("${state.review.plan.writableEntries} files will be extracted to ${state.review.destination.label}.")
            state.review.plan.estimatedBytes?.let { Text("$it bytes estimated") }
            state.review.plan.warnings.forEach { warning ->
                Text(warning.message, color = MaterialTheme.colorScheme.error)
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton(onClick = onChooseDestination) { Text("Choose folder") }
                OutlinedButton(onClick = { onCancel(state) }) { Text("Cancel") }
                Button(onClick = { onStart(state.review) }) { Text("Start extraction") }
            }
        }
        is ArchiveExtractionUiState.Starting -> Text("Starting extraction")
        is ArchiveExtractionUiState.Running -> Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(state.message)
            OutlinedButton(onClick = { onCancel(state) }) { Text("Cancel extraction") }
        }
        is ArchiveExtractionUiState.Completed -> Text(
            "Extraction complete: ${state.outcome.writtenEntries} files saved to ${state.outcome.destination}."
        )
        ArchiveExtractionUiState.Cancelled -> Text("Extraction cancelled")
        is ArchiveExtractionUiState.PasswordRequired -> Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(state.message)
            OutlinedTextField(
                value = passwordInput,
                onValueChange = onPasswordInputChanged,
                label = { Text("Password") },
                singleLine = true,
                visualTransformation = PasswordVisualTransformation(),
                modifier = Modifier.fillMaxWidth()
            )
            Button(
                enabled = passwordInput.isNotEmpty(),
                onClick = { onRetryWithPassword(selectedEntries) }
            ) { Text("Retry extraction") }
        }
        is ArchiveExtractionUiState.Failed -> Text(state.message, color = MaterialTheme.colorScheme.error)
        is ArchiveExtractionUiState.RecoveryAvailable -> Text(state.message, color = MaterialTheme.colorScheme.error)
    }
}

@Composable
private fun ArchivePreviewPanel(
    state: ArchivePreviewState,
    passwordInput: String,
    onPasswordInputChanged: (String) -> Unit,
    onSubmitPassword: (ArchiveEntrySummary) -> Unit
) {
    when (state) {
        ArchivePreviewState.Idle -> Unit
        is ArchivePreviewState.Loading -> {
            Text(
                text = "Preparing preview for ${state.entry.displayName}",
                style = MaterialTheme.typography.bodyMedium
            )
        }
        is ArchivePreviewState.Ready -> {
            Text(
                text = "Preview prepared for ${state.summary.entry.displayName}",
                style = MaterialTheme.typography.bodyMedium
            )
            state.summary.warnings.forEach { warning ->
                Text(
                    text = warning,
                    style = MaterialTheme.typography.bodySmall
                )
            }
        }
        is ArchivePreviewState.PasswordRequired -> {
            Spacer(modifier = Modifier.height(8.dp))
            Text(
                text = state.error.message,
                style = MaterialTheme.typography.bodyMedium
            )
            state.error.recoveryHint?.let { hint ->
                Text(
                    text = hint,
                    style = MaterialTheme.typography.bodySmall
                )
            }
            OutlinedTextField(
                value = passwordInput,
                onValueChange = onPasswordInputChanged,
                label = { Text("Password") },
                singleLine = true,
                visualTransformation = PasswordVisualTransformation(),
                modifier = Modifier.fillMaxWidth()
            )
            Button(
                enabled = passwordInput.isNotEmpty(),
                onClick = { onSubmitPassword(state.entry) }
            ) {
                Text("Retry preview")
            }
        }
        is ArchivePreviewState.Failed -> {
            Text(
                text = state.error.message,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.error
            )
            state.error.recoveryHint?.let { hint ->
                Text(
                    text = hint,
                    style = MaterialTheme.typography.bodySmall
                )
            }
        }
    }
}

@Composable
private fun ArchiveTestPanel(
    state: ArchiveTestState,
    selectedEntries: List<ArchiveEntrySummary>,
    passwordInput: String,
    onPasswordInputChanged: (String) -> Unit,
    onSubmitPassword: (List<ArchiveEntrySummary>) -> Unit
) {
    when (state) {
        ArchiveTestState.Idle -> Unit
        is ArchiveTestState.Loading -> {
            Text(
                text = if (state.selectedCount == 0) {
                    "Testing archive"
                } else {
                    "Testing ${state.selectedCount} selected entries"
                },
                style = MaterialTheme.typography.bodyMedium
            )
        }
        is ArchiveTestState.Ready -> {
            Text(
                text = if (state.summary.verified) {
                    "Archive verified"
                } else {
                    "Archive verification failed"
                },
                style = MaterialTheme.typography.bodyMedium
            )
            Text(
                text = listOf(
                    "${state.summary.testedEntries} tested",
                    "${state.summary.skippedEntries} skipped",
                    "${state.summary.testedBytes} bytes"
                ).joinToString(" - "),
                style = MaterialTheme.typography.bodySmall
            )
            state.summary.warnings.forEach { warning ->
                Text(
                    text = warning,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.error
                )
            }
        }
        is ArchiveTestState.PasswordRequired -> {
            Spacer(modifier = Modifier.height(8.dp))
            Text(
                text = state.error.message,
                style = MaterialTheme.typography.bodyMedium
            )
            state.error.recoveryHint?.let { hint ->
                Text(
                    text = hint,
                    style = MaterialTheme.typography.bodySmall
                )
            }
            OutlinedTextField(
                value = passwordInput,
                onValueChange = onPasswordInputChanged,
                label = { Text("Password") },
                singleLine = true,
                visualTransformation = PasswordVisualTransformation(),
                modifier = Modifier.fillMaxWidth()
            )
            Button(
                enabled = passwordInput.isNotEmpty(),
                onClick = { onSubmitPassword(selectedEntries) }
            ) {
                Text("Retry test")
            }
        }
        is ArchiveTestState.Failed -> {
            Text(
                text = state.error.message,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.error
            )
            state.error.recoveryHint?.let { hint ->
                Text(
                    text = hint,
                    style = MaterialTheme.typography.bodySmall
                )
            }
        }
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
