# ZManager Mobile Implementation Plan

Last reviewed: 2026-07-05

## Purpose

This document turns the launch requirements in [mobile-launch-spec.md](mobile-launch-spec.md) into an implementation plan for Android, iOS, and `zmanager-mobile-core`.

The launch goal is a polished native archive workbench backed by shared Rust archive behavior. Kotlin and Swift own platform UI and file-provider lifetimes. Rust owns archive detection, listing, testing, planning, extraction, creation, cancellation, and normalized archive errors.

This plan is intentionally implementation-facing. If a behavior is user-facing or product-positioning oriented, keep the source of truth in [mobile-product-design.md](mobile-product-design.md). If a requirement changes, update [mobile-launch-spec.md](mobile-launch-spec.md) first and then reflect the implementation impact here.

## V2 Adoption Scope

ZManager Mobile v2 adopts the full Keka-parity workflow set from the product design. "Must Adopt", "Should Adopt", and "Nice Later" are sequencing labels inside v2, not reasons to leave the behavior out of v2.

V2 must adopt:

- native open/import from app, Files/document picker, Android share/open intents, and iOS share/import
- archive browsing before extraction, search/sort, tree/list toggle, selected preview, selected extract, and selected share/export
- password-required, wrong-password, encrypted-create, test/verify, verify-after-compression, progress, cancellation, and completion states
- split/multipart detection, native destination choice, collision handling, safe extraction planning, redacted diagnostics, and no platform archive parsing

V2 should adopt:

- AppleArchive / AAR, XIP extraction, old filename charset handling, archive-items-separately, split-volume creation, iPad drag/drop, Photos picker input, VoiceOver, Dynamic Type, and default destination settings

V2 nice-later items that still belong in v2:

- Shortcuts and X-Callback-URL automation, pause/resume beyond cancellation, background task support, batch extraction, saved extraction reports, iPad multi-window, and Android tablet two-pane layout

Formats listed in the launch format scope are launch-blocking. They must pass the relevant `zmanager-core`, UniFFI bridge, Android, and iOS gates before launch and then be exposed in mobile UI. If a listed format operation cannot meet the gates, update [mobile-launch-spec.md](mobile-launch-spec.md) explicitly rather than hiding, disabling, or marking the format experimental in the launch UI.

## Non-Negotiable Constraints

- Do not implement archive parsing, extraction, creation, testing, repair, or extraction safety in Kotlin or Swift.
- Do not create RAR archives.
- Do not repair RAR archives.
- Do not promise generic repair for non-tzap archives.
- Do not persist, log, include in diagnostics, or pass passwords through command-line arguments.
- Do not require network access for local archive operations.
- Do not add ads, telemetry, or third-party analytics.
- Do not pass Android `content://` URIs or iOS security-scoped URLs into Rust as if they were durable filesystem paths.
- Expose every launch-scope format in mobile UI after it passes mobile quality gates on Android and iOS; failing format gates block launch until fixed or until the launch spec is explicitly changed.

## Target Platforms

Android:

- Kotlin
- Jetpack Compose
- Material 3
- min SDK 26
- target SDK 35
- Native ownership of document pickers, share/open intents, SAF, `content://` URIs, permissions, cache, destination commit, lifecycle, and background policy

iOS:

- Swift
- SwiftUI
- iOS deployment target 15.0
- Native ownership of document pickers, share/import flows, security-scoped URLs, app sandbox, destination commit, lifecycle, and interruption handling

Shared:

- Rust `rust/zmanager-mobile-core`
- UniFFI bridge over `zmanager-core`
- DTO-oriented API surface
- Job-based long-running operations

## Implementation Tracks

### Track 0: Foundation

Goal: make the repository buildable, testable, and ready for cross-platform bridge work.

Deliverables:

- Confirm Rust workspace builds with `cargo check`.
- Confirm Android app skeleton opens in Android Studio and can build a debug target.
- Confirm iOS project opens in Xcode and builds against the generated UniFFI bindings once available.
- Add local fixture directory conventions for archive test files.
- Add a documented way to regenerate UniFFI bindings.
- Add CI placeholders or scripts for Rust checks, Android checks, and iOS checks.
- Store generated Android Kotlin bindings in `android/app/src/main/java/org/tzap/zmanager/mobile/bridge/generated/`.
- Store generated iOS Swift bindings in `ios/ZManagerMobile/ZManagerMobile/Bridge/Generated/`.
- Add `scripts/generate-uniffi-bindings.sh` as the documented regeneration path.
- Do not check generated native binary artifacts into the repository by default; build or copy them through Gradle and Xcode integration scripts.
- Reuse the ZManager Desktop app icon as the mobile app icon source and generate platform-specific icon assets from it.

Definition of done:

- A new contributor can follow [local-development.md](local-development.md) and run the available checks.
- The bridge crate compiles without platform UI dependencies.
- Platform apps can depend on the bridge without duplicating archive logic.

### Track 1: Bridge Reality

Goal: expose a real mobile bridge over `zmanager-core` instead of placeholder behavior.

Required calls:

```text
healthcheck()
detect_archive(request)
list_archive(request)
test_archive(request)
materialize_preview(request)
plan_extract(request)
start_extract(request)
plan_create(request)
start_create(request)
poll_job_events(request)
pause_job(request)
resume_job(request)
cancel_job(request)
clear_sensitive_state()
```

Initial implementation order:

