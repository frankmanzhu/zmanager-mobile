# Mobile Follow-up Implementation Plan

Last reviewed: 2026-08-14

## Purpose

This plan covers three important workflows that are not yet complete in the
mobile shells:

1. browsing an archive contained inside another archive;
2. creating a new archive from a native folder or from a folder selected inside
   an opened archive; and
3. sharing files and archives over a local network with LocalSend-compatible
   devices.

The plan extends [mobile-implementation-plan.md](mobile-implementation-plan.md)
and [mobile-launch-spec.md](mobile-launch-spec.md). It does not replace either
document.

## Architectural rule

Nested browsing and archive repackaging should compose existing Rust operations
first. LocalSend should be introduced as a separate transfer subsystem. Archive
parsing, listing, extraction, creation, testing, and extraction safety remain
Rust-owned; Kotlin and Swift own UI, navigation, platform file access, and
platform lifecycle.

Passwords remain transient UI/request state and must never be persisted, logged,
passed through command-line arguments, or included in diagnostics.

## Current repository state

The repository already has:

- archive import and platform cache handling;
- Rust-backed detection, listing, preview materialization, testing, and
  extraction flows;
- generated `planCreate` and `startCreate` bridge types;
- Android JVM tests and iOS unit tests for listing, preview, testing, import,
  and extraction coordination;
- existing Maestro workflows for archive import/listing/testing and extraction
  fixtures.

The implemented baseline now also includes nested archive navigation with back
navigation, Rust-composed archive-folder repackaging, LocalSend-compatible
send/receive sessions with checksum and traversal-safe receiver commits,
explicit trusted-device revocation, deterministic archive creation/extraction
Maestro flows, and redacted operation reports. The remaining work is
concentrated in reverse-transfer compatibility, lifecycle/background behavior,
provider permission instrumentation, format promotion beyond the pinned create
DTO, accessibility/device evidence, and broader edge-case E2E coverage. Failed
native extraction commits now retain redacted recovery records and expose
Retry/Export/Discard actions on both shells.

Implementation status for the current workstream:

- Rust-backed native archive creation is now wired through Android and iOS
  staging/coordinator/UI paths, including optional password input and
  verify-after-create reporting.
- Android and iOS nested session stacks, materialization, cleanup, breadcrumbs,
  Back navigation, and archive-entry actions are wired.
- Android and iOS archive-folder repackaging coordinators compose extraction
  into private staging followed by the existing create planner/job, with a
  native review checkpoint before the jobs start.
- Android and iOS have outbound LocalSend primitives with v2.2 metadata,
  multicast discovery, HTTP registration fallback, upload preparation,
  SHA-256 metadata, upload, cancellation, visible transfer cancellation, and
  transient PIN-required retry UX. Each send now requires an explicit
  device/address/fingerprint confirmation. Stable per-installation fingerprints
  can be explicitly remembered, listed in a Trusted devices section, and
  revoked with Forget; addresses and transfer credentials are never persisted.
  Both shells can share the active archive or arbitrary selected files, expose
  validated upload receivers with registration responses, and export validated
  incoming files to an Android SAF or iOS security-scoped destination while
  keeping receiver writes app-staged. LocalSend device fingerprints are now
  stable per app installation, and the user may persist an explicit fingerprint
  approval; every transfer still presents the device identity before sending.
- Multipart nested entries are explicitly rejected as single-file nested
  archives until volume grouping is implemented.
- Android long extraction and creation jobs now hand off to a non-exported
  `dataSync` foreground service with a notification cancel action, tokenized
  result broadcast, in-process password ownership, and terminal-result
  recovery records for the next Activity launch. The service now records only
  a non-secret active token/kind marker, converts a killed process into an
  `INTERRUPTED` result on the next service/Activity lifecycle, cancels on task
  removal, and stops before the Android 15 data-sync timeout boundary. The
  Android emulator process-death harness now force-stops the app during a paced
  extraction and verifies recovery on the next launch. The deterministic timeout
  flow remains separate from validation of the real Android 15 platform boundary.
- iOS creation now accepts Photos picker image/video selections and iPad
  document drag/drop into the creation staging path. Provider data remains
  app-staged before Rust creation.
- Deterministic nested and create/repackage fixtures are bundled in both
  shells. Nested browsing, native-folder creation, archive-folder
  repackaging, and receive-mode lifecycle Maestro flows pass on Android and
  iOS simulators. The encrypted nested fixture now exercises wrong-password
  retry through successful verified repackaging on both platforms. The pinned
  iOS bridge, coordinator handoff, native XCUITest, and iOS Maestro flow all
  pass for the same recovery path.
