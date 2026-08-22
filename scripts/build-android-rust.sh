#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZMANAGER_DIR="$($ROOT_DIR/scripts/resolve-zmanager-source.sh)"
ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Library/Android/sdk}}"
ANDROID_NDK_VERSION="${ANDROID_NDK_VERSION:-28.2.13676358}"
ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-$ANDROID_SDK_ROOT/ndk/$ANDROID_NDK_VERSION}"
ANDROID_API_LEVEL="${ANDROID_API_LEVEL:-35}"
TZAP_PROFILE_ARGS=()
TZAP_FEATURE=""
if grep -Eq '^tzap-online[[:space:]]*=' "$ZMANAGER_DIR/crates/zmanager-ffi/Cargo.toml"; then
  TZAP_FEATURE="tzap-online"
elif grep -Eq '^auth[[:space:]]*=' "$ZMANAGER_DIR/crates/zmanager-ffi/Cargo.toml"; then
  TZAP_FEATURE="auth"
else
  echo "The zmanager-ffi checkout does not expose a supported full-profile feature." >&2
  exit 1
fi
case "${ZMANAGER_TZAP_PROFILE:-offline}" in
  full)
    TZAP_PROFILE_ARGS=(--no-default-features --features "$TZAP_FEATURE")
    ;;
  offline)
    TZAP_PROFILE_ARGS=(--no-default-features)
    ;;
  *)
    echo "ZMANAGER_TZAP_PROFILE must be full or offline" >&2
    exit 2
    ;;
esac
if [[ -d "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/darwin-arm64" ]]; then
  NDK_HOST="darwin-arm64"
elif [[ -d "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/darwin-x86_64" ]]; then
  NDK_HOST="darwin-x86_64"
else
  echo "No macOS Android NDK toolchain was found under $ANDROID_NDK_HOME." >&2
  exit 1
fi

TOOLCHAIN_DIR="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/$NDK_HOST"

# ABIs to build. Defaults to arm64-v8a only, matching every physical device
# this app ships to.
#
# x86_64 (the Android Studio emulator's ABI on Intel/Rosetta hosts) is
# supported by this script but NOT built by default: zmanager-unrar's vendored
# system.cpp and rijndael.cpp call __builtin_cpu_supports("avx2"/"aes") for
# runtime AES-NI/SIMD dispatch, which on this NDK's x86_64 target lowers to a
# non-PIC-compatible reference to the compiler-rt __cpu_model symbol and fails
# to link into a shared object:
#   ld.lld: error: relocation R_X86_64_PC32 cannot be used against symbol
#   '__cpu_model'; recompile with -fPIC
# This is not a missing -fPIC flag on our side (forcing CFLAGS_x86_64_linux_android
# and CXXFLAGS_x86_64_linux_android to -fPIC and forcing a clean rebuild of
# zmanager-unrar does not change the error); it reproduces identically after a
# forced rebuild, so the CPU-dispatch code itself needs a non-ifunc fallback
# path for this target. That is vendored-unrar work in the sibling zmanager
# repository, not something this script can work around. See Track 9 in
# docs/mobile-code-health-remediation-plan.md.
#
# armeabi-v7a and x86 are not built by default either: minSdk 26 already
# excludes very few remaining devices that would need them, and adding them
# means two more cross-compiles of the same vendored C++.
#
# Override with e.g. ZMANAGER_ANDROID_ABIS="arm64-v8a x86_64" once the
# upstream unrar fix lands.
read -r -a ABIS <<< "${ZMANAGER_ANDROID_ABIS:-arm64-v8a}"

abi_to_target() {
  case "$1" in
    arm64-v8a) echo "aarch64-linux-android" ;;
    x86_64) echo "x86_64-linux-android" ;;
    armeabi-v7a) echo "armv7-linux-androideabi" ;;
    x86) echo "i686-linux-android" ;;
    *)
      echo "Unknown Android ABI: $1" >&2
      exit 1
      ;;
  esac
}

# The NDK's per-arch sysroot directory that holds libc++_shared.so does not
# always match the Rust target triple (armv7-linux-androideabi's sysroot
# subdirectory is arm-linux-androideabi, for example).
abi_to_sysroot_arch() {
  case "$1" in
    arm64-v8a) echo "aarch64-linux-android" ;;
    x86_64) echo "x86_64-linux-android" ;;
    armeabi-v7a) echo "arm-linux-androideabi" ;;
    x86) echo "i686-linux-android" ;;
    *)
      echo "Unknown Android ABI: $1" >&2
      exit 1
      ;;
  esac
}

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

export ANDROID_NDK_HOME
export ANDROID_NDK_ROOT="$ANDROID_NDK_HOME"
export CMAKE_TOOLCHAIN_FILE="$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake"
export CMAKE_GENERATOR=Ninja
export CMAKE_MAKE_PROGRAM="$(command -v ninja)"
export PATH="$TEMP_TOOL_BIN:$TOOLCHAIN_DIR/bin:$PATH"

for abi in "${ABIS[@]}"; do
  target="$(abi_to_target "$abi")"
  sysroot_arch="$(abi_to_sysroot_arch "$abi")"
  clang="$TOOLCHAIN_DIR/bin/${target}${ANDROID_API_LEVEL}-clang"
  clangxx="$TOOLCHAIN_DIR/bin/${target}${ANDROID_API_LEVEL}-clang++"

  for required_path in "$ZMANAGER_DIR/Cargo.toml" "$ANDROID_NDK_HOME" "$clang" "$clangxx"; do
    if [[ ! -e "$required_path" ]]; then
      echo "Required Android FFI build path is missing: $required_path" >&2
      exit 1
    fi
  done

  target_env="${target//-/_}"
  ln -sf "$TOOLCHAIN_DIR/bin/llvm-ar" "$TEMP_TOOL_BIN/${target}-ar"
  ln -sf "$TOOLCHAIN_DIR/bin/llvm-ranlib" "$TEMP_TOOL_BIN/${target}-ranlib"
  ln -sf "$TOOLCHAIN_DIR/bin/llvm-nm" "$TEMP_TOOL_BIN/${target}-nm"

  export "CC_${target_env}=$clang"
  export "CXX_${target_env}=$clangxx"
  export "AR_${target_env}=$TOOLCHAIN_DIR/bin/llvm-ar"
  export "RANLIB_${target_env}=$TOOLCHAIN_DIR/bin/llvm-ranlib"
  export "CARGO_TARGET_$(echo "$target_env" | tr '[:lower:]' '[:upper:]')_LINKER=$clang"

  cargo rustc \
    --manifest-path "$ZMANAGER_DIR/Cargo.toml" \
    -p zmanager-ffi \
    "${TZAP_PROFILE_ARGS[@]}" \
    --target "$target" \
    --release \
    --lib \
    --crate-type cdylib

  JNI_DIR="$ROOT_DIR/android/app/src/main/jniLibs/$abi"
  mkdir -p "$JNI_DIR"
  cp "$ZMANAGER_DIR/target/$target/release/deps/libzmanager_ffi.so" "$JNI_DIR/libzmanager_ffi.so"
  cp "$TOOLCHAIN_DIR/sysroot/usr/lib/$sysroot_arch/libc++_shared.so" "$JNI_DIR/libc++_shared.so"

  echo "Built zmanager-ffi Android libraries in $JNI_DIR"
done
