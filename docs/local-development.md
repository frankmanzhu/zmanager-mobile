# Local Development

Run commands from the repository root unless a section says otherwise.

## Rust

```sh
scripts/check-rust.sh
```

The Rust bridge is owned by the sibling `zmanager` repository (`crates/zmanager-ffi`); this repo keeps no Rust workspace. `check-rust.sh` runs the `zmanager-ffi` tests there.

## Android

Open `android/` in Android Studio, or run the local check script:

```sh
scripts/check-android.sh
```

The script uses `./gradlew` when present, then an installed `gradle`, then the locally cached Gradle 8.9 distribution. It honors an existing `JAVA_HOME`; when `JAVA_HOME` is unset, it falls back to Android Studio's bundled JBR. Android Gradle Plugin 8.7 requires JDK 17, and this project is validated with Liberica JDK 17.0.20.

Before Android's `preBuild`, Gradle invokes `scripts/build-android-rust.sh`. That script builds `zmanager-ffi` from the sibling `zmanager` repository and copies the generated arm64 libraries into the ignored `android/app/src/main/jniLibs/arm64-v8a/` directory. Set `ZMANAGER_DIR`, `ANDROID_NDK_HOME`, `ANDROID_NDK_VERSION`, or `ANDROID_API_LEVEL` when the defaults do not match the local machine.

## Maestro UI tests

Maestro provides device-level smoke tests in `maestro/android/` and `maestro/ios/`. Install the CLI with:

```sh
brew install mobile-dev-inc/tap/maestro
```

Start an Android emulator or iOS Simulator, install/build the app, and run the matching flow:

```sh
MAESTRO_PLATFORM=android ./scripts/check-maestro.sh
MAESTRO_PLATFORM=ios ./scripts/check-maestro.sh
```

`scripts/check-maestro.sh` regenerates the deterministic fixture archive before it
runs. Build and install the debug app after changing fixture source files so the
debug-only **Load Maestro fixture** action is present. The workflow suite imports
that archive through the same app-cache import path as normal files, browses text,
JSON, SVG, Markdown, and PDF entries, verifies the archive through the Rust
bridge, and covers the complete plan-review, staged extraction, native commit,
and completion flow in `extraction-workflow.yaml`. The landing-screen smoke flow
continues to exercise the native `Open Archive` picker entry point.

The E2E destination is deterministic app storage. The UI also supports Android
SAF tree destinations and iOS security-scoped folders; exercise those
provider-specific commit paths manually against the providers supported by the
release build.

## iOS

Open this project on macOS with Xcode:

```sh
open ios/ZManagerMobile/ZManagerMobile.xcodeproj
```

iOS builds require macOS and Xcode. The local build check is:

```sh
scripts/check-ios.sh
```

## UniFFI Bindings

The UDL and `uniffi.toml` live in the sibling `zmanager` repo (`crates/zmanager-ffi`). Regenerate bindings after edits there:

```sh
../zmanager/scripts/regenerate-bindings.sh
```

Generated Android Kotlin is written to `android/app/src/main/java/org/tzap/zmanager/mobile/bridge/generated/`.

Generated iOS Swift/modulemap/header files are written to `ios/ZManagerMobile/ZManagerMobile/Bridge/Generated/`.

The iOS Xcode "Build Rust Bridge" phase invokes `zmanager/scripts/build-ios-rust.sh` and copies the fat simulator static library into `ios/ZManagerMobile/build/rust/`.

Do not check generated native binary artifacts into the repository by default. Platform build integration should build or copy those artifacts explicitly.

## Fixtures

Archive fixture conventions live in `fixtures/README.md`.

- `fixtures/archives/required/` is for launch-scope archive fixtures.
- `fixtures/archives/optional/` is for additional compatibility samples.
- `fixtures/archives/hostile/` is for bounded unsafe-path, duplicate-path, damaged, or zip-bomb-like samples.
- `fixtures/metadata/` stores non-secret fixture passwords and expected outcomes.
- `fixtures/platform/` stores provider, permission, low-storage, and cloud-unavailable simulation notes.

Do not store private archives, real provider URIs, security-scoped URLs, permission tokens, or sensitive passwords in fixtures.

## Icons

Mobile icons are derived from the ZManager Desktop icon source in `zmanager-desktop/src-tauri/icons/icon.png`.

Android icon assets live under `android/app/src/main/res/`.

iOS app icon assets live in `ios/ZManagerMobile/ZManagerMobile/Assets.xcassets/AppIcon.appiconset/`.