- Deterministic cancellation flows now exist at
  `maestro/android/extraction-cancellation.yaml` and
  `maestro/ios/extraction-cancellation.yaml`. They use debug-only pacing to
  hold a Rust job in the cancellable window, then assert the native cancelled
  state and cleanup path. Production operations do not use this pacing.
- Android also has a deterministic foreground-service timeout flow at
  `maestro/android/extraction-timeout.yaml`; the timed-out coordinator discards
  its staging and the UI exposes a retryable timeout message. iOS LocalSend
  uploads now report byte progress through `URLSession` delegate callbacks.
- Android and iOS native extraction commits now reject traversal and symlink-like
  paths outside the private staging root before writing platform destinations.
  Both shells also stop active LocalSend/repackaging work when entering the
  background, release selected-destination access, discard staged share files,
  and remove receive staging roots, with iOS lifecycle coverage in XCTest.
- Deterministic cancellation-cleanup harnesses now pass on the Android emulator
  and iOS simulator, leaving no committed final extraction files after a paced
  cancellation. This verifies the app-controlled cleanup path, not every
  production-size or OS-suspended job shape.
- Android has 44 JVM tests plus three ActivityScenario/instrumentation tests, and
  the iOS Xcode suite reports 44 passed unit/bridge/coordinator/UI tests.
  Controlled Android and iOS Maestro flows pass for nested browsing, archive repackaging,
  encrypted password retry, and receive lifecycle. A controlled LocalSend peer
  upload passes against Android through an adb-forwarded socket, and the iOS
  simulator runs the same validated upload path in XCTest.

Remaining launch work is reverse-download support if required, real Android 15
foreground-service timeout-boundary validation, deeper iOS interruption and
background-suspension hardening, native SAF/security-scoped and Photos picker
instrumentation, physical-device/device-matrix coverage, and production-size
large-job cancellation evidence. Simulator accessibility targets and responsive
wide-screen constraints are now wired; hardware TalkBack/VoiceOver and real
picker behavior still require device evidence.

## Track 1: Nested archive browsing

### User experience

- Show `Open archive` for supported archive-looking file entries.
- Use breadcrumbs such as `outer.zip / backups / inner.zip`.
- Support back, breadcrumb, and return-to-root navigation.
- Keep each archive level's listing state separate.
- Prompt separately for an encrypted inner archive.
- Disable the action for directories, unsupported files, and multipart entries
  that cannot be represented by a single materialized file.

### Implementation

Add a native archive-session stack. Each session should contain:

- a session ID;
- display name and source entry path;
- app-controlled local path;
- temporary cleanup root;
- listing/search/sort/selection state; and
- transient password state.

Opening a nested archive should:

1. call Rust `materialize_preview` for the selected file;
2. treat the materialized file as a new imported archive;
3. call `detect_archive` and `list_archive` on the new file;
4. push a new session; and
5. delete the materialized file when the session is popped or the whole flow
   ends.

The first version should support single-file nested archives. Multipart nested
archives require a separate volume-group representation and should not be
silently treated as complete archives.

### Tests

Add Android and iOS tests for:

- ZIP inside ZIP and ZIP inside TZAP;
- multiple nesting levels;
- back and breadcrumb navigation;
- cleanup after leaving a nested session;
- encrypted inner archives and wrong-password retry;
- unsupported or damaged inner archives;
- cancellation during materialization; and
- nesting and expansion limits.

Add Maestro coverage for opening a nested archive and returning to its parent.

## Track 2: Create an archive from a folder or archive folder

### Native folder flow

Android should use SAF folder selection and copy the selected tree into an
app-controlled staging directory. iOS should use security-scoped folder access
and copy or stage the selected tree. Both platforms must preserve user-visible
relative names separately from provider identifiers.

The native create coordinator should reuse:

```text
planCreate
startCreate
pollJobEvents
cancelJob
```

The UI flow is:

1. select files or a folder;
2. choose a supported output format;
3. choose output name and destination;
4. configure compression, encryption, and verification;
5. review the create plan and warnings;
6. start the cancellable create job; and
7. open, export, or share the completed archive.

The plan must show selected inputs, output format, estimated size when
available, encryption state, collisions, warnings, and verification support.

RAR creation remains unavailable.

### Folder inside an opened archive

The first implementation should compose existing Rust jobs:

```text
archive + selected folder
    -> plan_extract to private staging
    -> start_extract
    -> planCreate from staging
    -> startCreate
```

The staging directory must remain app-controlled and must never be exposed as
the user's final destination. Extraction safety, unsupported entries, links,
special files, and password handling continue to use the existing Rust bridge.

If profiling shows that the extra staging pass is too expensive, add a Rust
source variant for direct archive-entry streaming:

```text
CreateSource =
    LocalPaths(...)
  | ArchiveEntries {
        archivePath,
        selectedPaths,
        password
    }
```

