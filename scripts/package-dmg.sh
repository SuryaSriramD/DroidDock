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

SET UP ANDROID
Requires an Apple Silicon Mac (M-series) running macOS 13 or newer.
Open DroidDock and choose Set Up Android, then View Available Versions.
Choose Download beside the Android version you want. Review the download size,
free-space requirement and licenses, then choose Agree & Download. DroidDock
downloads the Android components directly from Google and creates a separate
phone for that version. Android Studio and Java are not required.
The Google Play Store is not included. After setup, open the device library
and choose Start Device.

Initial setup requires an internet connection and free disk space for the
download, extraction and device data. The setup screen shows current sizes.
Android components are downloaded on first setup, not bundled in this DMG.
You can also choose Use an Existing Android SDK to keep using existing devices.

MORE ANDROID VERSIONS AND APP UPDATES
Choose Android Versions or Add Phone to see the current stable versions.
Downloads are optional. Adding a version preserves existing phones and data.
Deleting a phone keeps its installed image for later phone creation.
Choose DroidDock > Check for Updates to check for a newer app release.
Settings controls daily automatic app update checks. App updates currently
use a DMG download and manual replacement in Applications.

TERMINAL AND EXPO
When first opened from /Applications or ~/Applications, DroidDock presents
Terminal Setup. Review the selected Android SDK and the directories to add
to PATH, then choose Set Up Terminal. Choose Later to skip without changing
terminal files. Reopen Terminal Setup from the DroidDock app menu, the
library sidebar, or Settings.

After you enable setup, new zsh and Bash terminals get the droiddock command.
With an Android SDK selected, they also get adb, emulator and that SDK's
Android environment. Later SDK selections keep the enabled environment
current. Open a new terminal after setup, then run:
  droiddock list
  droiddock boot DroidDock_Phone_API_36
Use an ID from droiddock list when choosing a different device.

Boot the phone with droiddock first. In your Expo project, run npx expo start
and press Shift+A to choose the running DroidDock phone, or A when it is the
only suitable device. Expo's own emulator launches are not routed through
DroidDock. Native Android builds may need additional SDK build packages.

Settings > Terminal shows setup status and lets you reopen Terminal Setup.
For an already-open project terminal, use Copy Android Environment and paste
those commands before starting Expo. Run droiddock --help for all commands.

After you choose Set Up Terminal, setup creates ~/.local/bin/droiddock and
adds a marked block to shell profiles to source DroidDock's generated
environment.sh. Existing profile content is preserved; changed profiles are
backed up under
~/Library/Application Support/DroidDock/Terminal/Backups. Copies opened from
this disk image or a development folder do not configure terminal tools.
Copy Terminal Install Command remains an optional manual fallback. That
script creates the command link and prints PATH instructions without editing
shell profiles.

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
