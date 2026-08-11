# Mobile Extraction UI and E2E Plan

Status: proposed

This plan covers the missing extraction-plan review, destination selection, staged extraction, native destination commit, progress, cancellation, and completion UI on Android and iOS. It also defines full archive-extraction UI E2E coverage.

The current app already has generated UniFFI types and functions for `plan_extract`, `start_extract`, `poll_job_events`, and `cancel_job`, but the native app only implements listing, preview, and test. The work below should be built on those generated bindings; do not hand-edit generated files or move archive behavior into Kotlin or Swift.

## Current gap

- Android `ArchiveBridgeGateway` has no extraction methods, and `MainActivity` has no Extract action or extraction state.
- iOS `ArchiveBridgeClient` has no extraction methods, and `ContentView` / `ArchiveImportModel` has no extraction state.
- Neither platform has a native destination abstraction, SAF/security-scoped destination handling, staged-output commit coordinator, or recovery record.
- Existing Maestro archive workflows verify listing and archive testing only. They intentionally do not claim full extraction coverage.
- The bridge contract already provides `ExtractionPlan`, `ExtractionPlanEntry`, collision policies, job events, terminal summaries, and job polling. Confirm the sibling `zmanager` bridge implementation and regenerate bindings only if that contract changes.

## Target user flow

1. From the archive detail screen, the user chooses `Extract`.
2. The app defaults to all entries, or uses the current selection for selected extraction. Directories selected in the listing must resolve to their descendants through the bridge request; native code must not expand archive paths itself.
3. The native shell presents a destination choice before planning. The destination is represented by a native-owned token/handle and an app-controlled staging path, never by passing a raw `content://` URI or security-scoped URL to Rust.
4. The app calls `plan_extract` with the archive path, selected paths, password if freshly entered, strip-components setting, and collision policy.
5. The app presents a review screen with destination, output root, counts, estimated bytes, collisions, warnings, rewrites, unsupported entries, blocked entries, and the reason extraction cannot start when `canStart == false`.
6. The user changes collision policy or destination, replans, or cancels. No final destination output is written before an explicitly accepted plan.
7. On approval, the app calls `start_extract`, polls `poll_job_events` using the returned cursor, and renders progress and cancellation state.
8. Rust writes to app-controlled staging for platform-owned destinations. The native commit coordinator copies/moves staged files into the selected destination while the native permission lifetime is active.
9. The app reports success only after commit succeeds. It then removes staging, or presents retry/export/discard recovery actions when commit is partial or fails.

## Shared state model

Use an explicit state machine on both platforms so UI and E2E selectors remain stable:

```text
Idle
  -> ChoosingDestination
  -> Planning
  -> PlanReview
       -> ChoosingDestination (change destination)
       -> Planning (change policy / retry)
       -> Starting
       -> Cancelled
Starting -> Running -> CommitPending -> Committing -> Completed
Running -> CancellationRequested -> Cancelled
Planning -> PasswordRequired -> Planning
Starting/Running/Committing -> Failed
Committing -> PartialSuccess / RecoveryAvailable
```

The state must retain only non-sensitive operation data: archive display name, destination display name, plan/job id, counts, warnings, and redacted error information. Passwords remain transient, are cleared after each bridge call, and never enter state restoration, logs, screenshots, or diagnostics.

### Shared UI states and stable semantics

Plan review must expose stable accessibility/test labels for:

- `Extraction plan`
- `Destination`
- `Output root`
- `Estimated size`
- `N writable`, `N skipped`, and `N blocked`
- `Warnings` / `Blocked entries`
- collision policy: `Refuse`, `Replace`, `Keep both`
- `Choose destination`, `Review extraction`, `Extract`, and `Cancel`

Progress must expose:

- `Extracting archive`
- current entry when available
- completed/total entries
- bytes written/estimated bytes when available
- `Cancel extraction`

Completion must expose:

