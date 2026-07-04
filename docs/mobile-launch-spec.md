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
- expose only formats and actions that pass mobile quality gates

The mobile apps must not:

- reimplement archive parsing, extraction, creation, testing, or repair logic in Kotlin or Swift
- create RAR archives
- repair RAR archives
- promise generic repair for non-tzap archives
- include ads, telemetry, or third-party analytics
- persist or log passwords
- require network access for local archive operations

Feedback goes through GitHub issues. Distribution is open source, free, and Apache-2.0 licensed.

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

## Format Scope

ZManager-Core may support more formats than the mobile app exposes. Mobile UI may advertise a format only after that format passes the launch quality gates on both Android and iOS.

Required read/list/extract exposure, subject to mobile quality gates:

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

Conditional read/list/extract exposure:

- ISO
- DMG
- CAB
- ARJ
- LHA / LZH
- CPIO
- WIM

Launch create exposure:

- ZIP
- encrypted ZIP, matching `zmanager-cli` behavior
- 7z
- `.tzst` / tar+zstd
- `.tzap`

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

Requirement CA-4: Create UI supports the launch create formats:

- ZIP
- encrypted ZIP
- 7z
- `.tzst` / tar+zstd
- `.tzap`

Requirement CA-5: Encrypted ZIP creation is launch scope and must match the bridge behavior exposed for `zmanager-cli`, including supported encryption method, password requirements, progress, cancellation, error states, and redaction.

Requirement CA-6: Create UI exposes only options that the bridge can honor safely.

Requirement CA-7: The user can share/export the created archive.

Acceptance:

- Existing output is not overwritten without explicit confirmation.
- Password/encryption UX is clear and redacted.
- Progress and cancellation behave like extraction jobs.
- RAR creation is not shown anywhere.
- Tzap creation clearly communicates recovery-oriented benefits when options are present.

### Preview

Requirement PR-1: The archive detail screen supports previewing archive contents before extraction through metadata, search/filter, and entry selection.

Requirement PR-2: The archive detail screen supports opening common individual files through safe temporary materialization.

Requirement PR-3: Temporary single-file preview uses the same safety planner as extraction and must materialize only the selected entry, not the whole archive.

Requirement PR-4: Preview cleanup roots are tracked and removed when no longer needed.

Requirement PR-5: Preview should be comparable to leading archive/file apps but must not turn ZManager Mobile into a full document/media suite.

Acceptance:

- Archive contents can be inspected before extraction.
- Preview is available for common text, image, and PDF files where platform renderers can handle them.
- Preview failures do not block extraction.
- Temporary preview files are cleaned up.

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
- Use foreground service or WorkManager only when job duration and Android rules require it.

iOS destination policy:

- Support true user-selected destination folders where iOS provides stable permission for the selected provider.
- Use app sandbox plus document picker/export/share flows as fallback paths when true folder extraction is unavailable or unreliable.
- Hold security-scoped access only around native file operations.
- Copy to app temporary storage when bridge calls require stable paths.
- Treat long extraction as foreground-first at launch.

Cleanup policy:

- Every planned job gets a job-specific staging directory.
- Successful commit deletes staging unless the user explicitly saves a report.
- Failed commit offers retry, export elsewhere, or discard where possible.
- Startup cleanup removes stale staging that is not tied to an active recovery record.

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
- Job progress
- Completion summary
- Diagnostics/report detail
- Settings/about/license/help

### Required States

- first launch
- recent archives empty
- opening archive
- listing large archive
- password required
- wrong password
- unsupported archive
- damaged archive
- unsafe entries found
- destination permission revoked
- cloud provider file unavailable
- not enough storage
- extraction in progress
- creation in progress
- cancellation requested
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
- split archive
- multipart RAR
- unsafe paths
- duplicate normalized paths
- hostile filenames
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
- cancellation during large extraction
- Android 8 through target SDK behavior

iOS tests:

- document picker import
- share/import extension
- security scope opens and closes
- iCloud file not downloaded locally
- Files provider latency/failure
- app suspended during job
- cancellation during extraction
- true user-selected destination where platform support allows it

Bridge tests:

- empty path
- unsupported archive
- password required
- wrong password
- damaged archive
- normalized warnings
- job event ordering
- cancellation
- password redaction
- diagnostics redaction

GUI QA:

- screenshot review for required screens and states
- light and dark mode
- small phone, large phone, Android tablet, iPad
- Dynamic Type / font scaling
- accessibility labels for icon-only actions
- long filename/path layout

## Launch Completion Criteria

ZManager Mobile is launch-ready when:

- launch format exposure matrix is documented and matches app behavior
- every advertised format passes launch quality gates on Android and iOS
- create/list/test/extract flows cover the mobile-exposed `zm` families
- RAR extraction works through a license-compatible extraction-only path
- RAR creation and RAR repair are absent from UI and docs except as out-of-scope notes
- `.tzap` recovery-oriented flows are clearly positioned
- encrypted ZIP creation matches `zmanager-cli`
- password redaction tests pass
- staging cleanup behavior is deterministic
- no-prior-knowledge usability probes pass open, inspect, extract, create, password, and cancellation tasks
- screenshot QA passes the required matrix
- README, product design doc, launch spec, in-app strings, and bridge behavior agree