1. Implement `healthcheck`.
2. Implement `detect_archive` for app-controlled local paths.
3. Implement `list_archive` with normalized archive summary, entries, warnings, and password-required errors.
4. Implement `test_archive` where `zmanager-core` supports it.
5. Implement `materialize_preview` for one safe temporary entry at a time.
6. Implement `plan_extract` without final writes, backed by `zmanager-core` extraction safety.
7. Implement job infrastructure for `start_extract`, `poll_job_events`, and `cancel_job`.
8. Add `pause_job` and `resume_job` only for operations with a proven safe resumable implementation; keep controls hidden otherwise.
9. Implement `plan_create` and `start_create`.
10. Implement verify-after-compression by testing the created archive through the same bridge error model.
11. Implement `clear_sensitive_state`.

Bridge rules:

- Requests must use app-controlled paths, cache IDs, or explicit bridge-owned file tokens.
- Platform permission tokens must stay native-owned.
- Bridge DTOs must be serializable through UniFFI without exposing internal core types directly.
- All format support is implemented in `zmanager-core` or Rust-owned backends behind the mobile bridge. Kotlin and Swift must not call AppleArchive, XIP, `aa`, `xip`, libarchive, or other archive engines directly.
- Platform gates for AppleArchive / AAR, XIP, and other formats validate mobile file access, lifecycle, destination commit, UI, and error behavior; they do not transfer archive behavior into Android or iOS shells.
- Long-running operations must return a `JobId` quickly and emit progress through `poll_job_events`.
- Launch job progress uses a pull model, matching ZManager Desktop: native shells call `poll_job_events` instead of subscribing to pushed platform-native streams.
- Mobile polling should add an explicit event cursor or sequence acknowledgement so app suspend/resume, duplicate-safe UI updates, and terminal event retention are deterministic.
- Platform-native streams are future work after the polling contract is proven.
- Pause/resume state must be explicit in `JobEvent`; unsupported pause must be represented as unavailable, not as a disabled mystery control.
- Password-required handling is a preflight or retry state for launch, not a mid-job wait state.
- `start_extract` and `start_create` must receive any required password in their initial request after the native UI has prompted.
- Do not add a job event that waits for a password unless the bridge also adds an explicit, redacted, time-bounded `provide_password` or resume API.
- Error codes must be stable enough for native UI state mapping.
- User-facing messages must be safe to show.
- Diagnostic details must be redacted by default.

Definition of done:

- Android and iOS can call the same bridge surface.
- Password-required, wrong-password, unsupported archive, damaged archive, cancellation, and redaction tests pass at the bridge boundary.
- The bridge can list real ZIP, RAR extraction-supported, 7z, tar-family, AppleArchive / AAR, and XIP fixtures where core support exists.

### Track 2: Read-Only Workbench

Goal: let users open and inspect archives safely on both platforms.

Android deliverables:

- Open archive from in-app picker.
- Open archive from `ACTION_VIEW`.
- Open archive from `ACTION_SEND` where applicable.
- Copy `content://` input to app cache when stable or random access is required.
- Preserve display name and source metadata separately from local cache path.
- Release temporary permission access after the native copy or controlled access step completes.
- Show archive detail screen with metadata, warnings, search, and entry list.

iOS deliverables:

- Open archive from document picker.
- Open archive from share/import flow.
- Start and stop security-scoped access around native file operations.
- Copy provider-backed input to app temporary storage when bridge calls require a stable path.
- Preserve display name and source metadata separately from temporary path.
- Show archive detail screen with metadata, warnings, search, and entry list.

Shared UI deliverables:

- Home screen with open action and recent-archive empty state.
- Archive detail screen with archive name, type, entry count, size hints, encryption/password-required state, safety warnings, searchable and sortable entry list, folder tree or grouped list affordance, and primary actions.
- Entry selection model that supports selected preview, selected extract, and selected share/export.
- Password prompt shown only after bridge response or encrypted create selection requires it.
- Unsupported, damaged, empty, loading, unsafe, password-required, and wrong-password states.
- Legacy filename charset warning or selector where the bridge exposes multiple safe interpretations.

Definition of done:

- Large archive listing does not block the main UI thread.
- No platform code parses archive internals.
- Password prompt state clears on completion, cancellation, wrong-password dismissal, and app background timeout.
- Archive warnings are understandable without opening diagnostics.

### Track 3: Safe Extraction

Goal: provide planned, cancellable extraction with deterministic cleanup and user-readable completion.

Extraction flow:

1. User selects all entries or selected entries.
2. User chooses destination.
3. Native shell resolves destination access.
4. Rust returns an extraction plan before any final output is written.
5. UI shows destination summary, estimated size, collisions, unsupported entries, unsafe paths, filename rewrites, blocked entries, and expected output root.
6. User accepts or cancels the plan.
7. Rust extracts to app-controlled staging for platform-owned destinations.
8. Native shell commits staged output to SAF, security-scoped destination, or share/export target.
9. UI shows completion summary and destination/share action.

Planning requirements:

- Archive entry path safety is platform-neutral archive behavior and belongs in `zmanager-core`; mobile shells must not reimplement it.
- Treat archive paths as untrusted archive-internal strings, not Android, iOS, Unix, or Windows filesystem paths.
- Reuse `zmanager-core` extraction safety planning and translate its path, collision, link, special-file, expansion, and overwrite decisions into mobile DTOs.
- Block unsafe path writes by default.
- Normalize slash and backslash separators consistently.
- Detect parent traversal.
- Detect absolute paths.
- Detect Windows drive prefixes and UNC-like paths even on Android and iOS.
- Detect duplicate normalized paths.
- Detect invalid filenames.
- Detect special files.
- Detect symlink and hardlink edge cases.
- Define and detect deeply nested paths or path/component length limits where the core policy needs portable mobile guardrails.
- Detect too many entries.
- Detect zip-bomb-like expansion when possible.
- Surface unsupported entries.
- Surface filename rewrites and blocked entries.

Collision behavior:

- Replace.
- Skip.
- Keep both.
- Cancel.
- Only show collision actions that the selected destination can honor safely.

