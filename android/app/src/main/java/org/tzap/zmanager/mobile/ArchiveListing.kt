package org.tzap.zmanager.mobile

import org.tzap.zmanager.mobile.bridge.generated.ArchiveEntry
import org.tzap.zmanager.mobile.bridge.generated.ArchiveEntryKind
import org.tzap.zmanager.mobile.bridge.generated.DetectArchiveRequest
import org.tzap.zmanager.mobile.bridge.generated.DetectArchiveResult
import org.tzap.zmanager.mobile.bridge.generated.ListArchiveRequest
import org.tzap.zmanager.mobile.bridge.generated.ListArchiveResult
import org.tzap.zmanager.mobile.bridge.generated.MaterializePreviewRequest
import org.tzap.zmanager.mobile.bridge.generated.MaterializePreviewResult
import org.tzap.zmanager.mobile.bridge.generated.TestArchiveRequest
import org.tzap.zmanager.mobile.bridge.generated.TestArchiveResult
import org.tzap.zmanager.mobile.bridge.generated.ZmanagerMobileException
import org.tzap.zmanager.mobile.bridge.generated.detectArchive as bridgeDetectArchive
import org.tzap.zmanager.mobile.bridge.generated.listArchive as bridgeListArchive
import org.tzap.zmanager.mobile.bridge.generated.materializePreview as bridgeMaterializePreview
import org.tzap.zmanager.mobile.bridge.generated.testArchive as bridgeTestArchive
import java.util.Locale

private const val ERROR_PASSWORD_REQUIRED = "password_required"
private const val ERROR_INVALID_PASSWORD = "invalid_password"
private const val ERROR_BRIDGE_UNAVAILABLE = "bridge_unavailable"
private const val ERROR_UNSUPPORTED_FORMAT = "unsupported_format"
private const val ERROR_UNKNOWN = "unknown_error"

sealed interface ArchiveListingState {
    data object Idle : ArchiveListingState
    data object Loading : ArchiveListingState
    data class Ready(val summary: ArchiveListingSummary) : ArchiveListingState
    data class PasswordRequired(val error: ArchiveListingError) : ArchiveListingState
    data class Failed(val error: ArchiveListingError) : ArchiveListingState
}

data class ArchiveListingSummary(
    val formatLabel: String,
    val entryCount: ULong,
    val totalSize: ULong?,
    val entries: List<ArchiveEntrySummary>,
    val warnings: List<String>
)

data class ArchiveEntrySummary(
    val id: String,
    val path: String,
    val displayName: String,
    val parentPath: String,
    val kind: ArchiveEntryKind,
    val size: ULong?
) {
    val isPreviewable: Boolean
        get() = kind == ArchiveEntryKind.FILE
}

data class ArchiveListingError(
    val code: String,
    val message: String,
    val recoveryHint: String?,
    val retryable: Boolean
)

enum class ArchiveEntrySort {
    PATH_ASCENDING,
    SIZE_DESCENDING,
    KIND_ASCENDING
}

enum class ArchiveEntryViewMode {
    LIST,
    FOLDERS
}

data class ArchiveEntryGroup(
    val id: String,
    val label: String,
    val entries: List<ArchiveEntrySummary>
)

sealed interface ArchivePreviewState {
    data object Idle : ArchivePreviewState
    data class Loading(val entry: ArchiveEntrySummary) : ArchivePreviewState
    data class Ready(val summary: ArchivePreviewSummary) : ArchivePreviewState
    data class PasswordRequired(
        val entry: ArchiveEntrySummary,
        val error: ArchiveListingError
    ) : ArchivePreviewState

    data class Failed(
        val entry: ArchiveEntrySummary?,
        val error: ArchiveListingError
    ) : ArchivePreviewState
}

sealed interface ArchiveTestState {
    data object Idle : ArchiveTestState
    data class Loading(val selectedCount: Int) : ArchiveTestState
    data class Ready(val summary: ArchiveTestSummary) : ArchiveTestState
    data class PasswordRequired(val error: ArchiveListingError) : ArchiveTestState
    data class Failed(val error: ArchiveListingError) : ArchiveTestState
}

data class ArchivePreviewSummary(
    val entry: ArchiveEntrySummary,
    val cleanupRoot: String,
    val previewPath: String,
    val writtenBytes: ULong,
    val warnings: List<String>
)

data class ArchiveTestSummary(
    val formatLabel: String,
    val verified: Boolean,
    val testedEntries: ULong,
    val skippedEntries: ULong,
    val totalEntries: ULong,
    val testedBytes: ULong,
    val selectedCount: Int,
    val warnings: List<String>
)

interface ArchiveBridgeGateway {
    fun detectArchive(path: String): DetectArchiveResult
    fun listArchive(path: String, password: String?): ListArchiveResult
    fun materializePreview(
        archivePath: String,
        entryPath: String,
        password: String?
    ): MaterializePreviewResult
    fun testArchive(
        archivePath: String,
        selectedPaths: List<String>,
        password: String?
    ): TestArchiveResult
}

