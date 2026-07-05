# Local Development

Run commands from the repository root unless a section says otherwise.

## Rust

```sh
scripts/check-rust.sh
```

The Rust workspace includes `rust/zmanager-mobile-core` and the local UniFFI bindgen helper.

## Android

Open `android/` in Android Studio, or run the local check script:

```sh
scripts/check-android.sh
```

The script uses `./gradlew` when present, then an installed `gradle`, then the locally cached Gradle 8.9 distribution. When Android Studio is installed, it pins `JAVA_HOME` to Android Studio's bundled JBR so command-line builds do not accidentally use an unsupported host Java version.

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

Regenerate bindings after edits to `rust/zmanager-mobile-core/uniffi/zmanager_mobile_core.udl` or `rust/zmanager-mobile-core/uniffi/uniffi.toml`:

```sh
scripts/generate-uniffi-bindings.sh
```

Generated Android Kotlin is written to `android/app/src/main/java/org/tzap/zmanager/mobile/bridge/generated/`.

Generated iOS Swift/modulemap/header files are written to `ios/ZManagerMobile/ZManagerMobile/Bridge/Generated/`.

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