Cancellation behavior:

- Cancellation must be cooperative.
- Pause and resume, once exposed, must be cooperative and end in a known resumable, completed, failed, or cancelled state.
- Cancellation before commit deletes staging by default.
- Cancellation during commit preserves a recovery record if partial output may exist.
- Failed commit keeps staging only long enough to retry, export elsewhere, or discard.
- Every cancellation path must end in a known UI state.

Progress events:

- percent when known
- entries completed
- current filename
- bytes written when available
- warning count
- cancel state
- paused or resumable state when supported

Completion summary:

- extracted count
- skipped count
- failed count
- warning count
- destination
- open destination or share/export action
- whether staged output was cleaned up or retained for recovery
- saved report action when report generation is enabled

Definition of done:

- The app never writes final output before the user sees and accepts the extraction plan.
- Platform provider failure, permission revocation, low storage, partial success, and interruption have user-readable states.
- Batch extraction uses the same planning, staging, progress, cancellation, and completion summary model as single-archive extraction.
- Completion summary matches actual output.
- Staging cleanup is deterministic after success, cancellation, and failure.

### Track 4: Create Archive

Goal: let users create launch-supported archives with safe planning, progress, cancellation, and export.

V2 create formats:

- ZIP
- encrypted ZIP
- 7z
- TAR
- GZIP
- BZIP2
- Zstd
- `.tzst` / tar+zstd
- `.tzap`
- AppleArchive / AAR where `zmanager-core` and Apple platform gates support it

Create flow:

1. User selects files and folders through native pickers.
2. Native shell resolves access and builds a staging manifest for Rust.
3. Rust plans creation before writing final output.
4. UI shows archive type, selected inputs, destination, output name, output collision state, compression/encryption options, and warnings.
5. Rust creates archive through a job.
6. UI optionally verifies the created archive through the bridge.
7. UI shows progress, cancellation, pause/resume where supported, completion, and share/export/open-location actions.

Native manifest requirements:

- Use app-controlled local paths, cache IDs, or bridge-owned file tokens for launch.
- Do not pass platform provider streams through UniFFI at launch.
- Treat streaming adapters as future work unless API shape, lifetime, retry, and cancellation semantics are explicitly designed.
- Preserve user-visible relative names separately from platform provider identifiers.
- Support archive-items-separately by creating one planned output per selected top-level item.
- Support split-volume creation only when the bridge can report volume names, sizes, verification status, and destination commit outcome.
- Exclude platform permission tokens from bridge DTOs.
- Avoid leaking full original paths into normal diagnostics.
- Treat provider failures as native errors mapped into user-readable states.

Encrypted ZIP requirements:

- Match `zmanager-cli` behavior exposed by the bridge.
- Use only bridge-supported encryption methods.
- Prompt only when the user selects encrypted ZIP creation.
- Keep password in transient UI/request state only long enough to call the bridge.
- Redact password values from UI logs, debug strings, errors, crash reports, diagnostics, and screenshots.
- Clear visible password state on completion, cancellation, wrong-password dismissal, and app background timeout.

Definition of done:

- Existing output is not overwritten without explicit confirmation.
- Create progress and cancellation behave like extraction jobs.
- Verify-after-compression produces a clear success, warning, unsupported, or failed state.
- Archive-items-separately and split-volume creation pass destination commit and cleanup tests.
- RAR creation is not visible anywhere except out-of-scope notes in docs.
- Tzap creation explains recovery-oriented benefits without promising universal recovery.

### Track 5: Preview

Goal: support archive inspection and safe preview without becoming a document or media suite.

Preview modes:

- Metadata preview through archive detail.
- Search/filter and entry selection.
- Single-file temporary materialization for common text, image, and PDF files where platform renderers can handle them.
- Quick Look on iOS and platform-native preview/share intents on Android where available.

Single-file preview requirements:

- Use the same safety planner as extraction.
- Materialize only the selected entry, not the whole archive.
- Store temporary preview output under a tracked preview cleanup root.
- Clean up preview files when no longer needed.
- Treat preview failures as non-blocking for extraction.

Definition of done:

- Common previewable files open through platform-native renderers.
- Unsafe preview paths are blocked or rewritten by the same planning rules as extraction.
- Temporary preview output does not linger beyond the intended cleanup lifetime.

### Track 6: V2 Parity And Automation

Goal: adopt the Keka-inspired workflow breadth without weakening the safety-first architecture.

Deliverables:

- Default destination settings for extraction and creation, with clear fallback when a provider is unavailable.
- Batch extract multiple archives using one visible queue and per-archive summaries.
- Save extraction and creation reports from completion screens.
- Shortcuts and X-Callback-URL support for safe, explicit open, extract, create, and verify actions.
- iOS Photos picker input for compressing photos and videos.
- iPad drag/drop into the compression contents list.
- iPad multi-window support.
- Android tablet two-pane layout.
- Background task support only after interruption, provider failure, partial output, and cleanup behavior are specified and tested.
- VoiceOver, Dynamic Type, TalkBack, and font-scaling QA across all primary flows.

Rules:

- Automation actions must not accept passwords in URLs, logs, command-line-like strings, or persisted shortcut metadata.
- Shortcuts and URL callbacks must return stable success/error states without exposing passwords, provider tokens, or raw platform URIs.
- Background work must never claim success until the native destination commit is complete or partial output is clearly explained.
- Batch extraction must not bypass per-archive safety plans.

### Track 7: Release Polish

Goal: make all public claims, docs, in-app strings, and tested behavior agree.

Deliverables:

