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

/** User choice to create one Rust-owned archive per staged top-level item. */
object ArchiveSeparateCreationPlanner {
    fun requests(
        sourcePaths: List<String>,
        destinationDirectory: String,
        format: CreateArchiveFormat,
        password: String? = null,
        preserveMetadata: Boolean = true,
        replaceExisting: Boolean = false,
        cleanSource: Boolean = false,
        verifyAfterCreate: Boolean = true,
        level: UInt = 6u,
        encryptFileNames: Boolean = false,
        volumeSize: ULong? = null,
        recoveryPercentage: UByte = 0u,
        volumeLossTolerance: UByte = 0u
    ): List<ArchiveCreationRequest> {
        require(sourcePaths.isNotEmpty()) { "Select at least one file or folder." }
        val outputNames = uniqueOutputNames(sourcePaths, format)
        return sourcePaths.mapIndexed { index, sourcePath ->
            ArchiveCreationRequest(
                sourcePaths = listOf(sourcePath),
                destinationArchivePath = File(destinationDirectory, outputNames[index]).path,
                format = format,
                password = password,
                preserveMetadata = preserveMetadata,
                replaceExisting = replaceExisting,
                cleanSource = cleanSource,
                verifyAfterCreate = verifyAfterCreate,
                level = level,
                encryptFileNames = encryptFileNames,
                volumeSize = volumeSize,
                recoveryPercentage = recoveryPercentage,
                volumeLossTolerance = volumeLossTolerance
            )
        }
    }

    private fun uniqueOutputNames(sourcePaths: List<String>, format: CreateArchiveFormat): List<String> {
        val extension = when (format) {
            CreateArchiveFormat.ZIP -> ".zip"
            CreateArchiveFormat.SEVEN_Z -> ".7z"
            CreateArchiveFormat.TAR_ZST -> ".tar.zst"
            CreateArchiveFormat.TZAP -> ".tzap"
        }
        val used = mutableSetOf<String>()
        return sourcePaths.map { sourcePath ->
            val sourceName = File(sourcePath).name
            val rawBase = sourceName.substringBeforeLast('.', sourceName)
                .replace(Regex("[\\\\/:*?\"<>|]"), "_")
                .filterNot(Char::isISOControl)
                .trim()
                .trim('.')
                .ifBlank { "archive" }
            var candidate = "$rawBase$extension"
            var index = 1
            while (!used.add(candidate)) {
                candidate = "$rawBase ($index)$extension"
                index += 1
            }
            candidate
        }
    }
}

data class ArchiveSeparateCreationReview(
    val items: List<ArchiveCreationReview>
)

/** Plans each selected top-level item with the existing Rust create operation. */
class ArchiveSeparateCreationCoordinator(
    private val coordinator: ArchiveCreationCoordinator
) {
    fun plan(requests: List<ArchiveCreationRequest>): ArchiveSeparateCreationReview {
        require(requests.isNotEmpty()) { "Select at least one file or folder." }
        val reviews = mutableListOf<ArchiveCreationReview>()
        return try {
            requests.forEach { reviews += coordinator.plan(it) }
            ArchiveSeparateCreationReview(reviews)
        } catch (error: Throwable) {
            reviews.forEach(coordinator::discard)
            throw error
        }
    }

    fun discard(review: ArchiveSeparateCreationReview) {
        review.items.forEach(coordinator::discard)
    }
}

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
    data class Completed(
        val outputPath: String,
        val verified: Boolean,
        val outputPaths: List<String> = listOf(outputPath)
    ) : ArchiveCreationOutcome
    data object Cancelled : ArchiveCreationOutcome
    data class Failed(val message: String) : ArchiveCreationOutcome
}

