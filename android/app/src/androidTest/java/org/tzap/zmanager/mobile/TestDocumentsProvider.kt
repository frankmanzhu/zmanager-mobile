package org.tzap.zmanager.mobile

import android.database.Cursor
import android.database.MatrixCursor
import android.os.CancellationSignal
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import android.provider.DocumentsContract.Root
import android.provider.DocumentsProvider
import java.io.File
import java.io.FileNotFoundException

/**
 * A small provider-backed filesystem used only by instrumentation tests. It
 * exercises ContentResolver and DocumentFile without relying on a device's
 * installed cloud/storage providers.
 */
class TestDocumentsProvider : DocumentsProvider() {
    companion object {
        const val AUTHORITY = "org.tzap.zmanager.mobile.test.documents"
        const val ROOT_ID = "root"
        private const val ROOT_DIRECTORY = "documents-provider-root"
        private val DEFAULT_DOCUMENT_PROJECTION = arrayOf(
            Document.COLUMN_DOCUMENT_ID,
            Document.COLUMN_DISPLAY_NAME,
            Document.COLUMN_MIME_TYPE,
            Document.COLUMN_SIZE,
            Document.COLUMN_FLAGS
        )

        fun documentUri(documentId: String) =
            DocumentsContract.buildDocumentUri(AUTHORITY, documentId)

        fun treeUri(documentId: String = ROOT_ID) =
            DocumentsContract.buildTreeDocumentUri(AUTHORITY, documentId)
    }

    private lateinit var root: File

    override fun onCreate(): Boolean {
        root = File(requireNotNull(context).filesDir, ROOT_DIRECTORY)
        return root.mkdirs() || root.isDirectory
    }

    override fun queryRoots(projection: Array<String>?): Cursor {
        val columns = projection ?: arrayOf(
            Root.COLUMN_ROOT_ID,
            Root.COLUMN_DOCUMENT_ID,
            Root.COLUMN_TITLE,
            Root.COLUMN_FLAGS,
            Root.COLUMN_MIME_TYPES
        )
        return MatrixCursor(columns).apply {
            addRow(columns.map { column ->
                when (column) {
                    Root.COLUMN_ROOT_ID -> ROOT_ID
                    Root.COLUMN_DOCUMENT_ID -> ROOT_ID
                    Root.COLUMN_TITLE -> "Test documents"
                    Root.COLUMN_FLAGS -> Root.FLAG_SUPPORTS_CREATE
                    Root.COLUMN_MIME_TYPES -> "*/*"
                    else -> null
                }
            }.toTypedArray())
        }
    }

    override fun queryDocument(documentId: String, projection: Array<String>?): Cursor =
        documentCursor(resolve(documentId), projection)

    override fun queryChildDocuments(
        parentDocumentId: String,
        projection: Array<String>?,
        sortOrder: String?
    ): Cursor {
        val directory = resolve(parentDocumentId)
        if (!directory.isDirectory) throw FileNotFoundException("Not a directory")
        val columns = projection ?: DEFAULT_DOCUMENT_PROJECTION
        return MatrixCursor(columns).apply {
            directory.listFiles()?.sortedBy(File::getName).orEmpty().forEach { child ->
                addRow(documentRow(child, columns))
            }
        }
    }

    override fun openDocument(
        documentId: String,
        mode: String,
        signal: CancellationSignal?
    ): ParcelFileDescriptor {
        val file = resolve(documentId)
        file.parentFile?.mkdirs()
        if (!file.exists() && !file.createNewFile()) {
            throw FileNotFoundException("Unable to create document")
        }
        val flags = when {
            mode.contains('w') && mode.contains('t') ->
                ParcelFileDescriptor.MODE_WRITE_ONLY or
                    ParcelFileDescriptor.MODE_CREATE or
                    ParcelFileDescriptor.MODE_TRUNCATE
            mode.contains('w') ->
                ParcelFileDescriptor.MODE_WRITE_ONLY or ParcelFileDescriptor.MODE_CREATE
            mode.contains('a') ->
                ParcelFileDescriptor.MODE_WRITE_ONLY or
                    ParcelFileDescriptor.MODE_CREATE or
                    ParcelFileDescriptor.MODE_APPEND
            else -> ParcelFileDescriptor.MODE_READ_ONLY
        }
        return ParcelFileDescriptor.open(file, flags)
    }

    override fun createDocument(parentDocumentId: String, mimeType: String, displayName: String): String {
        val parent = resolve(parentDocumentId)
        if (!parent.isDirectory) throw FileNotFoundException("Not a directory")
        val safeName = displayName.replace('/', '_').replace('\\', '_')
        val child = File(parent, safeName)
        if (mimeType == Document.MIME_TYPE_DIR) {
            check(child.mkdirs() || child.isDirectory) { "Unable to create directory" }
        } else {
            child.parentFile?.mkdirs()
            check(child.createNewFile()) { "Document already exists" }
        }
        return documentId(child)
    }

    override fun deleteDocument(documentId: String) {
        val file = resolve(documentId)
        check(file != root) { "Cannot delete provider root" }
        check(file.deleteRecursively()) { "Unable to delete document" }
    }

    override fun getDocumentType(documentId: String): String =
        if (resolve(documentId).isDirectory) Document.MIME_TYPE_DIR else "application/octet-stream"

    private fun resolve(documentId: String): File {
        if (documentId == ROOT_ID) return root
        require(documentId.startsWith("$ROOT_ID/")) { "Unknown document" }
        val relative = documentId.removePrefix("$ROOT_ID/")
        val candidate = File(root, relative).canonicalFile
        require(candidate.path.startsWith(root.canonicalPath + File.separator)) { "Unsafe document path" }
        return candidate
    }

    private fun documentId(file: File): String {
        val relative = file.canonicalFile.relativeTo(root.canonicalFile).invariantSeparatorsPath
        return "$ROOT_ID/$relative"
    }

    private fun documentCursor(file: File, projection: Array<String>?): Cursor {
        val columns = projection ?: DEFAULT_DOCUMENT_PROJECTION
        return MatrixCursor(columns).apply { addRow(documentRow(file, columns)) }
    }

    private fun documentRow(file: File, columns: Array<String>): Array<Any?> =
        columns.map { column ->
            when (column) {
                Document.COLUMN_DOCUMENT_ID -> if (file == root) ROOT_ID else documentId(file)
                Document.COLUMN_DISPLAY_NAME -> if (file == root) "Test documents" else file.name
                Document.COLUMN_MIME_TYPE -> if (file.isDirectory) Document.MIME_TYPE_DIR else "application/octet-stream"
                Document.COLUMN_SIZE -> if (file.isFile) file.length() else 0L
                Document.COLUMN_FLAGS -> Document.FLAG_SUPPORTS_WRITE or
                    Document.FLAG_SUPPORTS_DELETE
                else -> null
            }
        }.toTypedArray()

}
