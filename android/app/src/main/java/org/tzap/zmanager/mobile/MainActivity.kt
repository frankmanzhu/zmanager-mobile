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
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.core.content.FileProvider
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
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
    val scope = rememberCoroutineScope()
    var importedArchive by remember { mutableStateOf<ImportedArchive?>(null) }
    var listingState by remember { mutableStateOf<ArchiveListingState>(ArchiveListingState.Idle) }
    var importError by remember { mutableStateOf<String?>(null) }
    var isImporting by remember { mutableStateOf(false) }
    var passwordInput by remember { mutableStateOf("") }
    var previewPasswordInput by remember { mutableStateOf("") }
    var entrySearchQuery by remember { mutableStateOf("") }
    var entrySort by remember { mutableStateOf(ArchiveEntrySort.PATH_ASCENDING) }
    var entryViewMode by remember { mutableStateOf(ArchiveEntryViewMode.FOLDERS) }
    var selectedEntryIds by remember { mutableStateOf(emptySet<String>()) }
    var previewState by remember { mutableStateOf<ArchivePreviewState>(ArchivePreviewState.Idle) }
    var importRequestId by remember { mutableStateOf(0L) }
    var listingRequestId by remember { mutableStateOf(0L) }
    var previewRequestId by remember { mutableStateOf(0L) }

    fun clearPreviewState() {
        cleanupPreview(previewState)
        previewState = ArchivePreviewState.Idle
        previewPasswordInput = ""
        previewRequestId += 1
    }

    fun loadArchiveListing(archive: ImportedArchive, password: String?) {
        listingRequestId += 1
        val currentListingRequestId = listingRequestId
        selectedEntryIds = emptySet()
        clearPreviewState()
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

    fun startImport(uri: Uri) {
        importRequestId += 1
        val currentImportRequestId = importRequestId
        listingRequestId += 1
        clearPreviewState()
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

    val documentPicker = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.OpenDocument()
    ) { uri ->
        uri?.let { startImport(it) }
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
                        }
                    )
                }

                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(12.dp, Alignment.End)
                ) {
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
    onSubmitPreviewPassword: (ArchiveEntrySummary) -> Unit
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
            onSubmitPreviewPassword = onSubmitPreviewPassword
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
    onSubmitPreviewPassword: (ArchiveEntrySummary) -> Unit
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
    }
    ArchivePreviewPanel(
        state = previewState,
        passwordInput = previewPasswordInput,
        onPasswordInputChanged = onPreviewPasswordInputChanged,
        onSubmitPassword = onSubmitPreviewPassword
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
                        onCheckedChange = { onToggleEntrySelected(entry) }
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