sealed interface ArchiveCreationUiState {
    data object Idle : ArchiveCreationUiState
    data object Planning : ArchiveCreationUiState
    data class Review(val review: ArchiveCreationReview) : ArchiveCreationUiState
    data class SeparateReview(val review: ArchiveSeparateCreationReview) : ArchiveCreationUiState
    data class Starting(val review: ArchiveCreationReview) : ArchiveCreationUiState
    data class StartingSeparate(val review: ArchiveSeparateCreationReview) : ArchiveCreationUiState
    data class Running(val review: ArchiveCreationReview, val jobId: String, val message: String) : ArchiveCreationUiState
    data class RunningSeparate(val review: ArchiveSeparateCreationReview, val jobId: String, val message: String) : ArchiveCreationUiState
    data class Completed(val outcome: ArchiveCreationOutcome.Completed) : ArchiveCreationUiState
    data object Cancelled : ArchiveCreationUiState
    data class Failed(val message: String) : ArchiveCreationUiState
}

data class StagedCreationSources(
    val root: File,
    val sourcePaths: List<String>
)

object ArchiveVolumeSupport {
    private val SIZE_PATTERN = Regex("^([0-9]+)([kmgt]?i?b?)?$", RegexOption.IGNORE_CASE)

    fun supportsVolumeSize(format: CreateArchiveFormat): Boolean = when (format) {
        CreateArchiveFormat.ZIP,
        CreateArchiveFormat.SEVEN_Z,
        CreateArchiveFormat.TZAP -> true
        CreateArchiveFormat.TAR_ZST -> false
    }

    /** Parses the bridge/CLI-style binary size syntax without using floating point. */
    fun parseVolumeSize(raw: String): ULong? {
        val value = raw.trim()
        if (value.isEmpty()) return null
        val match = SIZE_PATTERN.matchEntire(value)
            ?: throw IllegalArgumentException("Volume size must look like 64k, 1m, or 1g.")
        val amount = match.groupValues[1].toULongOrNull()
            ?: throw IllegalArgumentException("Volume size is too large.")
        val suffix = match.groupValues[2].lowercase().removeSuffix("b").removeSuffix("i")
        val multiplier = when (suffix) {
            "" -> 1UL
            "k" -> 1024UL
            "m" -> 1024UL * 1024UL
            "g" -> 1024UL * 1024UL * 1024UL
            "t" -> 1024UL * 1024UL * 1024UL * 1024UL
            else -> throw IllegalArgumentException("Volume size must use bytes, k, m, g, or t.")
        }
        return amount.checkedMultiply(multiplier)
            ?: throw IllegalArgumentException("Volume size is too large.")
    }

    /** Derives every committed path when the pinned bridge reports only its base destination. */
    fun outputPaths(
        format: CreateArchiveFormat,
        destination: String,
        volumeCount: ULong?,
        reportedPaths: List<String>
    ): List<String> {
        val count = volumeCount?.toInt()?.takeIf { it > 1 } ?: return listOf(destination)
        val destinationFile = File(destination)
        val parent = destinationFile.parentFile
        val name = destinationFile.name
        val paths = when (format) {
            CreateArchiveFormat.ZIP -> {
                val stem = name.substringBeforeLast('.', name)
                (1 until count).map { index -> File(parent, "$stem.z${index.toString().padStart(2, '0')}").path } + destination
            }
            CreateArchiveFormat.SEVEN_Z -> {
                (1..count).map { index -> "$destination.${index.toString().padStart(3, '0')}" }
            }
            CreateArchiveFormat.TZAP -> {
                val stem = name.substringBeforeLast('.', name)
                val extension = name.substringAfterLast('.', "tzap")
                (0 until count).map { index -> File(parent, "$stem.vol${index.toString().padStart(3, '0')}.$extension").path }
            }
            CreateArchiveFormat.TAR_ZST -> reportedPaths.ifEmpty { listOf(destination) }
        }
        return paths
    }

