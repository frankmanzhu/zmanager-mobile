package org.tzap.zmanager.mobile

import android.app.Application
import android.net.Uri
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

/**
 * Cross-cutting session state: the imported archive, its listing, nested
 * navigation, recovery, and shared status messages. Everything else in the
 * app reads or resets against this, which is why it lives in one place
 * instead of being split per feature. See Track 7 in
 * docs/mobile-code-health-remediation-plan.md.
 */
class ArchiveSessionViewModel(application: Application) : AndroidViewModel(application) {
    private val context get() = getApplication<Application>()

    val importer = ArchiveImporter(context)
    val listingRepository = ArchiveListingRepository()
    val recoveryStore = ArchiveRecoveryStore(context)
    val destinationPreferences = ArchiveDestinationPreferences(context)
    val archiveSessions = ArchiveSessionStack()

    // Exposed as MutableState (not a plain var) so ZManagerApp can rebind
    // each one locally via `by` under its original name, e.g.
    // `var importedArchive by session.importedArchiveState`. That keeps the
    // rest of the composable's ~1,800 lines of rendering code, which reads
    // and writes these by bare name, unchanged by this move.
    val importedArchiveState: MutableState<ImportedArchive?> = mutableStateOf(null)
    var importedArchive by importedArchiveState

    val listingStateState: MutableState<ArchiveListingState> = mutableStateOf(ArchiveListingState.Idle)
    var listingState by listingStateState

    val importErrorState: MutableState<String?> = mutableStateOf(null)
    var importError by importErrorState

    val isImportingState: MutableState<Boolean> = mutableStateOf(false)
    var isImporting by isImportingState

    val passwordInputState: MutableState<String> = mutableStateOf("")
    var passwordInput by passwordInputState

    val entrySearchQueryState: MutableState<String> = mutableStateOf("")
    var entrySearchQuery by entrySearchQueryState

    val selectedEntryIdsState: MutableState<Set<String>> = mutableStateOf(emptySet())
    var selectedEntryIds by selectedEntryIdsState

    // True only when the user explicitly chose "Select all" with no active
    // search filter. extractionSelectedPaths reads this rather than
    // inferring "the whole archive" from set equality against
    // summary.entries, since summary.entries is no longer capped at 50 and a
    // window/search can make "every entry currently selected" a real proper
    // subset. See Track 3 in docs/mobile-code-health-remediation-plan.md.
    val selectedEverythingState: MutableState<Boolean> = mutableStateOf(false)
    var selectedEverything by selectedEverythingState

    val nestedNavigationVersionState: MutableState<Int> = mutableStateOf(0)
    var nestedNavigationVersion by nestedNavigationVersionState

    val nestedOpenErrorState: MutableState<String?> = mutableStateOf(null)
    var nestedOpenError by nestedOpenErrorState

    val foregroundRecoveryMessageState: MutableState<String?> = mutableStateOf(null)
    var foregroundRecoveryMessage by foregroundRecoveryMessageState

    val operationReportMessageState: MutableState<String?> = mutableStateOf(null)
    var operationReportMessage by operationReportMessageState

    var destinationPreferenceVersion by mutableStateOf(0)
    var recoveryVersion by mutableStateOf(0)

    // Debug/device-E2E pacing only; archive work remains Rust-owned. Shared
    // between import (which sets this ahead of a fixture-driven extraction)
    // and extraction planning (which reads it). Always NoOpJobPacer outside
    // the BuildConfig.DEBUG-gated buttons in MainActivity.kt. See Track 5 in
    // docs/mobile-code-health-remediation-plan.md.
    val debugJobPacerState: MutableState<JobPacer> = mutableStateOf(NoOpJobPacer)
    var debugJobPacer by debugJobPacerState

    var pendingAutomationAction by mutableStateOf<ArchiveAutomationAction?>(null)

    private var importRequestId by mutableStateOf(0L)
    private var listingRequestId by mutableStateOf(0L)

    val defaultExtractionDestination: ExtractionDestination
        get() {
            destinationPreferenceVersion
            return destinationPreferences.defaultExtractionDestination()
        }

    val recoveryRecords: List<ArchiveRecoveryRecord>
        get() {
            recoveryVersion
            return recoveryStore.records()
        }

    fun clearSessionSecrets() {
        passwordInput = ""
    }

    fun loadArchiveListing(
        archive: ImportedArchive,
        password: String?,
        onListingLoadStarted: () -> Unit
    ) {
        listingRequestId += 1
        val currentListingRequestId = listingRequestId
        selectedEntryIds = emptySet()
        selectedEverything = false
        onListingLoadStarted()
        listingState = ArchiveListingState.Loading
        viewModelScope.launch {
            val result = withContext(Dispatchers.IO) {
                listingRepository.load(archive, password)
            }
            if (currentListingRequestId == listingRequestId && importedArchive?.id == archive.id) {
                listingState = result
            }
        }
    }