- V2 format exposure matrix.
- Supported-format help page or in-app surface.
- Settings/about/license/help screen.
- Android and iOS app icons generated from the ZManager Desktop icon.
- Diagnostics/report detail screen.
- Default destination settings and destination reset flow.
- Shortcuts/automation help that explains supported actions without exposing sensitive examples.
- Screenshot QA for light mode and dark mode.
- Screenshot QA for small phone, large phone, Android tablet, and iPad.
- Accessibility labels for icon-only actions.
- Dynamic Type / font scaling review.
- Long filename and long path layout review.
- Drag/drop, multi-window, and tablet/foldable layout review.
- No placeholder text or dead buttons in launch flows.

Definition of done:

- Every launch-scope format passes launch quality gates on Android and iOS and is exposed in mobile UI.
- No-prior-knowledge usability probes pass open, inspect, extract, create, password, verification, selected preview, batch extraction, and cancellation tasks.
- README, product design doc, launch spec, in-app strings, and bridge behavior agree.

## Bridge DTO Plan

### ArchiveHandle

Purpose: identify a bridge-readable archive source without exposing platform provider lifetimes to Rust.

Fields to consider:

- opaque id
- app-controlled local path
- display name
- source kind: app cache, app files, temporary import, generated output
- archive size hint
- created-at timestamp for cleanup decisions

Rules:

- Do not store passwords in the handle.
- Do not store Android URI permission grants or iOS security-scoped URL tokens.
- Do not expose unredacted original provider paths in normal diagnostics.

### ArchiveSummary

Purpose: render archive-level metadata on the archive detail screen.

Fields to consider:

- archive type
- entry count
- compressed size when available
- uncompressed size estimate when available
- encryption state
- password-required state
- test support state
- create/extract support hints
- warning count by severity

### ArchiveEntry

Purpose: render archive contents and support selection.

Fields to consider:

- stable entry id
- original path
- normalized output path
- display name
- parent path
- entry kind: file, directory, symlink, hardlink, special, unsupported
- compressed size when available
- uncompressed size when available
- modified time when available
- encrypted flag
- warning codes

Rules:

- Entry IDs should remain stable across listing, selection, planning, and job events for the same archive handle.
- Display paths can be user-readable, but diagnostic exports must respect redaction rules.

### ArchiveWarning

Purpose: surface risk before extraction.

Fields to consider:

- stable warning code
- severity
- affected entry id when applicable
- affected path redacted or display-safe
- user-facing message
- recovery hint
- blocks extraction flag

Warning categories:

- unsafe path
- parent traversal
- absolute path
- duplicate normalized path
- invalid filename
- special file
- symlink or hardlink risk
- unsupported entry
- expansion risk
- huge entry count
- damaged metadata

### ExtractionPlan

Purpose: describe exactly what extraction would do before final output is written.

Fields to consider:

- plan id
- archive handle id
- selected entries
- destination summary
- expected output root
- estimated uncompressed size
- collision list
- filename rewrites
- blocked entries
- unsupported entries
- warnings
- requires password flag
- can start flag

### CreatePlan

Purpose: describe exactly what archive creation would do before final output is written.

Fields to consider:

- plan id
- input manifest id
- archive type
- output name
- output group mode: single archive or archive items separately
- destination summary
- compression options accepted by bridge
- encryption options accepted by bridge
- split-volume options accepted by bridge
- verify-after-compression support state
- estimated output size when available
- warnings
- output collision state
- can start flag

### DestinationPlan

Purpose: keep destination UI and job behavior explicit.

Fields to consider:

- destination display name
- destination kind: app-owned path, Android SAF, iOS security-scoped destination, share/export
- commit strategy: direct write, staged commit, export
- collision policy support
- low-storage status when available
- permission state

Rules:

- Rust may write directly only to app-owned filesystem paths with stable access.
- For platform-owned destinations, Rust writes to staging and the native shell commits.

### JobId

Purpose: identify long-running bridge jobs.

Rules:

- Opaque to native clients.
- Unique within the bridge process.
- Must not encode passwords, paths, or provider identifiers.

### JobEvent

Purpose: drive progress, warning, completion, error, and cancellation UI.

Delivery model:

- Events are delivered through `poll_job_events` at launch.
- Each event should have a monotonic sequence number within its job.
- Poll responses should include current job status, new events after the requested sequence or acknowledgement, and any retained terminal summary.
- Terminal summaries must remain available after terminal events have been read, until the native shell dismisses or clears the job.
- Push streams, callbacks, or platform-native event subscriptions are out of launch scope.

Event kinds:

- started
- progress
- paused
- resumed
- warning
- cancellation requested
- cancelled
- completed
- failed

Progress fields:

- percent when known
- entries completed
- total entries when known
- current entry display name
- bytes written when available
- total bytes when available
- warning count

Rules:

- Events must not include passwords.
- Launch jobs must not block waiting for a password; password-required and wrong-password states are returned before job start or from a failed start request.
- Events should avoid unredacted full paths by default.
- Completion events must include enough counts for the completion summary.
- Pause/resume events must include whether the job can actually resume after process interruption or only after an in-process pause.
- Launch pause/resume is in-process and cooperative only. If the app process dies, the job becomes interrupted and must surface recovery, retry, export, or cleanup state rather than pretending it can resume.
- Process-survivable resume requires a future durable job manifest, core checkpoint support, password-free or safely re-promptable state, and deterministic staging/commit recovery tests.

### PreviewMaterialization

Purpose: safely open one archive entry through native preview renderers without extracting the full archive.

Fields to consider:

- preview id
- archive handle id
- entry id
- temporary local path
- content type hint
- display name
- cleanup deadline
- warnings

Rules:

- Use extraction safety planning for the selected entry.
- Materialize only the requested entry.
- Do not expose passwords, provider tokens, or raw source URIs.
- Clean up preview output when the preview is dismissed, expired, or superseded.

