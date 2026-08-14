package org.tzap.zmanager.mobile

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import androidx.annotation.RequiresApi
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout
import org.json.JSONArray
import org.tzap.zmanager.mobile.bridge.generated.ZmanagerGuiException
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean

sealed interface ArchiveForegroundRequest {
    data class Extract(val request: ArchiveExtractionRequest) : ArchiveForegroundRequest
    data class Create(val request: ArchiveCreationRequest) : ArchiveForegroundRequest
    data class CreateSeparately(val requests: List<ArchiveCreationRequest>) : ArchiveForegroundRequest
    data class BatchExtract(val request: ArchiveBatchExtractionRequest) : ArchiveForegroundRequest
}

data class ArchiveForegroundResult(
    val token: String,
    val kind: String,
    val status: String,
    val message: String? = null,
    val outputPath: String? = null,
    val outputPaths: List<String> = emptyList(),
    val verified: Boolean? = null,
    val writtenEntries: ULong? = null,
    val recoveryId: String? = null
)

/**
 * Owns the Android long-job handoff. Requests are held only in this process;
 * passwords are never placed in Intent extras, notifications, or persisted
 * service state.
 */
object ArchiveJobForegroundService {
    const val ACTION_RESULT = "org.tzap.zmanager.mobile.ARCHIVE_JOB_RESULT"
    const val ACTION_CANCEL = "org.tzap.zmanager.mobile.ARCHIVE_JOB_CANCEL"
    private const val EXTRA_TOKEN = "token"
    private const val EXTRA_KIND = "kind"
    private const val EXTRA_STATUS = "status"
    private const val EXTRA_MESSAGE = "message"
    private const val EXTRA_OUTPUT_PATH = "outputPath"
    private const val EXTRA_OUTPUT_PATHS = "outputPaths"
    private const val EXTRA_VERIFIED = "verified"
    private const val EXTRA_WRITTEN_ENTRIES = "writtenEntries"
    private const val EXTRA_RECOVERY_ID = "recoveryId"
    private const val EXTRA_REQUEST_TOKEN = "requestToken"
    private const val EXTRA_CANCEL_TOKEN = "cancelToken"
    private const val KIND_EXTRACT = "extract"
    private const val KIND_CREATE = "create"
    private const val KIND_CREATE_SEPARATELY = "create-separately"
    private const val KIND_BATCH_EXTRACT = "batch-extract"
    private const val CHANNEL_ID = "archive_jobs"
    private const val NOTIFICATION_ID = 0x5A4D
    private const val RESULTS_PREFS = "archive_job_results"
    private const val RESULT_PREFIX = "result."
    private const val ACTIVE_TOKEN = "active.token"
    private const val ACTIVE_KIND = "active.kind"
    // Android's dataSync foreground-service budget is platform-limited on
    // newer releases. Stop before that boundary so the app can report a
    // deterministic timeout and clean its Rust staging state.
    private const val JOB_TIMEOUT_MILLIS = 5L * 60L * 60L * 1000L

    private val requests = ConcurrentHashMap<String, ArchiveForegroundRequest>()
    @Volatile
    private var serviceAlive = false

    fun submit(context: Context, request: ArchiveForegroundRequest): String {
        val token = UUID.randomUUID().toString()
        requests[token] = request
        val intent = Intent(context, Service::class.java)
            .putExtra(EXTRA_REQUEST_TOKEN, token)
        ContextCompat.startForegroundService(context, intent)
        return token
    }

    fun cancel(context: Context, token: String) {
        context.startService(
            Intent(context, Service::class.java)
                .setAction(ACTION_CANCEL)
                .putExtra(EXTRA_CANCEL_TOKEN, token)
        )
    }

    internal fun takeRequest(token: String): ArchiveForegroundRequest? = requests.remove(token)

