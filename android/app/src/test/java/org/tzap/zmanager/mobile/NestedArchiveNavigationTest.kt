package org.tzap.zmanager.mobile

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.tzap.zmanager.mobile.bridge.generated.ArchiveEntryKind

@RunWith(RobolectricTestRunner::class)
class NestedArchiveNavigationTest {
    @Test
    fun nestedArchiveSupportOnlyOffersRegularArchiveFiles() {
        assertTrue(NestedArchiveSupport.canOpen(entry("nested.zip", ArchiveEntryKind.FILE)))
        assertTrue(NestedArchiveSupport.canOpen(entry("nested.tzap", ArchiveEntryKind.FILE)))
        assertFalse(NestedArchiveSupport.canOpen(entry("folder.zip", ArchiveEntryKind.DIRECTORY)))
        assertFalse(NestedArchiveSupport.canOpen(entry("notes.txt", ArchiveEntryKind.FILE)))
    }

    @Test
    fun poppingNestedSessionCleansItsMaterializedRoot() {
        val cleanupRoot = createTempDirectory()
        val stack = ArchiveSessionStack()
        stack.push(
            ImportedArchive("outer", "outer.zip", "/cache/outer.zip", null, null, 0L),
            cleanupRoot = cleanupRoot.path
        )

        stack.pop()

        assertFalse(cleanupRoot.exists())
    }

    @Test
    fun popToKeepsRequestedParentAndCleansChildren() {
        val parentCleanup = createTempDirectory()
        val childCleanup = createTempDirectory()
        val stack = ArchiveSessionStack()
        val parent = stack.push(
            ImportedArchive("parent", "outer.zip", "/cache/outer.zip", null, null, 0L),
            cleanupRoot = parentCleanup.path
        )
        stack.push(
            ImportedArchive("child", "inner.zip", "/cache/inner.zip", null, null, 0L),
            cleanupRoot = childCleanup.path
        )

        assertTrue(stack.popTo(parent.id))
        assertTrue(stack.current?.id == parent.id)
        assertFalse(childCleanup.exists())
        assertTrue(parentCleanup.exists())

        stack.clear()
        assertFalse(parentCleanup.exists())
    }

    private fun entry(name: String, kind: ArchiveEntryKind) = ArchiveEntrySummary(
        id = name,
        path = name,
        displayName = name,
        parentPath = "",
        kind = kind,
        size = null
    )

    private fun createTempDirectory(): File = createTempDir("nested-archive-test")
}
