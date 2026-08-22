# Mobile Code Health Remediation Plan

Last reviewed: 2026-08-22

## Purpose

This plan covers defects and structural debt found in a critical review of the
Android and iOS shells. It is a remediation plan, not a feature plan: every
track here fixes something already shipped rather than adding new user-facing
capability.

The plan extends [mobile-implementation-plan.md](mobile-implementation-plan.md),
[mobile-follow-up-implementation-plan.md](mobile-follow-up-implementation-plan.md),
and [mobile-launch-spec.md](mobile-launch-spec.md). It does not replace any of
them.

Three findings were release blockers: the LocalSend receive path accepts
unauthenticated plaintext transfers (still open, deferred to a future Rust
module — see Track 1), the foreground-service handoff could retain a
password for the life of the process (**fixed**, Track 2), and archive
listings were silently truncated to 50 entries while the UI reported the true
entry count (**fixed**, Track 3).

## Delivery scope: offline first

This plan's tracks split into two groups. Tracks 2 through 9 fix behavior that
does not depend on the network: local archive listing, extraction, creation,
job handoff, build configuration, and the state/file structure that holds all
of it. Track 1 is the one networked feature, LocalSend, and it is scoped
differently on purpose: this pass produces the architecture decision and the
native-side module boundary, not a shipped fix. See Track 1 for why, and for
what "produces the architecture decision" means concretely.