### OperationReport

Purpose: let users save a redacted report after extraction, creation, verification, cancellation, or partial success.

Fields to consider:

- operation id
- operation kind
- archive display name
- archive type
- started and completed timestamps
- counts: processed, extracted, created, skipped, failed, warnings
- destination summary
- stable warning and error codes
- redaction level

Rules:

- Reports are redacted by default.
- Passwords and platform permission tokens are never included.
- Full paths or filenames appear only after explicit user export choices and never in crash reports.

### BridgeError

Purpose: map Rust and core failures into consistent native UI states.

Fields:

- stable error code
- user-facing message
- optional recovery hint
- severity
- retryable flag
- safe diagnostic details

Required normalized errors:

- empty path
- unsupported archive
- password required
- wrong password
- cancelled password
- damaged archive
- unsupported test
- unsafe extraction blocked
- destination unavailable
- insufficient storage
- permission revoked
- provider failure
- cancellation failed or unknown state
- pause unsupported
- resume unavailable
- preview unavailable
- verify unsupported
- automation request invalid
- internal error

Rules:

- No passwords.
- No platform permission tokens.
- No raw provider URIs in normal user-facing messages.
- No unredacted full paths unless the user explicitly exports diagnostics.

## Native File Access Plan

### Input Model

All archive inputs must become bridge-readable before Rust is invoked.

Recent archive bookmarks:

- Recents are display-only app records, not durable archive capabilities.
- Store display name, archive type when known, size hint when known, last opened time, source kind, and an app-cache handle only while the cached copy still exists.
- Do not store passwords, original provider URIs, iOS security-scoped URL or bookmark data, full external paths by default, or platform permission tokens.
- If the cached copy still exists, tapping a recent archive may reopen it.
- If the cache was cleaned or the source was provider-backed without a retained cache copy, tapping the recent archive asks the user to pick or open the archive again.
- Users can remove individual recent entries.
- Recents age out after 30 days and are capped at 20 items.

Android:

- Use `ACTION_OPEN_DOCUMENT` for user-picked archives.
- Use `ACTION_VIEW` and `ACTION_SEND` for open-with/share flows.
- Use platform share intents for selected extracted files and generated archives.
- Use `ContentResolver` to copy `content://` input to app cache when random access is required.
- Keep URI permission lifetime native-owned.
- Treat provider failure, revoked permission, and cloud latency as native file-access errors.

iOS:

- Use document picker for archive selection.
- Use share/import flow for "Open in ZManager".
- Use Photos picker for photo and video inputs during archive creation.
- Use drag/drop on iPad to add files to the compression contents list.
- Start security-scoped access around native copy or coordination work.
- Copy to app temporary storage when bridge calls require stable paths.
- Stop security-scoped access promptly after native file operations.
- Treat unavailable iCloud/provider files as user-readable file-access errors.
- True destination folder extraction is provider-gated. App sandbox destinations are supported first. Files-backed `On My iPhone` and iCloud Drive folder destinations are supported only after security-scoped access, coordinated writes, interruption handling, and staged commit tests pass.
- Third-party Files providers default to share/export fallback until that provider class passes the same destination-commit and recovery tests.
- Provider-specific support must be an allowlist backed by tests, not an optimistic assumption that every security-scoped URL behaves like a durable folder.

### Output Model

All platform-owned destinations use staged output and native commit.

Destination strategies:

- App-owned cache/files path: Rust may write directly.
- Android SAF destination: Rust writes to staging, Android commits through `ContentResolver` and document tree APIs.
- iOS security-scoped destination: Rust writes to staging, iOS commits while holding security-scoped access.
- Share/export destination: Rust writes to staging, native shell invokes platform share/export.
- Default destination: native shell resolves the saved setting into one of the supported destination strategies each time; stale or revoked defaults fall back to prompting.

Commit rules:

- Do not claim success until native commit succeeds or partial success is explained.
- Preserve a recovery record when partial output may exist.
- Successful commits delete staging immediately after completion summary and report data are captured.
- Cancellation before commit deletes staging immediately.
- Failed commits, permission failures, or provider failures retain staging for 24 hours, or until the user chooses retry, export elsewhere, or discard.
- Partial commits where external output may exist retain a recovery record for 7 days; staging is still deleted after 24 hours unless the user retries or exports it elsewhere.
- Startup cleanup removes staging older than 24 hours unless it is linked to an active retry/export flow.
- Startup cleanup removes recovery records older than 7 days.
- Saved operation reports are separate from staging and recovery records, and may remain until the user deletes them.
- Split-volume output is committed as a set; partial commit must identify which volumes exist and offer retry/export/discard.

## Password Handling Plan

Password lifecycle:

1. Bridge reports password required during detect/list/test/plan, or the user selects encrypted create.
2. Native UI prompts for password.
3. Native request retries the preflight call or starts the job with the fresh password.
4. Bridge uses password for that call or job start without caching it for later retry.
5. Native UI clears visible password state.
6. Wrong-password retry reuses the archive handle but prompts for a fresh password.
7. `clear_sensitive_state()` is called on app background timeout and other sensitive-state boundaries.

Native requirements:

- Keep passwords only in transient UI/request state.
- Do not put passwords in view models that persist across process restoration.
- Do not include passwords in screenshots, debug descriptions, logs, crash reports, analytics, or diagnostics.
- Clear password field on completion, cancellation, wrong-password dismissal, and app background timeout.

Rust requirements:

- Use dedicated password fields in request DTOs.
- Use redacted secret wrappers where practical.
- Do not derive or implement debug output that reveals passwords.
- Clear password-bearing request state as soon as practical.
- Do not cache passwords for retry.

Testing requirements:

