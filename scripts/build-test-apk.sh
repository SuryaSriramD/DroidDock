#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
SDK="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Library/Android/sdk}}"
JDK="${ANDROID_STUDIO_JDK:-/Applications/Android Studio.app/Contents/jbr/Contents/Home}"
TOOLS="$SDK/build-tools/${ANDROID_BUILD_TOOLS_VERSION:-36.1.0}"
PLATFORM="$SDK/platforms/android-${ANDROID_PLATFORM_API:-36}/android.jar"
OUT="$PWD/artifacts/test-apk"
for REQUIRED in "$JDK/bin/javac" "$JDK/bin/java" "$JDK/bin/jar" "$JDK/bin/keytool" "$TOOLS/aapt2" "$TOOLS/zipalign" "$TOOLS/lib/d8.jar" "$TOOLS/lib/apksigner.jar" "$PLATFORM"; do
  if [ ! -f "$REQUIRED" ]; then
    printf 'Missing build prerequisite: %s\nSet ANDROID_SDK_ROOT / ANDROID_STUDIO_JDK or install the matching SDK platform/build-tools.\n' "$REQUIRED" >&2
    exit 1
  fi
done
rm -rf "$OUT/classes" "$OUT/dex"
mkdir -p "$OUT/classes" "$OUT/dex"
"$JDK/bin/javac" -source 8 -target 8 -bootclasspath "$PLATFORM" -d "$OUT/classes" Tests/Fixtures/AndroidProbe/ProbeActivity.java
"$JDK/bin/jar" cf "$OUT/classes.jar" -C "$OUT/classes" .
"$JDK/bin/java" -cp "$TOOLS/lib/d8.jar" com.android.tools.r8.D8 --lib "$PLATFORM" --output "$OUT/dex" "$OUT/classes.jar"
"$TOOLS/aapt2" link -I "$PLATFORM" --manifest Tests/Fixtures/AndroidProbe/AndroidManifest.xml -o "$OUT/probe-unsigned.apk"
"$JDK/bin/jar" uf "$OUT/probe-unsigned.apk" -C "$OUT/dex" classes.dex
"$TOOLS/zipalign" -f 4 "$OUT/probe-unsigned.apk" "$OUT/probe-aligned.apk"
if [ ! -f "$OUT/debug.keystore" ]; then
  "$JDK/bin/keytool" -genkeypair -keystore "$OUT/debug.keystore" -storepass android -keypass android -alias androiddebugkey -dname "CN=Local Test" -keyalg RSA -validity 3650
fi
"$JDK/bin/java" -jar "$TOOLS/lib/apksigner.jar" sign --ks "$OUT/debug.keystore" --ks-pass pass:android --key-pass pass:android --out "$OUT/probe.apk" "$OUT/probe-aligned.apk"
"$JDK/bin/java" -jar "$TOOLS/lib/apksigner.jar" verify "$OUT/probe.apk"
printf 'Built %s\n' "$OUT/probe.apk"