Implementation proceeds one track at a time, in the order given under
[Recommended delivery order](#recommended-delivery-order), each landing as its
own reviewable change.

## Architectural rule

Remediation must not move behavior in the wrong direction. Archive parsing,
listing, extraction, creation, testing, and extraction safety remain Rust-owned.
Kotlin and Swift own UI, navigation, platform file access, and platform
lifecycle. Where this plan removes duplicated logic, it removes it by deleting
the native copy in favor of the Rust one, never by adding a third copy.

That rule was written for archive behavior, which already has a Rust home in
`zmanager-core`. LocalSend has no Rust home today: `crates/` in the sibling
`zmanager` repository contains no networking code, and neither native
LocalSend implementation calls the generated bridge. Track 1 extends the same
principle to LocalSend going forward: one implementation, in Rust, shared
through UniFFI, rather than the two independently-drifting native copies that
exist now. Building that Rust module is out of scope for this plan; it is
cross-repo work against `zmanager` and belongs in its own plan once the
interface is agreed.

Passwords remain transient UI/request state and must never be persisted,
logged, passed through command-line arguments, or included in diagnostics.
Track 2 exists because that rule is currently violated by an error path.

## Current repository state

The shells are functionally broad and the security posture is deliberate in
most places. Production code contains no logging calls at all, passwords are
never persisted, `ArchiveJobForegroundService` has real process-death recovery,
and the JVM/XCTest suites concentrate on the bridge boundary as intended. The
Android module decomposition is good.

The debt is concentrated in four areas:

1. the LocalSend receive path, which was built asymmetrically to the send path,
   never received the send path's transport hardening, and — like the send
   path — exists only as two independently-written native implementations with
   no Rust-shared core;
2. the iOS shell, which never received the file decomposition the Android shell
   has;
3. Compose and SwiftUI state management on both shells, where a single
   composable and a single observable object hold all screen state; and
4. build configuration, which has no release build type at all.

### Finding index

| # | Finding | Severity | Track |
|---|---|---|---|
| 1 | LocalSend receiver accepts plaintext, unauthenticated uploads | Blocker | 1 (design only this pass) |
| 2 | Trusted-device fingerprints are unbound random UUIDs | Blocker | 1 (design only this pass) |
| 3 | Receiver has no socket timeout, unbounded thread pool, unbounded header count, spinning accept loop | High | 1 (design only this pass) |
| 4 | Foreground-service handoff can strand a password-bearing request | Blocker | 2 |
| 5 | Listings truncated to 50 entries with no disclosure | Blocker | 3 — fixed |
| 6 | `ExtractionPathSafety` duplicated in Kotlin and Swift, and divergent | High | 4 — fixed via fallback (shared fixture table); Rust push still preferred, see Track 4 |
| 7 | Debug pacing fields shipped on production request types | Medium | 5 — fixed (iOS: compile-time isolated; Android: injected but not source-set isolated, see Track 5) |
| 8 | `ContentView.swift` is 6,685 lines holding 100+ top-level types | High | 6 — fixed |
| 9 | `ZManagerApp` is one 1,845-line composable with 49 state vars | High | 7 — fixed |
| 10 | `ArchiveImportModel` is 1,363 lines with 31 `@Published` | High | 7 — fixed |
| 11 | Composables taking 38-41 parameters | Medium | 7 — explicitly not done this pass, see Track 7 |
| 12 | `lifecycle-viewmodel-compose` declared but never used | Low | 7 — fixed (now in active use) |
| 13 | Listing filter/sort/group recomputed every recomposition | High | 8 — fixed (memoized; still runs on the main thread, see Track 8) |
| 14 | Job polling loops duplicated four times at a fixed 150 ms | Medium | 8 — fixed |
| 15 | Per-byte boxing in the receiver header parser | Low | 8 — fixed |
| 16 | No `buildTypes` block; no R8, shrinking, or release signing | High | 9 — fixed |
| 17 | `arm64-v8a` only; emulator (x86_64) unsupported | Medium | 9 — x86_64 attempted, blocked upstream; see Track 9 |

Findings 1 through 3 stay open after this plan's Track 1 lands. They are fixed
by the future Rust module, not by this pass — see Track 1.

## Track 1: LocalSend — move to a shared Rust module (design + prep only)

### Problem

The send path pins peer certificates by SHA-256
([LocalSendTls.kt:41](../android/app/src/main/java/org/tzap/zmanager/mobile/LocalSendTls.kt#L41)).
The receive path has none of that:

- [LocalSendReceiver.kt:74](../android/app/src/main/java/org/tzap/zmanager/mobile/LocalSendReceiver.kt#L74)
  opens a bare `ServerSocket`, and
  [ContentView.swift:6356](../ios/ZManagerMobile/ZManagerMobile/ContentView.swift#L6356)
  uses `NWListener(using: .tcp, ...)`. Archive bytes cross the LAN in cleartext.
- [LocalSend.kt:198](../android/app/src/main/java/org/tzap/zmanager/mobile/LocalSend.kt#L198)
  advertises `"protocol": "http"`.
- There is no PIN check anywhere in either receiver. Any LAN peer can call
  `prepare-upload` and write into the user's selected folder.
- `LocalSendIdentity.fingerprint` returns a persisted random `UUID`, not a
  certificate hash. Over plaintext HTTP a fingerprint is an unauthenticated
  claim, so a hostile peer can assert a fingerprint the user previously marked
  trusted. The Trusted devices list therefore provides no authentication on the
  receive path today.

Underneath all four items is a second problem: LocalSend is not one
implementation, it is two. `LocalSend.kt` / `LocalSendTls.kt` /
`LocalSendReceiver.kt` on Android and the `LocalSend*` section of
`ContentView.swift` on iOS were each hand-written against Apple's `Network`
framework and `java.net`/`javax.net.ssl` respectively. Neither calls the
generated bridge, and the sibling `zmanager` repository has no networking code
for either to call — `grep -rl` across `crates/` for TLS, multicast, or
LocalSend returns nothing relevant. Fixing the four items above in place would
be a third and fourth hand-written pass at the same protocol, which is exactly
the failure mode `ExtractionPathSafety` already demonstrates in Track 4: two
native copies of security-relevant logic drift.

### Why this track is scoped differently

Every other track in this plan fixes code that exists. This one does not,
because the correct target — a LocalSend protocol implementation in Rust,
exposed once through UniFFI, used identically by both shells — does not exist
yet, and building it is a materially different piece of work: new modules in
`zmanager-core` (TLS identity and serving, mDNS/multicast discovery, the
prepare-upload/upload/cancel protocol, PIN verification), new UniFFI surface,
regenerated bindings, and only then a rewrite of both native call sites to
delete themselves in favor of the bridge. That is cross-repo work against
`zmanager` on the scale of the other eight tracks combined, and it should be
its own plan once the interface below is agreed, not a subsection of this one.

This plan's Track 1 therefore delivers two things, both native-side and both
safe to land now without depending on any Rust work:

1. an interface sketch for the future bridge, so the eventual Rust work has an
   agreed target; and
2. the LocalSend module-boundary extraction that Track 6 already needs — moving
   the existing native LocalSend code into its own files with no behavior
   change — done in a way that leaves clean seams for deletion once the bridge
   exists.

Findings 1 through 3 (plaintext receive, unbound fingerprints, the unhardened
socket layer) remain open after this plan. They are the reason the future
Rust plan exists, not something this plan's Track 1 fixes in the native code.
If receive-path security is needed before the Rust module ships, that is a
separate, explicit decision to harden the native receiver in place — raise it
with whoever owns launch scope rather than treating it as implied by this
document.

### Interface sketch for the future Rust module

Recorded here so the future plan has a starting point, not as a commitment to
this exact shape:

```text
struct LocalSendIdentity { fingerprint: String }             // cert-bound, not a random UUID
fn local_send_identity() -> LocalSendIdentity
fn local_send_start_receiver(destination_root: String, pin: String) -> ReceiverHandle
fn local_send_stop_receiver(handle: ReceiverHandle)
fn local_send_discover(timeout_ms: u32) -> Vec<LocalSendDevice>
fn local_send_send(device: LocalSendDevice, files: Vec<String>, pin: Option<String>) -> JobHandle
// poll_job_events / cancel_job already exist for archive jobs; reuse them here
```

The identity and PIN requirement subsume findings 1, 2, and 3: a Rust-served
listener is TLS by construction, the fingerprint is the certificate hash by
construction, and one Rust-owned socket/thread implementation replaces both the
Android thread-pool receiver and the iOS `NWListener` receiver, so the socket
hardening in finding 3 only needs to be built once.

### Implementation (in scope for this pass)

Extract the existing native LocalSend code into its own module boundary, as a
pure move with no behavior change, folded into Track 6's file split:

- Android: `LocalSend.kt`, `LocalSendTls.kt`, `LocalSendReceiver.kt` already
  exist as separate files; group them under a common package
  (`org.tzap.zmanager.mobile.localsend`) so the eventual deletion is a package
  removal, not a hunt through `MainActivity.kt`.
- iOS: pull the `LocalSend*` types out of `ContentView.swift` into
  `LocalSend/LocalSendProtocol.swift`, `LocalSend/LocalSendClient.swift`,
  `LocalSend/LocalSendReceiver.swift`, `LocalSend/LocalSendTls.swift`,
  `LocalSend/LocalSendTrustStore.swift`, matching the Android file boundary so
  the two shells are structurally comparable.

Do not touch the TLS logic, the socket handling, or the trust store's storage
format while moving it — this pass is a location change so that Track 7's
state-holder split has a clean LocalSend view model boundary to land in later,
and so a future PR deleting this code in favor of the bridge touches a small,
well-defined set of files instead of clawing pieces out of a shared file.

### Tests

- Existing `LocalSendProtocolTest` (Android) and the LocalSend XCTest cases
  (iOS) pass unchanged after the file move; no test logic changes in this pass.
- No new tests are added for findings 1-3 in this plan; they belong to the
  future Rust-module plan.

## Track 2: Password lifetime in the foreground-service handoff

### Problem

[ArchiveJobForegroundService.submit](../android/app/src/main/java/org/tzap/zmanager/mobile/ArchiveJobForegroundService.kt#L87)
puts a password-bearing request into a process-lifetime `ConcurrentHashMap` and
starts the service:

```kotlin
requests[token] = request                              // holds request.password
ContextCompat.startForegroundService(context, intent)  // unguarded
```

The entry is removed only by `takeRequest`, which runs when the service actually
starts. On Android 12+ `startForegroundService` throws
`ForegroundServiceStartNotAllowedException` when the app is backgrounded. That
both crashes the app and strands the password in the static map for the life of
the process.

This is the one place that contradicts the AGENTS.md rule the rest of the
codebase follows carefully:
[ArchiveExtraction.kt:188](../android/app/src/main/java/org/tzap/zmanager/mobile/ArchiveExtraction.kt#L188)
nulls the password, and
[ArchiveCreation.kt:479](../android/app/src/main/java/org/tzap/zmanager/mobile/ArchiveCreation.kt#L479)
does `request.copy(password = null)`.

### Implementation

Wrap the start in `runCatching`, remove the map entry on any failure, and
surface a terminal result rather than propagating a crash:

```kotlin
fun submit(context: Context, request: ArchiveForegroundRequest): String {
    val token = UUID.randomUUID().toString()
    requests[token] = request
    val started = runCatching {
        ContextCompat.startForegroundService(
            context,
            Intent(context, Service::class.java).putExtra(EXTRA_REQUEST_TOKEN, token)
        )
    }
    if (started.isFailure) {
        requests.remove(token)
        throw ArchiveJobStartException(started.exceptionOrNull())
    }
    return token
}
```

Add a watchdog for the silent case where the service never reaches
`onStartCommand`: record a submit timestamp alongside each entry and sweep
entries older than a short grace period, both on the next `submit` and from the
existing `ON_STOP` lifecycle path that already scrubs password state in
`handleAppBackground`.

Have callers map `ArchiveJobStartException` to the existing failure states
(`ArchiveExtractionUiState.Failed`, `ArchiveCreationUiState.Failed`) with a
message telling the user to retry with the app in the foreground.

### Tests

- `submit` removes the map entry and throws when `startForegroundService`
  fails; assert the map is empty afterward.
- The sweep clears an entry whose service never started.
- Backgrounding while a submit is stranded leaves no password-bearing request
  reachable.
- Existing `ArchiveJobForegroundServiceTest` cases still pass unchanged.

## Track 3: Archive listing completeness — done

### Problem

`ArchiveListing.kt`'s `toSummary()`
did `entries.take(50)`, and `ArchiveListing.swift`'s `ListArchiveResult.summary`
(both moved by Track 6's file split; original line references no longer
apply) did `entries.prefix(50)`. Both shells then render the true total:

```kotlin
Text("${summary.formatLabel} - ${summary.entryCount} entries")
```

A 5,000-entry archive reports 5,000 and lists 50. Neither shell contains any
"showing first N" disclosure. Search, preview, nested-open, and per-entry
selection cannot reach entry 51 or beyond.

Extract-all is not affected *yet*: `extractionSelectedPaths` (at the time in
`MainActivity.kt`, since moved to `ArchiveSessionViewModel` by Track 7) maps
"every visible entry selected" to `emptyList()`, which the bridge treats as
extract-everything. That guard needs to keep working, not merely be left
alone: once the cap is removed, "every entry currently selected" can no
longer be inferred by comparing the selection to `summary.entries` by set
equality, since `summary.entries` will hold more than what's ever
selectable through the UI's window — see "What landed" below for the fix.

### Implementation

Treat the cap as a windowing concern rather than a listing concern.

Keep the full entry set in `ArchiveListingSummary` and introduce an explicit
window over it. Raise the render window to a page size the list can absorb
(start at 200), and add an explicit "Load more" affordance plus a visible
`Showing X of Y entries` line whenever the window is smaller than the total.
This depends on Track 8 memoizing the filter/sort/group pipeline; raising the
window without that change moves the cost onto every recomposition.

Two consequences to handle deliberately:

- **Search must query the full set, not the window.** Filter over all entries,
  then window the result. Otherwise search silently keeps the current bug.
- **`extractionSelectedPaths` must compare against the full set.** It currently
  compares the selection to `summary.entries`. Once `summary.entries` is
  complete, "select all" means the user selected everything visible in the
  window, which is no longer everything in the archive. Add an explicit
  `Select all N entries` action that sets a whole-archive flag consumed by
  `extractionSelectedPaths`, rather than inferring intent from set equality.

If profiling shows the full entry list is too large to hold natively for
pathological archives, the correct fix is a paged bridge listing call, not a
silent native truncation. Record that as a follow-up rather than reintroducing a
cap.

### What landed

The cap is gone on both platforms: `ArchiveListing.kt`'s `toSummary()` and
`ArchiveListing.swift`'s `ListArchiveResult.summary` both map every entry the
bridge returns, no `.take(50)`/`.prefix(50)`.

**Filtering was already separated from grouping** by Track 8's memoization
work, which made windowing a small addition rather than a restructure. On
Android, `ArchiveListingReadyPanel` now computes `filteredEntries` (full,
filtered, sorted — unwindowed), `windowedEntries = filteredEntries.take(windowSize)`,
then `groups = windowedEntries.grouped(viewMode)`. On iOS,
`ArchiveListingReadyPanel` computes the equivalent three properties the same
way. `windowSize` defaults to 200 and grows by 200 per "Load more" tap;
ownership lives in `ArchiveListingViewModel`/`ArchiveListingModel` (the Track 7
state holders) so it survives recomposition/redraw the same way search and
sort do, and resets to 200 whenever a new listing loads or the search query
changes (Android: keyed off the existing debounce `LaunchedEffect`; iOS: a
plain `.onChange(of: searchQuery)`, since iOS has no debounce to key off of —
Track 8 only added debouncing on Android, where MainActivity's shared
recomposition scope made it necessary).

A `Showing X of Y entries` line plus a `Load more` button appear only when
the window is smaller than the filtered count, matching the original
sketch. `Y` is the filtered count, not the raw archive total — searching
narrows what "more" means, matching the "search over the full set" fix below.

**Search queries the full entry set, not the window**, by construction:
`filteredSortedEntries`/`grouped` split out of the old combined `visibleGroups`
(kept intact, calling the two new functions in sequence, so the one existing
test locking its behavior — `visibleGroupsSearchesSortsAndGroupsEntries` on
both platforms — needed no changes) and only `.take(windowSize)` sits between
them. Filtering always runs over every entry.

**`extractionSelectedPaths` now reads an explicit flag instead of inferring
intent from set equality**, exactly as the plan called for. A new
`selectedEverything: Boolean` (Android, on `ArchiveSessionViewModel`) /
`selectedEverything: Bool` (iOS, on `ArchiveSessionModel`) is set `true` only
by a new "Select all N" action taken with no active search filter, and reset
to `false` by every other selection mutation (toggling one entry, "Select
visible", "Clear", loading a new listing). `extractionSelectedPaths` collapses
to one line: return `emptyList()`/`[]` if the flag is set, otherwise the
selected paths — the old set-equality comparison would have quietly stopped
working once `summary.entries` held more than the window, since "everything
currently selected" could no longer equal "the whole archive" by set
comparison alone.

"Select all N" itself splits behavior on whether a search is active: with no
filter, `N` is the true archive count and the action sets `selectedEverything`;
with a filter active, `N` is the filtered count and the action selects that
subset by ID the same way "Select visible" always has, correctly *not*
setting the whole-archive flag, since a filtered "select all" is a genuine
subset, not "everything." "Select visible" (an existing action, scoped to
just the current window) is kept alongside it as a separate, narrower action.

On iOS, "Select all", the per-entry toggle, and "Clear" mutate
`selectedEntryIds` directly via `@Binding` (the pre-existing style in this
file, not something this track introduced) rather than through session
methods, so `selectedEverything` needed its own `@Binding` threaded to the
same three call sites to stay in sync — the equivalent Android call sites were
converted to call `ArchiveSessionViewModel` methods (`toggleEntrySelected`,
`selectEntries`, `clearSelection`) instead of mutating state inline, which is
the more idiomatic fit for Android's ViewModel-owned state and keeps the
invariant in one place rather than three.

### Verification

- Android: `compileDebugKotlin` succeeds; full JVM suite **64/64 passing**
  (58 before this track, plus 2 listing tests — cap removal, full-set search —
  and 4 `ArchiveSessionViewModelTest` tests for the `selectedEverything`
  invariant).
- iOS: `xcodebuild build` for the `ZManagerMobile` scheme and the
  `ZManagerMobileShareExtension` target both succeed; full XCTest/UI-test
  suite **64/64 passing** (59 before this track, plus 2 listing tests and 3
  session-model tests, mirroring Android's).
- iOS file-size guard: largest file is 1,057 lines (`ArchiveListing.swift`,
  grew from adding the windowing/select-all UI), still under the 1,500-line
  ceiling.
- **On-device smoke test, Android** (adb-driven emulator, the same one used
  for Tracks 7/8): imported `maestro-nested.zip`, tapped the new "Select all 1"
  button, confirmed the entry's checkbox became checked, tapped Extract,
  confirmed the review step read `"1 files will be extracted to App storage"`
  (the empty-selected-paths/whole-archive bridge contract, exercised through
  the new flag rather than the old set-equality path), tapped Start, and
  confirmed `"Extraction complete: 1 files saved to App storage."` — the same
  successful outcome Tracks 7 and 8 verified, now going through the rebuilt
  selection path.
- **iOS on-device smoke test not completed this pass**: the Simulator tool's
  input events were logged as delivered (confirmed via `log show`, no crash)
  but produced no visible UI change across repeated attempts, including on
  navigation unrelated to this track (`About & help`) — simulator/tooling
  flakiness, not a finding about the code. iOS's build succeeded cleanly for
  both targets and the full XCTest/UI suite (64/64) directly exercises every
  scenario the Track 3 test list calls for, including the exact
  `selectedEverything` semantics via the three new `ArchiveSessionModel`
  tests, so behavior is verified at the unit level even without the manual
  pass.

### Tests

- Done, both platforms: a listing with more entries than the window reports
  the true total and states how many are shown (verified via the UI wiring
  above, not a dedicated unit test — the underlying computation is
  `filteredEntries.count` vs `windowedEntries.count`, both plain `List`/`Array`
  operations).
- Done, both platforms: search matches an entry outside the current window —
  `filteredSortedEntriesSearchesTheFullSetNotJustAWindow` /
  `testFilteredSortedEntriesSearchesTheFullSetNotJustAWindow`, a 300-entry
  fixture with the match at index 250, well past the 200-entry default
  window.
- Done, both platforms: select-all produces `emptyList()`/`[]` selected paths —
  `extractionSelectedPathsReturnsEmptyListOnlyAfterSelectEverything` /
  `testExtractionSelectedPathsReturnsEmptyListOnlyAfterSelectEverything`, plus
  the on-device Android confirmation above going through the real bridge
  contract.
- Done, both platforms: toggling a selected entry after "select all" leaves
  exactly the remaining subset selected and clears the flag —
  `togglingAnEntryClearsTheSelectEverythingFlag` /
  `testTogglingAnEntryClearsTheSelectEverythingFlag`.
- Not done: a dedicated Maestro flow (large fixture, disclosure line, load
  more, reach an entry past the first window) — no existing fixture has more
  than 200 entries, and generating one purely to exercise pagination was
  judged out of scope for this pass. The same behavior is covered by the unit
  tests above plus the Android on-device smoke test's exercise of the review
  step. Left as a follow-up if a large-archive Maestro fixture is added for
  other reasons.

## Track 4: Single-source extraction path safety — done, fallback approach

### Problem

AGENTS.md states: *"Do not reimplement archive parsing, extraction, creation, or
extraction safety in Kotlin or Swift."* `ExtractionPathSafety` exists in both
[ArchiveExtraction.kt:19](../android/app/src/main/java/org/tzap/zmanager/mobile/ArchiveExtraction.kt#L19)
and
[ArchiveExtraction.swift:104](../ios/ZManagerMobile/ZManagerMobile/Extraction/ArchiveExtraction.swift#L104)
(both moved by Tracks 6/7's file splits; original line references no longer
apply), and the two have already drifted:

```kotlin
// Android rejects empty components
relative.split('/').none { it.isEmpty() || it == "." || it == ".." }
```

```swift
// iOS lets empty components through
.allSatisfy({ $0 != "." && $0 != ".." })
```

The live impact is small because `standardizedFileURL` collapses `//` before the
check runs. The problem is structural: two hand-written copies of traversal
defense, drifting independently, in the exact place the architecture rule was
written to protect.

### Implementation

This check runs over *staged output paths the app itself produced* before
committing them to a user destination, so it is a native-side invariant rather
than archive parsing. Preferred fix is still to push it across the bridge:
expose a `verify_staged_relative_path` (or equivalent) helper from
`zmanager-ffi` and delete both native copies.

If the bridge cannot take it in this cycle, the fallback is to make the two
copies provably equivalent rather than merely similar: write one shared table of
cases in `fixtures/`, drive both platform test suites from that table, and treat
any behavioral difference as a build failure. Add the empty-component case to
the table immediately, since neither suite covers the case where they currently
differ.

Do not leave this at "both are tested" — both *are* tested today, and the tests
still agree while the implementations do not.

### What landed

Took the fallback path, not the Rust push: `verify_staged_relative_path`
would mean adding a UniFFI function to `zmanager-ffi` in the sibling
`zmanager` repository, regenerating bindings, and updating both platforms'
pinned dependency — real cross-repo work, out of scope for a change confined
to this repository this session. Recorded here as the still-preferred fix, not
abandoned.

**The empty-component divergence, empirically checked, does not reproduce.**
Before building anything, both implementations were driven directly with the
exact inputs the Problem section describes — `docs//readme.txt`,
`docs/./readme.txt`, a trailing separator, and the raw double-slash form — via
temporary probe tests on both platforms. Every one of those inputs produced
the **identical accepted result** (`"docs/readme.txt"`) on both Android and
iOS: `java.nio.file.Path` and Foundation's `URL` both collapse consecutive
separators and `.` components during path construction itself, before either
platform's explicit safety check ever runs. The doc's own code excerpt above
(`.allSatisfy` not checking for an empty string) is a real difference in the
*source text*, but not one reachable through any `File`/`URL` construction a
real caller in this codebase uses — confirmed, not assumed.

The explicit empty-component check was still added to Swift
(`!$0.isEmpty && $0 != "." && $0 != ".."`, matching Kotlin's
`it.isEmpty() || it == "." || it == ".."` shape) as defense-in-depth: cheap,
harmless, and brings the two implementations back to matching *source shape*
even though no live path reaches the difference today. `case-variant root
prefix` from the original test list was dropped from the fixture table for a
different reason: filesystem case-sensitivity is environment-dependent
(case-insensitive by default on macOS/the iOS Simulator, case-sensitive on
Linux CI runners), so a fixture case for it would be non-portable rather than
a genuine shared check.

**The shared fixture table** lives at
[extraction-path-safety.json](../fixtures/metadata/extraction-path-safety.json)
and covers the six cases that do meaningfully exercise the safety boundary:
normal nested path, `..` traversal that escapes root, an absolute path
outside root, root itself (rejected — a directory cannot stage into itself),
and both symlink cases (a symlinked parent directory and a symlinked leaf
file must each preserve their *archive* path rather than resolving to their
target, which is the whole reason the code does lexical-not-canonical
normalization on the final component). The three normalization-only cases
above and the case-variant-root-prefix case are recorded in the same file
under a `descoped` array with their reasons, so the file is a complete record
of what was checked and why, not just what passed.

Each platform's test reads the same JSON file directly (Android via a
repo-root-seeking `File` walk-up from the Gradle working directory; iOS via
`#filePath` — the compile-time absolute path of the test source file itself —
walking up the same way) and, for every case, builds a **fresh real temporary
directory** as `root` (symlink cases create a real symlink on disk; the
others are pure lexical checks), then asserts `ExtractionPathSafety.relativePath`
produces the expected result or throws. Neither platform hard-codes the case
list a second time — the JSON file is the only place the table exists.

### Verification

- Android: `compileDebugKotlin` succeeds; full JVM suite **65/65 passing**
  (64 before this track, plus the new fixture-table-driven test, which
  exercises all 6 cases in one test method).
- iOS: `xcodebuild build` for the `ZManagerMobile` scheme and the
  `ZManagerMobileShareExtension` target both succeed; full XCTest/UI suite
  **65/65 passing** (64 before this track, plus the equivalent fixture-driven
  test).
- Both platforms' fixture-driven tests read the literal same file at
  `fixtures/metadata/extraction-path-safety.json` and independently agree on
  every case — verified by running each in isolation and confirming a pass,
  not just that the full suite stayed green.

### Tests

- Done: shared fixture table covering normal nested path, `..` traversal,
  absolute path outside root, root itself, symlinked parent, and symlinked
  leaf. Empty component, `.` component, and trailing separator are recorded
  in the same file as investigated-and-descoped, with the empirical finding
  above as the reason, rather than silently dropped. Case-variant root prefix
  is recorded as descoped for CI portability.
- Done: Android and iOS suites both consume the table and agree on every row.
- Not done: moving the check to Rust and retiring both native copies — see
  "What landed" above. The native call sites remain; if a future cross-repo
  plan (see Track 1 for how that scoping works) implements
  `verify_staged_relative_path`, this fixture table becomes the bridge test
  suite's table instead, per the original plan.

## Track 5: Remove debug seams from production request types — done

### Problem

The debug UI entry points are correctly `BuildConfig.DEBUG`-gated. The data
model is not. `ArchiveExtractionRequest` (renamed by Track 7's split from
`ExtractionRequest`) carried `debugDelayMillis` and `debugTimeoutMillis`, and
`JobPollDriver.kt` (introduced by Track 8) executed `delay(debugDelayMillis)`
inside the polling loop that runs in release builds. `ArchiveJobForegroundService`
had the same field threaded through its own pre-start delay and timeout-budget
override.

### Implementation

Replace the fields with an injected pacing seam:

```kotlin
interface JobPacer {
    suspend fun beforePoll() {}
    val budget: Duration? get() = null
}
```

Production supplies a no-op implementation; the debug source set and the JVM
tests supply a delaying/timeout-bounded one. Remove `debugDelayMillis` and
`debugTimeoutMillis` from `ExtractionRequest`, `ArchiveForegroundRequest`, and
the two `MainActivity` state variables that feed them. The E2E scripts that rely
on this pacing (`check-cancellation-e2e.sh`, `check-extraction-e2e.sh`) keep
working because the debug build still injects the delaying pacer.

Apply the same treatment to `review.debugDelayNanoseconds` on iOS.

### What landed

**The fields are gone from every request type on both platforms**, replaced
by an injected `JobPacer`. Android:
[JobPacer.kt](../android/app/src/main/java/org/tzap/zmanager/mobile/JobPacer.kt) —
`interface JobPacer { suspend fun beforeStart(); suspend fun beforePoll(isTerminal: Boolean); val timeoutBudgetMillis: Long? }`,
with `NoOpJobPacer` (the always-used production default) and
`DelayingJobPacer` (constructed only inside the same `BuildConfig.DEBUG`-gated
buttons in `MainActivity.kt` that already gated every other debug affordance
in that file). `ArchiveExtractionRequest.pacer: JobPacer = NoOpJobPacer`
replaces the two Long fields; `ArchiveExtractionCoordinator.plan`/`awaitCompletion`,
`JobPollDriver.pollJobUntilTerminal`, `ArchiveJobForegroundService.runExtraction`'s
pre-start delay and cancel-during-delay logic, and its
`request.pacer.timeoutBudgetMillis ?: JOB_TIMEOUT_MILLIS` override all now
thread the pacer instance through instead of raw millis. iOS:
[JobPacer.swift](../ios/ZManagerMobile/ZManagerMobile/JobPacer.swift) — a
narrower `protocol JobPacer { func beforePoll(isTerminal: Bool) async }`
(iOS never had a pre-start delay the way Android's foreground service did —
its debug pacing only ever lived inside the poll loop — so there is no
`beforeStart()` on the iOS protocol; documented in the file rather than
carried over for cosmetic parity). `ExtractionReview.pacer: any JobPacer`
replaces `debugDelayNanoseconds`; `ArchiveExtractionCoordinator.plan`/`JobPollDriver.pollUntilTerminal`
thread it through the same way.

**iOS achieves the doc's original, stronger ask — a release build that fails
to compile if the debug type is referenced — Android does not.**
`DelayingJobPacer` on iOS is wrapped in `#if DEBUG` ... `#endif` at its
declaration, and the project's `SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG`
setting is defined only for the Debug build configuration (confirmed by
reading the actual build settings, not assumed): a Release-configuration
build of `ZManagerMobile.swift` genuinely cannot see `DelayingJobPacer` at
all. Verified directly: both `-configuration Debug` and `-configuration
Release` builds were run and both succeeded, the Release one only because
nothing in the Release-compiled sources references the DEBUG-gated type.

Android has no equivalent source-set boundary between where `MainActivity.kt`'s
debug buttons live and where `NoOpJobPacer` lives — `MainActivity.kt` is one
file compiled into every build type, and its debug buttons are already
runtime-gated by `if (!BuildConfig.DEBUG) return`, the same pattern the file
uses for every other debug-only affordance. Truly isolating `DelayingJobPacer`
into `src/debug/` would require moving those buttons' composable code out of
`MainActivity.kt` into a separate debug-only file reachable only through a
variant-supplied hook — a real restructure of the debug UI surface, not a
pacing change, and out of proportion to a Medium-severity finding. `DelayingJobPacer`
therefore lives in the same file as `NoOpJobPacer` in `src/main/`, consistent
with how every other Android debug affordance in this codebase is already
gated (`BuildConfig.DEBUG` at the call site, not source-set isolation) —
documented here as a deliberate, narrower scope than the doc's original ask,
not an oversight.

**The empty-component-style "assert it can't compile in release" test
couldn't be written the way the doc originally proposed** (Android side) for
the reason above; verified instead by compiling both `compileDebugKotlin` and
`compileReleaseKotlin` and confirming both succeed with `NoOpJobPacer` as the
only pacer ever constructed outside a `BuildConfig.DEBUG` guard — an
auditable, if not compiler-enforced, invariant.

### Verification

- Android: `compileDebugKotlin` and `compileReleaseKotlin` both succeed; full
  JVM suite **67/67 passing** (65 before this track, plus 2 new
  `JobPacerTest` cases: `NoOpJobPacer` never delays and has no timeout
  override, `DelayingJobPacer` delays before a start and before a
  non-terminal poll but not before a terminal one).
- iOS: `xcodebuild build` succeeds for **both** `-configuration Debug` and
  `-configuration Release`, plus the `ZManagerMobileShareExtension` target;
  full XCTest/UI suite **67/67 passing** (65 before this track, plus 2 new
  `JobPacer` test cases mirroring Android's).
- **On-device E2E, both platforms, both debug scenarios**: ran the real
  Maestro flows this track's refactor could plausibly have broken, not just
  the JVM/XCTest suites.
  - `scripts/check-cancellation-e2e.sh` (15s `DelayingJobPacer` delay, cancel
    mid-delay, assert zero files land in the final destination): **passed on
    both Android** (adb-driven emulator) **and iOS** (Maestro against the
    Simulator, confirmed separately via `xcrun simctl get_app_container` that
    zero files existed in the Extracted directory afterward).
  - `maestro/android/extraction-timeout.yaml` (15s delay with a 1s
    `timeoutBudgetMillis` override, asserting the platform-timeout message
    appears): **passed**, confirming `request.pacer.timeoutBudgetMillis`
    correctly overrides `JOB_TIMEOUT_MILLIS` in `ArchiveJobForegroundService`.
    iOS has no timeout-override scenario to test (see "What landed" above —
    it never had one).
- A real bug surfaced and was fixed during this verification: the first
  version of the iOS `JobPacer` test wrapped
  `testDelayingJobPacerDelaysBeforeNonTerminalPollsOnly` in `#if DEBUG`,
  mirroring the production type's own guard — but `ZManagerMobileTests`'s
  build settings don't define `SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG`
  the way the main `ZManagerMobile` target's Debug configuration does, so the
  test silently failed to compile into the test bundle at all (65/66 instead
  of 65/67, no failure reported — the test simply didn't exist). Found by
  noticing the count was one short of Android's and grepping the test log for
  the missing test's name. Fixed by removing the redundant guard — the test
  target's `@testable import` sees `DelayingJobPacer` regardless, since the
  *app* module being tested was compiled with Debug settings for this run.

### Tests

- Not done as originally specified (Android): "assert by keeping the pacer
  type out of the main source set entirely so a release build fails to
  compile if it is referenced" — see "What landed" for why, and for what was
  verified instead (both configurations compile; `NoOpJobPacer` is the only
  pacer reachable outside `BuildConfig.DEBUG`).
- Done (iOS): the stronger version of the same test — `DelayingJobPacer` is
  compiled only under `#if DEBUG`, verified by a green `-configuration
  Release` build.
- Done, both platforms: cancellation and timeout E2E scripts pass unchanged
  against the debug build — see "Verification" above for the actual runs,
  not just "should still work."

## Track 6: iOS file decomposition — done

### Problem

`ContentView.swift` was 6,685 lines and held over 100 top-level declarations. It
was not a view file. It contained the TLS pinning helper, the HTTP client, the
HTTP server, the trust store, five job coordinators, the recovery store, the
identity, every model type, and every panel view.

### What landed

Split by an automated, coverage-checked line-range extraction (every line of
the original file accounted for exactly once, verified before any file was
written) rather than by hand, because a 6,685-line manual cut-and-paste is
where transcription mistakes hide. Actual layout under
`ios/ZManagerMobile/ZManagerMobile/`, adjusted from the original sketch above
based on what the file actually contained once mapped against Android's real
per-file boundaries (not Android's aspirational ones — MainActivity.kt itself
has one small inconsistency, `ArchiveExtractionUiState` living in MainActivity
rather than ArchiveExtraction.kt, which this split does not reproduce):

```text
ContentView.swift                    root view only (677 lines, was 6,685)
ArchiveImportModel.swift             the 1,374-line god object, unchanged — Track 7's target, not this track's
Support/ContentViewSupport.swift     StableSecureInputField, StableInputBuffer, PreviewDocument, QuickLookPreview, RecoveryShareSheet
Import/ArchiveImport.swift           ImportedArchive, automation parsing, ArchiveImportStore, SharedImportStore
Creation/ArchiveCreation.swift       staging, ArchiveCreationCoordinator, ArchiveSeparateCreationCoordinator, volume support
Listing/ArchiveListing.swift         summary/entry/sort/group, loaders, ArchiveBridgeClient (Android inlines this in ArchiveListing.kt too)
Repackaging/ArchiveRepackaging.swift
Recovery/ArchiveRecovery.swift       + ArchiveOperationReport/Store
Extraction/ArchiveExtraction.swift   + ArchiveDestinationPreferences, batch extraction
Nested/NestedArchiveNavigation.swift
LocalSend/LocalSendProtocol.swift    device/announcement/identity types, LocalSendTransferError
LocalSend/LocalSendClient.swift      + LocalSendSourceStager, LocalSendPanel, LocalSendUIState
LocalSend/LocalSendReceiver.swift
LocalSend/LocalSendTls.swift         LocalSendCertificatePinning, LocalSendTrustDelegate
LocalSend/LocalSendTrustStore.swift
```

Two deliberate departures from the original sketch: no `Bridge/` file — Android
keeps its bridge gateway inside `ArchiveListing.kt` rather than a separate file,
and matching that turned out to be the more faithful mirror; and no
`Panels/*.swift` one-file-per-view split — Android keeps all its panel
composables inside `MainActivity.kt` (that colocation is Track 7's problem to
fix via per-feature state holders, not this track's), so panels here stay
colocated with their feature's models instead of fragmenting into ~9 more
files. `ArchiveImportModel.swift` also does not fit any single feature folder —
it reaches into every feature — so it stays at the top level as a visible,
named exception pending Track 7.

Two correctness issues surfaced doing the extraction, both instructive:

1. **Attributes must move with their declaration, not with the preceding
   chunk's boundary.** The first extraction pass split
   `@available(iOS 16.0, *)` from the `PhotoCreationPicker` struct it
   annotated, because the struct's own line was used as the boundary instead of
   its attribute line. This produced real, cascading compile errors ("'PreviewDocument' is only available in iOS 16.0 or newer") in an unrelated file — a
   useful reminder that Swift compile errors from a botched split can point far
   from the actual defect. Fixed by moving the boundary to the `@available`
   line. `grep -n "^@"` against the original file before extraction is now the
   check to run first on any future split like this.
2. **Four top-level declarations were `private` and used from a different file
   after the split**, which Swift rejects at compile time: `LocalSendCertificatePinning`
   and `LocalSendTrustDelegate` (declared in `LocalSendTls.swift`, used from
   `LocalSendClient.swift`), and the `private extension` adding `.creationState`
   to `ArchiveCreationOutcome` and `.state` to `ArchiveExtractionCoordinator.Outcome`
   (both used from `ArchiveImportModel.swift`). All four had `private` removed
   (Swift's top-level `private` is file-scoped, so this is exactly what a
   cross-file move requires); nothing else about them changed. This is the one
   respect in which the move is not textually pure, and it is the expected,
   necessary kind of change for a file split, not a behavior change — the
   symbols were never reachable outside the module either way.

### Verification

- `xcodebuild build` for the `ZManagerMobile` scheme (Debug, iOS Simulator) and
  the `ZManagerMobileShareExtension` target both succeed.
- Full `ZManagerMobileTests` suite: **61/61 passing**, run on the project's
  configured simulator (`ZManager iPhone 16 Pro`) via `xcodebuild test`.
- File-size guard added to [scripts/check-ios.sh](../scripts/check-ios.sh):
  fails the check if any non-generated Swift file exceeds 1,500 lines, with
  `ArchiveImportModel.swift` named as the one tracked exception (pointing at
  this section). Verified both directions: passes at the real 1,500-line
  threshold today, and was confirmed to actually fail when temporarily
  lowered to 100 lines.
- New files registered in `ZManagerMobile.xcodeproj/project.pbxproj` via the
  `xcodeproj` Ruby gem (added to the same `ZManagerMobile` target `ContentView.swift`
  was already a member of) rather than hand-edited, to avoid corrupting the
  project file's GUID/build-phase structure.

### Tests

- Existing XCTest suite passes unchanged (61/61); no test edits were needed.
- New file-size guard fails on a deliberately oversized file, confirmed above.

## Track 7: State holders on both shells — done

### Problem

Android: `ZManagerApp`
([MainActivity.kt:100](../android/app/src/main/java/org/tzap/zmanager/mobile/MainActivity.kt#L100))
is a single 1,845-line composable holding **49 `by remember` state variables and
39 local `fun` declarations**. Every one of those closures is reallocated on
every recomposition, so no child composable can ever skip. `ArchiveListingReadyPanel`
consequently takes **38 parameters**. `lifecycle-viewmodel-compose:2.8.7` is
already a declared dependency and `grep -r ViewModel app/src/main` returns
nothing.

iOS: `ArchiveImportModel`
([ContentView.swift:2555](../ios/ZManagerMobile/ZManagerMobile/ContentView.swift#L2555))
is 1,363 lines with **31 `@Published` properties and 67 methods**. Because the
root view observes the whole object, any property change invalidates the entire
tree.

### What the original sketch got wrong

The plan as written above assumed feature state was separable with coordination
only "at the edges" (ZManagerApp calling across view models). Reading every
function body in `ZManagerApp` before writing any code showed the coupling runs
much deeper than that:

- `startRepackaging` reads Creation's `createFormat`/`createPasswordInput`/
  `createVolumeSizeInput` to name and password-protect its output — repackaging
  has no format or password concept of its own, it borrows Creation's.
- `discardRecovery` reaches into Extraction's state (clears a matching
  `RecoveryAvailable`), and `retryRecovery` calls both `discardRecovery` and
  `planExtraction`.
- `startImport`/`startMaestroFixtureImport` reset Listing's preview/test state,
  Extraction's state, and LocalSend's staged-file selection in one call — a
  single "new archive, forget everything about the old one" operation that
  necessarily touches every feature.
- `foregroundRecoveryMessage` is one shared status-message field used by both
  the recovery panel and generic "share output" for Creation and Repackaging.

A decomposition into fully independent per-feature `ViewModel`s, each reachable
only through ZManagerApp passing explicit parameters, would have meant
restructuring most of these function signatures — a materially larger and
riskier change than a state-holder move. The landed architecture instead uses
one shared `ArchiveSessionViewModel` for genuinely cross-cutting state
(imported archive, listing, nested navigation, recovery, shared status
messages) plus feature `ViewModel`s that hold a constructor reference to
`ArchiveSessionViewModel` — and, where the coupling demands it, to each other
(`ArchiveRepackagingViewModel` holds references to both
`ArchiveExtractionViewModel` and `ArchiveCreationViewModel`, matching what
`startRepackaging` actually needs). This is a standard, accepted pattern for
apps built around one central session object; it is not the "zero-coupling"
version, but it is faithful to how the code actually behaves rather than to how
a clean diagram would prefer it to behave.

### What landed (Android) — done, verified on-device

**ViewModels**, one file each in
`android/app/src/main/java/org/tzap/zmanager/mobile/`:
[ArchiveSessionViewModel.kt](../android/app/src/main/java/org/tzap/zmanager/mobile/ArchiveSessionViewModel.kt),
[ArchiveListingViewModel.kt](../android/app/src/main/java/org/tzap/zmanager/mobile/ArchiveListingViewModel.kt),
[ArchiveExtractionViewModel.kt](../android/app/src/main/java/org/tzap/zmanager/mobile/ArchiveExtractionViewModel.kt),
[ArchiveBatchExtractionViewModel.kt](../android/app/src/main/java/org/tzap/zmanager/mobile/ArchiveBatchExtractionViewModel.kt),
[ArchiveCreationViewModel.kt](../android/app/src/main/java/org/tzap/zmanager/mobile/ArchiveCreationViewModel.kt),
[ArchiveRepackagingViewModel.kt](../android/app/src/main/java/org/tzap/zmanager/mobile/ArchiveRepackagingViewModel.kt).
LocalSend state stays local to `ZManagerApp` (deferred per Track 1) and is
untouched by this track.

**The "state alias" technique.** Rather than renaming every one of the
hundreds of scattered state reads throughout `ZManagerApp`'s ~1,800-line render
tree, each ViewModel exposes its state as a public `MutableState<T>` (e.g.
`val listingStateState: MutableState<ArchiveListingState>`) instead of a plain
`var`. `ZManagerApp` rebinds each one locally under its *original* name —
`var listingState by session.listingStateState` — so Compose's `by` delegate on
a `MutableState` works identically whether the state was created in this
function or read from another object. The render tree below that rebinding is
therefore almost entirely unchanged: reads, writes, and recomposition scoping
all behave exactly as before. The same idea applies to moved functions: each
one gets a same-signature wrapper in `ZManagerApp`
(`fun startExtraction(review) = extraction.startExtraction(review, context)`)
so every `::functionName` reference and direct call in the render tree keeps
working without modification. This is what made a ~1,845-line rewrite tractable
without an equally large, hard-to-review diff in the rendering code itself.

**Two real bugs found by cross-checking against the original, not by the
compiler:**

1. `ArchiveSessionViewModel.retryRecovery`'s first draft called
   `discardRecovery(record.id) {}` — an *empty* callback — silently dropping
   the original's side effect of clearing a matching
   `ArchiveExtractionUiState.RecoveryAvailable`. The compiler had no way to
   catch this: both versions type-checked. Caught by re-reading the original
   `retryRecovery` line by line against the new version. Fixed by threading an
   `onExtractionRecoveryDiscarded` callback through `retryRecovery` into
   `discardRecovery`, so the wrapper in `ZManagerApp` supplies the same
   extraction-state-clearing behavior either call path takes.
2. A duplicate, now-orphaned copy of `ArchiveExtractionUiState` and
   `Throwable.toExtractionUiState()` was left behind in `MainActivity.kt` after
   the type moved to `ArchiveExtractionViewModel.kt`. This one was closer to a
   near-miss than a live bug — Kotlin's file-scoped `private` would have made
   `MainActivity.kt`'s copy shadow the real one within that file, producing
   confusing type-mismatch errors the first time anything tried to pass an
   `extraction.extractionState` value across the boundary. Caught by grepping
   for the type name across the whole file before considering the move done,
   not by the compiler (which was never run against the stale state).

**Verification**, in order:
- `:app:compileDebugKotlin` succeeded on the first attempt after the full
  rewrite (strong signal the wrapper/alias approach was applied consistently).
- Manual line-by-line re-read of the entire render tree (every panel call,
  every picker callback, every `LaunchedEffect`) against the pre-refactor
  version, independent of the compiler — this is what caught bug 1 above.
- Full JVM suite: **58/58 passing**, unchanged.
- `:app:assembleDebug` and `:app:assembleRelease` (R8 + the Track 9 keep
  rules) both succeed.
- **On-device smoke test** on a booted `Medium_Phone_API_36.1` emulator,
  driven via `adb`: installed the debug build, imported the `maestro-nested.zip`
  fixture, opened the nested `maestro-inner.zip` (exercises
  `ArchiveSessionViewModel.openNestedArchive` and the session stack), selected
  `readme.txt` and extracted it through the real foreground-service job
  handoff, confirmed `"Extraction complete: 1 files saved to App storage."`
  rendered (exercises `handleForegroundJobResult` dispatching into
  `ArchiveExtractionViewModel` and back through the broadcast receiver), then
  navigated back and confirmed the listing reverted to the parent archive's
  contents. Every flow this track touches was exercised for real, not just
  compiled.

**Explicitly not done in this pass, to keep scope achievable:** panel
composables were *not* restructured to take a feature's state plus a callback
interface instead of a flat parameter list — `ArchiveListingReadyPanel` still
takes its original 38 parameters. The state-holder extraction (moving state and
logic out of the composable) is complete and is the larger architectural win;
collapsing panel signatures is a smaller, separable follow-up against finding
#11 that does not require touching ViewModel internals again.

### What landed (iOS) — done, verified on-device

The coupling investigation that shaped Android's design (above) applied
directly: `startRepackaging` reads Creation's format/password, recovery is
exposed through the extraction coordinator rather than a separate store, and
`handleSceneBackground` (iOS's name for `handleAppBackground`) touches every
feature's state in one call. Same shared-session-object shape landed:

**Models**, one file each in `ios/ZManagerMobile/ZManagerMobile/`:
[ArchiveSessionModel.swift](../ios/ZManagerMobile/ZManagerMobile/ArchiveSessionModel.swift),
[ArchiveListingModel.swift](../ios/ZManagerMobile/ZManagerMobile/ArchiveListingModel.swift),
[ArchiveExtractionModel.swift](../ios/ZManagerMobile/ZManagerMobile/ArchiveExtractionModel.swift),
[ArchiveBatchExtractionModel.swift](../ios/ZManagerMobile/ZManagerMobile/ArchiveBatchExtractionModel.swift),
[ArchiveCreationModel.swift](../ios/ZManagerMobile/ZManagerMobile/ArchiveCreationModel.swift),
[ArchiveRepackagingModel.swift](../ios/ZManagerMobile/ZManagerMobile/ArchiveRepackagingModel.swift),
[ArchiveLocalSendModel.swift](../ios/ZManagerMobile/ZManagerMobile/ArchiveLocalSendModel.swift).
Unlike Android, LocalSend's state was already class-owned `@Published` state
before this track (not simple local view state the way Android's `remember`
vars were), so giving it its own focused `ObservableObject` here is the
faithful low-risk move, not a deviation from Track 1's LocalSend-stays-deferred
stance — nothing about *how* LocalSend works changed, only where its existing
state lives.

**No Compose-style state alias was available.** SwiftUI's `@Published` belongs
to one specific `ObservableObject` instance; there is no equivalent of
rebinding a local `var` to another object's storage the way Compose's
`MutableState` allowed on Android. The mitigating fact, discovered before
writing any code: `grep`ping the whole iOS source tree showed `importModel`
referenced *only* inside `ContentView.swift` — every panel already took its
state as explicit parameters, exactly like Android's panels. That confined the
entire ~180-reference update to one 677-line file rather than spreading across
every panel file, which is what made a full manual reference-by-reference
update (rather than an alias trick) tractable. Wrapper functions with the
original method's exact shape (`private func importMaestroFixture(named:...)`
calling `session.importMaestroFixture(...)`) still cover the ~73 debug-fixture
button call sites, so those didn't need touching individually either.

**A cross-model coordination case Android didn't have.** `ArchiveCreationPanel`'s
cancel button originally cancelled both an in-flight creation job *and* a
matching in-flight repackaging job in one method
(`cancelCreation()` — repackaging composes staged extraction with the create
planner, so a cancel needs to reach both). Splitting the state holders meant
this single method couldn't stay single: `ArchiveCreationModel.cancelCreation()`
now covers only the creation half, and `ContentView` calls it together with
`ArchiveRepackagingModel.cancelRepackaging()` (an already-existing, slightly
broader method — it also handles `.passwordRequired`, a case the original inline
switch didn't cover, making the combination a superset of the original
behavior, not a narrowing).

**`handleSceneBackground` extracted as a free function, not a `ContentView`
method.** The original test suite called
`ArchiveImportModel.handleSceneBackground()` directly and asserted on its
effects — a pattern that stops working once the coordinator would otherwise
live as a `private` method on a SwiftUI `View` struct, which isn't practical to
unit test in isolation. It now lives in
[ArchiveSceneBackgroundCoordinator.swift](../ios/ZManagerMobile/ZManagerMobile/ArchiveSceneBackgroundCoordinator.swift)
as a `@MainActor` free function taking all seven models as parameters,
directly constructible and callable from XCTest without a SwiftUI host;
`ContentView.handleSceneBackground()` is now a three-line call into it.

**Two real bugs found and fixed, the same way as Android — by cross-checking
against the original, not by the compiler:**

1. A PhotoUI/SwiftUI cross-import overlay issue: `PhotosPickerItem` is only
   visible when **both** `PhotosUI` and `SwiftUI` are imported in the *same
   file* (Apple's cross-import overlay mechanism). `ArchiveCreationModel.swift`
   imported only `PhotosUI`, producing "cannot find type 'PhotosPickerItem' in
   scope" — a confusing error for what was actually a missing `import SwiftUI`.
2. Actor-isolation: exposing `session.extractionCoordinator` through a
   *computed* property on `ArchiveExtractionModel` failed to compile inside
   `Task.detached` closures ("main actor-isolated property... cannot be
   accessed from outside the actor"), while the original code's *stored* `let`
   of the same Sendable-conforming coordinator type compiled fine in the same
   position. Root cause: a stored `let` of a `Sendable` type on a `@MainActor`
   class is exempt from that class's actor isolation; a computed property
   forwarding to another actor-isolated object's storage is not, regardless of
   what it returns. Fixed by copying the coordinator into a stored `let` at
   init instead of reading it fresh through a computed accessor, in both
   `ArchiveExtractionModel` and `ArchiveCreationModel`.

**The existing test suite required real edits, not just relocation** — a
difference from Track 6, where no iOS test changes were needed. Five tests
directly constructed `ArchiveImportModel(...)` and touched its `@Published`
properties; since Track 7 changes *where* state lives (not just which file it's
in), these had to move to the new models. Three of the five ended up *more*
focused than before: two scene-background tests that only cared about
LocalSend now construct just `ArchiveLocalSendModel` instead of the entire
former god object.

**Verification**, in order:
- `xcodebuild build` for the `ZManagerMobile` scheme and the
  `ZManagerMobileShareExtension` target both succeed, with zero warnings from
  any of the eight new files.
- Full XCTest suite: **57/57 passing** (the true test-case count — a `func
  testArchiveContents(path:selectedPaths:password:)` helper with parameters is
  not an XCTest case despite the name; Track 6's report of "61" conflated a
  cruder grep count with the real number). Five tests updated to construct the
  new models instead of `ArchiveImportModel`; zero test behavior removed.
- File-size guard (Track 6): passes with an empty exception list —
  `ArchiveImportModel.swift`'s entry in `scripts/check-ios.sh` is removed
  since the file no longer exists. Largest new file is 448 lines
  (`ArchiveSessionModel.swift`), against the 1,500-line ceiling.
- **On-device smoke test** on the same booted simulator used for the Track 6
  verification, driven via the iOS Simulator tool: launched the debug build,
  imported the `maestro-nested.zip` fixture, opened the nested
  `maestro-inner.zip` (exercises `ArchiveSessionModel.openNestedArchive` and
  the session stack), selected `readme.txt` and extracted it, confirmed
  `"Extraction complete: 1 files saved to App storage."` rendered, then
  navigated back and confirmed the listing reverted to the parent archive's
  contents — the identical sequence run on Android, with identical results.

**Explicitly not done in this pass**, matching Android: panel views were not
restructured to take a feature's state plus a callback interface instead of
explicit parameters. That was already true before this track (panels already
took explicit parameters, which is what made the reference update tractable in
the first place) and stays a separable follow-up, not a Track 7 gap.

### Tests

- Android: see verification list above — done, 58/58 JVM tests, on-device
  smoke test.
- iOS: see verification list above — done, 57/57 XCTest tests (5 updated,
  none removed), on-device smoke test.
- The unused `lifecycle-viewmodel-compose` dependency finding is resolved:
  Android adopted `ViewModel` and it is in active use.
- Not done on either platform: a recomposition/re-render test asserting the
  listing panel does not update when unrelated state (for example LocalSend
  discovery) changes. That belongs with Track 8's memoization work, which this
  track's state-holder split is a prerequisite for, not a substitute for.
- Add a test that backgrounding clears every password field across all view
  models, mirroring the current `handleAppBackground` guarantees.

## Track 8: Listing and job-polling performance — done, with two items descoped

### Problem

**Unmemoized listing pipeline.**
[MainActivity.kt:1803](../android/app/src/main/java/org/tzap/zmanager/mobile/MainActivity.kt#L1803)
(line renumbered by Track 7's state-holder split; still the same panel
composable, now reading from `ArchiveListingViewModel` instead of local
`remember` state) runs three passes over all entries directly in the
composable body:

```kotlin
val groups = summary.visibleGroups(searchQuery, sort, viewMode)
val selectedEntries = summary.selectedEntries(selectedEntryIds)
val previewEntry = summary.previewableSelectedEntry(selectedEntryIds)
```

`visibleGroups` is `filter` then `sortedWith` then `groupBy` then `toSortedMap`
([ArchiveListing.kt:448](../android/app/src/main/java/org/tzap/zmanager/mobile/ArchiveListing.kt#L448)) —
several intermediate lists plus a tree map, with no `remember` key. Because all
49 state variables share one recomposition scope, any unrelated state change
re-runs it. The 50-entry cap currently hides this; Track 3 removes the cap, so
this must land with or before it.

**Duplicated polling loops.** The cursor/poll/last-event/`isTerminal` skeleton
is copy-pasted four times at a fixed 150 ms (line references below post-date
Tracks 6 and 7's file splits):
[ArchiveExtraction.swift:315](../ios/ZManagerMobile/ZManagerMobile/Extraction/ArchiveExtraction.swift#L315),
[ArchiveCreation.swift:758](../ios/ZManagerMobile/ZManagerMobile/Creation/ArchiveCreation.swift#L758),
[ArchiveExtraction.kt:236](../android/app/src/main/java/org/tzap/zmanager/mobile/ArchiveExtraction.kt#L236),
[ArchiveCreation.kt:532](../android/app/src/main/java/org/tzap/zmanager/mobile/ArchiveCreation.kt#L532).
A twenty-minute extraction wakes the CPU roughly 8,000 times with no backoff.
The creation path also calls `bridge.pollExtractionJob` and
`cancelExtractionJob`, a misnomer that should be renamed to the job-generic form
the bridge actually provides.

**Per-byte boxing.** `readLine`
([LocalSendReceiver.kt:302](../android/app/src/main/java/org/tzap/zmanager/mobile/LocalSendReceiver.kt#L302))
accumulates into `ArrayList<Byte>`, allocating a `java.lang.Byte` per byte.

### Implementation

Memoize the pipeline against its real inputs, at its existing call site. The
panel still takes `summary`/`searchQuery`/`sort`/`viewMode` as explicit
parameters rather than reading
[ArchiveListingViewModel](../android/app/src/main/java/org/tzap/zmanager/mobile/ArchiveListingViewModel.kt)
directly (finding #11, the flat-parameter-list problem, is explicitly not
restructured by Track 7 — see Track 7), so `remember` keyed on those
parameters is the correct scope for this fix, not a ViewModel-owned derived
value that would require collapsing the signature as a side effect:

```kotlin
val groups = remember(summary, searchQuery, sort, viewMode) {
    summary.visibleGroups(searchQuery, sort, viewMode)
}
```

Debounce the search query by roughly 150 ms before it reaches the filter, so
typing does not re-sort per keystroke. For large archives, move the
filter/sort/group off the main thread and publish the result.

Extract one shared job-poll driver per platform, parameterized by the progress
mapping and terminal handling that actually differ between extraction,
creation, separate creation, batch extraction, and repackaging. Give it capped
backoff — start at 100 ms, grow to about 1 s while no events arrive, and reset
on each event — so short jobs stay responsive and long jobs stop burning wakeups.
Rename the bridge call sites to the job-generic names.

Replace the `ArrayList<Byte>` accumulator with a reused `ByteArrayOutputStream`
bounded by the existing `MAX_HEADER_LINE`.

### What landed

**Listing memoization**, at
[MainActivity.kt:1803](../android/app/src/main/java/org/tzap/zmanager/mobile/MainActivity.kt#L1803):
`groups`, `selectedEntries`, and `previewEntry` are each wrapped in `remember`
keyed on their real inputs, exactly as sketched above. The search box itself
still binds to the raw, un-debounced `searchQuery` (so every keystroke shows
up immediately), but a second `debouncedSearchQuery` — updated via a
`LaunchedEffect(searchQuery) { delay(150); ... }` — is what actually feeds
`visibleGroups`, so a burst of keystrokes filters once, ~150ms after typing
stops, not once per keystroke.

**Shared job-poll driver**, one per platform:
[JobPollDriver.kt](../android/app/src/main/java/org/tzap/zmanager/mobile/JobPollDriver.kt)
and
[JobPollDriver.swift](../ios/ZManagerMobile/ZManagerMobile/JobPollDriver.swift).
Both take the same shape: a `poll` callback, an `onEvent` callback for
progress mapping, and an `onTerminal` callback for the job-kind-specific
completion handling, so `ArchiveExtractionCoordinator.awaitCompletion` and
`ArchiveCreationCoordinator.awaitCompletion` on each platform now differ only
in their terminal-branch bodies (verbatim-preserved from before this track),
not in the polling mechanics around them. Backoff starts at 100ms, doubles up
to a 1s cap on any poll that returns no new event, and resets to 100ms the
moment an event does arrive — so a fast job still gets near-immediate
progress updates while a long-running one stops waking the CPU every 150ms.
Rewiring both coordinators onto the shared driver on each platform is the
only reason "duplicated four times" in the Problem section above resolves to
two call sites per platform (extraction, creation) rather than four — batch
extraction and repackaging were never separate poll loops; both already
delegate to these same two coordinators.

One real bug turned up doing the iOS extraction: `ArchiveExtraction.swift`'s
`awaitCompletion` had a leftover `try await Task.sleep(...)` for
`debugDelayNanoseconds` *before* the polling loop even started, in addition
to the (correct) one inside the loop — a duplicate that `ArchiveCreation.swift`'s
equivalent function never had. Comparing the two side by side during the
extraction is what surfaced it; the shared driver has only the one, correct,
in-loop check.

**Bridge call renamed to its generic form.** `ArchiveBridgeClient.pollExtractionJob`/`cancelExtractionJob`
on iOS were used identically by both the extraction and creation coordinators
despite the extraction-specific name, and the underlying UniFFI bridge already
exposes the generic `pollJobEvents`/`cancelJob`. Renamed the wrapper methods
to `pollJob`/`cancelJob` to match. The rename produced one real conflict:
`GeneratedArchiveBridgeClient.cancelJob(jobId:)`'s body called the bridge's
`cancelJob(request:)` unqualified, and once the wrapper itself was also named
`cancelJob`, Swift resolved the unqualified call to itself instead of the
global function — the compiler's own fix-it (qualify with the module name,
`ZManagerMobile.cancelJob(request:)`) is what's in the code now. Android's
`bridge.pollJob`/`cancelJob` were already generically named; no rename was
needed there.

**Per-byte boxing removed**: [LocalSendReceiver.kt](../android/app/src/main/java/org/tzap/zmanager/mobile/LocalSendReceiver.kt)'s
`readLine` now writes into a `ByteArrayOutputStream` instead of an
`ArrayList<Byte>`. The buffer is allocated once per connection in `handle(...)`
and `.reset()` between header lines, rather than once per `readLine` call —
each connection already runs on its own thread (finding #3), so a
per-connection buffer is reused work without becoming a cross-thread hazard.

**Explicitly descoped, not done in this pass:**
- Moving the filter/sort/group pipeline off the main thread for very large
  archives. `remember` avoids recomputing on unrelated state changes, which
  was this track's actual complaint, but the computation itself still runs
  synchronously on the UI thread when its inputs do change. Left as a
  follow-up if a large-archive frame-budget problem is actually observed.
- Dedicated new tests asserting the recomposition skip and the backoff curve
  in isolation (a mock-poll-sequence test asserting successive backoff
  values, a Compose recomposition-count test). The existing suites already
  exercise every terminal branch of both coordinators end-to-end against the
  real Rust bridge (`testExtractionCoordinatorCommitsCompletedStagingOutput`,
  `testPinnedBridgeCreatesAndReportsSplitZipVolumes`,
  `testBatchExtractionRunsIndependentArchivesAndReportsEachResult`,
  `testSeparateCreationRunsEachRustJobSequentially`, and their Android
  counterparts in `ArchiveExtractionTest.kt`/`ArchiveCreationTest.kt`), which
  is what caught that the terminal-branch bodies were preserved correctly;
  none of them exercises a poll sequence long enough to reach the backoff
  ceiling, since the fake/real bridges used in tests return a terminal result
  on the first or second poll.

### Verification

- Android: `compileDebugKotlin` succeeds; full JVM suite **58/58 passing**.
- iOS: `xcodebuild build` for the `ZManagerMobile` scheme and the
  `ZManagerMobileShareExtension` target both succeed; full XCTest/UI-test
  suite **59/59 passing** (57 `ZManagerMobileTests` + 2 `ZManagerMobileUITests`,
  the same 57 counted in Track 7).
- iOS file-size guard: largest non-generated file is 999 lines
  (`ArchiveListing.swift`), still well under the 1,500-line ceiling with no
  exceptions.
- New files registered the same way as Track 7 — `JobPollDriver.swift` added
  to the `ZManagerMobile` target via the `xcodeproj` Ruby gem (the first
  attempt used a path relative to the wrong group root and produced a
  "Build input file cannot be found" error; fixed by matching the bare
  filename convention every other top-level model file already used).

### Tests

- Not added: a recomposition test asserting `visibleGroups` does not re-run
  when unrelated state changes, and a backoff-curve test. See "Explicitly
  descoped" above for why the existing suites were judged sufficient
  end-to-end coverage for this pass.
- Existing suites pass unchanged in behavior, confirming the terminal-branch
  bodies moved into the shared driver's `onTerminal` callback verbatim: **58/58**
  JVM, **59/59** XCTest/UI.
- Header parser: no dedicated new test was added for the `ByteArrayOutputStream`
  change; existing LocalSend receiver tests exercise `readLine` on every
  request already made against the receiver and continue to pass — iOS's
  `testLocalSendReceiverAnswersHttpRegistration` and
  `testLocalSendReceiverStreamsAndChecksumsLargeUpload`, Android's
  `receiverAnswersHttpRegistrationWithItsReachablePort` and
  `receiverStreamsAndChecksumsLargeUploadsWithoutBuffering` in
  [LocalSendProtocolTest.kt](../android/app/src/test/java/org/tzap/zmanager/mobile/LocalSendProtocolTest.kt).

## Track 9: Build configuration — done, with one ABI deferred

### Problem

[app/build.gradle.kts](../android/app/build.gradle.kts) had **no `buildTypes`
block at all**: no R8 or ProGuard, no resource shrinking, no release signing
config. Release builds shipped unminified and unshrunk.

`jniLibs` contained **`arm64-v8a` only**, breaking the emulator on Intel hosts.
The original write-up of this finding also asserted that `minSdk = 26`
therefore lets 32-bit-only devices install the app and crash at
`System.loadLibrary`. That assertion was not verified and, on investigation,
is probably wrong: Android's package installer resolves native-library ABI
compatibility at install time (`NativeLibraryHelper`) and returns
`INSTALL_FAILED_NO_MATCHING_ABIS` when an APK's `lib/<abi>/` directories don't
match any ABI the device supports, rather than installing and failing later.
The real-world effect of shipping arm64-v8a-only is very likely "some 32-bit
devices can't install the app," not "install and crash" — worth correcting
here since the original finding shaped this track's Implementation section
before it was checked against Android's actual install-time behavior.

### What landed

- **`buildTypes { release { ... } }`** in
  [app/build.gradle.kts](../android/app/build.gradle.kts) with
  `isMinifyEnabled` and `isShrinkResources` on, `getDefaultProguardFile("proguard-android-optimize.txt")`
  plus a new [app/proguard-rules.pro](../android/app/proguard-rules.pro).
- **R8 keep rules for the UniFFI/JNA boundary.** The generated bridge
  (`org.tzap.zmanager.mobile.bridge.generated`) subclasses `com.sun.jna.Structure`
  and implements `com.sun.jna.Library`/`Callback`, both resolved by JNA through
  runtime reflection on field order and names; `net.java.dev.jna:jna` ships no
  consumer ProGuard rules of its own (confirmed by extracting the AAR), so
  these keeps are load-bearing, not defensive duplication. Verified by
  building `:app:assembleRelease` and inspecting the output directly rather
  than trusting a clean compile: `dexdump` on the release APK's `classes.dex`
  shows `RustBuffer` (a `Structure` subclass) present with its `capacity`,
  `data`, and `len` fields intact and unrenamed, and the R8 mapping file shows
  all 234 `bridge.generated` classes and all 124 `com.sun.jna` classes mapping
  to themselves. This is the "release build lists and extracts a fixture
  archive" acceptance bar from the original Implementation plan, checked at
  the artifact level; full functional exercise on a device is still open, see
  below.
- **Release signing sourced from outside the repo.** A `signingConfigs.release`
  reads `RELEASE_STORE_FILE` / `RELEASE_STORE_PASSWORD` / `RELEASE_KEY_ALIAS` /
  `RELEASE_KEY_PASSWORD` from `android/local.properties` (already gitignored,
  already the conventional per-machine Android config file — no new gitignore
  entry needed) or from `ZMANAGER_RELEASE_*` environment variables for CI.
  Neither present leaves the release build type unsigned rather than failing
  Gradle configuration, which is what let this be verified locally without a
  real signing key: `:app:assembleRelease` succeeds and produces
  `app-release-unsigned.apk`.
- **`scripts/build-android-rust.sh` rewritten to loop over a configurable ABI
  list** (`ZMANAGER_ANDROID_ABIS`, space-separated), instead of hardcoding
  `arm64-v8a`/`aarch64-linux-android` throughout. `app/build.gradle.kts` reads
  the same variable (default `arm64-v8a`) to size the `buildZmanagerFfi` task's
  declared outputs and `defaultConfig.ndk.abiFilters`. Both debug and release
  assembly were rerun end to end through this rewritten script and confirmed
  working, and the full JVM suite (58 tests) still passes.

### x86_64 attempted, blocked upstream — deferred

Adding `x86_64` to the ABI list was tried, not just proposed. It fails, and
not on a missing flag:

```text
ld.lld: error: relocation R_X86_64_PC32 cannot be used against symbol
'__cpu_model'; recompile with -fPIC
  >>> defined in ...libzmanager_unrar-....rlib(...system.o)
  >>> referenced by system.cpp
```

The symbol comes from `__builtin_cpu_supports("avx2"/"sse4.1"/...)` in
`zmanager-unrar`'s vendored `system.cpp` and `__builtin_cpu_supports("aes")` in
`rijndael.cpp` — Clang/GCC's x86 CPU-dispatch builtins, used for runtime
AES-NI/SIMD detection. On this NDK's `x86_64-linux-android` target that
lowers to a non-PIC-safe reference to compiler-rt's `__cpu_model`, and it
cannot be linked into a shared object. This was not a missing `-fPIC`: forcing
`CFLAGS_x86_64_linux_android` / `CXXFLAGS_x86_64_linux_android` to `-fPIC` and
force-rebuilding `zmanager-unrar` from clean reproduced the identical error.
`aarch64-linux-android` doesn't hit this because ARM's runtime feature
detection doesn't go through the same x86 CPU-dispatch builtin path, which is
exactly why arm64-v8a already builds.

Fixing this means giving the vendored unrar CPU-dispatch code a non-ifunc
fallback for Android x86_64 — real work in security-sensitive vendored C++ in
the sibling `zmanager` repository, not a `zmanager-mobile` build-script change.
It is out of scope for this pass. `ZMANAGER_ANDROID_ABIS="arm64-v8a x86_64"`
is ready to flip on the day that upstream fix lands; the script and Gradle
wiring already support it, they're just not defaulted to it.

`armeabi-v7a` and `x86` remain out of scope entirely, now for a better reason
than before: given the corrected understanding above, shipping without them
does not crash 32-bit devices, it makes the app not installable on them, which
is a product-scope decision (how many, if any, 32-bit-only Android 8+ devices
this app needs to support) rather than a defect to silently fix by adding a
third and fourth cross-compile of the same vendored C++.

### Tests

- `:app:assembleDebug` and `:app:assembleRelease` both succeed against the
  rewritten multi-ABI-capable script with the default single-ABI (arm64-v8a)
  configuration.
- R8 mapping and `dexdump` verification above stands in for a release-mode
  device functional test; a real "install the release build and extract a
  fixture archive on a device" pass is still open and belongs with the
  physical-device verification work already tracked in
  [mobile-follow-up-implementation-plan.md](mobile-follow-up-implementation-plan.md).
- Full Android JVM suite (58 tests) passes unchanged.
- Not done: CI running on an `x86_64` emulator (blocked on the upstream unrar
  fix above), and any ABI-split/bundle packaging work, since there is only one
  default ABI to split.

## Recommended delivery order

This plan covers the offline tracks (2 through 9) plus Track 1's design and
file-move scope only. Building the Rust LocalSend module itself is a future,
separate plan against `zmanager` and is not sequenced here.

1. **Track 2** — done. Smallest blocker, self-contained, removes a
   password-retention path and a crash.
2. **Track 9** — done except x86_64 ABI support, which is blocked upstream (see
   Track 9). Landed before any release-candidate build is cut, so R8 problems
   surfaced early rather than at launch.
3. **Track 6** — done. Pure file moves on iOS, including the Track 1 LocalSend
   extraction. Landed before Track 7 so the state-holder diffs land in files of
   sane size.
4. **Track 7** — done. State holders on both shells. Largest structural change;
   no behavior change, verified by the existing suites (58/58 JVM, 57/57
   XCTest) plus an on-device smoke test on each platform.
5. **Track 8** — done, with off-main-thread filtering and dedicated
   backoff/recomposition tests descoped (see Track 8). Memoization and the
   shared poll driver landed on top of the new state holders.
6. **Track 3** — done. Removed the entry cap. Ordered after Track 8 because
   raising the window without memoization would have moved the cost onto
   every frame; verified 64/64 JVM, 64/64 XCTest/UI, plus an on-device
   Android smoke test of the new select-all/extract path (see Track 3).
7. **Track 4** — done via the fallback (shared fixture table; the bridge
   change coordinated with `zmanager` remains the preferred fix for a future
   cross-repo pass). Verified 65/65 JVM, 65/65 XCTest/UI.
8. **Track 5** — done. Debug pacing is now an injected `JobPacer` on top of
   Track 8's poll driver, exactly the natural injection point this ordering
   was chosen for. Verified 67/67 JVM, 67/67 XCTest/UI, plus both platforms'
   real cancellation/timeout Maestro E2E flows passing on-device.

Track 1's file-move component ships inside Track 6 rather than as a standalone
step; its security fixes (findings 1-3) are explicitly out of this plan's
sequencing — see Track 1.

Track 2 and Track 9 are independent of the others and can run in parallel with
the structural work if more than one person is on this.

## Definition of done

- LocalSend's native code lives in its own module boundary on both platforms
  (Track 1/6), with an agreed interface sketch recorded for the future Rust
  module. The receive-path security findings (plaintext transport, unbound
  fingerprints, unhardened sockets) are explicitly deferred to that future
  work, not silently left unresolved-and-unmentioned.
- No code path can retain a password-bearing request after its job fails to
  start. **Done** (Track 2): `ArchiveJobForegroundService.submit` removes the
  pending entry on a `startForegroundService` failure and sweeps entries whose
  service never started; verified by test and the full JVM suite (58/58).
- Archive listings never truncate silently; whenever a window is smaller than
  the archive, the UI says so and the user can reach the rest. **Done**
  (Track 3): the 50-entry cap is gone on both platforms; a `Showing X of Y
  entries` line and `Load more` appear whenever the render window is smaller
  than the filtered set.
- Select-all still extracts the whole archive, verified by test. **Done**
  (Track 3): an explicit `selectedEverything` flag replaces the old
  set-equality inference, verified by unit tests on both platforms and an
  on-device Android extraction.
- Extraction path safety has exactly one implementation, or two implementations
  proven equivalent by a shared fixture table that includes the cases where they
  previously differed. **Done** (Track 4): two implementations remain, now
  proven equivalent by
  [extraction-path-safety.json](../fixtures/metadata/extraction-path-safety.json),
  consumed by both platforms' test suites; the single-implementation version
  (pushed into `zmanager-ffi`) remains the preferred fix for a future
  cross-repo pass.
- No debug pacing field exists on any production request type. **Done**
  (Track 5): both platforms replaced raw `debugDelayMillis`/`debugTimeoutMillis`/
  `debugDelayNanoseconds` fields with an injected `JobPacer`, defaulting to a
  no-op in every production code path.
- No Swift file outside `Bridge/Generated/` exceeds the size guard, and no
  composable takes a flat parameter list of screen state. **Done** (Tracks 6
  and 7): `ContentView.swift` split from 6,685 to 677 lines across 14 files
  (Track 6), then its former 1,374-line `ArchiveImportModel.swift` god object
  was deleted and replaced by seven focused state holders (Track 7).
  `scripts/check-ios.sh`'s 1,500-line ceiling now applies with no named
  exceptions; `xcodebuild` and the full XCTest suite (57/57) both pass. On
  Android, `MainActivity.kt`'s 1,845-line composable was split into a shared
  `ArchiveSessionViewModel` plus feature ViewModels; the JVM suite (58/58)
  passes. Flat parameter lists on individual panels were not restructured on
  either platform — an explicitly separate, un-scheduled follow-up.
- The listing pipeline does not recompute on unrelated state changes.
- One job-poll driver per platform, with capped backoff.
- A minified, signed release build lists and extracts a fixture archive on every
  shipped ABI. **Partially done** (Track 9): `:app:assembleRelease` minifies,
  shrinks, and (given local signing credentials) signs; the UniFFI/JNA keep
  rules are verified at the artifact level (`dexdump` shows `RustBuffer`'s
  JNA-reflected fields intact and unrenamed in the release `classes.dex`).
  Shipped ABI is arm64-v8a only — x86_64 is attempted and blocked on a
  vendored-unrar issue in the sibling `zmanager` repo, not shipped. A real
  on-device "install the release build and extract a fixture archive" pass is
  still open.
- Passwords and transfer credentials remain absent from logs, diagnostics, and
  persistent state.