- `Extraction complete`, `Extraction cancelled`, `Extraction failed`, or `Extraction partially complete`
- extracted, skipped, failed, and warning counts
- committed destination
- `Open destination`, `Share`, `Retry commit`, `Export`, and `Discard` where applicable

## Android implementation

### Native layers

Add an extraction feature module or keep the first vertical slice beside the current listing code:

- `android/app/src/main/java/org/tzap/zmanager/mobile/ArchiveExtraction.kt`
  - bridge DTO mapping and `ArchiveExtractionRepository`
  - `ExtractionPlanState`, `ExtractionJobState`, `ExtractionCompletion`
  - cursor-safe polling and terminal-summary handling
  - password-required and normalized error mapping
- `android/app/src/main/java/org/tzap/zmanager/mobile/ArchiveDestination.kt`
  - destination model: app storage and SAF tree
  - `ACTION_OPEN_DOCUMENT_TREE` launcher result handling
  - persistable URI permission acquisition/release
  - destination display name and provider failure normalization
- `android/app/src/main/java/org/tzap/zmanager/mobile/ArchiveCommitCoordinator.kt`
  - staged-file enumeration and safe relative-path handling
  - `ContentResolver` / `DocumentFile` commit into the selected tree
  - collision policy enforcement only where the provider supports it
  - partial-commit record, retry, export, discard, and cleanup
- `android/app/src/main/java/org/tzap/zmanager/mobile/MainActivity.kt`
  - wire destination picker and extraction state into the Compose screen
  - use a foreground service for long user-started jobs once the foreground-service lifecycle is covered
  - clear sensitive state on background timeout and terminal operation

Do not allow the commit coordinator to reinterpret archive paths. It consumes the bridge plan’s normalized destination paths and rejects any path that is not a safe relative path. The bridge remains the authority for archive path safety.

### Android UI

Add an `Extract` action to the ready archive panel. Use a separate full-height route/screen rather than expanding the current listing panel so back navigation, system picker return, and progress are deterministic.

Recommended screens:

- `ExtractionDestinationScreen`: app storage default plus `Choose folder`.
- `ExtractionPlanScreen`: plan summary, warning sections, collision policy, and disabled Extract button when blocked.
- `ExtractionProgressScreen`: progress, current item, cancel confirmation, and interruption state.
- `ExtractionCompletionScreen`: counts, destination, open/share/retry/export/discard actions.

The first deterministic E2E path should use an app-private test destination that still runs through the same destination coordinator. SAF folder selection and provider behavior get a second Android-specific flow.

### Android unit/instrumentation coverage

- Plan request uses all entries vs selected paths and the selected collision policy.
- Password is passed only to the immediate plan/start request and is cleared afterward.
- Cursor advances monotonically; duplicate polls do not duplicate UI events.
- Terminal summary is rendered even when the final event was already consumed.
- SAF permission grant, revocation, provider failure, low-storage failure, partial commit, retry, and discard are covered with instrumentation/fake `ContentResolver` tests.
- Commit never writes outside the plan’s normalized relative paths.
- Cancellation before commit removes staging; cancellation during commit produces recovery state.

## iOS implementation

### Native layers

Add extraction types and services in `ios/ZManagerMobile/ZManagerMobile/` (split into files rather than extending the already large `ContentView.swift`):

- `ArchiveExtraction.swift`
  - bridge client additions for plan/start/poll/cancel
  - `ExtractionPlanState`, `ExtractionJobState`, and completion models
  - cursor-safe polling and error mapping
- `ArchiveDestination.swift`
  - app Documents destination and user-selected folder destination
  - security-scoped access start/stop around native operations
  - provider capability and permission state
- `ArchiveCommitCoordinator.swift`
  - staged-file commit using coordinated native file operations
  - collision handling, partial-commit recovery, retry/export/discard, and cleanup
- `ContentView.swift` / `ArchiveImportModel`
  - route the archive detail action into destination selection, plan review, progress, and completion
  - clear transient password state on background, cancellation, wrong password, and terminal state

