package org.tzap.zmanager.mobile

import java.io.File
import java.util.UUID

data class ArchiveSession(
    val id: String,
    val archive: ImportedArchive,
    val parentEntryPath: String? = null,
    val cleanupRoot: String? = null
)

/** Owns nested archive lifetime and removes materialized files when a session is left. */
class ArchiveSessionStack {
    private val sessions = ArrayDeque<ArchiveSession>()

    val current: ArchiveSession?
        get() = sessions.lastOrNull()

    val breadcrumbs: List<ArchiveSession>
        get() = sessions.toList()

    fun push(archive: ImportedArchive, parentEntryPath: String? = null, cleanupRoot: String? = null): ArchiveSession {
        val session = ArchiveSession(
            id = UUID.randomUUID().toString(),
            archive = archive,
            parentEntryPath = parentEntryPath,
            cleanupRoot = cleanupRoot
        )
        sessions.addLast(session)
        return session
    }

    fun pop(): ArchiveSession? {
        val removed = sessions.removeLastOrNull() ?: return null
        removed.cleanupRoot?.let { File(it).deleteRecursively() }
        return removed
    }

    fun popTo(sessionId: String): Boolean {
        if (sessions.none { it.id == sessionId }) return false
        while (sessions.lastOrNull()?.id != sessionId) pop()
        return true
    }

    fun clear() {
        while (sessions.isNotEmpty()) pop()
    }
}

object NestedArchiveSupport {
    // Nested-archive browsing is a UI capability over registry-listable
    // formats. The set is pinned by FormatRegistryConformanceTest against the
    // zmanager format contract snapshot. XIP is intentionally absent: the FFI
    // reports canList=false for it, so nesting into an .xip always fails.
    internal val archiveExtensions = setOf(
        "zip", "7z", "rar", "tar", "gz", "tgz", "bz2", "tbz2", "xz", "txz",
        "zst", "tzst", "lzma", "tlzma", "lz", "lzo", "z", "lz4", "uu", "b64",
        "cpio", "cpgz", "xar", "pkg", "iso", "dmg", "msi", "vhd", "vmdk", "udf",
        "tzap", "aar", "cab", "deb", "jar", "apk", "ipa"
    )

    fun canOpen(entry: ArchiveEntrySummary): Boolean {
        if (entry.kind != org.tzap.zmanager.mobile.bridge.generated.ArchiveEntryKind.FILE) return false
        val name = entry.displayName.lowercase()
        if (name.endsWith(".001") || name.contains(".part") || name.matches(Regex(".*\\.z\\d{2}$"))) {
            return false
        }
        return archiveExtensions.any { extension ->
            name.endsWith(".$extension")
        }
    }
}