- Password-required listing does not log password.
- Password-required extraction does not log password.
- Wrong password returns recoverable normalized error.
- Bridge errors and job events contain password metadata, never values.
- Crash-safe diagnostics exclude password fields.
- App background clears visible password state.

## UI Implementation Plan

### Brand And App Icon

ZManager Mobile should reuse the ZManager Desktop app icon for brand continuity.

Source assets:

- Canonical desktop icon source copied into this repository before platform icon generation.
- Temporary local source, until copied: `/Users/frankzhu/IdeaProjects/zmanager-desktop/src-tauri/icons/`

Implementation requirements:

- Generate Android launcher icon assets from the desktop icon, including adaptive icon foreground/background assets where the platform requires them.
- Generate iOS `AppIcon` asset catalog entries from the desktop icon.
- Preserve the recognizable ZManager mark while adapting only the padding, safe area, and platform-specific output sizes needed for Android and iOS.
- Do not introduce a separate mobile-only icon unless the desktop icon cannot satisfy store or platform requirements.
- Keep generated icon files in the platform asset folders, not in Rust.

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
- Shortcuts/automation setup help

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
- cancelled with cleanup complete
- cancelled with partial output retained
- background task active
- background task unavailable
- partial success
- success

### Home

Purpose: provide a calm entry point and a clear open action.

Requirements:

- Primary open archive action.
- Primary create archive action.
- Recent archives empty state.
- Recent archive entries as display-only bookmarks without passwords, provider URIs, permission tokens, security-scoped bookmarks, or full external paths by default.
- Recent archive entries reopen only while an app-cache handle still exists; otherwise they prompt the user to pick or open the archive again.
- Recent archive entries can be removed by the user, age out after 30 days, and are capped at 20 items.
- Privacy/trust status without marketing clutter.
- Settings/about/license/help access.
- Default destination status when configured.

### Archive Detail

Purpose: let the user understand the archive before acting.

Requirements:

- Archive display name.
- Archive type.
- Entry count.
- Size hints when available.
- Encryption/password-required state.
- Safety warnings.
- Searchable entry list.
- Sort controls.
- Folder tree or grouped list affordance.
- Selected entry actions: preview, extract, share/export where safe.
- Primary actions: test, extract, create/export where relevant.
- Empty, loading, unsupported, damaged, password-required, and unsafe states.

### Extraction Plan Review

Purpose: show exactly what will be written before final output is touched.

Requirements:

- Selected entries summary.
- Destination summary.
- Estimated uncompressed size when available.
- Expected output root.
- Collision list and selected collision policy.
- Unsafe path warnings or blocks.
- Unsupported entries.
- Filename rewrites or blocked entries.
- Start and cancel actions.

### Create Plan Review

Purpose: show exactly what archive creation will do.

Requirements:

- Input summary.
- Output name.
- Archive format.
- Destination summary.
- Compression options that the bridge can honor safely.
- Encryption options that the bridge can honor safely.
- Verify-after-compression toggle when supported.
- Archive-items-separately option when multiple top-level inputs are selected.
- Split-volume settings when supported by the selected format.
- Output collision warning.
- Start and cancel actions.

### Job Progress

Purpose: keep long-running work explainable and cancellable.

Requirements:

- Operation type.
- Percent when known.
- Entries completed.
- Current filename.
- Bytes written when available.
- Warning count.
- Cancel action.
- Pause/resume actions when supported.
- Cancellation requested state.
- Paused/resumable state.
- Background/interruption messaging where relevant.

### Completion Summary

Purpose: answer what happened and what the user can do next.

Requirements:

- Success, partial success, cancelled, or failed state.
- Extracted/created count where applicable.
- Skipped count.
- Failed count.
- Warning count.
- Destination.
- Open destination or share/export action.
- Staging cleanup or retained recovery state.
- Diagnostics/report action.
- Save report action.
- Verification result for created archives when verify-after-compression ran.

## Android Implementation Plan

Recommended modules or package areas:

- file access and SAF adapters
- cache/staging manager
- bridge binding wrapper
- job event repository
- archive detail state holder
- extraction planner state holder
- create planner state holder
- password prompt state holder
- diagnostics redaction helpers

Android-specific tasks:

- Add document picker integration.
- Add `ACTION_VIEW` handling.
- Add `ACTION_SEND` handling.
- Add selected-output share intent support.
- Implement `content://` to app cache copy.
- Implement app cache cleanup rules.
- Implement SAF tree/document destination selection.
- Implement staged commit to SAF destinations.
- Implement default destination settings and revoked-default recovery.
- Implement permission revocation handling.
- Implement low-storage handling where platform APIs allow.
- Implement tablet/foldable two-pane archive detail and batch queue layouts.
- Use an Android foreground service for long user-started archive jobs that may continue after the app is backgrounded.
- Keep `detect_archive`, `list_archive`, `plan_extract`, `plan_create`, and small preview materialization foreground-only.
- Run `start_extract`, `start_create`, `test_archive`, verify-after-compression, and batch jobs through the foreground service when they may outlive the visible activity.
- The foreground service owns the notification, polls bridge jobs, exposes cancellation, and records cleanup or recovery state.
- Do not use WorkManager at launch for archive jobs; persisted rescheduling conflicts with transient passwords, bridge process state, SAF permission lifetimes, and deterministic staging cleanup.
- Treat WorkManager as future work only for password-free, resumable jobs with persisted manifests.
- Implement Android 15+ foreground-service timeout handling and tests for target SDK 35 behavior.
- Ensure Compose screens handle lifecycle and background timeout.

Android tests:

- `content://` archive copy.
- Share/open intent.
- Revoked URI permission.
- SAF destination write.
- Low storage.
- App background during job.
- Pause/resume where the bridge exposes it.
- Cancellation during large extraction.
- Batch extraction queue.
- Saved operation report.
- Tablet/foldable two-pane layout.
- Android 8 through target SDK behavior.
- Password redaction in logs and diagnostics.