    fun startImport(
        uris: List<Uri>,
        automationAction: ArchiveAutomationAction? = null,
        onImportStarted: () -> Unit,
        onImported: (ImportedArchive) -> Unit
    ) {
        debugJobPacer = NoOpJobPacer
        pendingAutomationAction = automationAction
        importRequestId += 1
        val currentImportRequestId = importRequestId
        listingRequestId += 1
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
        selectedEverything = false
        onImportStarted()
        viewModelScope.launch {
            val result = withContext(Dispatchers.IO) {
                runCatching { importer.importUris(uris) }
            }
            if (currentImportRequestId != importRequestId) {
                return@launch
            }
            result
                .onSuccess { archive ->
                    importedArchive = archive
                    onImported(archive)
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
        displayAssetNames: List<String> = listOf(assetName) + companionAssetNames,
        onImportStarted: () -> Unit,
        onImported: (ImportedArchive) -> Unit
    ) {
        if (automationAction != ArchiveAutomationAction.EXTRACT) {
            debugJobPacer = NoOpJobPacer
        }
        pendingAutomationAction = automationAction
        importRequestId += 1
        val currentImportRequestId = importRequestId
        listingRequestId += 1
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
        selectedEverything = false
        onImportStarted()
        viewModelScope.launch {
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
                    onImported(archive)
                }
                .onFailure {
                    importError = "Unable to import the test fixture."
                }
            isImporting = false
        }
    }

    fun discardRecovery(id: String, onExtractionRecoveryDiscarded: (recoveryId: String) -> Unit) {
        recoveryStore.discard(id)
        recoveryVersion += 1
        onExtractionRecoveryDiscarded(id)
    }

    fun exportRecovery(id: String) {
        val files = recoveryStore.files(id)
        if (files.isEmpty()) {
            foregroundRecoveryMessage = "The retained recovery output is no longer available."
            return
        }
        runCatching {
            val uris = files.map { file ->
                androidx.core.content.FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
            }
            context.startActivity(
                android.content.Intent.createChooser(
                    android.content.Intent(android.content.Intent.ACTION_SEND_MULTIPLE)
                        .setType("application/octet-stream")
                        .putParcelableArrayListExtra(android.content.Intent.EXTRA_STREAM, ArrayList(uris))
                        .addFlags(android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION),
                    "Export retained extraction"
                ).addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
            )
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
                androidx.core.content.FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
            }
            val intent = if (uris.size == 1) {
                android.content.Intent(android.content.Intent.ACTION_SEND)
                    .setType("application/octet-stream")
                    .putExtra(android.content.Intent.EXTRA_STREAM, uris.single())
            } else {
                android.content.Intent(android.content.Intent.ACTION_SEND_MULTIPLE)
                    .setType("application/octet-stream")
                    .putParcelableArrayListExtra(android.content.Intent.EXTRA_STREAM, ArrayList(uris))
            }
            context.startActivity(
                android.content.Intent.createChooser(
                    intent.addFlags(android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION),
                    title
                ).addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
            )
        }.onFailure {
            foregroundRecoveryMessage = "Unable to share the created archive."
        }
    }

    fun retryRecovery(
        record: ArchiveRecoveryRecord,
        onExtractionRecoveryDiscarded: (recoveryId: String) -> Unit,
        onPlanExtraction: (archive: ImportedArchive, entries: List<ArchiveEntrySummary>, destination: ExtractionDestination, password: String?) -> Unit
    ) {
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
        discardRecovery(record.id, onExtractionRecoveryDiscarded)
        onPlanExtraction(archive, entries, defaultExtractionDestination, null)
    }

    fun openNestedArchive(
        entry: ArchiveEntrySummary,
        onOpened: (child: ImportedArchive) -> Unit
    ) {
        val parent = importedArchive ?: return
        if (!NestedArchiveSupport.canOpen(entry)) return
        nestedOpenError = null
        viewModelScope.launch {
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
                    onOpened(child)
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

    fun navigateBackFromNested(onNavigated: (parent: ImportedArchive?) -> Unit) {
        val removed = archiveSessions.pop() ?: return
        val parent = archiveSessions.current?.archive
        if (parent == null) {
            importedArchive = null
            listingState = ArchiveListingState.Idle
        } else {
            importedArchive = parent
        }
        nestedOpenError = null
        nestedNavigationVersion += 1
        onNavigated(parent)
    }

    fun extractionSelectedPaths(entries: List<ArchiveEntrySummary>): List<String> {
        return if (selectedEverything) emptyList() else entries.map { it.path }
    }

    fun toggleEntrySelected(entry: ArchiveEntrySummary) {
        selectedEverything = false
        selectedEntryIds = if (selectedEntryIds.contains(entry.id)) {
            selectedEntryIds - entry.id
        } else {
            selectedEntryIds + entry.id
        }
    }

    fun selectEntries(entries: List<ArchiveEntrySummary>) {
        selectedEverything = false
        selectedEntryIds = selectedEntryIds + entries.map { it.id }.toSet()
    }

    fun selectEverything(summary: ArchiveListingSummary) {
        selectedEntryIds = summary.entries.map { it.id }.toSet()
        selectedEverything = true
    }

    fun clearSelection() {
        selectedEverything = false
        selectedEntryIds = emptySet()
    }

    fun recordDestinationPreference(destination: ExtractionDestination.DocumentTree) {
        destinationPreferences.setExtractionDestination(destination)
        destinationPreferenceVersion += 1
    }

    fun resetDefaultDestination() {
        destinationPreferences.resetExtractionDestination()
        destinationPreferenceVersion += 1
    }
}
