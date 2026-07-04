# ZManager Mobile Architecture

## Direction

ZManager Mobile uses native Android and iOS shells over a shared Rust archive layer.

```text
Android: Kotlin + Jetpack Compose
iOS:     Swift + SwiftUI
Shared:  Rust + UniFFI bridge over zmanager-core
```

The mobile apps should share archive behavior, not UI code.

## Boundaries

### Native Shells Own

- file and directory pickers
- Android Storage Access Framework and `content://` URI handling
- iOS document picker and security-scoped resource access
- permissions
- share/import extensions
- app lifecycle, notifications, and platform background rules
- user-facing presentation and navigation

### Rust Owns

- archive type detection
- listing
- extraction planning
- extraction safety
- creation planning
- create/extract/test execution
- job progress and cancellation
- normalized archive errors

## Rust Bridge

The bridge should stay small and DTO-oriented:

```text
healthcheck
list_archive
test_archive
plan_extract
start_extract
plan_create
start_create
poll_job_events
cancel_job
```

Do not pass passwords through logs, persistent storage, command-line arguments, analytics, or crash diagnostics.

## File Strategy

Mobile platforms often do not provide durable filesystem paths.

Android usually gives `content://` URIs. The Android shell should copy archive inputs to app cache or expose a controlled stream before Rust touches them. Extraction outputs may need to be written through SAF when the user chooses an external destination.

iOS may require security-scoped URLs from the document picker. The iOS shell should open the security scope, copy or coordinate access as needed, and pass Rust a temporary path when that is safer than holding a platform URL across the bridge.

## Initial Platform Targets

- Android min SDK: 26
- Android target SDK: 35
- iOS deployment target: 15.0

## Repo Layout

```text
android/
  app/
    src/main/java/org/tzap/zmanager/mobile/

ios/
  ZManagerMobile/
    ZManagerMobile.xcodeproj/
    ZManagerMobile/

rust/
  Cargo.toml
  zmanager-mobile-core/
    Cargo.toml
    src/
    uniffi/
```

