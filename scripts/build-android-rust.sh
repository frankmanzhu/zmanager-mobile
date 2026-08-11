#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZMANAGER_DIR="${ZMANAGER_DIR:-$ROOT_DIR/../zmanager}"
ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Library/Android/sdk}}"
ANDROID_NDK_VERSION="${ANDROID_NDK_VERSION:-28.2.13676358}"
ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-$ANDROID_SDK_ROOT/ndk/$ANDROID_NDK_VERSION}"
ANDROID_API_LEVEL="${ANDROID_API_LEVEL:-35}"
TARGET="aarch64-linux-android"
ABI="arm64-v8a"
if [[ -d "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/darwin-arm64" ]]; then
  NDK_HOST="darwin-arm64"
elif [[ -d "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/darwin-x86_64" ]]; then
  NDK_HOST="darwin-x86_64"
else
  echo "No macOS Android NDK toolchain was found under $ANDROID_NDK_HOME." >&2
  exit 1
fi

TOOLCHAIN_DIR="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/$NDK_HOST"
CLANG="$TOOLCHAIN_DIR/bin/${TARGET}${ANDROID_API_LEVEL}-clang"
CLANGXX="$TOOLCHAIN_DIR/bin/${TARGET}${ANDROID_API_LEVEL}-clang++"

for required_path in "$ZMANAGER_DIR/Cargo.toml" "$ANDROID_NDK_HOME" "$CLANG" "$CLANGXX"; do
  if [[ ! -e "$required_path" ]]; then
    echo "Required Android FFI build path is missing: $required_path" >&2
    exit 1
  fi
done

if ! command -v cmake >/dev/null 2>&1; then
  echo "cmake is required to build zmanager-ffi for Android." >&2
  exit 1
fi

if ! command -v ninja >/dev/null 2>&1; then
  echo "ninja is required to build zmanager-ffi for Android." >&2
  exit 1
fi

TEMP_TOOL_BIN="$(mktemp -d "${TMPDIR:-/tmp}/zmanager-android-tools.XXXXXX")"
cleanup() {
  rm -rf "$TEMP_TOOL_BIN"
}
trap cleanup EXIT

ln -s "$TOOLCHAIN_DIR/bin/llvm-ar" "$TEMP_TOOL_BIN/${TARGET}-ar"
ln -s "$TOOLCHAIN_DIR/bin/llvm-ranlib" "$TEMP_TOOL_BIN/${TARGET}-ranlib"
ln -s "$TOOLCHAIN_DIR/bin/llvm-nm" "$TEMP_TOOL_BIN/${TARGET}-nm"

export ANDROID_NDK_HOME
export ANDROID_NDK_ROOT="$ANDROID_NDK_HOME"
export CMAKE_TOOLCHAIN_FILE="$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake"
export CMAKE_GENERATOR=Ninja
export CMAKE_MAKE_PROGRAM="$(command -v ninja)"
export CC_${TARGET//-/_}="$CLANG"
export CXX_${TARGET//-/_}="$CLANGXX"
export AR_${TARGET//-/_}="$TOOLCHAIN_DIR/bin/llvm-ar"
export RANLIB_${TARGET//-/_}="$TOOLCHAIN_DIR/bin/llvm-ranlib"
export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$CLANG"
export PATH="$TEMP_TOOL_BIN:$TOOLCHAIN_DIR/bin:$PATH"

cargo rustc \
  --manifest-path "$ZMANAGER_DIR/Cargo.toml" \
  -p zmanager-ffi \
  --target "$TARGET" \
  --release \
  --lib \
  --crate-type cdylib

JNI_DIR="$ROOT_DIR/android/app/src/main/jniLibs/$ABI"
mkdir -p "$JNI_DIR"
cp "$ZMANAGER_DIR/target/$TARGET/release/deps/libzmanager_ffi.so" "$JNI_DIR/libzmanager_ffi.so"
cp "$TOOLCHAIN_DIR/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so" "$JNI_DIR/libc++_shared.so"

echo "Built zmanager-ffi Android libraries in $JNI_DIR"
