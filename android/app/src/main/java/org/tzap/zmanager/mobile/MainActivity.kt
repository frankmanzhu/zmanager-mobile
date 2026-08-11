package org.tzap.zmanager.mobile

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
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
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.tzap.zmanager.mobile.bridge.generated.ExtractionCollisionPolicy
import org.tzap.zmanager.mobile.bridge.generated.CreateArchiveFormat
import org.tzap.zmanager.mobile.bridge.generated.ZmanagerGuiException
import java.io.File
import java.util.Locale

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
    val creationCoordinator = remember(context) { ArchiveCreationCoordinator(context) }
    val repackagingCoordinator = remember(context) { ArchiveRepackagingCoordinator(context, extractionCoordinator, creationCoordinator) }
    val creationSourceStager = remember(context) { ArchiveCreationSourceStager(context) }
    val localSendClient = remember { LocalSendClient() }
    val localSendReceiver = remember { LocalSendReceiver() }
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
    var extractionPasswordInput by remember { mutableStateOf("") }
    var repackagingState by remember { mutableStateOf<ArchiveRepackagingUiState>(ArchiveRepackagingUiState.Idle) }
    var creationState by remember { mutableStateOf<ArchiveCreationUiState>(ArchiveCreationUiState.Idle) }
    var createFormat by remember { mutableStateOf(CreateArchiveFormat.ZIP) }
    var createPasswordInput by remember { mutableStateOf("") }
    var stagedCreationSources by remember { mutableStateOf<StagedCreationSources?>(null) }
    var localSendState by remember { mutableStateOf<LocalSendUiState>(LocalSendUiState.Idle) }
    var activeLocalSendSession by remember { mutableStateOf<Pair<LocalSendDevice, String>?>(null) }
    var receiveSession by remember { mutableStateOf<LocalSendReceiverSession?>(null) }
    val archiveSessions = remember { ArchiveSessionStack() }
    var nestedNavigationVersion by remember { mutableStateOf(0) }
    var nestedOpenError by remember { mutableStateOf<String?>(null) }
    var importRequestId by remember { mutableStateOf(0L) }
    var listingRequestId by remember { mutableStateOf(0L) }
    var previewRequestId by remember { mutableStateOf(0L) }
    var testRequestId by remember { mutableStateOf(0L) }
    var showFixtureMenu by remember { mutableStateOf(false) }

    DisposableEffect(localSendReceiver) {
        onDispose { localSendReceiver.stop() }
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
        (creationState as? ArchiveCreationUiState.Review)?.review?.let(creationCoordinator::discard)
        stagedCreationSources?.let(creationSourceStager::discard)
        stagedCreationSources = null
        creationState = ArchiveCreationUiState.Idle
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

    fun startRepackaging(entries: List<ArchiveEntrySummary>) {
        val archive = importedArchive ?: return
        // Repackaging requires an explicit source selection. An empty list is
        // reserved by extraction for "the whole archive", which would make
        // the repackaging coordinator reject a deliberate whole-archive pick.
        val selectedPaths = entries.map { it.path }
        val outputName = when (createFormat) {
            CreateArchiveFormat.ZIP -> "repackaged.zip"
            CreateArchiveFormat.SEVEN_Z -> "repackaged.7z"
            CreateArchiveFormat.TAR_ZST -> "repackaged.tar.zst"
            CreateArchiveFormat.TZAP -> "repackaged.tzap"
        }
        repackagingState = ArchiveRepackagingUiState.Planning
        scope.launch {
            val planned = withContext(Dispatchers.IO) {
                runCatching {
                    repackagingCoordinator.plan(
                        ArchiveRepackagingRequest(
                            sourceArchive = archive,
                            selectedPaths = selectedPaths,
                            destinationArchivePath = creationCoordinator.appStorageOutput(outputName).absolutePath,
                            format = createFormat,
                            sourcePassword = passwordInput.takeIf { it.isNotEmpty() },
                            destinationPassword = createPasswordInput.takeIf { it.isNotEmpty() }
                        )
                    )
                }
            }
            planned.onSuccess { review ->
                repackagingState = ArchiveRepackagingUiState.Review(review)
            }.onFailure {
                repackagingState = ArchiveRepackagingUiState.Failed(it.message ?: "Unable to repackage the selection.")
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
                is ArchiveRepackagingOutcome.Failed -> ArchiveRepackagingUiState.Failed(outcome.message)
            }
            passwordInput = ""
            createPasswordInput = ""
        }
    }

    fun planCreation(staged: StagedCreationSources) {
        clearCreationState()
        stagedCreationSources = staged
        val outputName = when (createFormat) {
            CreateArchiveFormat.ZIP -> "archive.zip"
            CreateArchiveFormat.SEVEN_Z -> "archive.7z"
            CreateArchiveFormat.TAR_ZST -> "archive.tar.zst"
            CreateArchiveFormat.TZAP -> "archive.tzap"
        }
        creationState = ArchiveCreationUiState.Planning
        scope.launch {
            val result = withContext(Dispatchers.IO) {
                runCatching {
                    creationCoordinator.plan(
                            ArchiveCreationRequest(
                            sourcePaths = staged.sourcePaths,
                            destinationArchivePath = creationCoordinator.appStorageOutput(outputName).absolutePath,
                            format = createFormat,
                            password = createPasswordInput.takeIf { it.isNotEmpty() }
                        )
                    )
                }
            }
            creationState = result.fold(
                onSuccess = { review ->
                    if (review.plan.canStart) ArchiveCreationUiState.Review(review)
                    else ArchiveCreationUiState.Failed(
                        review.plan.warnings.firstOrNull()?.message
                            ?: "This creation plan cannot be started."
                    )
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

    fun startCreation(review: ArchiveCreationReview) {
        createPasswordInput = ""
        creationState = ArchiveCreationUiState.Starting(review)
        scope.launch {
            val started = withContext(Dispatchers.IO) { runCatching { creationCoordinator.start(review) } }
            started.onSuccess { jobId ->
                creationState = ArchiveCreationUiState.Running(review, jobId, "Creating archive")
                val outcome = withContext(Dispatchers.IO) {
                    creationCoordinator.awaitCompletion(review, jobId) { progress ->
                        scope.launch {
                            creationState = ArchiveCreationUiState.Running(review, jobId, progress.message)
                        }
                    }
                }
                creationState = when (outcome) {
                    is ArchiveCreationOutcome.Completed -> ArchiveCreationUiState.Completed(outcome)
                    ArchiveCreationOutcome.Cancelled -> ArchiveCreationUiState.Cancelled
                    is ArchiveCreationOutcome.Failed -> ArchiveCreationUiState.Failed(outcome.message)
                }
                stagedCreationSources?.let(creationSourceStager::discard)
                stagedCreationSources = null
            }.onFailure { error ->
                creationCoordinator.discard(review)
                stagedCreationSources?.let(creationSourceStager::discard)
                stagedCreationSources = null
                creationState = ArchiveCreationUiState.Failed(error.message ?: "Unable to create archive.")
            }
        }
    }

    fun planExtraction(
        archive: ImportedArchive,
        entries: List<ArchiveEntrySummary>,
        destination: ExtractionDestination,
        password: String?
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
                        // contract so full extraction reaches the format's
                        // native backend instead of the per-entry fallback.
                        selectedPaths = selectedPaths,
                        destination = destination,
                        password = password,
                        collisionPolicy = ExtractionCollisionPolicy.REFUSE
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

    fun startExtraction(review: ExtractionReview) {
        extractionState = ArchiveExtractionUiState.Starting(review)
        scope.launch {
            val start = withContext(Dispatchers.IO) { runCatching { extractionCoordinator.start(review) } }
            start.onSuccess { jobId ->
                extractionState = ArchiveExtractionUiState.Running(review, jobId, "Extracting archive")
                val outcome = withContext(Dispatchers.IO) {
                    extractionCoordinator.awaitCompletion(review, jobId) { progress ->
                        scope.launch {
                            extractionState = ArchiveExtractionUiState.Running(review, jobId, progress.message)
                        }
                    }
                }
                extractionState = when (outcome) {
                    is ExtractionOutcome.Completed -> ArchiveExtractionUiState.Completed(outcome)
                    ExtractionOutcome.Cancelled -> ArchiveExtractionUiState.Cancelled
                    is ExtractionOutcome.Failed -> ArchiveExtractionUiState.Failed(outcome.message)
                }
            }.onFailure { error ->
                extractionCoordinator.discard(review)
                extractionState = error.toExtractionUiState()
            }
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

    fun startImport(uris: List<Uri>) {
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
        companionAssetNames: List<String> = emptyList()
    ) {
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
                runCatching { importer.importAssets(assetName, listOf(assetName) + companionAssetNames) }
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

    fun sendCurrentArchive(device: LocalSendDevice) {
        val archive = importedArchive ?: return
        localSendState = LocalSendUiState.Sending(device, "Preparing transfer")
        scope.launch {
            val result = withContext(Dispatchers.IO) {
                runCatching {
                    val file = LocalSendFile(file = File(archive.localPath), displayName = archive.displayName)
                    val session = localSendClient.prepareUpload(device, listOf(file))
                    activeLocalSendSession = device to session.sessionId
                    localSendClient.upload(device, session, listOf(file)) { item, sent, total ->
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
                onSuccess = { LocalSendUiState.Completed(device) },
                onFailure = { LocalSendUiState.Failed(it.message ?: "LocalSend transfer failed.") }
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
        scope.launch {
            val result = withContext(Dispatchers.IO) {
                runCatching {
                    localSendReceiver.start(File(context.filesDir, "ReceivedFiles"))
                }
            }
            result.onSuccess {
                receiveSession = it
                localSendState = LocalSendUiState.Receiving(it.port)
            }.onFailure {
                localSendState = LocalSendUiState.Failed("Unable to receive LocalSend files.")
            }
        }
    }

    fun stopLocalReceive() {
        scope.launch(Dispatchers.IO) { localSendReceiver.stop() }
        receiveSession = null
        localSendState = LocalSendUiState.Idle
    }

    val documentPicker = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.OpenMultipleDocuments()
    ) { uris ->
        uris.takeIf { it.isNotEmpty() }?.let(::startImport)
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
            planExtraction(archive, entries, ExtractionDestination.DocumentTree(uri), null)
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

    LaunchedEffect(incomingIntent) {
        incomingIntent?.let { intent ->
            ArchiveImportIntents.firstArchiveUri(intent)?.let { uri ->
                startImport(listOf(uri))
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
                    if (BuildConfig.DEBUG) {
                        OutlinedButton(
                            enabled = !isImporting,
                            onClick = { startMaestroFixtureImport("maestro-nested.zip") }
                        ) {
                            Text("Load nested fixture")
                        }
                        OutlinedButton(
                            enabled = creationState !is ArchiveCreationUiState.Planning &&
                                creationState !is ArchiveCreationUiState.Starting &&
                                creationState !is ArchiveCreationUiState.Running,
                            onClick = ::stageDebugCreationFixture
                        ) {
                            Text("Create debug folder archive")
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
                    ArchiveCreationPanel(
                        state = creationState,
                        format = createFormat,
                        password = createPasswordInput,
                        onPasswordChanged = { createPasswordInput = it },
                        onFormatChanged = { createFormat = it },
                        onChooseFiles = { creationFilesPicker.launch(arrayOf("*/*")) },
                        onChooseFolder = { creationFolderPicker.launch(null) },
                        onStart = ::startCreation,
                        onCancel = { state ->
                            when (state) {
                                is ArchiveCreationUiState.Running -> scope.launch(Dispatchers.IO) {
                                    creationCoordinator.cancel(state.jobId)
                                }
                                is ArchiveCreationUiState.Review -> clearCreationState()
                                else -> Unit
                            }
                        }
                    )
            LocalSendPanel(
                archive = importedArchive,
                state = localSendState,
                onDiscover = ::discoverLocalSendDevices,
                onSend = ::sendCurrentArchive,
                onCancelSend = ::cancelLocalSend,
                onStartReceive = ::startLocalReceive,
                onStopReceive = ::stopLocalReceive
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
                                planExtraction(archive, entries, extractionCoordinator.appStorageDestination(), null)
                            }
                        },
                        onChooseDestination = { destinationPicker.launch(null) },
                        onStartExtraction = ::startExtraction,
                        onCancelExtraction = { state ->
                            when (state) {
                                is ArchiveExtractionUiState.Running -> scope.launch(Dispatchers.IO) {
                                    extractionCoordinator.cancel(state.jobId)
                                }
                                is ArchiveExtractionUiState.Review -> clearExtractionState()
                                else -> Unit
                            }
                        },
                        onRetryExtractionWithPassword = { entries ->
                            importedArchive?.let { archive ->
                                val password = extractionPasswordInput.takeIf { it.isNotEmpty() }
                                extractionPasswordInput = ""
                                planExtraction(archive, entries, extractionCoordinator.appStorageDestination(), password)
                            }
                        },
                        repackagingState = repackagingState,
                        onRepackageEntries = ::startRepackaging,
                        onStartRepackaging = { state ->
                            if (state is ArchiveRepackagingUiState.Review) runRepackaging(state.review)
                        },
                        onCancelRepackaging = { state ->
                            when (state) {
                                is ArchiveRepackagingUiState.Review -> {
                                    repackagingCoordinator.discard(state.review)
                                    repackagingState = ArchiveRepackagingUiState.Idle
                                }
                                is ArchiveRepackagingUiState.Running -> {
                                    scope.launch(Dispatchers.IO) { repackagingCoordinator.cancel(state.review) }
                                }
                                else -> Unit
                            }
                        }
                    )
                }

                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(12.dp, Alignment.End)
                ) {
                    OutlinedButton(
                        enabled = creationState !is ArchiveCreationUiState.Planning &&
                            creationState !is ArchiveCreationUiState.Starting &&
                            creationState !is ArchiveCreationUiState.Running,
                        onClick = { creationFilesPicker.launch(arrayOf("*/*")) }
                    ) {
                        Text("Create archive")
                    }
                    OutlinedButton(
                        enabled = creationState !is ArchiveCreationUiState.Planning &&
                            creationState !is ArchiveCreationUiState.Starting &&
                            creationState !is ArchiveCreationUiState.Running,
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
                                listOf(
                                    MaestroFixture("ZIP fixture", "maestro-files.zip"),
                                    MaestroFixture("7z fixture", "maestro-files.7z"),
                                    MaestroFixture("TGZ fixture", "maestro-files.tgz"),
                                    MaestroFixture("TAR.ZST fixture", "maestro-files.tar.zst"),
                                    MaestroFixture("TZAP fixture", "maestro-files.tzap"),
                                    MaestroFixture("Nested ZIP fixture", "maestro-nested.zip"),
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
                                    MaestroFixture("CAB fixture", "maestro-files.cab")
                                ).forEach { fixture ->
                                    DropdownMenuItem(
                                        text = { Text(fixture.label) },
                                        onClick = {
                                            showFixtureMenu = false
                                            startMaestroFixtureImport(fixture.assetName, fixture.companionAssetNames)
                                        }
                                    )
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
                        onClick = { documentPicker.launch(arrayOf("*/*")) }
                    ) {
                        Text(if (isImporting) "Importing" else "Open Archive")
                    }
                }
            }
        }
    }
}

private data class MaestroFixture(
    val label: String,
    val assetName: String,
    val companionAssetNames: List<String> = emptyList()
)

@Composable
private fun ArchiveCreationPanel(
    state: ArchiveCreationUiState,
    format: CreateArchiveFormat,
    password: String,
    onPasswordChanged: (String) -> Unit,
    onFormatChanged: (CreateArchiveFormat) -> Unit,
    onChooseFiles: () -> Unit,
    onChooseFolder: () -> Unit,
    onStart: (ArchiveCreationReview) -> Unit,
    onCancel: (ArchiveCreationUiState) -> Unit
) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text("Create archive", style = MaterialTheme.typography.titleMedium)
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            CreateFormatButton("ZIP", CreateArchiveFormat.ZIP, format, onFormatChanged)
            CreateFormatButton("7z", CreateArchiveFormat.SEVEN_Z, format, onFormatChanged)
            CreateFormatButton("TAR.ZST", CreateArchiveFormat.TAR_ZST, format, onFormatChanged)
            CreateFormatButton("TZAP", CreateArchiveFormat.TZAP, format, onFormatChanged)
        }
        OutlinedTextField(
            value = password,
            onValueChange = onPasswordChanged,
            label = { Text("Optional password") },
            visualTransformation = PasswordVisualTransformation(),
            singleLine = true,
            modifier = Modifier.fillMaxWidth()
        )
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
            is ArchiveCreationUiState.Starting -> Text("Starting archive creation")
            is ArchiveCreationUiState.Running -> {
                Text(state.message)
                TextButton(onClick = { onCancel(state) }) { Text("Cancel") }
            }
            is ArchiveCreationUiState.Completed -> {
                Text("Created ${state.outcome.outputPath}")
                if (state.outcome.verified) Text("Verified")
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
    state: LocalSendUiState,
    onDiscover: () -> Unit,
    onSend: (LocalSendDevice) -> Unit,
    onCancelSend: () -> Unit,
    onStartReceive: () -> Unit,
    onStopReceive: () -> Unit
) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text("Share on local network", style = MaterialTheme.typography.titleMedium)
        Button(enabled = archive != null && state !is LocalSendUiState.Discovering, onClick = onDiscover) {
            Text(if (state is LocalSendUiState.Discovering) "Discovering" else "Find LocalSend devices")
        }
        if (state is LocalSendUiState.Receiving) {
            OutlinedButton(onClick = onStopReceive) { Text("Stop receiving") }
            Text("Receiving LocalSend files on port ${state.port} into app storage.")
        } else {
            OutlinedButton(onClick = onStartReceive) { Text("Receive files") }
        }
        when (state) {
            LocalSendUiState.Idle, LocalSendUiState.Discovering -> Unit
            is LocalSendUiState.Receiving -> Unit
            is LocalSendUiState.Devices -> {
                if (state.devices.isEmpty()) Text("No compatible devices found.")
                state.devices.forEach { device ->
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text("${device.alias} (${device.address})", modifier = Modifier.weight(1f))
                        OutlinedButton(onClick = { onSend(device) }) { Text("Send archive") }
                    }
                }
            }
            is LocalSendUiState.Sending -> Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("${state.message} to ${state.device.alias}", modifier = Modifier.weight(1f))
                OutlinedButton(onClick = onCancelSend) { Text("Cancel") }
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
    onRepackageEntries: (List<ArchiveEntrySummary>) -> Unit,
    onStartRepackaging: (ArchiveRepackagingUiState) -> Unit,
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
            onRepackageEntries = onRepackageEntries,
            onStartRepackaging = onStartRepackaging,
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
    onRepackageEntries: (List<ArchiveEntrySummary>) -> Unit,
    onStartRepackaging: (ArchiveRepackagingUiState) -> Unit,
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
        onStart = onStartRepackaging,
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
    onStart: (ArchiveRepackagingUiState) -> Unit,
    onCancel: (ArchiveRepackagingUiState) -> Unit
) {
    when (state) {
        ArchiveRepackagingUiState.Idle -> Unit
        ArchiveRepackagingUiState.Planning -> Text("Preparing repackaging plan")
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
            Text(if (state.outcome.verified) "Verified" else "Created without verification")
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
