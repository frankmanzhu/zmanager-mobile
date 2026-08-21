# ZManager Mobile Format Exposure Matrix

Last reviewed: 2026-08-14

This is an evidence matrix, not a claim that every ZManager-Core format is
launch-ready. A format is exposed only when the selected bridge, both native
shells, and the relevant UI/E2E evidence agree. `blocked` means the current
bridge or mobile shell is insufficient; it must not be silently treated as
supported.

The temporary pinned mobile bridge is
`b1336fc48fbc2bd1db548b7cb9042c8fbf6f7224` (`v2.1.0`); the default local
source follows the sibling `../zmanager` checkout at the same release revision.
The current sibling FFI maps CAB and several other native-reader kinds to its
generic `Other` capability, which reports list/extract as unavailable. Its
create DTO currently exposes
only ZIP, 7z, TAR+Zstd, and TZAP. Read/list support is driven by the generated
bridge and the format contract snapshot at
`android/app/src/test/resources/format-capabilities.json`.

The committed snapshot and generated bindings now follow the current sibling
engine contract and contain the expanded format registry. When reproducing the
temporary pinned build, regenerate the snapshot and bindings from the
`.cache/zmanager` override before relying on its format evidence.

| Format family | List/read | Extract | Create | Android evidence | iOS evidence | UI status / limitation |
|---|---|---|---|---|---|---|
| ZIP | verified | verified | verified, including encrypted ZIP | JVM, instrumentation, Maestro | XCTest/UI, Maestro | exposed |
| 7z | registry-backed | fixture/listing coverage | verified through create DTO | JVM/fixture | XCTest/fixture | exposed |
| TAR+Zstd / `.tzst` | registry-backed | fixture/listing coverage | verified through create DTO | JVM/fixture | XCTest/fixture | exposed |
| TZAP | registry-backed | fixture/listing coverage | verified through create DTO | JVM/fixture | XCTest/fixture | exposed; recovery-oriented copy is still limited |
| TAR, gzip, bzip2, xz, zstd streams | registry-backed | bridge capability required per format | blocked by pinned create enum | snapshot/conformance only | generated bridge only | read/extract capability must be separately gated |
| RAR / multipart RAR | registry-backed | extraction-only and volume-grouping evidence required | intentionally absent | split fixtures/conformance | split fixtures/conformance | no single-file nested claim; no create/repair |
| split ZIP / split 7z | registry-backed | volume-set handling verified | verified through pinned `volume_size` DTO | JVM, Maestro split-create/extract | XCTest, Maestro split-create/extract | exposed with companion-volume guidance |
| AppleArchive / AAR | registry-backed | pinned bridge/platform gate required | pinned create enum lacks AAR | fixture only | fixture only | blocked pending bridge/core evidence |
| XIP | core may identify it | current mobile nesting excludes it | not applicable | explicit unsupported nesting test | explicit unsupported nesting test | not exposed as nested archive |
| ISO, DMG, CAB, CPIO, RPM, XAR, PKG, LHA, AR, WARC, MTREE, DEB | registry-backed where listed | per-format bridge fixture and safety evidence required | not in create DTO | contract snapshot only unless fixture listed | contract snapshot only unless fixture listed | not launch-complete |
| JAR, APK, IPA, APPX, XPI | ZIP-family listing path | bridge fixture and mobile file-access evidence required | not separate create formats | registry/conformance | registry/conformance | read-only aliases; not separate create options |

## Required next evidence

- Refresh this matrix whenever the selected Rust commit or generated bridge
  contract changes.
- Add one bridge fixture and native destination test for every format promoted
  from `blocked` to `exposed`.
- Do not add a format selector merely because the Rust registry lists a format;
  the generated create DTO and verify-after-create behavior must support it.
- Keep RAR creation and repair absent from code and UI.
