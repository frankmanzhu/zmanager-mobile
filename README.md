# ZManager Mobile

Native Android and iOS shells for ZManager, backed by the shared Rust archive engine.

## Layout

```text
android/                  Kotlin + Jetpack Compose Android app
ios/                      Swift + SwiftUI iOS app
rust/zmanager-mobile-core UniFFI bridge over zmanager-core
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

## Initial Targets

- Android: min SDK 26
- iOS: deployment target 15.0

## First Milestone

Wire `zmanager-mobile-core` to `zmanager-core` and expose:

- `healthcheck`
- `list_archive`
- `test_archive`
- `plan_extract`
- `start_extract`
- `plan_create`
- `start_create`
- `poll_job_events`
- `cancel_job`

