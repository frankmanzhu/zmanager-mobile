# ZManager Mobile Product Design

Last reviewed: 2026-07-05

## Executive Summary

ZManager Mobile should launch at the v2 quality bar rather than stepping through a small v1. ZArchiver and RAR already have massive Android distribution, very broad format support, and years of edge-case polish. Apple Files and Files by Google already own the simple ZIP path because they are installed, trusted, and native.

ZManager can stand out by being the safest, clearest, most consistent mobile archive tool for people who need to open, inspect, verify, create, and extract archives without surprises. ZManager-Core is the foundation for archive correctness; the mobile apps depend on native GUI quality, platform file access, job orchestration, and the clarity of every state around the engine.

The strongest wedge is:

- no ads, no dark patterns, no unnecessary network access
- archive safety visible before extraction
- trustworthy password handling
- native Android and iOS file workflows
- consistent behavior from the shared Rust engine
- reliable progress, cancellation, and resumable user flows
- clean handling of large archives, nested folders, odd filenames, and protected archives

The product goal is not "a file manager that also does archives." It is "the archive workbench you trust when the archive might be large, messy, encrypted, or risky."

## Product Assumption

ZManager Mobile depends on ZManager-Core for archive compression and decompression. The design assumes ZManager-Core already covers the supported archive types and that archive parsing, extraction safety, creation, testing, and format-specific behavior stay in Rust. Platform shells must not call AppleArchive, XIP, `aa`, `xip`, libarchive, or other archive engines directly.

Implementation requirements are tracked in [mobile-launch-spec.md](mobile-launch-spec.md).

That means the mobile work should focus on:

- a polished native Android and iOS GUI
- correct Android SAF, `content://`, share intent, and cache handling
- correct iOS document picker, security-scoped URL, import, and export handling
- reliable bridge DTOs, progress, cancellation, and error normalization
- careful password and diagnostics handling at the platform boundary
- user confidence before, during, and after each archive job

The mobile app should not duplicate core archive logic. It should make ZManager-Core feel obvious, modern, and dependable on a phone or tablet.

## V2 Launch Bar

ZManager Mobile should use the same philosophy as the `zm` CLI 100% polish target: the engine is already strong, so the release bar is consistency, presentation, installability, recovery from interruption, and long-tail UX polish. Mobile should not ship as a thin proof of concept over ZManager-Core. It should ship as a complete archive utility with a GUI people can trust immediately.

The mobile v2 bar means:

- public UI, docs, supported-format claims, and bridge behavior agree
- every visible action has a complete loading, error, cancellation, and success state
- progress, cancellation, and partial-output states are reliable
- Android and iOS file-provider behavior is tested instead of assumed
- format support is broad where ZManager-Core is already broad, but only exposed after mobile-shell gates pass
- password flows are polished enough for non-technical users and strict enough for privacy-sensitive users
- install, onboarding, first launch, share/open-with, and destination flows feel production-ready
- screenshot QA, accessibility QA, and large-archive responsiveness are release gates

This is a quality target, not a promise to implement every possible archive-adjacent feature. Archive editing, generic repair, cloud sync, and niche forensic workflows remain out of scope unless they serve the polished mobile archive workbench goal.

## Market Snapshot

This section uses public app store and support pages reviewed on 2026-07-05.

