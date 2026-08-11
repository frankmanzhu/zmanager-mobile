package org.tzap.zmanager.mobile

import android.content.Context
import android.net.Uri
import androidx.documentfile.provider.DocumentFile
import kotlinx.coroutines.delay
import org.tzap.zmanager.mobile.bridge.generated.ExtractionCollisionPolicy
import org.tzap.zmanager.mobile.bridge.generated.MobileJobStatus
import org.tzap.zmanager.mobile.bridge.generated.PlanExtractResult
import java.io.File
import java.io.IOException
import java.util.UUID

sealed interface ExtractionDestination {
    val label: String

    data class AppStorage(private val root: File) : ExtractionDestination {
        override val label: String = "App storage"
        fun root(): File = root
    }

    data class DocumentTree(val uri: Uri) : ExtractionDestination {
        override val label: String = "Selected folder"
    }
}

data class ExtractionReview(
    val id: String,
    val destination: ExtractionDestination,
    val plan: PlanExtractResult,
    val collisionPolicy: ExtractionCollisionPolicy
)

data class ExtractionProgress(
    val message: String,
    val processedBytes: ULong?,
    val totalBytes: ULong?,
    val processedEntries: ULong?,
    val totalEntries: ULong?
)

sealed interface ExtractionOutcome {
    data class Completed(val writtenEntries: ULong, val destination: String) : ExtractionOutcome
    data object Cancelled : ExtractionOutcome
    data class Failed(val message: String) : ExtractionOutcome
}

/**
 * Keeps Rust responsible for archive I/O. The platform only commits files from a private,
 * per-job staging directory to the user-selected destination after Rust reports completion.
 */
