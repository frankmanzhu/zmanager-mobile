# ZManager Mobile Launch Specification

Last reviewed: 2026-07-05

## Purpose

This specification turns the product direction in [mobile-product-design.md](mobile-product-design.md) into implementation requirements for the first serious ZManager Mobile release.

ZManager Mobile targets a v2-level launch bar from the start. The app should feel like a complete native archive workbench, not a thin mobile wrapper around ZManager-Core.

## Product Contract

ZManager Mobile is a native Android and iOS archive workbench backed by ZManager-Core.

The mobile apps must:

- provide polished native GUI flows for archive work
- use ZManager-Core for archive behavior
- keep platform file permissions and platform file-provider lifetimes native-owned
- keep passwords transient and redacted
- support safe planning before extraction
- provide reliable progress, cancellation, completion, and recovery states
- adopt Keka-level iOS workflow breadth in v2 while preserving ZManager's safety and privacy contract
- treat listed mobile format support as launch-blocking: listed formats must pass mobile quality gates and be exposed, not hidden as launch gaps

The mobile apps must not:

- reimplement archive parsing, extraction, creation, testing, or repair logic in Kotlin or Swift
- create RAR archives
- repair RAR archives
- promise generic repair for non-tzap archives
- include ads, telemetry, or third-party analytics
- persist or log passwords
- require network access for local archive operations

Feedback goes through GitHub issues. Distribution is open source, free, and Apache-2.0 licensed.

## V2 Adoption Scope

ZManager Mobile v2 adopts the full Keka-parity workflow set from the product design. Must/should/nice-later labels describe implementation order, not exclusion from v2.

V2 includes:

- open/import from app launchers, document pickers, Files, Android share/open intents, and iOS share/import
- archive browsing, search, sort, tree/list toggle, selected preview, selected extract, selected share/export, and legacy filename charset handling
- password-required, wrong-password, encrypted create, test/verify, verify-after-compression, split/multipart guidance, progress, cancellation, pause/resume where safe, and completion reports
- archive-items-separately, split-volume creation, Photos picker input, iPad drag/drop, default destinations, batch extraction, Shortcuts/X-Callback-URL automation, background task support where safe, iPad multi-window, Android tablet two-pane layout, VoiceOver, TalkBack, and Dynamic Type polish

