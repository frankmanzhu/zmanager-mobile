#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ANDROID_DIR="$ROOT_DIR/android"
JBR_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"

if [[ -x "$JBR_HOME/bin/java" ]]; then
  export JAVA_HOME="$JBR_HOME"
fi

cd "$ANDROID_DIR"

if [[ -x "./gradlew" ]]; then
  ./gradlew :app:assembleDebug
elif command -v gradle >/dev/null 2>&1; then
  gradle :app:assembleDebug
elif [[ -x "$HOME/.gradle/wrapper/dists/gradle-8.9-bin/90cnw93cvbtalezasaz0blq0a/gradle-8.9/bin/gradle" ]]; then
  "$HOME/.gradle/wrapper/dists/gradle-8.9-bin/90cnw93cvbtalezasaz0blq0a/gradle-8.9/bin/gradle" :app:assembleDebug
else
  cat >&2 <<'EOF'
Android Gradle is unavailable.

Open android/ in Android Studio, or install/generate a Gradle wrapper and rerun:
  ./gradlew :app:assembleDebug
EOF
  exit 1
fi
