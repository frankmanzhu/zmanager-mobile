package org.tzap.zmanager.mobile

import android.content.Context
import android.net.Uri
import androidx.documentfile.provider.DocumentFile
import kotlinx.coroutines.delay
import org.tzap.zmanager.mobile.bridge.generated.CreateArchiveFormat
import org.tzap.zmanager.mobile.bridge.generated.MobileJobStatus
import org.tzap.zmanager.mobile.bridge.generated.PlanCreateRequest
import org.tzap.zmanager.mobile.bridge.generated.PlanCreateResult
import org.tzap.zmanager.mobile.bridge.generated.StartCreateRequest
import java.io.File
import java.io.IOException
import java.util.UUID

data class ArchiveCreationRequest(
    val sourcePaths: List<String>,
    val destinationArchivePath: String,
    val format: CreateArchiveFormat,
    val password: String? = null,
    val preserveMetadata: Boolean = true,
    val replaceExisting: Boolean = false,
    val cleanSource: Boolean = false,
    val verifyAfterCreate: Boolean = true,
    val level: UInt = 6u,
    val encryptFileNames: Boolean = false,
    val volumeSize: ULong? = null,
    val recoveryPercentage: UByte = 0u,
    val volumeLossTolerance: UByte = 0u
)

data class ArchiveCreationReview(
    val id: String,
    val request: ArchiveCreationRequest,
    val plan: PlanCreateResult
)

data class ArchiveCreationProgress(
    val message: String,
    val processedBytes: ULong?,
    val totalBytes: ULong?,
    val processedEntries: ULong?,
    val totalEntries: ULong?
)

sealed interface ArchiveCreationOutcome {
    data class Completed(val outputPath: String, val verified: Boolean) : ArchiveCreationOutcome
    data object Cancelled : ArchiveCreationOutcome
    data class Failed(val message: String) : ArchiveCreationOutcome
}

sealed interface ArchiveCreationUiState {
    data object Idle : ArchiveCreationUiState
    data object Planning : ArchiveCreationUiState
    data class Review(val review: ArchiveCreationReview) : ArchiveCreationUiState
    data class Starting(val review: ArchiveCreationReview) : ArchiveCreationUiState
    data class Running(val review: ArchiveCreationReview, val jobId: String, val message: String) : ArchiveCreationUiState
    data class Completed(val outcome: ArchiveCreationOutcome.Completed) : ArchiveCreationUiState
    data object Cancelled : ArchiveCreationUiState
    data class Failed(val message: String) : ArchiveCreationUiState
}

data class StagedCreationSources(
    val root: File,
    val sourcePaths: List<String>
)

/** Converts provider-backed files into stable, app-owned paths for the Rust create bridge. */
class ArchiveCreationSourceStager(private val context: Context) {
    fun stageFiles(uris: List<Uri>): StagedCreationSources {
        require(uris.isNotEmpty()) { "Select at least one file." }
        val root = File(context.cacheDir, "creation-sources/${UUID.randomUUID()}")
        check(root.mkdirs()) { "Unable to prepare archive creation staging." }
        return try {
            val sourcePaths = uris.mapIndexed { index, uri ->
                val document = DocumentFile.fromSingleUri(context, uri)
                val name = safeName(document?.name ?: uri.lastPathSegment ?: "file-$index")
                val destination = uniqueFile(root, name)
                context.contentResolver.openInputStream(uri)?.use { input ->
                    destination.outputStream().use(input::copyTo)
                } ?: throw IOException("Unable to read selected file.")
                destination.absolutePath
            }
            StagedCreationSources(root, sourcePaths)
        } catch (error: Throwable) {
            root.deleteRecursively()
            throw error
        }
    }

    fun stageTree(uri: Uri): StagedCreationSources {
        val document = DocumentFile.fromTreeUri(context, uri)
            ?: throw IOException("Unable to open selected folder.")
        val root = File(context.cacheDir, "creation-sources/${UUID.randomUUID()}")
        check(root.mkdirs()) { "Unable to prepare archive creation staging." }
        return try {
            val folder = File(root, safeName(document.name ?: "folder"))
            copyDirectory(document, folder)
            StagedCreationSources(root, listOf(folder.absolutePath))
        } catch (error: Throwable) {
            root.deleteRecursively()
            throw error
        }
    }

    /** Deterministic app-owned source used by debug/device E2E only. */
    fun stageDebugFixture(): StagedCreationSources {
        val root = File(context.cacheDir, "creation-sources/${UUID.randomUUID()}")
        val folder = File(root, "fixture-folder")
        check(folder.mkdirs()) { "Unable to prepare archive creation staging." }
        return try {
            File(folder, "readme.txt").writeText("ZManager Mobile creation fixture\n")
            File(folder, "nested/data.bin").apply {
                parentFile?.mkdirs()
                writeBytes(byteArrayOf(0, 1, 2, 3, 4, 5))
            }
            StagedCreationSources(root, listOf(folder.absolutePath))
        } catch (error: Throwable) {
            root.deleteRecursively()
            throw error
        }
    }

    fun discard(staged: StagedCreationSources) {
        staged.root.deleteRecursively()
    }

    private fun safeName(raw: String): String {
        val cleaned = raw
            .substringAfterLast('/')
            .substringAfterLast('\\')
            .replace(Regex("[\\\\/:*?\"<>|]"), "_")
            .filterNot(Char::isISOControl)
            .trim()
            .trim('.')
        return cleaned.ifBlank { "file" }
    }

