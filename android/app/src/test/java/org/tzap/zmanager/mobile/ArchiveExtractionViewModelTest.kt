package org.tzap.zmanager.mobile

import org.junit.Assert.assertSame
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment

@RunWith(RobolectricTestRunner::class)
class ArchiveExtractionViewModelTest {

    // Regression test for a real bug found during a critical review of
    // Track 5 (docs/mobile-code-health-remediation-plan.md): a debug-only
    // pacer set ahead of a planned review survived abandoning that review
    // without starting it, leaking into the next, unrelated extraction.
    @Test
    fun clearExtractionStateResetsAStaleDebugPacer() {
        val context = RuntimeEnvironment.getApplication()
        val session = ArchiveSessionViewModel(context as android.app.Application)
        val extraction = ArchiveExtractionViewModel(context, session)
        session.debugJobPacer = DelayingJobPacer(delayMillis = 15_000L)

        extraction.clearExtractionState()

        assertSame(NoOpJobPacer, session.debugJobPacer)
    }

    // Regression coverage for a gap found during a critical review of Track
    // 7 (docs/mobile-code-health-remediation-plan.md): nothing exercised the
    // app-background password fan-out on Android, unlike iOS's
    // testSceneBackgroundClearsTransientPasswords. clearAllTransientSecrets
    // was extracted out of MainActivity.handleAppBackground specifically so
    // this invariant is independently testable without a Compose host.
    @Test
    fun clearAllTransientSecretsClearsEveryPasswordFieldAcrossViewModels() {
        val context = RuntimeEnvironment.getApplication() as android.app.Application
        val session = ArchiveSessionViewModel(context)
        val listing = ArchiveListingViewModel(session)
        val extraction = ArchiveExtractionViewModel(context, session)
        val creation = ArchiveCreationViewModel(context)
        val repackaging = ArchiveRepackagingViewModel(context, session, extraction, creation)

        session.passwordInput = "archive-password"
        listing.previewPasswordInput = "preview-password"
        listing.testPasswordInput = "test-password"
        extraction.extractionPasswordInput = "extract-password"
        creation.createPasswordInput = "create-password"
        repackaging.repackagingPasswordInput = "repackage-password"

        clearAllTransientSecrets(session, listing, extraction, creation, repackaging)

        org.junit.Assert.assertEquals("", session.passwordInput)
        org.junit.Assert.assertEquals("", listing.previewPasswordInput)
        org.junit.Assert.assertEquals("", listing.testPasswordInput)
        org.junit.Assert.assertEquals("", extraction.extractionPasswordInput)
        org.junit.Assert.assertEquals("", creation.createPasswordInput)
        org.junit.Assert.assertEquals("", repackaging.repackagingPasswordInput)
    }

    // Regression test for a bug fixed during Track 7 (docs/mobile-code-health-remediation-plan.md):
    // retryRecovery's first draft called discardRecovery(record.id) {} with
    // an empty lambda, silently dropping the caller's
    // onExtractionRecoveryDiscarded side effect. Not caught by the compiler
    // (both versions type-check); needs an assertion on the callback firing.
    @Test
    fun retryRecoveryThreadsTheDiscardCallbackThrough() {
        val context = RuntimeEnvironment.getApplication()
        val session = ArchiveSessionViewModel(context as android.app.Application)
        val entry = ArchiveEntrySummary(
            id = "1",
            path = "readme.txt",
            displayName = "readme.txt",
            parentPath = "",
            kind = org.tzap.zmanager.mobile.bridge.generated.ArchiveEntryKind.FILE,
            size = 12UL
        )
        val archive = ImportedArchive("archive", "archive.zip", "/cache/archive.zip", 1L, "application/zip", 0L)
        session.importedArchive = archive
        session.listingState = ArchiveListingState.Ready(
            ArchiveListingSummary(
                formatLabel = "ZIP",
                entryCount = 1UL,
                totalSize = null,
                entries = listOf(entry),
                warnings = emptyList()
            )
        )
        val stagingRoot = java.io.File(context.cacheDir, "recovery-test-${System.nanoTime()}").apply { mkdirs() }
        val record = session.recoveryStore.save(
            archive = archive,
            selectedPaths = emptyList(),
            stagingRoot = stagingRoot,
            destinationLabel = "Selected folder",
            message = "Provider failed"
        )

        var discardedId: String? = null
        var plannedArchive: ImportedArchive? = null
        session.retryRecovery(
            record,
            onExtractionRecoveryDiscarded = { id -> discardedId = id },
            onPlanExtraction = { planArchive, _, _, _ -> plannedArchive = planArchive }
        )

        org.junit.Assert.assertEquals(record.id, discardedId)
        org.junit.Assert.assertEquals(archive, plannedArchive)
    }
}