class GeneratedArchiveBridgeGateway : ArchiveBridgeGateway {
    override fun detectArchive(path: String): DetectArchiveResult {
        return bridgeDetectArchive(DetectArchiveRequest(archivePath = path))
    }

    override fun listArchive(path: String, password: String?): ListArchiveResult {
        return bridgeListArchive(ListArchiveRequest(archivePath = path, password = password))
    }

    override fun materializePreview(
        archivePath: String,
        entryPath: String,
        password: String?
    ): MaterializePreviewResult {
        return bridgeMaterializePreview(
            MaterializePreviewRequest(
                archivePath = archivePath,
                entryPath = entryPath,
                password = password,
                stripComponents = 0UL
            )
        )
    }

    override fun testArchive(
        archivePath: String,
        selectedPaths: List<String>,
        password: String?
    ): TestArchiveResult {
        return bridgeTestArchive(
            TestArchiveRequest(
                archivePath = archivePath,
                password = password,
                selectedPaths = selectedPaths
            )
        )
    }
}

class ArchiveListingRepository(
    private val bridge: ArchiveBridgeGateway = GeneratedArchiveBridgeGateway()
) {
    fun load(archive: ImportedArchive, password: String?): ArchiveListingState {
        return try {
            val detection = bridge.detectArchive(archive.localPath)
            if (!detection.canList) {
                return ArchiveListingState.Failed(
                    ArchiveListingError(
                        code = ERROR_UNSUPPORTED_FORMAT,
                        message = "${detection.formatLabel} listing is not available.",
                        recoveryHint = "Try another archive format or update ZManager Mobile.",
                        retryable = false
                    )
                )
            }

            val listing = bridge.listArchive(archive.localPath, password)
            ArchiveListingState.Ready(listing.toSummary())
        } catch (error: ZmanagerMobileException.Bridge) {
            error.toListingState()
        } catch (error: LinkageError) {
            ArchiveListingState.Failed(
                ArchiveListingError(
                    code = ERROR_BRIDGE_UNAVAILABLE,
                    message = "The archive engine is not available in this build.",
                    recoveryHint = "Install a build with the mobile core native library.",
                    retryable = false
                )
            )
        } catch (error: RuntimeException) {
            ArchiveListingState.Failed(
                ArchiveListingError(
                    code = ERROR_UNKNOWN,
                    message = "Unable to read that archive.",
                    recoveryHint = null,
                    retryable = false
                )
            )
        }
    }

    fun materializePreview(
        archive: ImportedArchive,
        entry: ArchiveEntrySummary,
        password: String?
    ): ArchivePreviewState {
        return try {
            val preview = bridge.materializePreview(archive.localPath, entry.path, password)
            ArchivePreviewState.Ready(preview.toSummary(entry))
        } catch (error: ZmanagerMobileException.Bridge) {
            val listingError = error.toListingError()
            if (listingError.code == ERROR_PASSWORD_REQUIRED || listingError.code == ERROR_INVALID_PASSWORD) {
                ArchivePreviewState.PasswordRequired(entry, listingError)
            } else {
                ArchivePreviewState.Failed(entry, listingError)
            }
        } catch (error: LinkageError) {
            ArchivePreviewState.Failed(
                entry,
                ArchiveListingError(
                    code = ERROR_BRIDGE_UNAVAILABLE,
                    message = "The archive engine is not available in this build.",
                    recoveryHint = "Install a build with the mobile core native library.",
                    retryable = false
                )
            )
        } catch (error: RuntimeException) {
            ArchivePreviewState.Failed(
                entry,
                ArchiveListingError(
                    code = ERROR_UNKNOWN,
                    message = "Unable to preview that archive entry.",
                    recoveryHint = null,
                    retryable = false
                )
            )
        }
    }

    fun testArchive(
        archive: ImportedArchive,
        selectedEntries: List<ArchiveEntrySummary>,
        password: String?
    ): ArchiveTestState {
        return try {
            val result = bridge.testArchive(
                archivePath = archive.localPath,
                selectedPaths = selectedEntries.map { it.path },
                password = password
            )
            ArchiveTestState.Ready(result.toSummary(selectedEntries.size))
        } catch (error: ZmanagerMobileException.Bridge) {
            val listingError = error.toListingError()
            if (listingError.code == ERROR_PASSWORD_REQUIRED || listingError.code == ERROR_INVALID_PASSWORD) {
                ArchiveTestState.PasswordRequired(listingError)
            } else {
                ArchiveTestState.Failed(listingError)
            }
        } catch (error: LinkageError) {
            ArchiveTestState.Failed(
                ArchiveListingError(
                    code = ERROR_BRIDGE_UNAVAILABLE,
                    message = "The archive engine is not available in this build.",
                    recoveryHint = "Install a build with the mobile core native library.",
                    retryable = false
                )
            )
        } catch (error: RuntimeException) {
            ArchiveTestState.Failed(
                ArchiveListingError(
                    code = ERROR_UNKNOWN,
                    message = "Unable to test that archive.",
                    recoveryHint = null,
                    retryable = false
                )
            )
        }
    }

    private fun ListArchiveResult.toSummary(): ArchiveListingSummary {
        return ArchiveListingSummary(
            formatLabel = formatLabel,
            entryCount = entryCount,
            totalSize = totalSize,
            entries = entries.take(50).mapIndexed { index, entry -> entry.toSummary(index) },
            warnings = warnings.map { it.message }
        )
    }

    private fun ArchiveEntry.toSummary(index: Int): ArchiveEntrySummary {
        val normalizedSeparators = path.replace('\\', '/')
        val displayName = normalizedSeparators.substringAfterLast('/').ifBlank { path }
        val parentPath = normalizedSeparators.substringBeforeLast('/', missingDelimiterValue = "")
        return ArchiveEntrySummary(
            id = "$index:$path",
            path = path,
            displayName = displayName,
            parentPath = parentPath,
            kind = kind,
            size = size
        )
    }

    private fun MaterializePreviewResult.toSummary(entry: ArchiveEntrySummary): ArchivePreviewSummary {
        return ArchivePreviewSummary(
            entry = entry,
            cleanupRoot = cleanupRoot,
            previewPath = previewPath,
            writtenBytes = writtenBytes,
            warnings = warnings.map { it.message }
        )
    }

    private fun TestArchiveResult.toSummary(selectedCount: Int): ArchiveTestSummary {
        return ArchiveTestSummary(
            formatLabel = formatLabel,
            verified = verified,
            testedEntries = testedEntries,
            skippedEntries = skippedEntries,
            totalEntries = totalEntries,
            testedBytes = testedBytes,
            selectedCount = selectedCount,
            warnings = warnings.map { it.message }
        )
    }

    private fun ZmanagerMobileException.Bridge.toListingState(): ArchiveListingState {
        val error = toListingError()

        return if (code == ERROR_PASSWORD_REQUIRED || code == ERROR_INVALID_PASSWORD) {
            ArchiveListingState.PasswordRequired(error)
        } else {
            ArchiveListingState.Failed(error)
        }
    }

    private fun ZmanagerMobileException.Bridge.toListingError(): ArchiveListingError {
        return ArchiveListingError(
            code = code,
            message = userMessage,
            recoveryHint = recoveryHint,
            retryable = retryable
        )
    }
}