Formats listed in [Format Scope](#format-scope) are launch-blocking once listed. They must pass the relevant bridge, Android, and iOS quality gates before launch and then be exposed in the mobile UI. If a listed format operation cannot meet the gates, update this launch spec explicitly rather than hiding, disabling, or marking the format experimental in the launch UI.

## Platforms

Android:

- Kotlin and Jetpack Compose
- Material 3 visual system
- Android min SDK 26
- Android target SDK 35
- Native ownership of document pickers, share/open intents, SAF, `content://` URIs, permissions, cache, destination commits, lifecycle, and background policy

iOS:

- Swift and SwiftUI
- Apple Human Interface Guidelines visual and interaction conventions
- iOS deployment target 15.0
- Native ownership of document pickers, share/import flows, security-scoped URLs, app sandbox, destination commits, lifecycle, and interruption handling

Shared:

- Rust `zmanager-mobile-core` UniFFI bridge
- ZManager-Core for archive logic
- Native UI and platform file access do not share code
- All format support is implemented in `zmanager-core` or Rust-owned backends behind the mobile bridge. Kotlin and Swift do not call AppleArchive, XIP, `aa`, `xip`, libarchive, or other archive engines directly.
- Platform gates for formats validate mobile file access, lifecycle, destination commit, UI, and error behavior; they do not transfer archive behavior into Android or iOS shells.

## Format Scope

ZManager-Core may support more formats than the mobile app launch exposes. Mobile UI must expose every format operation listed in this section after it passes the launch quality gates on both Android and iOS. A failing format gate blocks launch until fixed, or until this spec is explicitly changed.

Read/list/extract exposure:

- ZIP
- RAR extraction
- 7z
- TAR
- GZIP
- BZIP2
- XZ
- Zstd
- TGZ / TBZ2 / TXZ
- split ZIP
- multipart RAR extraction
- AppleArchive / AAR where `zmanager-core` exposes support and platform gates pass
- XIP where `zmanager-core` exposes safe extraction and platform gates pass
- JAR
- APK
- APPX
- XPI
- IPA
- CPGZ
- CPT

Additional read/list/extract exposure:

- ISO
- DMG
- CAB
- MSI
- EXE / self-extracting archive containers
- PAX
- LZMA
- ARJ
- LHA / LZH
- CPIO
- WIM

V2 create exposure:

- ZIP
- encrypted ZIP, matching `zmanager-cli` behavior
- 7z
- TAR
- GZIP
- BZIP2
- Zstd
- `.tzst` / tar+zstd
- `.tzap`
- AppleArchive / AAR where `zmanager-core` exposes creation support and platform gates pass

Out of scope:

- RAR creation
- RAR repair
- generic repair for non-tzap archives
- archive editing such as update, delete, freshen, or in-place mutation

`.tzap` is the recovery-first format. ZManager Mobile must present tzap as the preferred path for new archives that need archive-native repair, verification, bit-rot recovery, volume-loss tolerance, or long-term resilience.

## Core User Flows

### Open And Inspect

Requirement OI-1: The user can open an archive from inside the app.

Requirement OI-2: Android supports open-with and share/open intents for archives.

Requirement OI-3: iOS supports document picker and share/import flows for archives.

Requirement OI-4: The native shell resolves platform objects into app-controlled readable sources before invoking Rust when stable path access is needed.

Requirement OI-5: The archive detail screen shows:

- archive display name
- archive type
- entry count
- size hints when available
- encryption/password-required state
- safety warnings
- searchable entry list
- folder tree or grouped list affordance
- primary actions: test, extract, create/export where relevant

Acceptance:

- Large archive listing does not block the main UI thread.
- Empty, loading, unsupported, damaged, password-required, and unsafe states are visibly handled.
- No platform code parses archive internals.

### Password Handling

Requirement PW-1: Password prompts are shown only when required by a bridge response or user-selected encrypted create flow.

Requirement PW-2: Passwords are held only in transient UI/request state long enough to call the bridge.

Requirement PW-3: Passwords are never included in logs, diagnostics, crash reports, screenshots, debug strings, errors, analytics, or persistent storage.

Requirement PW-4: Wrong-password retry reuses the archive handle and prompts for a fresh password; it does not persist the previous password.

Requirement PW-5: Visible password state clears on completion, cancellation, wrong-password dismissal, and app background timeout.

Acceptance:

- Password-required, wrong-password, cancelled-password, and success states are user-readable.
- Password redaction tests pass for bridge errors and job events.
- Crash-safe diagnostics exclude password fields.

### Test Archive

Requirement TA-1: The user can test archive integrity where ZManager-Core supports testing.

Requirement TA-2: Test results show tested entries, warnings, failures, and recovery hints.

Requirement TA-3: Non-tzap damaged archives report clear failure states without promising repair.

Requirement TA-4: Tzap archives may expose recovery-aware verification and repair-within-budget language where ZManager-Core exposes those workflows.

Acceptance:

- The UI distinguishes "test failed", "password required", "unsupported test", and "damaged archive".
- Tzap recovery language is precise and never says all damage is recoverable.

### Extraction Planning

Requirement EP-1: Extraction must be planned before final output is written.

Requirement EP-2: The plan includes:

- selected entries
- destination summary
- estimated uncompressed size when available
- collisions
- unsafe paths
- unsupported entries
- filename rewrites or blocked entries
- expected output root

Requirement EP-3: The user can choose all entries or selected entries.

Requirement EP-4: Collision handling supports replace, skip, keep both, and cancel where platform destination behavior permits.

Requirement EP-5: Unsafe path writes are blocked by default.

Acceptance:

- Parent traversal, absolute paths, duplicate normalized paths, invalid filenames, special files, symlink/hardlink edge cases, too many entries, and zip-bomb-like expansion are surfaced through plan warnings or blocks.
- The app never writes final output before the user sees and accepts the extraction plan.

### Extraction Execution

Requirement EX-1: Rust extracts into an app-controlled staging location for platform-owned destinations.

Requirement EX-2: Rust may write directly only to app-owned filesystem paths with stable access.

Requirement EX-3: The native shell commits staged output to Android SAF, iOS security-scoped destinations, or share/export destinations.

Requirement EX-4: Progress shows:

- percent when known
- entries completed
- current filename
- bytes written when available
- warning count
- cancel action

Requirement EX-5: Cancellation is cooperative and always ends in a known state.

Requirement EX-6: Completion shows:

- extracted count
- skipped count
- failed count
- warning count
- destination
- open destination or share/export action
- whether staged output was cleaned up or retained for recovery

Acceptance:

- Cancellation before commit deletes staging by default.
- Cancellation during commit preserves a recovery record if partial output may exist.
- Failed commit keeps staging only long enough to retry, export elsewhere, or discard.
- Platform provider failure, permission revocation, low storage, partial success, and interruption have user-readable states.

### Create Archive

Requirement CA-1: The user can select files/folders through native pickers.

Requirement CA-2: Native shells build a staging manifest for Rust.

Requirement CA-3: Rust plans creation before writing final output.

Requirement CA-4: Create UI supports the v2 create formats:

- ZIP
- encrypted ZIP
- 7z
- TAR
- GZIP
- BZIP2
- Zstd
- `.tzst` / tar+zstd
- `.tzap`
- AppleArchive / AAR where supported

Requirement CA-5: Encrypted ZIP creation is launch scope and must match the bridge behavior exposed for `zmanager-cli`, including supported encryption method, password requirements, progress, cancellation, error states, and redaction.

Requirement CA-6: Create UI exposes only options that the bridge can honor safely.

Requirement CA-7: The user can share/export the created archive.

Requirement CA-8: The user can verify after compression where the created format supports bridge-backed testing.

Requirement CA-9: The user can archive items separately and create split-volume archives where the bridge and destination commit model support those options safely.

Requirement CA-10: iOS supports Photos picker input for compressing photos and videos and iPad drag/drop into the compression contents list.

Acceptance:

- Existing output is not overwritten without explicit confirmation.
- Password/encryption UX is clear and redacted.
- Progress and cancellation behave like extraction jobs.
- Verify-after-compression reports success, warning, unsupported, or failed state.
- Archive-items-separately and split-volume creation have clear destination commit and cleanup behavior.
- RAR creation is not shown anywhere.
- Tzap creation clearly communicates recovery-oriented benefits when options are present.

### Preview

Requirement PR-1: The archive detail screen supports previewing archive contents before extraction through metadata, search/filter, and entry selection.

Requirement PR-2: The archive detail screen supports opening common individual files through safe temporary materialization.

Requirement PR-3: Temporary single-file preview uses the same safety planner as extraction and must materialize only the selected entry, not the whole archive.

Requirement PR-4: Preview cleanup roots are tracked and removed when no longer needed.

Requirement PR-5: Preview should be comparable to leading archive/file apps but must not turn ZManager Mobile into a full document/media suite.

Requirement PR-6: Preview supports selected preview, selected extract, and selected share/export actions from the archive detail screen where safe.

Acceptance:

- Archive contents can be inspected before extraction.
- Preview is available for common text, image, and PDF files where platform renderers can handle them.
- Preview failures do not block extraction.
- Temporary preview files are cleaned up.

Legacy filename charset handling:

- Core chooses an automatic best interpretation by default.
- Ambiguous or non-UTF-8 path interpretation is surfaced as a warning.
- Native UI lets the user choose a different bridge-provided safe interpretation before preview, planning, extraction, or selected share/export.
- Charset choices are scoped to the current archive handle/session and are not stored in recents.

### Automation, Batch, And Resumability

Requirement AU-1: The app supports batch extraction with per-archive safety plans, progress, cancellation, and completion summaries.

Requirement AU-2: The app supports saved extraction and creation reports.

Requirement AU-3: Shortcuts and X-Callback-URL automation expose only safe, explicit actions and never accept passwords in URLs, command-line-like strings, logs, or persisted shortcut metadata.

Requirement AU-4: Pause/resume is exposed only for operations that can maintain coherent staging and destination state. Launch pause/resume is in-process and cooperative only. If the app process dies, the job becomes interrupted and must surface recovery, retry, export, or cleanup state rather than pretending it can resume.

Requirement AU-5: Default destination settings recover gracefully when provider permissions are revoked or unavailable.

Requirement AU-6: Background task support is exposed only after interruption, partial output, provider failure, and cleanup behavior are specified and tested.

## Mobile File Commit Model

The launch file workflow is two-phase:

1. Native shell resolves the user-selected input into an app-controlled readable source.
2. Rust lists, tests, plans, creates, or extracts using app-controlled paths.
3. Native shell commits final output to the platform destination.
4. Native shell presents destination, share, or export actions.

Android destination policy:

- Use SAF tree/document APIs for external destinations.
- Copy `content://` inputs to app cache when random access is required.
- Avoid broad storage permissions where scoped alternatives work.
- Use an Android foreground service for long user-started archive jobs that may continue after the app is backgrounded.
- Keep archive detection, listing, planning, and small preview materialization foreground-only.
- Do not use WorkManager at launch for archive jobs because persisted rescheduling conflicts with transient passwords, bridge process state, SAF permission lifetimes, and deterministic staging cleanup.
- Treat WorkManager as future work only for password-free, resumable jobs with persisted manifests.
- Handle Android 15+ foreground-service timeout behavior in long-job tests for target SDK 35.

iOS destination policy:

- Support app sandbox destinations first.
- Support true user-selected Files folder destinations for `On My iPhone` and iCloud Drive after security-scoped access, coordinated writes, interruption handling, and staged commit tests pass.
- Use share/export fallback for third-party Files providers until that provider class passes the same destination-commit and recovery tests.
- Use app sandbox plus document picker/export/share flows as fallback paths when true folder extraction is unavailable or unreliable.
- Hold security-scoped access only around native file operations.
- Copy to app temporary storage when bridge calls require stable paths.
- Treat long extraction as foreground-first at launch.

Cleanup policy:

- Every planned job gets a job-specific staging directory.
- Successful commits delete staging immediately after completion summary and report data are captured.
- Cancellation before commit deletes staging immediately.
- Failed commits, permission failures, or provider failures retain staging for 24 hours, or until the user chooses retry, export elsewhere, or discard.
- Partial commits where external output may exist retain a recovery record for 7 days; staging is still deleted after 24 hours unless the user retries or exports it elsewhere.
- Startup cleanup removes staging older than 24 hours unless it is linked to an active retry/export flow.
- Startup cleanup removes recovery records older than 7 days.
- Saved operation reports are separate from staging and recovery records, and may remain until the user deletes them.

## Bridge Requirements

The bridge must stay small, DTO-oriented, and job-based.

Required calls:

```text
healthcheck()
detect_archive(request)
list_archive(request)
test_archive(request)
plan_extract(request)
start_extract(request)
plan_create(request)
start_create(request)
poll_job_events(request)
cancel_job(request)
clear_sensitive_state()
```

Required DTO families:

- `ArchiveHandle`
- `ArchiveSummary`
- `ArchiveEntry`
- `ArchiveWarning`
- `ExtractionPlan`
- `CreatePlan`
- `DestinationPlan`
- `JobId`
- `JobEvent`
- `BridgeError`

Bridge errors must include:

- stable error code
- user-facing message
- optional recovery hint
- severity
- retryable flag
- safe diagnostic details

Bridge errors must not include:

- passwords
- unredacted full paths unless the user explicitly exports diagnostics
- platform permission tokens
- raw provider URIs in normal user-facing messages

## GUI Specification

### Visual Direction

Android uses Material 3. iOS uses SwiftUI and Apple HIG conventions.

Visual references:

- iOS/iPadOS: Apple Human Interface Guidelines and Documents by Readdle-level polish
- Android: Material 3 and clean Files-style surfaces
- Avoid copying dense utility styling from archive apps; ZManager should be calmer and clearer

Shared GUI requirements:

- restrained professional palette
- semantic warning, destructive, success, and neutral states
- compact metadata rows
- clear primary action
- no nested cards
- subtle, consistent corner radius
- icon-only controls have accessibility labels
- long paths use readable middle truncation
- no placeholder text or dead buttons in launch flows

### Required Screens

- Home
- Archive detail
- Password prompt
- Safety warning detail
- Extraction plan review
- Create plan review
- Preview
- Job progress
- Batch queue
- Completion summary
- Diagnostics/report detail
- Settings/about/license/help
- Shortcuts/automation help

### Required States

- first launch
- recent archives empty
- opening archive
- listing large archive
- password required
- wrong password
- unsupported archive
- damaged archive
- filename charset warning
- unsafe entries found
- destination permission revoked
- cloud provider file unavailable
- not enough storage
- preview materializing
- preview unavailable
- extraction in progress
- creation in progress
- verification in progress
- paused
- resumable
- cancellation requested
- background task active
- background task unavailable
- cancelled with cleanup complete
- cancelled with partial output retained
- partial success
- success

GUI acceptance:

- Screens pass light and dark review.
- Screens pass small phone, large phone, Android tablet, and iPad review.
- Dynamic Type / font scaling does not break primary flows.
- Long filenames and localized strings do not overlap controls.
- Archive lists scroll smoothly with large entry counts.
- Risk and completion summaries are understandable without opening diagnostics.

## Security And Privacy Requirements

Requirement SP-1: No ads.

Requirement SP-2: No telemetry or third-party analytics.

Requirement SP-3: Feedback goes through GitHub issues.

Requirement SP-4: No password persistence or logging.

Requirement SP-5: No archive paths or filenames in crash reports unless the user explicitly exports diagnostics.

Requirement SP-6: No command-line password passing.

Requirement SP-7: No network dependency for local archive work.

Requirement SP-8: Safe extraction defaults are always enabled.

Requirement SP-9: Diagnostics are user-copyable and redacted by default.

## Testing Requirements

Fixture corpus must include:

- normal ZIP
- encrypted ZIP
- RAR
- 7z
- TAR.GZ
- `.tzst`
- `.tzap`
- AppleArchive / AAR
- XIP
- split archive
- multipart RAR
- split-volume created output
- unsafe paths
- duplicate normalized paths
- hostile filenames
- legacy filename charset archive
- huge entry count
- large file
- damaged archive
- wrong-password archive

Android tests:

- `content://` archive copy
- share/open intent
- revoked URI permission
- SAF destination write
- low storage
- app background during job
- pause/resume where supported
- cancellation during large extraction
- batch extraction queue
- saved operation report
- tablet/foldable two-pane layout
- Android 8 through target SDK behavior

iOS tests:

- document picker import
- share/import extension
- security scope opens and closes
- iCloud file not downloaded locally
- Files provider latency/failure
- app suspended during job
- pause/resume where supported
- cancellation during extraction
- Photos picker compression input
- iPad drag/drop compression input
- Shortcuts and X-Callback-URL safe request validation
- batch extraction queue
- saved operation report
- iPad multi-window
- true user-selected destination where platform support allows it

Bridge tests:

- empty path
- unsupported archive
- password required
- wrong password
- damaged archive
- normalized warnings
- job event ordering
- preview materialization
- verify-after-compression
- pause/resume where supported
- cancellation
- password redaction
- diagnostics redaction

GUI QA:

- screenshot review for required screens and states
- light and dark mode
- small phone, large phone, Android tablet, iPad
- Dynamic Type / font scaling
- VoiceOver and TalkBack main-flow review
- accessibility labels for icon-only actions
- iPad multi-window and Android tablet/foldable layout
- drag/drop and batch queue states
- long filename/path layout

## Launch Completion Criteria

ZManager Mobile is launch-ready when:

- v2 format exposure matrix is documented and matches app behavior
- every launch-scope format passes launch quality gates on Android and iOS and is exposed in mobile UI
- create/list/test/extract flows cover the mobile-exposed `zm` families
- V2 Keka-parity workflow adoption is complete, or any non-format scope change is explicitly documented with a bridge/platform reason before launch
- RAR extraction works through a license-compatible extraction-only path
- RAR creation and RAR repair are absent from UI and docs except as out-of-scope notes
- `.tzap` recovery-oriented flows are clearly positioned
- encrypted ZIP creation matches `zmanager-cli`
- AppleArchive / AAR, XIP, and every other launch-scope format operation have passed gates and are exposed; non-format workflow items with unresolved bridge or platform blockers require explicit documented scope changes before launch
- password redaction tests pass
- staging cleanup behavior is deterministic
- no-prior-knowledge usability probes pass open, inspect, selected preview, extract, create, password, verification, batch extraction, and cancellation tasks
- screenshot QA passes the required matrix
- README, product design doc, launch spec, in-app strings, and bridge behavior agree