    /** Recovers committed sidecar volumes when an older bridge omits volume metadata. */
    fun committedOutputPaths(
        format: CreateArchiveFormat,
        destination: String,
        volumeCount: ULong?,
        reportedPaths: List<String>
    ): List<String> {
        val expected = outputPaths(format, destination, volumeCount, reportedPaths).toMutableList()
        if (volumeCount?.let { it > 1UL } == true || reportedPaths.isNotEmpty()) {
            return expected
        }
        val destinationFile = File(destination)
        val parent = destinationFile.parentFile ?: File(".")
        val stem = destinationFile.nameWithoutExtension
        val baseName = destinationFile.name
        val extension = destinationFile.extension
        val sidecars = parent.listFiles()?.filter { file ->
            if (!file.isFile) return@filter false
            when (format) {
                CreateArchiveFormat.ZIP -> file.name.startsWith("$stem.z") &&
                    file.name.length == stem.length + 4 &&
                    file.name.drop(stem.length + 2).all(Char::isDigit)
                CreateArchiveFormat.SEVEN_Z -> file.name.startsWith("$baseName.") &&
                    file.name.length == baseName.length + 4 &&
                    file.name.drop(baseName.length + 1).all(Char::isDigit)
                CreateArchiveFormat.TZAP -> file.name.startsWith("$stem.vol") &&
                    file.name.endsWith(".$extension")
                CreateArchiveFormat.TAR_ZST -> false
            }
        }?.sortedBy(File::getName).orEmpty()
        sidecars.forEach { file ->
            if (!expected.contains(file.path)) expected += file.path
        }
        return expected.filter { File(it).isFile }.ifEmpty { listOf(destination) }
    }

    private fun ULong.checkedMultiply(other: ULong): ULong? =
        if (other != 0UL && this > ULong.MAX_VALUE / other) null else this * other
}

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

    /** Deterministic incompressible source used by split-volume device E2E only. */
    fun stageDebugSplitFixture(): StagedCreationSources {
        val root = File(context.cacheDir, "creation-sources/${UUID.randomUUID()}")
        val folder = File(root, "split-fixture-folder")
        check(folder.mkdirs()) { "Unable to prepare split creation fixture." }
        return try {
            File(folder, "readme.txt").writeText("ZManager Mobile split creation fixture\n")
            val bytes = ByteArray(4_000_000)
            var state = 0x6D2B79F5
            bytes.indices.forEach { index ->
                state = state xor (state shl 13)
                state = state xor (state ushr 17)
                state = state xor (state shl 5)
                bytes[index] = state.toByte()
            }
            File(folder, "payload.bin").writeBytes(bytes)
            StagedCreationSources(root, listOf(folder.absolutePath))
        } catch (error: Throwable) {
            root.deleteRecursively()
            throw error
        }
    }

    /** Two top-level files used by separate-archive device E2E only. */
    fun stageDebugSeparateFixture(): StagedCreationSources {
        val root = File(context.cacheDir, "creation-sources/${UUID.randomUUID()}")
        check(root.mkdirs()) { "Unable to prepare separate creation fixture." }
        return try {
            File(root, "one.txt").writeText("first separate archive\n")
            File(root, "two.txt").writeText("second separate archive\n")
            StagedCreationSources(root, listOf(File(root, "one.txt").absolutePath, File(root, "two.txt").absolutePath))
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
        return File(appStorageDirectory(), safeName)
    }

    fun appStorageDirectory(): File {
        val root = File(context.filesDir, "CreatedArchives")
        check(root.mkdirs() || root.isDirectory) { "Unable to prepare archive output storage." }
        return root
    }

    fun plan(request: ArchiveCreationRequest): ArchiveCreationReview {
        require(request.sourcePaths.isNotEmpty()) { "Select at least one file or folder." }
        require(request.volumeSize == null || ArchiveVolumeSupport.supportsVolumeSize(request.format)) {
            "Split volumes are supported only for ZIP, 7z, and TZAP archives."
        }
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
                        val outputPaths = ArchiveVolumeSupport.committedOutputPaths(
                            request.format,
                            request.destinationArchivePath,
                            update.terminalSummary?.volumeCount,
                            update.terminalSummary?.outputPaths.orEmpty()
                        )
                        discard(review)
                        ArchiveCreationOutcome.Completed(request.destinationArchivePath, verified, outputPaths)
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