| Reference app | Platform | Strengths | Opportunity | ZManager response |
| --- | --- | --- | --- | --- |
| [ZArchiver](https://play.google.com/store/apps/details?id=ru.zdevs.zarchiver) | Android | Huge install base, broad create/extract/view support, split archives, password support, no declared data collection | Dense utility UX, Android storage access friction in reviews, hard to out-format quickly | Emphasize safety-first planning, clearer progress, modern SAF behavior, and a quieter UI |
| [RAR by RARLAB](https://play.google.com/store/apps/details?id=com.rarlab.rar) | Android | Official RAR pedigree, creates RAR/ZIP, repair command, recovery records, multipart support | Ad/analytics stack disclosed in privacy policy, technical UI, strongest around RAR specifically | Support RAR extraction for compatibility, but make tzap the preferred path for new recovery-aware archives |
| [Keka](https://ios.keka.io/) | iOS/iPadOS | Broad create/extract support, archive browsing, selected preview/extract/share, passwords, AppleArchive, Photos input, split volumes, Shortcuts, and polished native workflows | Paid iOS app and less safety-forward positioning; strongest on broad utility parity | Treat as the v2 iOS capability benchmark while differentiating through safer extraction planning, redaction, and clearer completion states |
| [iZip](https://apps.apple.com/us/app/izip-zip-unzip-unrar/id413971331) | iOS/iPadOS | High rating, many formats, cloud integrations, simple ZIP/RAR management | Some security and advanced features are Pro; UX is utility/file-manager oriented | Offer transparent free core, safer extraction planning, and native document-picker flows |
| [WinZip](https://apps.apple.com/us/app/winzip-1-zip-unzip-tool/id500637987) | iOS/iPadOS | Recognized brand, cloud integrations, ZIPX, AES encryption, broad document preview | Lower iOS rating than iZip/Documents in observed listing, broad app surface | Keep the experience focused on archives with fewer non-archive distractions |
| [Documents by Readdle](https://apps.apple.com/us/app/documents-file-manager-docs/id364901807) | iOS/iPadOS | Excellent distribution, polished file manager, cloud, PDF, media, archive support | Archive work is one feature among many; large app surface and subscription ecosystem | Be the specialist tool for risky archives, verification, and extraction control |
| [Apple Files ZIP support](https://support.apple.com/en-us/102532) | iOS/iPadOS | Built in, trusted, simple ZIP create/open | ZIP-only oriented; little planning, verification, password, or advanced format depth | Provide value whenever user needs beyond basic ZIP |
| [Files by Google ZIP support](https://support.google.com/files/answer/9048509) | Android | Built in on many devices, simple ZIP extraction | Google docs state only `.zip` files are supported for unzip; compression is ZIP-only | Support RAR/7z/TAR/XZ/Zstd, password flows, planning, and extraction control |

## Product Differentiation

ZManager should define success by usefulness, trust, and polish rather than by framing other apps as direct opponents.

Compared with built-in tools, ZManager adds capability. Apple Files and Files by Google are convenient for ZIP, but they are not serious archive workbenches. Support more formats, encrypted archives, test-before-extract, and extraction planning, and ZManager has a clear reason to exist.

Compared with ad-supported utilities, ZManager leads with trust. RAR's own privacy policy says the Android app integrates AdMob, Firebase Analytics, and Crashlytics. ZManager should make "no ads, no trackers, no password persistence" a product promise and an implementation constraint.

Compared with broad file managers, ZManager stays focused. Documents by Readdle is a polished all-in-one file hub. ZManager should not copy that. It should do archive work with fewer steps, clearer risk labels, and better completion confidence.

Compared with Keka on iOS, ZManager should adopt the same practical workflow breadth by v2: open/import, browse, preview, selected extract, create, password, verify, split-volume handling, Photos input, drag/drop, and automation hooks. The differentiation is not "more buttons." It is making risky archive work safer, more explainable, and more privacy-preserving.

ZManager should not expect to match ZArchiver's Android distribution immediately. If ZManager-Core already supports the needed archive formats, the mobile response is not to rebuild format logic; it is to make every supported format feel safer, calmer, and easier to operate than established apps.

For repair-oriented workflows, tzap is the primary option and the intended replacement path for RAR-style recovery expectations. ZManager Mobile should recognize and present `.tzap` archives as the best path for self-healing, long-term, recovery-aware storage. Generic archive repair should not be a ZManager Mobile promise.

Success condition:

- On first serious release, users prefer ZManager over built-in ZIP tools for non-trivial archives.
- Power users prefer ZManager over generic unzip apps because it feels safer, clearer, and more complete.
- Users choose tzap when they need archive-native repair, long-term storage resilience, bit-rot recovery, or missing-volume tolerance.
- Users choose tzap instead of RAR when creating new archives that need recovery, verification, or long-term resilience.

## Product Positioning

One-line positioning:

> ZManager Mobile is a private, safety-first archive workbench for Android and iOS.

Primary promise:

- Open the archive.
- See what is inside.
- Know whether extraction is safe.
- Choose exactly where output goes.
- Watch progress.
- Cancel cleanly.
- Keep passwords transient.

## Repair Positioning

ZManager Mobile should be excellent at safe listing, testing, planning, creation, extraction, and completion confidence for supported archive formats. It should not try to become the best generic archive repair tool.

Repair positioning:

- `.tzap` is the recovery-first format.
- tzap is the primary product for archive-native repair, bit-rot recovery, multi-volume loss tolerance, and long-term storage resilience.
- RAR creation and RAR repair are intentionally out of scope.
- ZManager Mobile should make tzap archives easy to recognize, verify, inspect, create, and restore where ZManager-Core exposes those workflows.
- For non-tzap formats, ZManager Mobile should offer integrity testing and clear failure states, not speculative repair promises.
- RAR support exists for reading and extracting archives users already have, not for creating or repairing new recovery-oriented archives.

User-facing repair language should stay precise:

- Good: "This archive can be tested before extraction."
- Good: "This tzap archive includes recovery data and can attempt repair within its configured budget."
- Good: "This archive is damaged and cannot be safely extracted."
- Avoid: "Repair any archive."
- Avoid: "Recover all damaged files."

Anti-goals:

- Do not become a general-purpose cloud file manager.
- Do not hide risky archive behavior behind a single "Extract" button.
- Do not add ads or analytics that weaken the trust story.
- Do not reimplement archive parsing in Kotlin or Swift.
- Do not make RAR creation, RAR repair, or generic repair a promise; position tzap as the recovery-first archive option.
- Do not expose a format or action in the GUI before the mobile-shell quality gates pass; launch-scope formats must pass those gates and be exposed rather than hidden as launch gaps.

## Target Users

### Casual Receiver

Gets a ZIP/RAR/7z from email, chat, LMS, or browser. Wants to open it, preview filenames, and extract it into Files/Downloads/iCloud/Drive with minimal confusion.

Must have:

- open from share sheet / "Open with"
- plain-language password prompt
- clear extraction destination
- no scary technical errors unless needed

### Mobile Power User

Moves ROMs, backups, datasets, logs, game assets, mod packs, or school/work bundles on a phone or tablet. Cares about format support, split archives, performance, progress, and preserving paths.

Must have:

- list large archives without freezing
- partial selection
- progress with current file and total work
- cancel without leaving confusing partial output
- detect suspicious paths before writing

### Privacy-Sensitive User

Handles personal, client, legal, medical, tax, or business files. Needs confidence that filenames and passwords are not sent anywhere.

Must have:

- no network requirement for local archive work
- no password persistence
- safe diagnostics that redact paths when requested
- local-only crash reporting posture unless explicitly opted in later

## Core User Flows

### Open And Inspect

1. User launches the app or opens an archive from another app.
2. Platform shell obtains access:
   - Android: document picker, SAF URI, share intent, or cached copy.
   - iOS: document picker, security-scoped URL, share/import action, or app sandbox copy.
3. Native shell creates a controlled local path or stream handle for Rust.
4. Rust detects archive type and returns metadata.
5. UI shows:
   - archive name and type
   - total entries, visible size, compressed size when available
   - encryption/password-required state
   - warnings: absolute paths, parent traversal, duplicate output paths, suspicious symlinks, unsupported entries
   - searchable tree/list of entries

### Password-Required Listing

1. Rust returns a normalized `PasswordRequired` error.
2. UI prompts for password in transient state.
3. Password is passed only to the bridge call that needs it.
4. Password is cleared from UI state after operation completion, cancellation, or app background timeout.
5. No password appears in logs, diagnostics, crash reports, command-line arguments, or persistent storage.

### Extraction Planning

1. User selects all entries or a subset.
2. User chooses destination:
   - Android: app-specific folder, Downloads, or SAF document tree.
   - iOS: app sandbox, Files export, security-scoped destination, or share sheet.
3. Rust returns an extraction plan:
   - files and folders to write
   - total uncompressed size estimate
   - collision list
   - unsafe path rewrites or blocked entries
   - unsupported entry types
   - whether background execution is possible
4. UI asks the user to resolve collisions before execution.

### Extraction Execution

1. Native shell opens destination access and keeps permission lifetime native-owned.
2. Rust runs the extraction job against an app-controlled staging location.
3. Native shell commits staged output to the final destination when the destination is a platform object.
4. Rust may write directly only when the destination is an app-owned filesystem path with stable access.
5. UI shows progress:
   - percent when known
   - entries completed
   - current filename
   - bytes written
   - warnings count
6. User can cancel.
7. Completion screen states exactly what happened:
   - extracted count
   - skipped count
   - failed count
   - destination
   - "Open destination" action

Launch should prefer staging plus native commit over long-lived direct writes into platform destinations. Android SAF trees and iOS security-scoped destinations are platform-owned resources, not ordinary durable paths. A future streaming/write-adapter bridge can be added after cancellation, partial output cleanup, provider failure, and retry behavior are specified and tested.

### Create Archive

1. User selects files/folders through native pickers.
2. Native shell resolves access and creates a staging manifest.
3. Rust plans output:
   - archive type
   - compression level
   - encryption options
   - split size if supported
   - output name
4. Rust creates archive with progress and cancellation.
5. UI offers share/export/open location.

V2 should target polished create flows for the same practical families as `zm` plus Keka-parity iOS formats where ZManager-Core exposes the workflow through the bridge: ZIP, encrypted ZIP, 7z, TAR, GZIP, BZIP2, Zstd, modern tar+zstd / `.tzst`, `.tzap`, and AppleArchive / AAR where supported. RAR creation and RAR repair are intentionally out of scope.

## Feature Requirements

ZManager Mobile v2 adopts the full Keka-parity workflow set below. "Must Adopt", "Should Adopt", and "Nice Later" describe implementation sequencing inside v2, not scope exclusion. Launch-scope formats are not hidden or marked experimental as a release workaround: they must pass ZManager-Core, bridge, Android, and iOS gates and then be exposed in the UI.

### V2 Must Adopt

- Open archive from app launcher and in-app picker.
- Open archive from Android share/open intents.
- Open archive from iOS document picker and share/import flow.
- Browse archive contents before extraction through Rust-backed listing.
- Search, sort, and switch between folder tree and flat/grouped list views.
- Extract all entries or selected entries.
- Preview common text, image, and PDF files through safe temporary materialization and platform renderers.
- Password-required, wrong-password, cancelled-password, and encrypted-create flows.
- Create archives and then share/export/open the result.
- Test or verify archive integrity where the bridge supports it.
- Verify after compression where the bridge can test the created format.
- Detect split and multipart archives with friendly "select the first part" guidance.
- Choose native-feeling destinations, including iOS Files destinations where platform access permits.
- Show progress, cancellation, known cleanup state, and a clear completion summary.
- Collision handling: replace, skip, keep both, cancel.
- Safety handling:
  - block parent traversal by default
  - block absolute path writes by default
  - detect duplicate output paths after normalization
  - detect invalid or hostile filenames
  - detect entries too large for available space when platform allows
- Normalized errors with recovery hints.
- Recent archives stored as display-only bookmarks without passwords.
- Extract to app cache then native export/commit for platform-owned destinations.
- Share extracted files/folders.
- No archive parsing in platform code.
- No password logging or persistence.
- Visual design and state handling that meet the GUI quality gates below.

### V2 Should Adopt

- AppleArchive / AAR create, list, test where possible, and extract support when ZManager-Core exposes it and platform gates pass.
- XIP extraction support when ZManager-Core exposes it safely and platform gates pass.
- Old filename charset handling for real-world archives with legacy encodings.
- Archive items separately during create.
- Split-volume creation where the bridge supports it.
- iPad drag/drop into the compression contents list.
- Photos picker input for compressing photos and videos.
- VoiceOver and Dynamic Type polish from the start, not after release.
- Default destination settings for extraction and creation.

### V2 Nice Later

These are still adopted in v2, but can land after the core open/list/extract/create flows are stable.

- Shortcuts and X-Callback-URL automation.
- Pause and resume for compression and extraction, beyond basic cancellation.
- Background task support once interruption, partial output, and cleanup behavior are fully specified.
- Batch extract multiple archives.
- Save extraction reports.
- iPad multi-window support.
- Android tablet two-pane layout.

### V2 Quality Gates

Every v2-supported format must pass mobile smoke tests before launch. A listed launch-scope format that fails gates blocks launch until fixed, or until the launch spec is explicitly changed.

Required gates:

- listing works from app cache, Android `content://`, Android share/open intent, iOS document picker, and iOS share/import flow
- password-required, wrong-password, and cancelled-password states are user-readable
- extraction plan returns before writing final output
- progress does not block UI interaction
- cancellation produces a known cleanup state
- pause/resume, if exposed for the operation, does not corrupt staging or destination state
- launch pause/resume is in-process only; process death surfaces interruption recovery rather than a fake resume
- completion summary matches actual output
- verify-after-compression reports success, warnings, unsupported verification, or failure without hiding the created archive state
- diagnostics never include passwords
- visual states exist for loading, empty archive, damaged archive, unsupported archive, unsafe archive, wrong password, no storage, permission revoked, cancelled, partial success, and success

### Out Of V2 Scope

- Archive editing if core supports safe update operations.
- Generic repair commands for non-tzap archives.
- Cloud provider integrations only after local archive workflows are excellent.
- Optional sync between desktop ZManager and mobile ZManager.

## Format Strategy

ZManager-Core owns real format support. ZManager Mobile should expose every launch-scope format once mobile UX, bridge, Android, and iOS gates pass.

Prioritize by user demand and mobile-shell confidence:

| Tier | Formats | Behavior |
| --- | --- | --- |
| Tier 1 | ZIP, RAR extraction, 7z, TAR, GZIP, BZIP2 | List, test where possible, extract |
| Tier 2 | XZ, Zstd, TGZ, TBZ2, TXZ, split ZIP, multipart RAR extraction | List/extract with clear limitations |
| Tier 3 | ISO, DMG, CAB, ARJ, LHA/LZH, CPIO, WIM, XIP, executable/self-extracting archive containers | V2 exposure after ZManager-Core support and mobile-shell gates pass |
| Apple parity | AppleArchive / AAR, IPA, APPX, APK, JAR, XPI, CPGZ, CPT | Prioritize list/extract where core support exists because these are common in Keka's iOS promise |
| Create v2 | ZIP, encrypted ZIP, 7z, TAR, GZIP, BZIP2, Zstd, `.tzst` / tar+zstd, `.tzap`, AppleArchive / AAR where ZManager-Core exposes creation support | Create only where bridge support, password/encryption UX, progress, cancellation, verification, and destination commit are polished |
| Post-v2 candidates | Other writable formats not listed above | Add only through a future scope update after UX and tests cover edge cases |
| Out of scope | RAR creation, RAR repair | Use tzap for new recovery-aware archives |

The app should never claim support for a format in mobile UI unless tests prove that format works across listing, extraction, password behavior where applicable, cancellation, destination commit, and error normalization on both platforms. For launch-scope formats, missing proof blocks launch rather than becoming a hidden or experimental format gap.

## UX Design Principles

### Modern Native GUI Contract

ZManager Mobile should look like a modern native utility, not a desktop archive manager squeezed onto a phone. The interface should be calm, crisp, and tactile, with enough density for power users and enough guidance for casual users.

Android:

- Use Jetpack Compose with Material 3 components, color roles, typography, motion, and adaptive layout patterns.
- Use Android system document and share surfaces instead of custom fake file pickers.
- Use Material icons or a consistent icon set for archive, folder, warning, lock, search, filter, cancel, share, and destination actions.
- Support dynamic color where it improves platform fit, but keep warning, destructive, and success states semantically consistent.
- Provide phone, foldable, and tablet layouts; tablets should use split panes for archive tree plus details/actions.

iOS:

- Use SwiftUI with native navigation, sheets, toolbars, menus, context menus, and document interactions.
- Follow iOS spacing, typography, blur/material, motion, and haptic expectations without copying Android patterns.
- Support compact iPhone, large iPhone, iPad, split view, dark mode, and Dynamic Type.
- Use SF Symbols consistently for archive, folder, lock, warning, search, filter, cancel, share, and destination actions.
- Keep destructive and risky actions visually distinct but not alarming when no action is required.

Shared visual direction:

- Use Apple Human Interface Guidelines as the platform reference for iOS and iPadOS.
- Use Material Design 3 as the platform reference for Android.
- Use Documents by Readdle as the iOS polish benchmark for a file-centric utility, especially its approachable organization, preview, and Files/cloud integration posture.
- Use Files by Google / Material-style file surfaces as the Android benchmark for clean native density.
- Do not copy ZArchiver's visual language; offer comparable power through a cleaner, calmer, more modern interface.
- Prefer a restrained professional palette with strong semantic colors over a single-hue theme.
- Use cards only for repeated archive/file items or focused panels; avoid nested cards.
- Keep rounded corners subtle and consistent.
- Make the primary action obvious on every screen, but never hide risk details behind it.
- Keep archive paths readable with truncation from the middle when needed.
- Use compact metadata rows, status chips, and progressive disclosure for details.
- Provide polished empty, loading, error, warning, progress, cancellation, and completion states.
- Avoid decorative illustrations that distract from file information; visual polish should come from spacing, hierarchy, motion, iconography, and state clarity.

GUI acceptance criteria:

- No screen ships with placeholder text, dead buttons, or unhandled states.
- Text fits on small phones, large phones, and tablets with Dynamic Type / font scaling.
- Long filenames, long paths, and localized strings do not overlap controls.
- Primary flows are reachable with one hand on phones.
- Archive lists scroll smoothly with large entry counts through virtualization or incremental loading.
- Risk and completion summaries are understandable without reading diagnostics.
- Screenshots are reviewed in light mode and dark mode for Android phone, Android tablet, iPhone, and iPad before release.

### The App Should Feel Calm Under Pressure

Archive apps are often used when something already went wrong: a deadline, a broken download, a weird file from someone else, or a full phone. ZManager should avoid noisy chrome and show only the next useful decision.

Primary screens:

- Home: recent archives, open button, privacy/trust status.
- Archive detail: metadata, warnings, tree/list, actions.
- Plan review: destination, collisions, unsafe entries, size.
- Preview: selected file materialization through native renderers.
- Job progress: current work, cancel, background state.
- Batch queue: per-archive progress and summary.
- Completion: summary, open/share destination, report.
- Settings/help: default destinations, supported formats, licenses, automation help.

Required screen states:

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
- iCloud/cloud provider file unavailable
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

### Risk Labels

Use plain labels:

- Safe to extract
- Needs password
- Some files need review
- Extraction blocked
- Not enough storage
- Unsupported archive
- Damaged archive

Avoid dumping low-level errors into the main UI. Keep detailed diagnostics behind a copyable "Details" affordance with redaction.

### Extraction Confidence

After every job, answer:

- Did it finish?
- Where are the files?
- Were any files skipped?
- Did any filenames change for safety?
- What can I do next?

This directly targets a common pain in utility apps: progress stalls or unclear partial completion.

## Technical Architecture

ZManager Mobile keeps native UI and platform file access separate from archive behavior:

```text
Android Compose / iOS SwiftUI
  -> native picker, share, permission, cache, destination handling
  -> UniFFI DTO bridge
  -> zmanager-mobile-core
  -> zmanager-core
```

Native shells own:

- document pickers
- share/import flows
- permissions
- Android `content://` URI handling
- iOS security-scoped URL handling
- app lifecycle and background constraints
- user-facing presentation

Rust owns:

- archive detection
- listing
- integrity tests
- extraction planning
- extraction safety
- creation planning
- execution
- progress events
- cancellation
- normalized archive errors

## Mobile File Commit Architecture

The safest launch model is a two-phase file workflow:

1. Native shell resolves the user-selected input into an app-controlled readable source.
2. Rust lists, tests, plans, creates, or extracts using app-controlled paths.
3. Native shell commits final output to the platform destination.
4. Native shell presents the final destination or share/export action.

Why:

- Android `content://` URIs and SAF trees are not normal filesystem paths.
- iOS security-scoped URLs require native lifetime management.
- Cloud-backed providers can be slow, unavailable, revoked, or only partially downloaded.
- Native shells can present platform-specific recovery when a provider fails.
- Rust remains focused on archive correctness instead of platform document-provider behavior.

Launch destination policy:

- App-owned cache/files path: Rust may write directly.
- Android SAF destination: Rust writes to staging, Android commits through `ContentResolver` / document tree APIs.
- iOS security-scoped destination: Rust writes to staging, iOS commits while holding the security scope.
- Share/export destination: Rust writes to staging, native shell invokes platform share/export.

Cleanup policy:

- Planned extraction creates a job-specific staging directory.
- Successful commits delete staging immediately after completion summary and report data are captured.
- Cancellation before commit deletes staging immediately.
- Failed commits, permission failures, or provider failures retain staging for 24 hours, or until the user chooses retry, export elsewhere, or discard.
- Partial commits where external output may exist retain a recovery record for 7 days; staging is still deleted after 24 hours unless the user retries or exports it elsewhere.
- Cancellation during commit preserves a recovery record so the completion screen can explain partial output.

## Bridge Design

The bridge should stay small, DTO-oriented, and job-based.

Planned calls:

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

Important DTOs:

- `ArchiveHandle`: native-controlled local path, cache id, or file token.
- `ArchiveSummary`: type, entry count, size hints, encryption state.
- `ArchiveEntry`: path, normalized path, type, size, modified time, permissions, encrypted flag.
- `ArchiveWarning`: code, severity, path, message, recovery hint.
- `ExtractionPlan`: destination summary, selected entries, collisions, blocked entries, estimated size.
- `JobId`: opaque id for running work.
- `JobEvent`: progress, warning, error, completion, cancellation.
- `BridgeError`: normalized user-facing and diagnostic error.

Passwords:

- Use a dedicated password field in request DTOs.
- Represent passwords with a redacted secret type on both sides of the bridge where the language allows it.
- Never include passwords in `Debug`, `Display`, `toString`, logs, errors, analytics, diagnostics, screenshots, or crash reports.
- Clear password-bearing request objects as soon as practical, recognizing that FFI and managed-runtime copies may not be perfectly zeroizable.
- Do not cache passwords in Rust or native shells.
- Clear visible password UI on completion, cancellation, wrong-password dismissal, and app background timeout.
- Wrong-password retry should reuse the archive handle, not persist the previous password.
- If a short-lived in-memory retry token is ever added, make it opt-in, time-bounded, memory-only, and redacted from diagnostics.

Password tests:

- wrong password returns a normalized recoverable error
- password-required listing and extraction do not log the password
- crash-safe diagnostics exclude password fields
- app background clears transient native password state
- bridge errors and job events contain password-required metadata, never password values

## Android Platform Design

Input:

- Use `ACTION_OPEN_DOCUMENT` for user-picked archives.
- Use `ACTION_SEND` / `ACTION_VIEW` for open-with flows.
- Use `ContentResolver` to copy into app cache when random access is required.
- Prefer streaming only when zmanager-core can safely handle it.

Output:

- Use SAF tree/document APIs for external destinations.
- Use app cache or app files for intermediate extraction when destination writes cannot be random-access.
- Avoid broad storage permissions where modern Android provides scoped alternatives.

Background:

- Use an Android foreground service for long user-started archive jobs that may continue after the app is backgrounded.
- Keep archive detection, listing, planning, and small preview materialization foreground-only.
- Do not use WorkManager at launch for archive jobs; revisit it only for password-free resumable jobs with persisted manifests.
- Handle Android 15+ foreground-service timeout behavior in target SDK 35 tests.
- Keep job state recoverable enough that app backgrounding does not leave the user confused.

Android-specific tests:

- `content://` archive copy.
- revoked URI permission.
- SAF destination write.
- low storage.
- app background during extraction.
- cancellation during large file extraction.
- Android 8 through current target behavior.

## iOS Platform Design

Input:

- Use document picker for archive selection.
- Use share/import extension for "Open in ZManager."
- Start and stop security-scoped resource access around native file operations.
- Copy to app temporary storage when bridge calls require stable paths.

Output:

- Use document picker/export/share flows for destinations.
- Use app sandbox for in-progress work.
- Avoid holding security-scoped URLs across long bridge calls unless lifecycle handling is explicit.

Background:

- Treat long extraction as foreground-first at launch.
- Save enough state to explain partial output after interruption.
- Use iOS background APIs only after job semantics are tested.

iOS-specific tests:

- security scope opens and closes.
- iCloud file not downloaded locally.
- Files provider latency/failure.
- app suspended during extraction.
- share sheet import.
- cancellation during extraction.

## Security And Privacy Requirements

Non-negotiable:

- No ads.
- No telemetry or third-party analytics; feedback goes through GitHub issues.
- No password persistence.
- No password logging.
- No archive paths or filenames in crash reports unless the user explicitly exports diagnostics.
- No command-line password passing.
- No network dependency for local archive work.
- Safe extraction defaults.

Archive safety checks:

- parent traversal (`../`)
- absolute paths
- Windows drive paths and UNC-like paths
- duplicate output paths after platform normalization
- symlink and hardlink behavior
- device/special files
- invalid Unicode or platform-invalid names
- zip bombs / extreme expansion ratio where detectable
- deeply nested paths
- too many entries

Diagnostics:

- Provide a user-copyable report with redaction controls.
- Include app version, platform version, archive type, operation, error code, and warning codes.
- Exclude passwords always.
- Redact full paths by default.

## Launch Readiness Tracks

### Track 0: Bridge Reality

- Wire `zmanager-mobile-core` to `zmanager-core`.
- Replace placeholder `list_archive`.
- Add bridge tests for empty path, unsupported archive, password required, and damaged archive.
- Confirm supported format matrix from actual core behavior.
- Define the mobile format exposure matrix from ZManager-Core support plus mobile-shell quality gates.

### Track 1: Read-Only Workbench

- Android and iOS open archive.
- List entries.
- Search entries.
- Sort entries.
- Toggle folder tree and flat/grouped list.
- Password-required listing.
- Safety warnings.
- Test archive integrity.
- Preview selected common files through safe temporary materialization.
- Share/export selected entries where safe.
- Surface legacy filename charset warnings or choices where the bridge supports them.
- Modern archive detail UI with real loading, empty, warning, and error states.
- Screenshot review for phone and tablet layouts on both platforms.

Success metric: user can inspect real ZIP/RAR/7z archives on both platforms without platform code parsing the archive.

### Track 2: Safe Extraction

- Plan extraction.
- Choose destination.
- Collision handling.
- Extract all and selected.
- Batch extract multiple archives.
- Progress events.
- Pause/resume where bridge job semantics are safe.
- Cancellation.
- Completion summary.
- Save extraction reports.
- App-controlled staging and native destination commit.
- Default destination settings with graceful fallback when permissions are revoked.
- Recovery states for permission revocation, provider failure, low storage, partial commit, and cancellation.

Success metric: extraction is boring, accurate, and explainable even when files are skipped or renamed.

### Track 3: Create And Share

- ZIP, encrypted ZIP, 7z, TAR, GZIP, BZIP2, Zstd, `.tzst`, `.tzap`, and AppleArchive / AAR creation where bridge support is production-ready.
- Password/encryption only if implementation and UX are safe.
- Verify-after-compression.
- Archive items separately.
- Split-volume creation where bridge and destination commit behavior are safe.
- Photos picker input for compressing photos and videos.
- iPad drag/drop into the compression contents list.
- Share/export created archive.
- Save recent output destinations.
- Creation UI that makes format, encryption, destination, and output size understandable without desktop-style option overload.

Success metric: user can create a practical archive and send it without needing a desktop, while power users can choose modern ZManager/tzap formats deliberately.

### Track 4: Power And Polish

- AppleArchive / AAR, XIP, Keka-style app-container formats, and old filename charset handling after the relevant format gates pass.
- Shortcuts and X-Callback-URL automation with redacted, safe request validation.
- Background task support once interruption and partial-output behavior is proven.
- iPad multi-window and Android tablet/foldable two-pane layouts.
- VoiceOver, TalkBack, Dynamic Type, and font-scaling QA.
- release-quality onboarding, help, supported-format docs, and automation docs
- public UI strings, in-app claims, and docs agree

## Success Metrics

Product:

- 95 percent of successful extractions end with a visible destination action.
- Less than 2 percent of completed jobs produce user reports of "I do not know where my files went."
- Password-required archives have a successful retry path without app restart.
- Users can complete open-list-extract in under 30 seconds for a normal small archive.
- Keka-parity probes pass for selected preview/extract/share, verify-after-compression, split-volume guidance, batch extraction, default destinations, Photos input, drag/drop, and automation where exposed.

Reliability:

- No known password leaks in logs, diagnostics, crash reports, or persisted state.
- Cancellation leaves no unknown job state.
- Unsafe path test corpus passes on Android and iOS.
- Bridge behavior is consistent across platforms for the same archive corpus.
- Every launch-scope mobile format passes the mobile format quality gates and is exposed.
- Large archive listing stays responsive through virtualization or incremental loading.
- Extraction progress and cancellation never block the main UI thread.
- Pause/resume, where exposed, never leaves staging or destination state ambiguous.
- Platform provider failures produce recoverable, user-readable states.
- Staging cleanup is deterministic after success, cancellation, and failure.

GUI:

- Android and iOS each pass screenshot review for first launch, archive detail, warning, password, progress, completion, and error states.
- Light mode, dark mode, small phone, large phone, and tablet/iPad layouts are checked before release.
- Accessibility labels exist for icon-only actions.
- Dynamic Type / font scaling does not break primary flows.
- VoiceOver and TalkBack can complete the main open, inspect, extract, create, password, and completion flows.
- Long names and paths remain readable without overlapping actions.

Market Position:

- Extend beyond built-in tools by supporting Tier 1 non-ZIP extraction.
- Establish trust against generic unzip apps: no ads, no trackers, explicit safety plan.
- Offer archive-specific clarity beyond broad file managers: warnings, plans, progress, reports.
- Handle recovery positioning clearly by directing recovery-first users to tzap instead of over-promising generic repair.

## Launch Completion Criteria

ZManager Mobile can be called launch-ready when:

- every V2 adoption item is implemented, or any non-format scope change is intentionally documented with a bridge/platform reason
- supported-format claims, in-app labels, README/docs, and bridge behavior agree
- Android and iOS both pass the launch quality gates for every launch-scope format
- the create/extract/list/test flows cover the practical `zm` families exposed on mobile
- Keka-parity workflows pass probes for selected preview/extract/share, verify-after-compression, split-volume guidance, batch extraction, saved reports, default destinations, Photos input, drag/drop, and automation entry points where exposed
- `.tzap` recovery-oriented flows are clearly positioned and do not blur into generic repair claims
- no-prior-knowledge usability probes pass open, inspect, selected preview, extract, create, password, verification, batch extraction, and cancellation tasks
- screenshot QA passes for the required phone/tablet, light/dark, and state matrix
- app interruption, provider failure, cancellation, and staging cleanup have tested outcomes
- password and diagnostic redaction tests pass
- installation, first launch, share/open-with, and destination flows feel production-grade

## Resolved Product Decisions

- RAR extraction is allowed when provided through a license-compatible extraction-only path. RAR creation and RAR repair remain out of scope.
- Encrypted ZIP creation is launch scope and should match the behavior already available in `zmanager-cli`.
- Feedback should go through GitHub issues. Do not add telemetry or third-party analytics.
- Distribution should be open source, free, and Apache-2.0 licensed.
- iOS destinations should be comparable to leading archive/file apps: support app sandbox destinations first; support `On My iPhone` and iCloud Drive folder destinations after security-scope and staged-commit tests pass; use share/export fallback for third-party Files providers until that provider class passes the same tests.
- Archive preview should be comparable to leading archive/file apps: list archive contents, search/filter entries, preview common files through safe temporary materialization, and avoid becoming a full document/media suite.
- Keka is the iOS workflow benchmark for v2 breadth: browse, selected preview/extract/share, create, password, verify, split volumes, Photos input, drag/drop, automation, and native destination polish.
- Visual direction should be native and polished: Apple HIG plus Documents by Readdle on iOS/iPadOS; Material 3 plus clean Files-style surfaces on Android.

## Recommended Immediate Next Steps

1. Create high-fidelity native GUI direction for home, archive detail, preview, plan review, progress, batch queue, completion, password, warning, and error states.
2. Build a fixture corpus: normal ZIP, encrypted ZIP, RAR, 7z, TAR.GZ, AppleArchive / AAR, XIP, split archive, unsafe paths, legacy charset paths, duplicate normalized paths, and huge entry count.
3. Expand the UniFFI API to include normalized errors, warnings, preview materialization, planning, jobs, progress, pause/resume capability, cancellation, and reports.
4. Implement read-only listing on Android and iOS through native pickers, share/import flows, and cached local paths.
5. Implement the staging plus native commit model before broad external-destination extraction.
6. Add v2 parity tracks for verify-after-compression, archive-items-separately, split-volume creation, Photos input, drag/drop, batch extraction, reports, default destinations, and automation.
7. Decide and document the launch mobile exposure matrix from ZManager-Core support plus platform-shell tests.
