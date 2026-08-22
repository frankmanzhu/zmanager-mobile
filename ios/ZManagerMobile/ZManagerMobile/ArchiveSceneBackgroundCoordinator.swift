import Foundation

/// Fans out scene-background cleanup (password scrubbing, job cancellation,
/// LocalSend teardown) to each model's own scoped handling, rather than one
/// model reaching into the others. Kept as a free function rather than a
/// private `ContentView` method so it stays directly unit-testable without a
/// SwiftUI host — see `testSceneBackgroundClearsTransientPasswords` and
/// neighboring tests in ZManagerMobileTests.swift. Mirrors Android's
/// handleAppBackground coordinator. See Track 7 in
/// docs/mobile-code-health-remediation-plan.md.
@MainActor
enum ArchiveSceneBackgroundCoordinator {
    static func handle(
        session: ArchiveSessionModel,
        listing: ArchiveListingModel,
        extraction: ArchiveExtractionModel,
        creation: ArchiveCreationModel,
        repackaging: ArchiveRepackagingModel,
        batchExtraction: ArchiveBatchExtractionModel,
        localSend: ArchiveLocalSendModel
    ) {
        session.clearSessionSecrets()
        listing.clearTransientSecrets()
        extraction.clearTransientSecrets()
        creation.clearTransientSecrets()
        repackaging.clearTransientSecrets()
        localSend.handleSceneBackground()
        extraction.handleSceneBackground()
        creation.handleSceneBackground()
        repackaging.handleSceneBackground()
        batchExtraction.handleSceneBackground()
    }
}