## iOS Implementation Plan

Recommended areas:

- document picker coordinator
- share/import handling
- Photos picker coordinator
- drag/drop coordinator
- security-scoped access wrapper
- temporary import manager
- staging manager
- bridge binding wrapper
- job event model
- SwiftUI screen view models
- diagnostics redaction helpers

iOS-specific tasks:

- Add document picker import/open flow.
- Add share/import flow.
- Add Photos picker flow for compression inputs.
- Add drag/drop into the compression contents list on iPad.
- Implement security-scoped access open/close wrapper.
- Copy provider-backed files to app temporary storage when needed.
- Implement app sandbox destination flow.
- Implement true user-selected destination folders for app sandbox destinations first, then for Files-backed `On My iPhone` and iCloud Drive folders after provider-gated security-scope and staged-commit tests pass.
- Route third-party Files providers through export/share fallback until that provider class passes the same destination-commit and recovery tests.
- Implement export/share fallback destinations.
- Implement default destination settings and revoked-default recovery.
- Implement staged commit while holding security-scoped access.
- Handle iCloud file unavailable states.
- Add Shortcuts and X-Callback-URL entry points after safe request validation exists.
- Add iPad multi-window support.
- Treat long extraction as foreground-first at launch.
- Implement background task support only after lifecycle and partial-output behavior is tested.
- Save enough state to explain partial output after interruption.

iOS tests:

- Document picker import.
- Share/import extension.
- Security scope opens and closes.
- iCloud file not downloaded locally.
- Files provider latency/failure.
- App suspended during job.
- Pause/resume where the bridge exposes it.
- Cancellation during extraction.
- Photos picker compression input.
- iPad drag/drop compression input.
- Shortcuts and X-Callback-URL safe request validation.
- Batch extraction queue.
- Saved operation report.
- iPad multi-window.
- True user-selected destination where platform support allows it.
- Password redaction in logs and diagnostics.

## Rust Implementation Plan

Rust responsibilities:

- Archive detection.
- Archive listing.
- Integrity testing.
- Preview materialization.
- Extraction planning.
- Extraction safety.
- Create planning.
- Create execution.
- Extract execution.
- Progress events.
- Pause/resume support where safe.
- Cooperative cancellation.
- Normalized archive errors.
- Redaction-safe diagnostics.

Recommended internal areas:

- DTO mapping from core types to UniFFI-safe types.
- Request validation.
- Archive handle registry.
- Job registry.
- Cancellation token management.
- Event queue per job.
- Staging path validation.
- Password redaction utilities.
- Diagnostic detail sanitizer.

Rust tasks:

- Wire `zmanager-mobile-core` to `zmanager-core`.
- Replace placeholder listing behavior.
- Normalize core errors into mobile bridge errors.
- Build extraction plans without writes.
- Materialize one preview entry at a time through extraction safety.
- Ensure extraction jobs report progress and support cancellation.
- Ensure create jobs report progress and support cancellation.
- Add pause/resume only for job implementations that can preserve a coherent staging and output state. Launch support is in-process only unless a specific operation proves durable checkpoint/resume semantics.
- Add verify-after-compression by invoking bridge-supported test behavior on created archives.
- Support archive-items-separately and split-volume creation where core support and destination commit behavior are ready.
- Surface old filename charset behavior through stable metadata, warnings, and selection DTOs. Core chooses an automatic best interpretation by default, marks ambiguous or non-UTF-8 path interpretation with warnings, and lets native UI request a different safe interpretation before preview, planning, extraction, or selected share/export.
- Charset overrides are scoped to the current archive handle/session unless a future explicit setting is designed. Do not persist per-archive charset choices in recents.
- Ensure password-bearing DTOs are never printed in debug logs.
- Implement `clear_sensitive_state`.
- Add bridge-boundary tests for required error and redaction cases.

Rust tests:

- Empty path.
- Unsupported archive.
- Password required.
- Wrong password.
- Damaged archive.
- Normalized warnings.
- Job event ordering.
- Preview materialization.
- Verify-after-compression.
- Pause/resume where supported.
- Cancellation.
- Password redaction.
- Diagnostics redaction.

## Format Exposure Plan

Mobile UI must expose every launch-scope format after the format passes launch quality gates on Android and iOS. Failing gates block launch until fixed, or until the launch spec is explicitly changed.

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
- encrypted ZIP
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

Exposure matrix columns:

- format
- list support
- test support
- extract support
- create support
- password support
- split/multipart support
- filename charset support
- verify-after-compression support
- Android gate status
- iOS gate status
- visible in UI, which must be true for each launch-scope format after gates pass
- limitations copy

## Fixture Corpus

Required fixtures:

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

Recommended additional fixtures:

- plain TAR
- standalone GZIP
- standalone BZIP2
- standalone XZ
- standalone Zstd
- JAR
- APK
- APPX
- XPI
- IPA
- CPGZ
- CPT
- ISO
- CAB
- MSI
- EXE / self-extracting archive container
- PAX
- LZMA
- TGZ
- TBZ2
- TXZ
- unsupported archive
- empty archive
- symlink archive
- hardlink archive
- special-file archive
- zip-bomb-like expansion fixture with safe test limits
- cloud-provider unavailable simulation input
- Photos picker media input fixtures using synthetic, non-sensitive images/videos
- batch extraction fixture set with mixed success, warning, and failure cases

Fixture rules:

- Do not check in copyrighted or sensitive files.
- Do not include real passwords outside test-only fixture metadata.
- Store fixture passwords in test code or fixture docs only when needed, clearly marked as non-secret test data.
- Keep hostile fixtures safe to store and run in CI.