fun ArchiveListingSummary.visibleGroups(
    searchQuery: String,
    sort: ArchiveEntrySort,
    viewMode: ArchiveEntryViewMode
): List<ArchiveEntryGroup> {
    val filtered = entries
        .filter { entry -> entry.matchesSearch(searchQuery) }
        .sortedWith(sort.comparator())

    return when (viewMode) {
        ArchiveEntryViewMode.LIST -> {
            if (filtered.isEmpty()) {
                emptyList()
            } else {
                listOf(ArchiveEntryGroup(id = "all", label = "All entries", entries = filtered))
            }
        }
        ArchiveEntryViewMode.FOLDERS -> filtered
            .groupBy { entry -> entry.parentPath.ifBlank { "/" } }
            .toSortedMap(compareBy<String> { it != "/" }.thenBy { it.lowercase(Locale.ROOT) })
            .map { (parentPath, groupedEntries) ->
                ArchiveEntryGroup(
                    id = parentPath,
                    label = parentPath,
                    entries = groupedEntries
                )
            }
    }
}

fun ArchiveListingSummary.selectedEntries(selectedIds: Set<String>): List<ArchiveEntrySummary> {
    return entries.filter { selectedIds.contains(it.id) }
}

fun ArchiveListingSummary.previewableSelectedEntry(
    selectedIds: Set<String>
): ArchiveEntrySummary? {
    val selected = selectedEntries(selectedIds)
    return selected.singleOrNull()?.takeIf { it.isPreviewable }
}

private fun ArchiveEntrySummary.matchesSearch(searchQuery: String): Boolean {
    val normalizedQuery = searchQuery.trim()
    if (normalizedQuery.isEmpty()) {
        return true
    }

    return path.contains(normalizedQuery, ignoreCase = true) ||
        displayName.contains(normalizedQuery, ignoreCase = true) ||
        parentPath.contains(normalizedQuery, ignoreCase = true)
}

private fun ArchiveEntrySort.comparator(): Comparator<ArchiveEntrySummary> {
    val pathComparator = compareBy<ArchiveEntrySummary> { it.path.lowercase(Locale.ROOT) }
    return when (this) {
        ArchiveEntrySort.PATH_ASCENDING -> pathComparator
        ArchiveEntrySort.SIZE_DESCENDING -> compareByDescending<ArchiveEntrySummary> { it.size ?: 0UL }
            .then(pathComparator)
        ArchiveEntrySort.KIND_ASCENDING -> compareBy<ArchiveEntrySummary> { it.kind.name }
            .then(pathComparator)
    }
}
