#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

APP="$PWD/artifacts/DroidDock.app"
OUTPUT="$PWD/artifacts/DroidDock-macOS.dmg"
if [[ ! -d "$APP" ]]; then
  printf 'Build the app first with ./scripts/build.sh\n' >&2
  exit 1
fi
/usr/bin/codesign --verify --deep --strict "$APP"
/usr/bin/plutil -lint "$APP/Contents/Info.plist"

# Keep build-only Python dependencies isolated and pinned. No Python or build
# tools are included in the image or required by users installing the app.
DMG_TOOLS="$PWD/.build/dmg-tools"
if [[ ! -x "$DMG_TOOLS/bin/python" ]] || ! "$DMG_TOOLS/bin/python" -c 'import sys; sys.exit(sys.version_info < (3, 10))'; then
  DMG_PYTHON="${DROIDDOCK_DMG_PYTHON:-}"
  if [[ -z "$DMG_PYTHON" ]]; then
    for candidate in python3 python3.14 python3.13 python3.12 python3.11 python3.10 /opt/homebrew/bin/python3 /usr/local/bin/python3; do
      if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys; sys.exit(sys.version_info < (3, 10))' 2>/dev/null; then
        DMG_PYTHON="$candidate"
        break
      fi
    done
  fi
  if [[ -z "$DMG_PYTHON" ]] || ! "$DMG_PYTHON" -c 'import sys; sys.exit(sys.version_info < (3, 10))'; then
    printf 'DMG packaging needs Python 3.10 or newer. Set DROIDDOCK_DMG_PYTHON to its executable.\n' >&2
    exit 1
  fi
  "$DMG_PYTHON" -m venv --clear "$DMG_TOOLS"
fi
if ! cmp -s scripts/dmg-requirements.txt "$DMG_TOOLS/requirements.installed"; then
  "$DMG_TOOLS/bin/python" -m pip install --disable-pip-version-check \
    --require-hashes -r scripts/dmg-requirements.txt
  cp scripts/dmg-requirements.txt "$DMG_TOOLS/requirements.installed"
fi

# Generate the background separately from the app. Packaging never rebuilds or
# re-signs the validated application.
swift scripts/make-dmg-background.swift
DMG_WORK_DIR=$(mktemp -d "$PWD/artifacts/.dmg-build.XXXXXX")
cleanup() {
  local result=$?
  if [[ "$result" -ne 0 && -f "$DMG_WORK_DIR/dmg-verification.json" ]]; then
    cp "$DMG_WORK_DIR/dmg-verification.json" artifacts/dmg-last-failure.json
  fi
  if ! python3 scripts/cleanup-dmg-staging.py "$DMG_WORK_DIR"; then
    [[ "$result" -ne 0 ]] || result=1
  fi
  exit "$result"
}
trap cleanup EXIT
mkdir "$DMG_WORK_DIR/support"
cat > "$DMG_WORK_DIR/support/Read Me.txt" <<'DMG_INSTALL_GUIDE'
DroidDock for macOS

INSTALL
Quit any running Android Simulator or DroidDock app before installing.
1. Drag DroidDock.app to the Applications shortcut.
2. Eject this disk image.
3. Open DroidDock from Applications.

REQUIREMENTS
An Apple Silicon Mac (M-series), macOS 13 or newer, an existing Android SDK
with Emulator and Platform-Tools, and an existing compatible virtual device.
The app detects common SDK locations; choose another location in SDK Settings.
Android SDK tools and system images are not included in this download.

TERMINAL AND EXPO
After installing the app, open Settings > Terminal and copy the install
command. Paste it into Terminal, then follow its PATH instructions.
  droiddock list
  droiddock boot Pixel_10_Pro
In your Expo project, run npx expo start and press A. Use Shift+A to select
the device when more than one is available. Use the same Android SDK in
Expo and in this app. Run droiddock --help for all commands.

DEVELOPMENT BUILD
This build is ad-hoc signed and has not been notarized by Apple. macOS may
block a downloaded copy from opening. Public distribution with the standard
macOS trust checks requires Developer ID signing and notarization.

Bundled third-party licenses are in the application's Contents/Resources.
DMG_INSTALL_GUIDE

"$DMG_TOOLS/bin/dmgbuild" -s scripts/dmg-settings.py \
  -D "project=$PWD" -D "support=$DMG_WORK_DIR/support" \
  DroidDock "$DMG_WORK_DIR/DroidDock-macOS.dmg"
"$DMG_TOOLS/bin/python" scripts/verify-dmg.py \
  "$DMG_WORK_DIR/DroidDock-macOS.dmg" "$APP" \
  --report "$DMG_WORK_DIR/dmg-verification.json"
mv -f "$DMG_WORK_DIR/DroidDock-macOS.dmg" "$OUTPUT"
mv -f "$DMG_WORK_DIR/dmg-verification.json" artifacts/dmg-verification.json
(cd artifacts && /usr/bin/shasum -a 256 DroidDock-macOS.dmg > DroidDock-macOS.dmg.sha256)
printf 'Created %s\n' "$OUTPUT"