This optimization should not be implemented in Kotlin or Swift.

### Tests

Add bridge, Android, and iOS coverage for:

- native folder to ZIP, 7z, and TZAP;
- encrypted ZIP creation;
- archive folder to a new archive;
- archive folder from a password-protected parent;
- empty folders;
- unsupported, special, symlink, and hardlink entries;
- output collision handling;
- cancellation during staging and creation;
- verify-after-compression; and
- cleanup after success, failure, and cancellation.

Add Android instrumentation and iOS UI tests for SAF and security-scoped folder
selection.

## Track 3: LocalSend-compatible local-network sharing

Use the [LocalSend Protocol v2.2 specification](https://github.com/localsend/protocol)
as the compatibility contract. The protocol defines multicast discovery, HTTP
registration fallback, metadata preparation, upload/download endpoints,
cancellation, and optional SHA-256 verification.

### Phase 3A: send to LocalSend devices

Implement outbound sharing first:

1. discover nearby devices over multicast UDP;
2. fall back to HTTP registration when multicast is unavailable;
3. show device alias, type, and connection details;
4. require explicit device selection and confirmation;
5. call `POST /api/localsend/v2/prepare-upload`;
6. upload each file with `POST /api/localsend/v2/upload`;
7. include SHA-256 where practical;
8. expose per-file and total progress; and
9. call `POST /api/localsend/v2/cancel` on cancellation.

The default protocol values are multicast address `224.0.0.167` and UDP/TCP
port `53317`, but the implementation must allow fallback/configuration because
local networks can block multicast or the default port.

### Phase 3B: receive from LocalSend devices

The current receive implementation covers LocalSend's upload API, where the
mobile app owns the HTTP receiver and another device sends files to it. It
must:

- advertise the app only while receiving is enabled;
- expose `download: true` only while the temporary receiver is active;
- ask the user for a destination before writing files;
- sanitize incoming names and reject traversal or unsafe paths; and
- remove incomplete files after cancellation, timeout, or process termination.

The reverse-transfer `prepare-download`/`download` API is a separate optional
compatibility phase and must not be conflated with upload receiving.

### Ownership and security

Rust should own protocol DTOs, hashing, transfer state, cancellation, and
normalized errors. Android and iOS should own socket lifecycle, network
permissions, foreground/background behavior, notifications, user confirmation,
and destination provider access.

LocalSend HTTP is local-network transport rather than end-to-end encryption.
The UI must identify the target device, support PIN-required flows, and clearly
communicate the network trust boundary. Prefer HTTPS when advertised by the
peer.

Never log file contents, passwords, transfer tokens, or sensitive paths.
Expire discovery records, transfer sessions, and temporary receive files.

### Tests

Add protocol-level tests for:

- LocalSend JSON serialization;
- multicast discovery and HTTP fallback;
- upload preparation and acceptance/rejection;
- single and multiple file uploads;
- checksum success and mismatch;
- PIN-required transfers;
- cancellation, timeout, and peer disappearance;
- receive/download behavior; and
- malicious filenames and incomplete-transfer cleanup.

Add device compatibility tests against the official LocalSend application on
the supported desktop and mobile platforms.

## Launch-spec gaps to close

Before calling the mobile launch specification complete, add explicit
requirements and acceptance criteria for:

- nested archive sessions and cleanup;
- create-from-native-folder;
- create-from-archive-folder;
- LocalSend outbound sharing;
- LocalSend inbound receiving, if it is included in launch scope;
- Android and iOS network permission/lifecycle behavior;
- platform-device compatibility tests; and
- the new Maestro and native UI test flows.

The existing launch specification also contains broader unfinished areas,
including native create UI, full instrumentation/XCUITest coverage, complete
destination commit behavior, background job handling, and several launch-format
quality gates. Those should be tracked separately rather than hidden inside
these three feature tracks.

## Recommended delivery order

1. Finish the bridge and native create coordinator around the existing create
   DTOs.
2. Implement nested archive session navigation using preview materialization.
3. Implement archive-folder repackaging through staged Rust extraction and
   creation.
4. Add Android instrumentation, iOS UI, and Maestro coverage for those flows.
5. Implement LocalSend outbound discovery and upload.
6. Add LocalSend receive/download support.
7. Add background transfer behavior and cross-device compatibility testing.

## Definition of done

- No archive parsing or archive safety logic exists in Kotlin or Swift.
- Nested archive sessions clean up temporary files deterministically.
- Folder and archive-folder creation always has a reviewable plan before final
  output is written.
- Creation, extraction, and transfer jobs expose progress, cancellation, and
  terminal states.
- LocalSend interoperability is verified against at least one external
  LocalSend client on each mobile platform.
- Passwords and transfer credentials are absent from logs, diagnostics, and
  persistent state.
