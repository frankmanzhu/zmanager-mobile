# Local Development

## Rust

```powershell
cd C:\Users\frankzhu\Projects\zmanager-mobile\rust
cargo check
```

## Android

Open `android/` in Android Studio, or use Gradle once a wrapper has been generated:

```powershell
cd C:\Users\frankzhu\Projects\zmanager-mobile\android
.\gradlew.bat :app:assembleDebug
```

The skeleton does not check in a Gradle wrapper yet. Generate one from Android Studio or an installed Gradle distribution before CI setup.

## iOS

Open this project on macOS with Xcode:

```sh
open ios/ZManagerMobile/ZManagerMobile.xcodeproj
```

iOS builds require macOS and Xcode.

