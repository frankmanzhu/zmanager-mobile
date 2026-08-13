# Local Development

Run commands from the repository root unless a section says otherwise.

## Rust

```sh
scripts/check-rust.sh
```

The Rust bridge is owned by the `zmanager` repository (`crates/zmanager-ffi`); this repo keeps no Rust workspace. Mobile builds temporarily pin the Rust source to commit `f65d23385ae583462f6d9e68dd84c6fcae1ec89c` through the shared `ZMANAGER_RELATIVE_DIR` path configuration.

The default `ZMANAGER_RELATIVE_DIR` is `.cache/zmanager`, while
`ZMANAGER_COMMIT` pins that checkout to
`f65d23385ae583462f6d9e68dd84c6fcae1ec89c`. The resolver clones that commit
into the ignored cache directory when needed and does not read from or modify
the sibling `../zmanager` checkout. Set
`ZMANAGER_RELATIVE_DIR` when CI or a later refactor provides the checkout at a
different mobile-relative location. `ZMANAGER_DIR` is an absolute or
mobile-relative override; `ZMANAGER_COMMIT`, `ZMANAGER_REPOSITORY`, and
`ZMANAGER_CACHE_ROOT` are also available for controlled overrides.
`check-rust.sh` runs the `zmanager-ffi` tests from the resolved checkout in
both the explicit `full` (`--features tzap-online`) and `offline`
(`--no-default-features`) profiles. The pinned default is the zmanager
`1e5554e` profile-aware checkout; set `ZMANAGER_DIR` and `ZMANAGER_COMMIT`
explicitly when validating another checked-out revision.

## Android

Open `android/` in Android Studio, or run the local check script:

```sh
scripts/check-android.sh
```

The script uses `./gradlew` when present, then an installed `gradle`, then the locally cached Gradle 8.9 distribution. It honors an existing `JAVA_HOME`; when `JAVA_HOME` is unset, it falls back to Android Studio's bundled JBR. Android Gradle Plugin 8.7 requires JDK 17, and this project is validated with Liberica JDK 17.0.20.

Before Android's `preBuild`, Gradle invokes `scripts/build-android-rust.sh`. That script builds the offline `zmanager-ffi` profile by default and copies the generated arm64 libraries into the ignored `android/app/src/main/jniLibs/arm64-v8a/` directory. Set `ZMANAGER_TZAP_PROFILE=full` when a hosted-auth build is required. You can also set `ZMANAGER_RELATIVE_DIR`, `ZMANAGER_DIR`, `ZMANAGER_COMMIT`, `ANDROID_NDK_HOME`, `ANDROID_NDK_VERSION`, or `ANDROID_API_LEVEL` when the defaults do not match the local machine.

## Maestro UI tests

Maestro provides device-level smoke tests in `maestro/android/` and `maestro/ios/`. Install the CLI with:

```sh
brew install mobile-dev-inc/tap/maestro
```

Start an Android emulator or iOS Simulator, install/build the app, and run the matching flow:

```sh
MAESTRO_PLATFORM=android ./scripts/check-maestro.sh
MAESTRO_PLATFORM=ios ./scripts/check-maestro.sh

# Runs the archive matrix one flow at a time and verifies committed files.
# This clears the debug app's deterministic Extracted test destination per flow.
MAESTRO_PLATFORM=android ./scripts/check-extraction-e2e.sh
MAESTRO_PLATFORM=ios ./scripts/check-extraction-e2e.sh
```

Both Maestro scripts regenerate deterministic ZIP, 7z, TGZ, TAR.ZST, TZAP,
Apple Archive, split ZIP, split 7z, split TZAP, multipart RAR, DEB, and CAB
fixtures before they run. Build and install the debug app after changing fixture
source files so the debug-only **Load test fixture** menu is present. The
extraction matrix covers eleven formats on Android (the five single-file formats
plus six broader-format/multipart cases) and twelve on iOS (the same eleven plus
Apple Archive). Each flow imports the archive through the normal app-cache path,
confirms its listing, reviews the extraction plan, starts the job, and asserts
that every fixture file was committed to app storage. Multipart flows copy all
selected volumes into one private import directory before calling the Rust bridge.
The landing-screen smoke flow continues to exercise the native `Open Archive`
picker entry point.

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

The UDL and `uniffi.toml` live in the pinned `zmanager` checkout
(`crates/zmanager-ffi`). Regenerate bindings after bridge edits:

```sh
scripts/regenerate-bindings-pinned.sh
```

Generated Android Kotlin is written to `android/app/src/main/java/org/tzap/zmanager/mobile/bridge/generated/`.

Generated iOS Swift/modulemap/header files are written to `ios/ZManagerMobile/ZManagerMobile/Bridge/Generated/`.

The iOS Xcode "Build Rust Bridge" phase invokes `scripts/build-ios-rust-pinned.sh`, which builds the pinned checkout's offline profile by default and copies the fat simulator static library into `ios/ZManagerMobile/build/rust/`. Set `ZMANAGER_TZAP_PROFILE=full` for a hosted-auth build.

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