    /**
     * Converts a service process death into a visible, retryable terminal
     * result. Only a token and operation kind are persisted; requests and
     * passwords remain process-memory only.
     */
    internal fun recoverInterruptedResult(context: Context) {
        val preferences = context.getSharedPreferences(RESULTS_PREFS, Context.MODE_PRIVATE)
        val token = preferences.getString(ACTIVE_TOKEN, null) ?: return
        val kind = preferences.getString(ACTIVE_KIND, "unknown") ?: "unknown"
        persistResult(
            context,
            ArchiveForegroundResult(
                token = token,
                kind = kind,
                status = "INTERRUPTED",
                message = "The archive job was interrupted when the app process stopped. Review and retry it."
            )
        )
        clearActiveMarker(context)
    }

    private fun markActive(context: Context, token: String, kind: String) {
        context.getSharedPreferences(RESULTS_PREFS, Context.MODE_PRIVATE).edit()
            .putString(ACTIVE_TOKEN, token)
            .putString(ACTIVE_KIND, kind)
            .apply()
    }

    private fun clearActiveMarker(context: Context) {
        context.getSharedPreferences(RESULTS_PREFS, Context.MODE_PRIVATE).edit()
            .remove(ACTIVE_TOKEN)
            .remove(ACTIVE_KIND)
            .apply()
    }

    internal fun resultFrom(intent: Intent): ArchiveForegroundResult? {
        val token = intent.getStringExtra(EXTRA_TOKEN) ?: return null
        return ArchiveForegroundResult(
            token = token,
            kind = intent.getStringExtra(EXTRA_KIND) ?: return null,
            status = intent.getStringExtra(EXTRA_STATUS) ?: return null,
            message = intent.getStringExtra(EXTRA_MESSAGE),
            outputPath = intent.getStringExtra(EXTRA_OUTPUT_PATH),
            outputPaths = intent.getStringArrayListExtra(EXTRA_OUTPUT_PATHS).orEmpty().ifEmpty {
                intent.getStringExtra(EXTRA_OUTPUT_PATH)?.let(::listOf).orEmpty()
            },
            verified = if (intent.hasExtra(EXTRA_VERIFIED)) intent.getBooleanExtra(EXTRA_VERIFIED, false) else null,
            writtenEntries = intent.getStringExtra(EXTRA_WRITTEN_ENTRIES)?.toULongOrNull(),
            recoveryId = intent.getStringExtra(EXTRA_RECOVERY_ID)
        )
    }

    /** Returns terminal results left while the Activity was not alive. */
    internal fun takePersistedResults(context: Context): List<ArchiveForegroundResult> {
        if (!serviceAlive) {
            recoverInterruptedResult(context)
        }
        val preferences = context.getSharedPreferences(RESULTS_PREFS, Context.MODE_PRIVATE)
        val tokens = preferences.all.keys
            .filter { it.startsWith(RESULT_PREFIX) && it.endsWith(".status") }
            .map { it.removePrefix(RESULT_PREFIX).removeSuffix(".status") }
        val results = tokens.mapNotNull { token ->
            val kind = preferences.getString("$RESULT_PREFIX$token.kind", null) ?: return@mapNotNull null
            val status = preferences.getString("$RESULT_PREFIX$token.status", null) ?: return@mapNotNull null
            ArchiveForegroundResult(
                token = token,
                kind = kind,
                status = status,
                message = preferences.getString("$RESULT_PREFIX$token.message", null),
                outputPath = preferences.getString("$RESULT_PREFIX$token.outputPath", null),
                outputPaths = preferences.getString("$RESULT_PREFIX$token.outputPaths", null)
                    ?.let(::JSONArray)
                    ?.let { paths -> List(paths.length()) { index -> paths.optString(index) }.filter(String::isNotEmpty) }
                    .orEmpty()
                    .ifEmpty {
                        preferences.getString("$RESULT_PREFIX$token.outputPath", null)?.let(::listOf).orEmpty()
                    },
                verified = if (preferences.contains("$RESULT_PREFIX$token.verified")) {
                    preferences.getBoolean("$RESULT_PREFIX$token.verified", false)
                } else null,
                writtenEntries = preferences.getString("$RESULT_PREFIX$token.writtenEntries", null)?.toULongOrNull(),
                recoveryId = preferences.getString("$RESULT_PREFIX$token.recoveryId", null)
            )
        }
        if (results.isNotEmpty()) {
            preferences.edit().apply {
                results.forEach { result ->
                    remove("$RESULT_PREFIX${result.token}.kind")
                    remove("$RESULT_PREFIX${result.token}.status")
                    remove("$RESULT_PREFIX${result.token}.message")
                    remove("$RESULT_PREFIX${result.token}.outputPath")
                    remove("$RESULT_PREFIX${result.token}.outputPaths")
                    remove("$RESULT_PREFIX${result.token}.verified")
                    remove("$RESULT_PREFIX${result.token}.writtenEntries")
                    remove("$RESULT_PREFIX${result.token}.recoveryId")
                }
            }.apply()
        }
        return results
    }

