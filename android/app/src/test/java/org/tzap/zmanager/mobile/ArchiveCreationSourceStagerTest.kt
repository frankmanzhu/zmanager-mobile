package org.tzap.zmanager.mobile

import android.net.Uri
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment

@RunWith(RobolectricTestRunner::class)
class ArchiveCreationSourceStagerTest {
    @Test
    fun stagedFilesAreCopiedIntoPrivateCacheAndCanBeRemoved() {
        val context = RuntimeEnvironment.getApplication()
        val source = File(context.cacheDir, "source-${System.nanoTime()}.txt")
        source.writeText("archive input")
        val staged = ArchiveCreationSourceStager(context).stageFiles(listOf(Uri.fromFile(source)))

        assertEquals("archive input", File(staged.sourcePaths.single()).readText())
        assertTrue(staged.root.path.startsWith(context.cacheDir.path))

        ArchiveCreationSourceStager(context).discard(staged)
        assertTrue(!staged.root.exists())
        source.delete()
    }
}
