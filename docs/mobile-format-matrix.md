# ZManager Mobile Format Exposure Matrix

Last reviewed: 2026-08-21

This matrix is the mobile V2 format contract. Every format registered by
`zmanager-core` must have a dedicated mobile bridge classification and a
capability row; no registered kind may be collapsed into `Other`. The
capability row is authoritative for list/extract/create operations on the
current target. A platform/backend limitation is reported explicitly by the
bridge and is not a missing mobile type.

The mobile bridge is generated from the sibling `../zmanager` checkout at the
same release revision. `ArchiveFormat` now mirrors every registered core kind,
including the previously missing TAR codecs, ISO/CAB/package/disk-image
formats, DEB, and UDF. `CreateArchiveFormat` mirrors every core create adapter:
ZIP (including split volume mode), 7z, TAR+Zstd, TAR+Gzip, TZAP, and Apple
Archive. Formats with no core create adapter remain valid read/extract formats;
they are not silently advertised as creators. Read/list support is driven by the
generated bridge and the format contract snapshot at
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
| TAR+Gzip / `.tgz`, `.tar.gz` | registry-backed | fixture/listing coverage | verified through create DTO | JVM/bridge | XCTest/bridge | exposed |
| TZAP | registry-backed | fixture/listing coverage | verified through create DTO | JVM/fixture | XCTest/fixture | exposed; recovery-oriented copy is still limited |
| TAR, TAR.BZ2, TAR.XZ, TAR.LZMA, TAR.LZ, TAR.LZO, TAR.Z, TAR.LZ4, TAR.UU | registry-backed | registry-backed | no core create adapter | snapshot/conformance | snapshot/conformance | dedicated bridge types; read/extract only |
| GZIP, BZIP2, XZ, Zstd streams | registry-backed | registry-backed | no core create adapter | snapshot/conformance | snapshot/conformance | dedicated bridge types; read/extract only |
| RAR / multipart RAR | verified | verified, including grouped five-part extraction | intentionally absent | bridge + Maestro multipart flow | bridge + Maestro multipart flow | extraction-only; no create/repair |
| split ZIP / split 7z | verified | volume-set handling verified | verified through pinned `volume_size` DTO | JVM, connected, Maestro split-create/extract | XCTest, Maestro split-create/extract | exposed with companion-volume guidance |
| AppleArchive / AAR | registry-backed | registry-backed where platform backend is available | core create adapter exposed | capability snapshot/fixture | capability snapshot/fixture | dedicated bridge type; target availability remains explicit |
| XIP | core may identify it | current mobile nesting excludes it | not applicable | explicit unsupported nesting test | explicit unsupported nesting test | not exposed as nested archive |
| ISO, CAB, CPIO, RPM, XAR, PKG, DMG, LHA, AR, WARC, DEB, MSI, VHD, VMDK, UDF | verified | verified on Android and iOS | no core create adapter | bridge + connected + Maestro | bridge + XCTest + Maestro | dedicated bridge types; read/extract only |
| MTREE | verified | intentionally unavailable in the core registry | no core create adapter | bridge + connected + Maestro test flow | bridge + XCTest + Maestro test flow | list/test-only capability is explicit, not a mobile gate |
| JAR, APK, IPA, APPX, XPI | ZIP-family listing path | bridge fixture and mobile file-access evidence required | not separate create formats | registry/conformance | registry/conformance | read-only aliases; not separate create options |

## Required evidence

- Refresh this matrix whenever the selected Rust commit or generated bridge
  contract changes.
- Keep one bridge classification/capability assertion for every registered core
  kind and add native archive fixtures as each format enters device E2E.
- Do not add a create selector for a format unless the core registry exposes a
  create adapter and the mobile bridge carries its create options.
- Treat `UnsupportedPlatform` and `no registered operation adapter` as explicit
  capability results, never as `Other` or a hidden selector gap.
- Keep RAR creation and repair absent from code and UI.
- Treat split ZIP, split 7z, split TZAP, and multipart RAR as volume sets at
  import time; companion files must be staged and cleaned together.
- The current device matrix has direct Android and iOS extraction/test flows
  for every row above, including AppleArchive, DEB, CAB, split archives, and
  multipart RAR. The E2E harness verifies app-private output counts and removes
  its temporary fixture/import roots after every flow.