    private fun resultIntent(result: ArchiveForegroundResult): Intent =
        Intent(ACTION_RESULT)
            .setPackage("org.tzap.zmanager.mobile")
            .putExtra(EXTRA_TOKEN, result.token)
            .putExtra(EXTRA_KIND, result.kind)
            .putExtra(EXTRA_STATUS, result.status)
            .apply {
                result.message?.let { putExtra(EXTRA_MESSAGE, it) }
                result.outputPath?.let { putExtra(EXTRA_OUTPUT_PATH, it) }
                result.outputPaths.takeIf { it.isNotEmpty() }?.let {
                    putStringArrayListExtra(EXTRA_OUTPUT_PATHS, ArrayList(it))
                }
                result.verified?.let { putExtra(EXTRA_VERIFIED, it) }
                result.writtenEntries?.let { putExtra(EXTRA_WRITTEN_ENTRIES, it.toString()) }
                result.recoveryId?.let { putExtra(EXTRA_RECOVERY_ID, it) }
            }

    private fun persistResult(context: Context, result: ArchiveForegroundResult) {
        context.getSharedPreferences(RESULTS_PREFS, Context.MODE_PRIVATE).edit().apply {
            putString("$RESULT_PREFIX${result.token}.kind", result.kind)
            putString("$RESULT_PREFIX${result.token}.status", result.status)
            result.message?.let { putString("$RESULT_PREFIX${result.token}.message", it) }
            result.outputPath?.let { putString("$RESULT_PREFIX${result.token}.outputPath", it) }
            putString(
                "$RESULT_PREFIX${result.token}.outputPaths",
                JSONArray(result.outputPaths.ifEmpty { result.outputPath?.let(::listOf).orEmpty() }).toString()
            )
            result.verified?.let { putBoolean("$RESULT_PREFIX${result.token}.verified", it) }
            result.writtenEntries?.let { putString("$RESULT_PREFIX${result.token}.writtenEntries", it.toString()) }
            result.recoveryId?.let { putString("$RESULT_PREFIX${result.token}.recoveryId", it) }
        }.apply()
    }

    class Service : android.app.Service() {
        private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        private var activeToken: String? = null
        private var activeKind: String? = null
        private var cancelActive: (() -> Unit)? = null
        private val platformTimeout = AtomicBoolean(false)

        override fun onCreate() {
            super.onCreate()
            serviceAlive = true
            recoverInterruptedResult(applicationContext)
            createChannel()
            startForeground(NOTIFICATION_ID, notification("Archive job starting"))
        }

