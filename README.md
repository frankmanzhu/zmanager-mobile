# ZManager Mobile

Native Android and iOS shells for ZManager, backed by the shared Rust archive engine.

## Layout

```text
android/                  Kotlin + Jetpack Compose Android app
ios/                      Swift + SwiftUI iOS app
fixtures/                 Shared archive fixture conventions
scripts/                  Local checks
docs/                     Architecture and platform notes
```

The Rust bridge (`zmanager-ffi`) is owned and built by the sibling
[`zmanager`](https://github.com/tzap-org/zmanager) repository. Generated UniFFI
bindings are checked in here so the app builds without a local Rust toolchain;
regenerate them from `zmanager` when the UDL changes.

## Architecture

Mobile UI and platform file access are native-owned. Archive behavior stays in Rust.

```text
Android Compose / iOS SwiftUI
  -> platform file picker and permission layer
  -> generated UniFFI bindings (from zmanager/zmanager-ffi)
  -> zmanager-core
```

See [docs/mobile-product-design.md](docs/mobile-product-design.md) for the expanded product design, market context, mobile workflows, and roadmap. See [docs/mobile-launch-spec.md](docs/mobile-launch-spec.md) for implementation-facing launch requirements.

## Local Checks

```sh
scripts/check-rust.sh     # runs zmanager-ffi tests in the sibling zmanager repo
scripts/check-android.sh
scripts/check-ios.sh
```

Regenerate UniFFI bindings after bridge UDL or config changes:

```sh
../zmanager/scripts/regenerate-bindings.sh
```

Generated Android bindings live in `android/app/src/main/java/org/tzap/zmanager/mobile/bridge/generated/`. Generated iOS bindings live in `ios/ZManagerMobile/ZManagerMobile/Bridge/Generated/`. Native binary artifacts are built or copied by platform integration and are not checked in by default; the iOS Xcode build phase invokes `zmanager/scripts/build-ios-rust.sh`.

## Initial Targets

- Android: min SDK 26
- iOS: deployment target 15.0

## Launch Direction

ZManager Mobile targets a polished v2-level archive workbench from the first serious release, aligned with the `zm` CLI polish goal: public claims, docs, GUI states, bridge behavior, and platform file handling should agree before a feature is advertised.

The first engineering slice is to wire `zmanager-ffi` to `zmanager-core` and expose:

- `healthcheck`
- `detect_archive`
- `list_archive`
- `test_archive`
- `materialize_preview`
- `plan_extract` / `plan_create`
- job-based `start_create` / `start_extract` with `poll_job_events` / `cancel_job`
