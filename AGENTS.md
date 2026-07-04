# Repository Guidelines

## Architecture

ZManager Mobile uses native Android and iOS shells over a shared Rust bridge.

- `android/`: Kotlin and Jetpack Compose. Own Android file pickers, Storage Access Framework, `content://` handling, permissions, and UI.
- `ios/`: Swift and SwiftUI. Own iOS document pickers, security-scoped URLs, share/import flows, permissions, and UI.
- `rust/zmanager-mobile-core/`: UniFFI bridge over `zmanager-core`. Keep archive behavior in Rust.
- `docs/`: architecture and development notes.

Do not reimplement archive parsing, extraction, creation, or extraction safety in Kotlin or Swift.

## Security

Passwords must never be logged, persisted, passed through command-line arguments, included in diagnostics, or stored in crash reports. Platform shells may hold passwords only in transient UI state long enough to call the Rust bridge.

## Mobile File Rules

Android `content://` URIs and iOS security-scoped URLs are platform objects. Convert them to controlled cache paths or streams before invoking Rust, and keep platform permission lifetimes native-owned.

## Testing

Prioritize bridge-boundary tests, platform file access behavior, archive listing, extraction planning, cancellation, error normalization, and password-required flows.