        override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
            if (intent?.action == ACTION_CANCEL) {
                cancelActive?.invoke()
                return START_NOT_STICKY
            }
            val token = intent?.getStringExtra(EXTRA_REQUEST_TOKEN) ?: return START_NOT_STICKY
            if (activeToken != null) {
                val request = takeRequest(token)
                sendResult(
                    ArchiveForegroundResult(
                        token,
                        request?.let(::kindOf) ?: "unknown",
                        "FAILED",
                        "Another archive job is already running."
                    )
                )
                return START_NOT_STICKY
            }
            val request = takeRequest(token)
            if (request == null) {
                sendResult(ArchiveForegroundResult(token, "unknown", "FAILED", "The archive job request expired."))
                return START_NOT_STICKY
            }
            activeToken = token
            activeKind = kindOf(request)
            platformTimeout.set(false)
            markActive(applicationContext, token, activeKind ?: "unknown")
            serviceScope.launch {
            try {
                    val timeoutMillis = (request as? ArchiveForegroundRequest.Extract)
                        ?.request?.debugTimeoutMillis
                        ?: JOB_TIMEOUT_MILLIS
                    withTimeout(timeoutMillis) {
                        when (request) {
                            is ArchiveForegroundRequest.Extract -> runExtraction(token, request.request)
                            is ArchiveForegroundRequest.Create -> runCreation(token, request.request)
                            is ArchiveForegroundRequest.CreateSeparately -> runCreationSeparately(token, request.requests)
                            is ArchiveForegroundRequest.BatchExtract -> runBatchExtraction(token, request.request)
                        }
                    }
                } catch (error: TimeoutCancellationException) {
                    cancelActive?.invoke()
                    sendResult(
                        ArchiveForegroundResult(
                            token,
                            kindOf(request),
                            "TIMEOUT",
                            "The archive job exceeded the Android background time limit. Retry it in the app."
                        )
                    )
                } catch (_: CancellationException) {
                    if (!platformTimeout.get()) {
                        sendResult(ArchiveForegroundResult(token, kindOf(request), "CANCELLED"))
                    }
                } catch (error: Throwable) {
                    sendResult(
                        ArchiveForegroundResult(
                            token,
                            kindOf(request),
                            "FAILED",
                            error.userMessage()
                        )
                    )
                } finally {
                    clearActiveMarker(applicationContext)
                    cancelActive = null
                    activeToken = null
                    activeKind = null
                    stopSelfResult(startId)
                }
            }
            return START_NOT_STICKY
        }

