#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
swift build -c release --disable-sandbox
APP="$PWD/artifacts/DroidDock.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/AndroidSimulator "$APP/Contents/MacOS/AndroidSimulator"
cp .build/release/droiddock "$APP/Contents/MacOS/droiddock"
ln -sfn droiddock "$APP/Contents/MacOS/android-simulator"
cp scripts/install-cli.sh "$APP/Contents/Resources/install-cli.sh"
cp Resources/scrcpy-server "$APP/Contents/Resources/scrcpy-server"
for resource in Resources/*; do
  if [ -f "$resource" ]; then cp "$resource" "$APP/Contents/Resources/"; fi
done
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>AndroidSimulator</string>
<key>CFBundleIdentifier</key><string>dev.androidsimulator.mac</string>
<key>CFBundleName</key><string>DroidDock</string>
<key>CFBundleDisplayName</key><string>DroidDock</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.1</string>
<key>CFBundleVersion</key><string>3</string>
<key>CFBundleURLTypes</key><array><dict>
<key>CFBundleURLName</key><string>dev.androidsimulator.mac.commands</string>
<key>CFBundleURLSchemes</key><array><string>droiddock</string><string>android-simulator</string></array>
<key>CFBundleTypeRole</key><string>Editor</string>
</dict></array>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHumanReadableCopyright</key><string>DroidDock. Contains scrcpy server under Apache License 2.0.</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP/Contents/MacOS/droiddock"
codesign --force --sign - "$APP"
printf 'Built %s\n' "$APP"
