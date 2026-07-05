# ZManager Mobile

Native Android and iOS shells for ZManager, backed by the shared Rust archive engine.

## Layout

```text
android/                  Kotlin + Jetpack Compose Android app
ios/                      Swift + SwiftUI iOS app
rust/zmanager-mobile-core UniFFI bridge over zmanager-core
fixtures/                 Shared archive fixture conventions
scripts/                  Binding generation and local checks
docs/                     Architecture and platform notes
```

## Architecture

Mobile UI and platform file access are native-owned. Archive behavior stays in Rust.

```text
Android Compose / iOS SwiftUI
  -> platform file picker and permission layer
  -> generated UniFFI bindings
  -> zmanager-mobile-core
  -> zmanager-core
```

See [docs/mobile-product-design.md](docs/mobile-product-design.md) for the expanded product design, market context, mobile workflows, and roadmap. See [docs/mobile-launch-spec.md](docs/mobile-launch-spec.md) for implementation-facing launch requirements.

## Local Checks

```sh
scripts/check-rust.sh
scripts/check-android.sh
scripts/check-ios.sh
```

Regenerate UniFFI bindings after bridge UDL or config changes:

```sh
scripts/generate-uniffi-bindings.sh
```

Generated Android bindings live in `android/app/src/main/java/org/tzap/zmanager/mobile/bridge/generated/`. Generated iOS bindings live in `ios/ZManagerMobile/ZManagerMobile/Bridge/Generated/`. Native binary artifacts are built or copied by platform integration and are not checked in by default.

## Initial Targets

- Android: min SDK 26
- iOS: deployment target 15.0

## Launch Direction

ZManager Mobile targets a polished v2-level archive workbench from the first serious release, aligned with the `zm` CLI polish goal: public claims, docs, GUI states, bridge behavior, and platform file handling should agree before a feature is advertised.

The first engineering slice is to wire `zmanager-mobile-core` to `zmanager-core` and expose:

- `healthcheck`
- `detect_archive`
- `list_archive`
- `test_archive`
- `plan_extract`
- `start_extract`
- `plan_create`
- `start_create`
- `poll_job_events`
- `cancel_job`
- `clear_sensitive_state`