        /**
         * Android 15 invokes this when the declared foreground-service type
         * exhausts its platform budget. Stop the Rust job and persist the same
         * redacted terminal state used by the app-level timeout path.
         */
        @RequiresApi(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
        override fun onTimeout(startId: Int) {
            handlePlatformTimeout(startId)
        }

        @RequiresApi(Build.VERSION_CODES.VANILLA_ICE_CREAM)
        override fun onTimeout(startId: Int, fgsType: Int) {
            handlePlatformTimeout(startId)
        }

        private fun handlePlatformTimeout(startId: Int) {
            val token = activeToken ?: run {
                stopSelfResult(startId)
                return
            }
            if (platformTimeout.compareAndSet(false, true)) {
                cancelActive?.invoke()
                sendResult(
                    ArchiveForegroundResult(
                        token = token,
                        kind = activeKind ?: "unknown",
                        status = "TIMEOUT",
                        message = "The archive job exceeded the Android background time limit. Retry it in the app."
                    )
                )
                serviceScope.cancel()
            }
            stopSelfResult(startId)
        }

        private suspend fun runExtraction(token: String, request: ArchiveExtractionRequest) {
            val coordinator = ArchiveExtractionCoordinator(applicationContext)
            val review = coordinator.plan(
                archive = request.archive,
                selectedPaths = request.selectedPaths,
                destination = request.destination,
                password = request.password,
                collisionPolicy = request.collisionPolicy
            )
            try {
                val jobId = coordinator.start(review)
                val debugCancellationRequested = AtomicBoolean(false)
                cancelActive = {
                    if (request.debugDelayMillis > 0L) debugCancellationRequested.set(true)
                    runCatching { coordinator.cancel(jobId) }
                }
                if (request.debugDelayMillis > 0L) {
                    delay(request.debugDelayMillis.coerceIn(0L, 30_000L))
                }
                if (debugCancellationRequested.get()) {
                    coordinator.discard(review)
                    sendResult(ArchiveForegroundResult(token, KIND_EXTRACT, "CANCELLED"))
                    return
                }
                val outcome = coordinator.awaitCompletion(
                    review,
                    jobId,
                    debugDelayMillis = request.debugDelayMillis
                ) { updateNotification("Extracting archive") }
                when (outcome) {
                is ExtractionOutcome.Completed -> sendResult(
                    ArchiveForegroundResult(
                        token,
                        KIND_EXTRACT,
                        "COMPLETED",
                        message = outcome.destination,
                        writtenEntries = outcome.writtenEntries
                    )
                )
                ExtractionOutcome.Cancelled -> sendResult(ArchiveForegroundResult(token, KIND_EXTRACT, "CANCELLED"))
                is ExtractionOutcome.RecoveryAvailable -> sendResult(
                    ArchiveForegroundResult(
                        token,
                        KIND_EXTRACT,
                        "RECOVERY",
                        outcome.message,
                        recoveryId = outcome.recoveryId
                    )
                )
                    is ExtractionOutcome.Failed -> sendResult(
                        ArchiveForegroundResult(token, KIND_EXTRACT, "FAILED", outcome.message)
                    )
                }
            } catch (error: CancellationException) {
                coordinator.discard(review)
                throw error
            }
        }

        private suspend fun runCreation(token: String, request: ArchiveCreationRequest) {
            val coordinator = ArchiveCreationCoordinator(applicationContext)
            val review = coordinator.plan(request)
            val jobId = coordinator.start(review)
            cancelActive = { runCatching { coordinator.cancel(jobId) } }
            val outcome = coordinator.awaitCompletion(review, jobId) { progress ->
                updateNotification("Creating archive")
            }
            when (outcome) {
                is ArchiveCreationOutcome.Completed -> sendResult(
                    ArchiveForegroundResult(
                        token,
                        KIND_CREATE,
                        "COMPLETED",
                        outputPath = outcome.outputPath,
                        outputPaths = outcome.outputPaths,
                        verified = outcome.verified
                    )
                )
                ArchiveCreationOutcome.Cancelled -> sendResult(ArchiveForegroundResult(token, KIND_CREATE, "CANCELLED"))
                is ArchiveCreationOutcome.Failed -> sendResult(
                    ArchiveForegroundResult(token, KIND_CREATE, "FAILED", outcome.message)
                )
            }
        }

        private suspend fun runCreationSeparately(token: String, requests: List<ArchiveCreationRequest>) {
            val coordinator = ArchiveCreationCoordinator(applicationContext)
            val completedOutputs = mutableListOf<String>()
            var verified = true
            try {
                requests.forEachIndexed { index, request ->
                    val review = coordinator.plan(request)
                    val jobId = coordinator.start(review)
                    cancelActive = { runCatching { coordinator.cancel(jobId) } }
                    val outcome = coordinator.awaitCompletion(review, jobId) {
                        updateNotification("Creating archive ${index + 1} of ${requests.size}")
                    }
                    when (outcome) {
                        is ArchiveCreationOutcome.Completed -> {
                            completedOutputs += outcome.outputPaths
                            verified = verified && outcome.verified
                        }
                        ArchiveCreationOutcome.Cancelled -> {
                            sendResult(
                                ArchiveForegroundResult(
                                    token,
                                    KIND_CREATE_SEPARATELY,
                                    "CANCELLED",
                                    "Separate archive creation cancelled after ${completedOutputs.size} output file(s).",
                                    outputPath = completedOutputs.firstOrNull(),
                                    outputPaths = completedOutputs,
                                    verified = completedOutputs.takeIf { it.isNotEmpty() }?.let { verified }
                                )
                            )
                            return
                        }
                        is ArchiveCreationOutcome.Failed -> {
                            sendResult(
                                ArchiveForegroundResult(
                                    token,
                                    KIND_CREATE_SEPARATELY,
                                    "FAILED",
                                    outcome.message,
                                    outputPath = completedOutputs.firstOrNull(),
                                    outputPaths = completedOutputs,
                                    verified = completedOutputs.takeIf { it.isNotEmpty() }?.let { verified }
                                )
                            )
                            return
                        }
                    }
                }
                sendResult(
                    ArchiveForegroundResult(
                        token,
                        KIND_CREATE_SEPARATELY,
                        "COMPLETED",
                        outputPath = completedOutputs.firstOrNull(),
                        outputPaths = completedOutputs,
                        verified = verified
                    )
                )
            } finally {
                cancelActive = null
            }
        }

        private suspend fun runBatchExtraction(token: String, request: ArchiveBatchExtractionRequest) {
            val coordinator = BatchExtractionCoordinator(ArchiveExtractionCoordinator(applicationContext))
            val review = coordinator.plan(request.items)
            cancelActive = { coordinator.cancel() }
            val outcome = coordinator.run(review) { archive, _ ->
                updateNotification("Extracting ${archive.displayName}")
            }
            when (outcome) {
                is BatchExtractionOutcome.Completed -> {
                    val completed = outcome.results.count { it.status == BatchExtractionItemResult.Status.COMPLETED }
                    val failed = outcome.results.count { it.status == BatchExtractionItemResult.Status.FAILED }
                    sendResult(
                        ArchiveForegroundResult(
                            token,
                            KIND_BATCH_EXTRACT,
                            "COMPLETED",
                            "Batch extraction complete: $completed completed, $failed failed."
                        )
                    )
                }
                is BatchExtractionOutcome.Cancelled -> sendResult(
                    ArchiveForegroundResult(token, KIND_BATCH_EXTRACT, "CANCELLED", "Batch extraction cancelled.")
                )
            }
            coordinator.discard(review)
        }

        private fun sendResult(result: ArchiveForegroundResult) {
            persistResult(applicationContext, result)
            sendBroadcast(resultIntent(result))
        }

        private fun createChannel() {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                getSystemService(NotificationManager::class.java).createNotificationChannel(
                    NotificationChannel(CHANNEL_ID, "Archive jobs", NotificationManager.IMPORTANCE_LOW)
                )
            }
        }