The iOS app should support app sandbox/Documents first for deterministic extraction. True Files folder extraction (`On My iPhone`, iCloud Drive, or an allowlisted provider) is enabled only after security-scoped access, coordinated writes, interruption, and recovery tests pass. Use share/export as the fallback for providers that cannot guarantee folder commit semantics.

### iOS UI

Use a `NavigationStack` route or a sheet with a dedicated navigation context. The destination picker must return a destination model, not a raw URL that leaks into Rust. The plan review and completion screens should use native list sections and VoiceOver labels matching the shared semantics above.

Recommended routes:

- `ExtractionDestinationView`
- `ExtractionPlanView`
- `ExtractionProgressView`
- `ExtractionCompletionView`

The deterministic E2E path uses the app Documents destination. A separate Files-provider flow validates true security-scoped destination commit on simulator/device configurations where the provider is available.

### iOS unit/UI coverage

- Plan/start requests carry selected paths and collision policy correctly.
- Security scope starts before commit and stops after commit, including errors and cancellation.
- Password input is not retained in `ObservableObject` restoration or completion state.
- Polling handles cursor gaps, duplicate events, terminal summaries, app suspension, and bridge errors.
- Staging cleanup and recovery record behavior is deterministic.
- Commit rejects unsafe relative paths and reports partial output accurately.

## Full archive-extraction UI E2E coverage

Use Maestro for cross-platform device flows because the repository already uses it for Android and iOS smoke/workflow tests. Keep bridge, commit, and lifecycle edge cases in native unit/instrumentation tests; Maestro should verify the complete user-visible path and the actual committed result.

### Test fixtures

Extend `fixtures/maestro/contents/` or add a dedicated deterministic extraction fixture set. The primary fixture should contain:

- a root text file
- nested Markdown and JSON files
- a nested directory
- an SVG or other visible file
- a known total of five entries, matching the existing `maestro-files.zip`

Add separate bounded fixtures for:

- an existing destination collision
- unsafe parent-traversal and absolute-path entries
- duplicate normalized paths
- encrypted ZIP with a non-secret test password stored in fixture metadata
- a larger archive that emits multiple progress events
- a fixture that causes a deterministic commit failure in a debug test destination

The archive fixture must never contain real secrets. The E2E output destination must be isolated per test run and cleaned by the app or test harness.

### Deterministic testability hooks

Add debug-only controls/configuration, excluded from release builds:

- `Load extraction fixture`
- `Use test destination` (Android app-private destination / iOS app Documents)
- deterministic collision and commit-failure modes
- an in-app `Inspect extracted files` result view, or an equivalent completion summary that lists committed relative paths

These hooks must invoke the production planning, staging, commit, polling, and cleanup services. They may only replace nondeterministic external providers and fixture setup.

### Required Maestro flows

Add matching Android and iOS workflows under `maestro/android/` and `maestro/ios/`.

#### 1. Full happy path: all entries

```text
launch with clear state
load extraction fixture
wait for archive listing
tap Extract
choose/use test destination
assert Extraction plan
assert destination and 5 selected/writable entries
assert no final files are visible before approval
tap Extract
wait for progress and terminal state
assert Extraction complete
assert extracted count is 5 and skipped/failed counts are 0
open/inspect destination
assert every expected relative path is present
assert staging/recovery is cleaned or reported as cleaned
```

#### 2. Selected extraction

Select one nested file and extract. Assert the plan contains one selected path, the completion count is one, and the destination does not contain unselected files.

#### 3. Plan warning/blocking

Load the hostile fixture, open the plan, and assert unsafe/blocked entries are visible. Assert `Extract` is disabled while blocking entries remain. Assert no destination file is created.

#### 4. Collision policy

Pre-seed the test destination with a known file, plan extraction, and exercise:

- `Refuse`: plan cannot start or requires explicit resolution.
- `Replace`: existing file is replaced and completion reports replacement.
- `Keep both` / bridge `RENAME`: both files exist with deterministic renamed output.

