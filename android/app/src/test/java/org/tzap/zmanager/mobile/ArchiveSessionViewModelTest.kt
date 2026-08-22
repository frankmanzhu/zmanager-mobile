package org.tzap.zmanager.mobile

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment

@RunWith(RobolectricTestRunner::class)
class ArchiveSessionViewModelTest {

    @Test
    fun extractionSelectedPathsReturnsEmptyListOnlyAfterSelectEverything() {
        val session = ArchiveSessionViewModel(RuntimeEnvironment.getApplication())
        val entries = listOf(
            testEntry(id = "1", path = "a.txt"),
            testEntry(id = "2", path = "b.txt")
        )
        val summary = ArchiveListingSummary(
            formatLabel = "ZIP",
            entryCount = 2UL,
            totalSize = null,
            entries = entries,
            warnings = emptyList()
        )

        session.selectEverything(summary)

        assertEquals(emptyList<String>(), session.extractionSelectedPaths(entries))
    }

    @Test
    fun extractionSelectedPathsReturnsTheSubsetWhenNotEverythingIsSelected() {
        val session = ArchiveSessionViewModel(RuntimeEnvironment.getApplication())
        val entries = listOf(testEntry(id = "1", path = "a.txt"))

        session.selectEntries(entries)

        assertEquals(listOf("a.txt"), session.extractionSelectedPaths(entries))
    }

    @Test
    fun togglingAnEntryClearsTheSelectEverythingFlag() {
        val session = ArchiveSessionViewModel(RuntimeEnvironment.getApplication())
        val entries = listOf(
            testEntry(id = "1", path = "a.txt"),
            testEntry(id = "2", path = "b.txt")
        )
        val summary = ArchiveListingSummary(
            formatLabel = "ZIP",
            entryCount = 2UL,
            totalSize = null,
            entries = entries,
            warnings = emptyList()
        )
        session.selectEverything(summary)

        session.toggleEntrySelected(entries[0])

        assertFalse(session.selectedEverything)
        val stillSelected = entries.filter { session.selectedEntryIds.contains(it.id) }
        assertEquals(listOf("b.txt"), session.extractionSelectedPaths(stillSelected))
    }

    @Test
    fun clearSelectionResetsTheSelectEverythingFlag() {
        val session = ArchiveSessionViewModel(RuntimeEnvironment.getApplication())
        val entries = listOf(testEntry(id = "1", path = "a.txt"))
        val summary = ArchiveListingSummary(
            formatLabel = "ZIP",
            entryCount = 1UL,
            totalSize = null,
            entries = entries,
            warnings = emptyList()
        )
        session.selectEverything(summary)

        session.clearSelection()

        assertFalse(session.selectedEverything)
        assertEquals(emptySet<String>(), session.selectedEntryIds)
    }

    private fun testEntry(id: String, path: String): ArchiveEntrySummary {
        val displayName = path.substringAfterLast('/')
        val parentPath = path.substringBeforeLast('/', missingDelimiterValue = "")
        return ArchiveEntrySummary(
            id = id,
            path = path,
            displayName = displayName,
            parentPath = parentPath,
            kind = org.tzap.zmanager.mobile.bridge.generated.ArchiveEntryKind.FILE,
            size = 12UL
        )
    }
}