        private fun notification(message: String): Notification {
            val cancelIntent = Intent(this, Service::class.java).setAction(ACTION_CANCEL)
            return NotificationCompat.Builder(this, CHANNEL_ID)
                .setSmallIcon(android.R.drawable.stat_sys_download)
                .setContentTitle("ZManager archive job")
                .setContentText(message)
                .setOngoing(true)
                .setCategory(NotificationCompat.CATEGORY_PROGRESS)
                .addAction(
                    android.R.drawable.ic_menu_close_clear_cancel,
                    "Cancel",
                    PendingIntent.getService(this, 1, cancelIntent, PendingIntent.FLAG_UPDATE_CURRENT or immutableFlag())
                )
                .build()
        }

        private fun updateNotification(message: String) {
            getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, notification(message))
        }

        private fun immutableFlag(): Int =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0

        override fun onDestroy() {
            activeToken?.let { token ->
                cancelActive?.invoke()
                sendResult(ArchiveForegroundResult(token, activeKind ?: "unknown", "CANCELLED"))
                clearActiveMarker(applicationContext)
                activeToken = null
                activeKind = null
            }
            serviceScope.cancel()
            serviceAlive = false
            super.onDestroy()
        }

        override fun onTaskRemoved(rootIntent: Intent?) {
            // Swiping the task away is an explicit interruption boundary for
            // user-started archive work. The Rust coordinator receives cancel;
            // if the process is killed before it can report, the marker is
            // converted into INTERRUPTED on the next service start.
            cancelActive?.invoke()
            super.onTaskRemoved(rootIntent)
        }

        override fun onBind(intent: Intent?): IBinder? = null
    }

    private fun kindOf(request: ArchiveForegroundRequest): String = when (request) {
        is ArchiveForegroundRequest.Extract -> KIND_EXTRACT
        is ArchiveForegroundRequest.Create -> KIND_CREATE
        is ArchiveForegroundRequest.CreateSeparately -> KIND_CREATE_SEPARATELY
        is ArchiveForegroundRequest.BatchExtract -> KIND_BATCH_EXTRACT
    }

    private fun Throwable.userMessage(): String = when (this) {
        is ZmanagerGuiException.Bridge -> userMessage
        else -> message ?: "Archive job failed."
    }
}