## Testing Strategy

### Bridge Boundary Tests

Focus:

- request validation
- error normalization
- warning normalization
- password handling
- preview materialization
- verify-after-compression
- job event ordering
- pause/resume where supported
- cancellation
- diagnostics redaction

Exit criteria:

- All required normalized errors have tests.
- No password value appears in test-captured logs, events, errors, diagnostics, or debug strings.
- Cancellation always ends in a known state.

### Platform File Access Tests

Focus:

- Android `content://` handling
- Android SAF destination commit
- iOS security-scoped URL lifetime
- iOS document picker import
- iOS Photos picker input
- iOS drag/drop input
- cloud/provider failure states
- permission revocation
- default destination recovery after permission loss
- low storage

Exit criteria:

- Platform object lifetimes are native-owned.
- Rust receives only app-controlled paths or bridge-safe tokens.
- Provider failures produce user-readable states.

### GUI QA

Focus:

- required screens
- required states
- light/dark mode
- small phone
- large phone
- Android tablet
- iPad
- font scaling / Dynamic Type
- accessibility labels
- VoiceOver and TalkBack flow review
- long names and paths
- iPad multi-window
- Android tablet/foldable two-pane layout
- drag/drop and batch queue states

Exit criteria:

- No placeholder text or dead buttons in launch flows.
- Long filenames and localized strings do not overlap controls.
- Risk and completion summaries are understandable without diagnostics.

### End-To-End Smoke Tests

Core flows:

- open archive from app
- open archive from Android share/open intent
- open archive from iOS document picker
- list archive
- password-required listing
- wrong-password retry
- test archive
- preview selected file
- extraction plan
- extract all
- extract selected
- batch extract multiple archives
- collision handling
- pause/resume where supported
- cancellation before commit
- cancellation during commit
- create ZIP
- create encrypted ZIP
- create 7z
- create TAR
- create GZIP
- create BZIP2
- create Zstd
- create `.tzst`
- create `.tzap`
- create AppleArchive / AAR where supported
- create archive items separately
- create split-volume archive where supported
- verify after compression
- create from Photos picker input
- share/export result
- save operation report
- run Shortcuts/X-Callback-URL action where supported

Exit criteria:

- Completion summary matches actual output.
- Staging cleanup behavior is deterministic.
- No launch-scope format fails required gates.

## Diagnostics And Reports

Diagnostics must be user-copyable and redacted by default.

Allowed by default:

- app version
- platform version
- archive type
- operation
- stable error code
- warning codes
- severity
- retryable flag

Redacted by default:

- full archive paths
- full output paths
- provider URIs
- filenames when crash-report context would leave the device

Never allowed:

- passwords
- platform permission tokens
- command-line password arguments
- unredacted provider URIs in normal user-facing messages

User-exported diagnostics may include more path detail only after explicit user action. Passwords are still never included.

## Release Gates

ZManager Mobile is launch-ready when:

- V2 format exposure matrix is documented and matches app behavior.
- Every launch-scope format passes launch quality gates on Android and iOS and is exposed in mobile UI.
- Create/list/test/extract flows cover the mobile-exposed `zm` families.
- V2 Keka-parity workflow adoption is complete, or any non-format scope change is explicitly documented with a bridge/platform reason before launch.
- RAR extraction works through a license-compatible extraction-only path.
- RAR creation and RAR repair are absent from UI and docs except as out-of-scope notes.
- `.tzap` recovery-oriented flows are clearly positioned.
- Encrypted ZIP creation matches `zmanager-cli`.
- AppleArchive / AAR, XIP, and every other launch-scope format operation have passed gates and are exposed; non-format workflow items with unresolved bridge or platform blockers require explicit documented scope changes before launch.
- Password redaction tests pass.
- Staging cleanup behavior is deterministic.
- No-prior-knowledge usability probes pass open, inspect, selected preview, extract, create, password, verification, batch extraction, and cancellation tasks.
- Screenshot QA passes the required matrix.
- README, product design doc, launch spec, in-app strings, and bridge behavior agree.

## Suggested Implementation Order

1. Make bridge healthcheck and binding generation work end to end.
2. Implement app-controlled input import on Android and iOS.
3. Implement `detect_archive` and `list_archive`.
4. Build archive detail UI and password-required listing flow.
5. Implement search/sort/tree-list selection plus selected preview materialization.
6. Implement normalized bridge errors and warning DTOs.
7. Implement `test_archive`.
8. Implement `plan_extract` and extraction plan review UI.
9. Implement staged extraction jobs, polling, progress, cancellation, and destination commit.
10. Implement completion summary, saved reports, and cleanup/recovery records.
11. Implement create planning and create jobs.
12. Implement encrypted ZIP creation, verify-after-compression, archive-items-separately, split-volume creation, and password redaction tests.
13. Add AppleArchive / AAR, XIP, and legacy charset exposure after the relevant format gates pass.
14. Add Photos picker, iPad drag/drop, default destinations, batch extraction, and saved reports.
15. Add Shortcuts/X-Callback-URL and pause/resume once request validation and job-state invariants are proven.
16. Complete tablet/iPad, multi-window, accessibility, background-task, and screenshot QA.
17. Complete format exposure matrix and fixture corpus.
18. Run release GUI QA and no-prior-knowledge usability probes.

## Open Implementation Decisions

No open implementation decisions remain in this plan. Any new decision that changes launch scope, format claims, privacy posture, or archive behavior belongs in [mobile-launch-spec.md](mobile-launch-spec.md) before this implementation plan is updated.

Implementation may still discover bugs or provider-specific limitations, but those should be resolved against the documented decisions above rather than becoming implicit scope changes.