class ArchiveExtractionCoordinator(
    private val context: Context,
    private val bridge: ArchiveBridgeGateway = GeneratedArchiveBridgeGateway()
) {
    private data class Session(
        val archive: ImportedArchive,
        val selectedPaths: List<String>,
        val stagingRoot: File,
        val destination: ExtractionDestination,
        val collisionPolicy: ExtractionCollisionPolicy,
        val stagingCollisionPolicy: ExtractionCollisionPolicy,
        var password: String?
    )

    private val sessions = mutableMapOf<String, Session>()

    fun appStorageDestination(): ExtractionDestination.AppStorage {
        return ExtractionDestination.AppStorage(File(context.filesDir, "Extracted"))
    }

    fun plan(
        archive: ImportedArchive,
        selectedPaths: List<String>,
        destination: ExtractionDestination,
        password: String?,
        collisionPolicy: ExtractionCollisionPolicy = ExtractionCollisionPolicy.REFUSE
    ): ExtractionReview {
        val id = UUID.randomUUID().toString()
        val stagingRoot = File(context.cacheDir, "extractions/$id/staging")
        check(stagingRoot.parentFile?.mkdirs() != false || stagingRoot.parentFile?.isDirectory == true) {
            "Unable to prepare private extraction staging."
        }
        val stagingPath = stagingRoot.canonicalPath
        val plan = bridge.planExtract(
            archivePath = archive.localPath,
            destinationRoot = stagingPath,
            selectedPaths = selectedPaths,
            password = password,
            // The stage is private and freshly created. Replace avoids Android cache
            // filesystems rejecting AtomicOutputFile's refuse-policy hard-link commit.
            collisionPolicy = ExtractionCollisionPolicy.REPLACE
        )
        val session = Session(
            archive = archive,
            selectedPaths = selectedPaths,
            stagingRoot = stagingRoot,
            destination = destination,
            collisionPolicy = collisionPolicy,
            stagingCollisionPolicy = ExtractionCollisionPolicy.REPLACE,
            password = password
        )
        sessions[id] = session
        return ExtractionReview(id, destination, plan, collisionPolicy)
    }

    fun start(review: ExtractionReview): String {
        val session = sessions[review.id] ?: throw IllegalStateException("The extraction review expired.")
        check(review.plan.canStart && review.plan.planToken.isNotBlank()) {
            "This extraction plan cannot be started."
        }
        val result = bridge.startExtract(
            archivePath = session.archive.localPath,
            destinationRoot = session.stagingRoot.canonicalPath,
            selectedPaths = session.selectedPaths,
            password = session.password,
            collisionPolicy = session.stagingCollisionPolicy,
            planToken = review.plan.planToken
        )
        session.password = null
        return result.jobId
    }

    suspend fun awaitCompletion(
        review: ExtractionReview,
        jobId: String,
        onProgress: (ExtractionProgress) -> Unit
    ): ExtractionOutcome {
        val session = sessions[review.id] ?: return ExtractionOutcome.Failed("The extraction session expired.")
        var cursor = 0UL
        while (true) {
            val update = bridge.pollJob(jobId, cursor)
            cursor = update.nextCursor
            update.events.lastOrNull()?.let { event ->
                onProgress(
                    ExtractionProgress(
                        message = event.message ?: event.path ?: "Extracting archive",
                        processedBytes = event.totalBytesProcessed ?: event.bytes,
                        totalBytes = event.totalBytes,
                        processedEntries = event.entries,
                        totalEntries = event.totalEntries
                    )
                )
            }
            if (update.isTerminal) {
                return when (update.status) {
                    MobileJobStatus.COMPLETED -> commitCompletedSession(review, session)
                    MobileJobStatus.CANCELLED -> {
                        discard(review)
                        ExtractionOutcome.Cancelled
                    }
                    else -> ExtractionOutcome.Failed(
                        update.events.lastOrNull()?.error?.message
                            ?: update.events.lastOrNull()?.message
                            ?: "Archive extraction failed."
                    )
                }
            }
            delay(150)
        }
    }

    fun cancel(jobId: String) {
        bridge.cancelJob(jobId)
    }

    fun discard(review: ExtractionReview) {
        sessions.remove(review.id)?.let { session ->
            session.password = null
            session.stagingRoot.parentFile?.deleteRecursively()
        }
    }

    private fun commitCompletedSession(review: ExtractionReview, session: Session): ExtractionOutcome {
        return try {
            when (val destination = session.destination) {
                is ExtractionDestination.AppStorage -> commitToFileRoot(
                    session.stagingRoot,
                    destination.root(),
                    review.collisionPolicy
                )
                is ExtractionDestination.DocumentTree -> commitToDocumentTree(
                    session.stagingRoot,
                    destination.uri,
                    review.collisionPolicy
                )
            }
            val writtenEntries = review.plan.writableEntries
            val label = session.destination.label
            discard(review)
            ExtractionOutcome.Completed(writtenEntries, label)
        } catch (error: IOException) {
            ExtractionOutcome.Failed(error.message ?: "Unable to save extracted files.")
        }
    }

    private fun commitToFileRoot(sourceRoot: File, targetRoot: File, policy: ExtractionCollisionPolicy) {
        require(sourceRoot.isDirectory) { "The staged extraction is unavailable." }
        sourceRoot.walkTopDown().forEach { source ->
            if (source == sourceRoot) return@forEach
            val relative = source.relativeTo(sourceRoot).path
            val target = File(targetRoot, relative)
            if (source.isDirectory) {
                if (target.exists() && !target.isDirectory) resolveFileCollision(target, policy).mkdirs()
                else target.mkdirs()
            } else {
                val resolved = resolveFileCollision(target, policy)
                resolved.parentFile?.mkdirs()
                source.inputStream().use { input -> resolved.outputStream().use(input::copyTo) }
            }
        }
    }

    private fun commitToDocumentTree(
        sourceRoot: File,
        treeUri: Uri,
        policy: ExtractionCollisionPolicy
    ) {
        require(sourceRoot.isDirectory) { "The staged extraction is unavailable." }
        val root = DocumentFile.fromTreeUri(context, treeUri)
            ?: throw IOException("The selected folder is no longer available.")
        sourceRoot.walkTopDown().filter { it.isFile }.forEach { source ->
            val pieces = source.relativeTo(sourceRoot).invariantSeparatorsPath.split('/').filter(String::isNotEmpty)
            var parent = root
            for (name in pieces.dropLast(1)) {
                parent = parent.findFile(name)?.takeIf { it.isDirectory } ?: parent.createDirectory(name)
                    ?: throw IOException("Unable to create $name in the selected folder.")
            }
            val desiredName = pieces.last()
            val existing = parent.findFile(desiredName)
            val target = when {
                existing == null -> parent.createFile("application/octet-stream", desiredName)
                policy == ExtractionCollisionPolicy.REPLACE -> {
                    existing.delete()
                    parent.createFile("application/octet-stream", desiredName)
                }
                policy == ExtractionCollisionPolicy.RENAME -> parent.createFile(
                    "application/octet-stream",
                    uniqueDocumentName(parent, desiredName)
                )
                else -> throw IOException("$desiredName already exists in the selected folder.")
            } ?: throw IOException("Unable to create $desiredName in the selected folder.")
            context.contentResolver.openOutputStream(target.uri, "wt")?.use { output ->
                source.inputStream().use { it.copyTo(output) }
            } ?: throw IOException("Unable to write $desiredName.")
        }
    }

    private fun resolveFileCollision(target: File, policy: ExtractionCollisionPolicy): File {
        if (!target.exists()) return target
        return when (policy) {
            ExtractionCollisionPolicy.REPLACE -> target.apply { if (isDirectory) deleteRecursively() else delete() }
            ExtractionCollisionPolicy.RENAME -> uniqueFile(target)
            ExtractionCollisionPolicy.REFUSE -> throw IOException("${target.name} already exists in the destination.")
        }
    }

    private fun uniqueFile(target: File): File {
        val base = target.name.substringBeforeLast('.', target.name)
        val extension = target.name.substringAfterLast('.', "").takeIf { it != target.name }
        return generateSequence(1) { it + 1 }
            .map { index -> File(target.parentFile, "$base ($index)" + extension?.let { ".$it" }.orEmpty()) }
            .first { !it.exists() }
    }

    private fun uniqueDocumentName(parent: DocumentFile, name: String): String {
        val base = name.substringBeforeLast('.', name)
        val extension = name.substringAfterLast('.', "").takeIf { it != name }
        return generateSequence(1) { it + 1 }
            .map { index -> "$base ($index)" + extension?.let { ".$it" }.orEmpty() }
            .first { parent.findFile(it) == null }
    }
}
