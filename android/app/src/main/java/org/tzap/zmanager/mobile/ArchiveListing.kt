package org.tzap.zmanager.mobile

import org.tzap.zmanager.mobile.bridge.generated.ArchiveEntry
import org.tzap.zmanager.mobile.bridge.generated.ArchiveEntryKind
import org.tzap.zmanager.mobile.bridge.generated.DetectArchiveRequest
import org.tzap.zmanager.mobile.bridge.generated.DetectArchiveResult
import org.tzap.zmanager.mobile.bridge.generated.ListArchiveRequest
import org.tzap.zmanager.mobile.bridge.generated.ListArchiveResult
import org.tzap.zmanager.mobile.bridge.generated.ZmanagerMobileException
import org.tzap.zmanager.mobile.bridge.generated.detectArchive as bridgeDetectArchive
import org.tzap.zmanager.mobile.bridge.generated.listArchive as bridgeListArchive

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
    val path: String,
    val kind: ArchiveEntryKind,
    val size: ULong?
)

data class ArchiveListingError(
    val code: String,
    val message: String,
    val recoveryHint: String?,
    val retryable: Boolean
)

interface ArchiveBridgeGateway {
    fun detectArchive(path: String): DetectArchiveResult
    fun listArchive(path: String, password: String?): ListArchiveResult
}

class GeneratedArchiveBridgeGateway : ArchiveBridgeGateway {
    override fun detectArchive(path: String): DetectArchiveResult {
        return bridgeDetectArchive(DetectArchiveRequest(archivePath = path))
    }

    override fun listArchive(path: String, password: String?): ListArchiveResult {
        return bridgeListArchive(ListArchiveRequest(archivePath = path, password = password))
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

    private fun ListArchiveResult.toSummary(): ArchiveListingSummary {
        return ArchiveListingSummary(
            formatLabel = formatLabel,
            entryCount = entryCount,
            totalSize = totalSize,
            entries = entries.take(50).map { it.toSummary() },
            warnings = warnings.map { it.message }
        )
    }

    private fun ArchiveEntry.toSummary(): ArchiveEntrySummary {
        return ArchiveEntrySummary(
            path = path,
            kind = kind,
            size = size
        )
    }

    private fun ZmanagerMobileException.Bridge.toListingState(): ArchiveListingState {
        val error = ArchiveListingError(
            code = code,
            message = userMessage,
            recoveryHint = recoveryHint,
            retryable = retryable
        )

        return if (code == ERROR_PASSWORD_REQUIRED || code == ERROR_INVALID_PASSWORD) {
            ArchiveListingState.PasswordRequired(error)
        } else {
            ArchiveListingState.Failed(error)
        }
    }
}