Use the exact policy names exposed by the generated bridge; do not invent a UI option the bridge cannot honor.

#### 5. Password-required extraction

Open the encrypted fixture, enter the non-secret fixture password, assert the password field is not present after submission, then assert plan review and extraction completion. Add a wrong-password retry flow and assert the password value is never rendered in error or completion UI.

#### 6. Cancellation before commit

Start the multi-event fixture, cancel during extraction, assert the terminal cancelled state, assert staging cleanup, and assert no incomplete final destination is presented as success.

#### 7. Commit failure and recovery

Use the deterministic failing destination, approve a valid plan, assert the extraction job completes or reaches commit pending, then assert a user-readable partial/recovery state with `Retry`, `Export`, and `Discard`. Assert `Discard` removes staging and the recovery record.

#### 8. Permission/provider failure

Android: revoke SAF permission before commit and assert the app asks for a new destination without claiming success. iOS: invalidate or deny the security-scoped destination and assert the same recovery behavior. These may be platform-tagged workflows if the simulator/provider cannot be controlled identically.

#### 9. Lifecycle interruption

Background the app during a foreground extraction job, return to the app, and assert either resumed polling with a correct terminal result or an explicit interrupted/recovery state. Never assert success solely from a pre-commit Rust terminal event.

#### 10. Accessibility and layout smoke

Run the happy path with TalkBack/VoiceOver enabled where the Maestro environment supports it. Assert the primary controls have meaningful labels and that plan warnings, progress, cancel, and completion actions remain reachable on small phone screens and iPad/tablet layouts.

### Suggested workflow names

- `maestro/android/extraction-workflow.yaml`
- `maestro/ios/extraction-workflow.yaml`
- `maestro/android/extraction-edge-cases.yaml`
- `maestro/ios/extraction-edge-cases.yaml`

Keep the happy path short and deterministic. Put password, collision, cancellation, provider, and lifecycle cases in edge-case workflows so a single failure identifies the affected contract.

## Acceptance criteria

Implementation is complete when:

- Both platforms expose the same plan-review → approve → progress → native commit → completion state model.
- No platform final destination is written before plan approval.
- Android SAF and iOS security-scoped commits hold permissions only for the native commit operation.
- Successful extraction is not shown until native commit succeeds.
- Blocked/unsafe entries, collisions, rewrites, unsupported entries, and estimated size are visible in plan review.
- Passwords are transient and absent from logs, state restoration, diagnostics, screenshots, and E2E assertions.
- Cancellation, provider failure, low storage, interruption, partial commit, retry, export, discard, and staging cleanup have deterministic states.
- The full happy-path Maestro flow passes on Android and iOS and verifies actual committed output.
- Selected extraction, password retry, collision handling, blocked plan, cancellation, recovery, and provider failure flows are covered on both platforms or explicitly marked platform-specific with an equivalent test.
- Android and iOS unit/instrumentation tests cover bridge mapping, polling cursor behavior, native permission lifetime, and commit safety.
- `docs/local-development.md`, the launch spec, and the implementation plan link to the completed coverage and no longer claim extraction E2E is absent.

## Delivery order

1. Confirm bridge DTO/event semantics against the sibling `zmanager` repository and add/repair bridge boundary tests.
2. Implement shared native models and bridge adapters, with fake gateways/clients for plan, job, and terminal states.
3. Implement app-private destination commit on Android and iOS.
4. Add plan review UI and wire it from archive detail.
5. Add job polling, progress, cancellation, completion, and cleanup/recovery UI.
6. Add Android SAF and iOS security-scoped destination coordinators.
7. Add deterministic fixture/test-destination hooks and the full happy-path Maestro flows.
8. Add edge-case Maestro flows plus provider/lifecycle instrumentation.
9. Run Android/iOS builds, native tests, Maestro flows, screenshot/accessibility QA, and update the release gates.

