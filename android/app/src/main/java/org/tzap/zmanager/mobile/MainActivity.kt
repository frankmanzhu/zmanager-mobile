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
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.Composable
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
    var importRequestId by remember { mutableStateOf(0L) }
    var listingRequestId by remember { mutableStateOf(0L) }
    var previewRequestId by remember { mutableStateOf(0L) }
    var testRequestId by remember { mutableStateOf(0L) }

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

    fun planExtraction(
        archive: ImportedArchive,
        entries: List<ArchiveEntrySummary>,
        destination: ExtractionDestination,
        password: String?
    ) {
        clearExtractionState()
        extractionState = ArchiveExtractionUiState.Planning(destination.label)
        scope.launch {
            val result = withContext(Dispatchers.IO) {
                runCatching {
                    extractionCoordinator.plan(
                        archive = archive,
                        selectedPaths = entries.map { it.path },
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

    fun startImport(uri: Uri) {
        importRequestId += 1
        val currentImportRequestId = importRequestId
        listingRequestId += 1
        clearPreviewState()
        clearTestState()
        clearExtractionState()
        isImporting = true
        importError = null
        importedArchive = null
        listingState = ArchiveListingState.Idle
        passwordInput = ""
        entrySearchQuery = ""
        selectedEntryIds = emptySet()
        scope.launch {
            val result = withContext(Dispatchers.IO) {
                runCatching { importer.importUri(uri) }
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

    fun startMaestroFixtureImport() {
        importRequestId += 1
        val currentImportRequestId = importRequestId
        listingRequestId += 1
        clearPreviewState()
        clearTestState()
        clearExtractionState()
        isImporting = true
        importError = null
        importedArchive = null
        listingState = ArchiveListingState.Idle
        passwordInput = ""
        entrySearchQuery = ""
        selectedEntryIds = emptySet()
        scope.launch {
            val result = withContext(Dispatchers.IO) {
                runCatching { importer.importAsset("maestro-files.zip") }
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
                    importError = "Unable to import the Maestro fixture."
                }
            isImporting = false
        }
    }

    val documentPicker = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.OpenDocument()
    ) { uri ->
        uri?.let { startImport(it) }
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

    LaunchedEffect(incomingIntent) {
        incomingIntent?.let { intent ->
            ArchiveImportIntents.firstArchiveUri(intent)?.let { uri ->
                startImport(uri)
            }
            onIncomingIntentHandled(intent)
        }
    }

    MaterialTheme {
        Surface(modifier = Modifier.fillMaxSize()) {
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(horizontal = 24.dp, vertical = 32.dp),
                verticalArrangement = Arrangement.SpaceBetween
            ) {
                Column {
                    Text(
                        text = "ZManager",
                        style = MaterialTheme.typography.headlineMedium
                    )
                    Spacer(modifier = Modifier.height(8.dp))
                    Text(
                        text = "Open an archive, inspect its contents, then extract safely.",
                        style = MaterialTheme.typography.bodyLarge
                    )
                    Spacer(modifier = Modifier.height(24.dp))
                    importedArchive?.let { archive ->
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
                        }
                    )
                }

                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(12.dp, Alignment.End)
                ) {
                    if (BuildConfig.DEBUG) {
                        OutlinedButton(
                            enabled = !isImporting,
                            onClick = { startMaestroFixtureImport() }
                        ) {
                            Text("Load Maestro fixture")
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
    onRetryExtractionWithPassword: (List<ArchiveEntrySummary>) -> Unit
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
            onRetryExtractionWithPassword = onRetryExtractionWithPassword
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
    onRetryExtractionWithPassword: (List<ArchiveEntrySummary>) -> Unit
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
                }
            }
        }
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