    private fun uniqueFile(root: File, name: String): File {
        var candidate = File(root, name)
        var index = 1
        while (candidate.exists()) {
            val base = name.substringBeforeLast('.', name)
            val extension = name.substringAfterLast('.', "").takeIf { it != name }
            candidate = File(root, if (extension == null) "$base ($index)" else "$base ($index).$extension")
            index += 1
        }
        return candidate
    }

    private fun copyDirectory(source: DocumentFile, destination: File) {
        check(destination.mkdirs() || destination.isDirectory) { "Unable to prepare folder staging." }
        source.listFiles().forEach { child ->
            val childName = safeName(child.name ?: "file")
            if (child.isDirectory) {
                copyDirectory(child, File(destination, childName))
            } else if (child.isFile) {
                val target = uniqueFile(destination, childName)
                context.contentResolver.openInputStream(child.uri)?.use { input ->
                    target.outputStream().use(input::copyTo)
                } ?: throw IOException("Unable to read selected folder entry.")
            }
        }
    }
}

/** Coordinates planned Rust archive creation without allowing native code to archive files. */
class ArchiveCreationCoordinator(
    private val context: Context,
    private val bridge: ArchiveBridgeGateway = GeneratedArchiveBridgeGateway()
) {
    private val sessions = mutableMapOf<String, ArchiveCreationRequest>()

    fun appStorageOutput(displayName: String): File {
        val safeName = displayName
            .replace(Regex("[\\\\/:*?\"<>|]"), "_")
            .trim()
            .ifBlank { "archive.zip" }
        val root = File(context.filesDir, "CreatedArchives")
        check(root.mkdirs() || root.isDirectory) { "Unable to prepare archive output storage." }
        return File(root, safeName)
    }

    fun plan(request: ArchiveCreationRequest): ArchiveCreationReview {
        require(request.sourcePaths.isNotEmpty()) { "Select at least one file or folder." }
        val result = bridge.planCreate(
            PlanCreateRequest(
                sourcePaths = request.sourcePaths,
                destinationArchivePath = request.destinationArchivePath,
                format = request.format,
                password = request.password,
                preserveMetadata = request.preserveMetadata,
                replaceExisting = request.replaceExisting,
                cleanSource = request.cleanSource,
                verifyAfterCreate = request.verifyAfterCreate
            )
        )
        val id = UUID.randomUUID().toString()
        sessions[id] = request
        return ArchiveCreationReview(id, request, result)
    }

    fun start(review: ArchiveCreationReview): String {
        val request = sessions[review.id] ?: throw IllegalStateException("The creation review expired.")
        check(review.plan.canStart) { "This creation plan cannot be started." }
        val result = bridge.startCreate(
            StartCreateRequest(
                sourcePaths = request.sourcePaths,
                destinationArchivePath = request.destinationArchivePath,
                format = request.format,
                password = request.password,
                preserveMetadata = request.preserveMetadata,
                replaceExisting = request.replaceExisting,
                cleanSource = request.cleanSource,
                verifyAfterCreate = request.verifyAfterCreate,
                excludedPaths = emptyList(),
                level = request.level,
                encryptFileNames = request.encryptFileNames,
                volumeSize = request.volumeSize,
                recoveryPercentage = request.recoveryPercentage,
                volumeLossTolerance = request.volumeLossTolerance,
                tzapSigningCertificate = null,
                tzapSigningPrivateKey = null,
                tzapSigningChain = emptyList(),
                tzapIdentity = null,
                tzapIdentityPassword = null
            )
        )
        // Do not retain passwords after the bridge accepts the job.
        sessions[review.id] = request.copy(password = null)
        return result.jobId
    }

    suspend fun awaitCompletion(
        review: ArchiveCreationReview,
        jobId: String,
        onProgress: (ArchiveCreationProgress) -> Unit
    ): ArchiveCreationOutcome {
        val request = sessions[review.id]
            ?: return ArchiveCreationOutcome.Failed("The creation session expired.")
        var cursor = 0UL
        while (true) {
            val update = bridge.pollJob(jobId, cursor)
            cursor = update.nextCursor
            update.events.lastOrNull()?.let { event ->
                onProgress(
                    ArchiveCreationProgress(
                        message = event.message ?: event.path ?: "Creating archive",
                        processedBytes = event.totalBytesProcessed ?: event.bytes,
                        totalBytes = event.totalBytes,
                        processedEntries = event.entries,
                        totalEntries = event.totalEntries
                    )
                )
            }
            if (update.isTerminal) {
                return when (update.status) {
                    MobileJobStatus.COMPLETED -> {
                        val verified = request.verifyAfterCreate &&
                            update.terminalSummary?.verified == true
                        discard(review)
                        ArchiveCreationOutcome.Completed(request.destinationArchivePath, verified)
                    }
                    MobileJobStatus.CANCELLED -> {
                        discard(review)
                        ArchiveCreationOutcome.Cancelled
                    }
                    else -> {
                        val message = update.events.lastOrNull()?.error?.message
                            ?: update.events.lastOrNull()?.message
                            ?: "Archive creation failed."
                        discard(review)
                        ArchiveCreationOutcome.Failed(message)
                    }
                }
            }
            delay(150)
        }
    }

    fun cancel(jobId: String) {
        bridge.cancelJob(jobId)
    }

    fun discard(review: ArchiveCreationReview) {
        sessions.remove(review.id)?.let { request ->
            // Clear the transient password reference as soon as the session ends.
            request.copy(password = null)
        }
    }
}
