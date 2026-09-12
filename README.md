# DroidDock

A native macOS workspace for Android virtual devices, with a Simulator-style device window and a terminal command for app development and Expo workflows.

**[Download DroidDock for Apple Silicon](https://github.com/SuryaSriramD/DroidDock/releases/download/v0.2.1/DroidDock-macOS.dmg)** · [SHA-256 checksum](https://github.com/SuryaSriramD/DroidDock/releases/download/v0.2.1/DroidDock-macOS.dmg.sha256) · [Release notes](https://github.com/SuryaSriramD/DroidDock/releases/tag/v0.2.1)

Version **0.2.1 is a development preview**. The app is ad-hoc signed and has not been notarized by Apple, so macOS may block a downloaded copy. Developer ID signing, notarization, and broader compatibility testing remain release work.

## Requirements

- An Apple Silicon Mac running macOS 13 or newer. The downloadable build is `arm64`; Intel support has not been validated.
- An existing Android SDK with **Android Emulator** and **Platform-Tools** installed.
- An existing Android virtual device (AVD) with a compatible `arm64-v8a` system image. Create one in Android Studio's Device Manager before using DroidDock.
- Enough memory and disk space for your virtual device.

Android SDK tools and system images are not bundled. Xcode and Python are not required to install or run the downloaded app.

## Install

1. Quit any running DroidDock or older Android Simulator app.
2. Open the DMG and drag **DroidDock** onto **Applications**.
3. Eject the disk image and open DroidDock from Applications.
4. Confirm the Android SDK path in Settings, select your virtual device, and choose **Start Device**.

The installer has a compact mint background, an app-to-Applications arrow, and instructions. Existing preferences and runtime history are preserved across the rename from Android Simulator.

## Terminal and Expo

In DroidDock, open **Settings → Terminal → Copy Terminal Install Command**, then paste the command into Terminal. Alternatively, after installing in Applications:

```sh
/bin/bash "/Applications/DroidDock.app/Contents/Resources/install-cli.sh"
export PATH="$HOME/.local/bin:$PATH"
droiddock list
droiddock boot Pixel_10_Pro
```

Replace `Pixel_10_Pro` with an ID returned by `list`. The installer creates a link at `~/.local/bin/droiddock`; it does not edit shell profiles or overwrite an existing command. Add that directory to your shell's PATH to keep the command available in future sessions.

With the device running, start your Expo project:

```sh
npx expo start
# Press A to open Android, or Shift+A to choose the running device.
```

Use the same Android SDK in Expo and DroidDock. Expo connects to the existing device through ADB.

Other commands:

```sh
droiddock status Pixel_10_Pro --json
droiddock install Pixel_10_Pro /absolute/path/app.apk
droiddock open-url Pixel_10_Pro 'exp://127.0.0.1:8081'
droiddock stop Pixel_10_Pro
droiddock --help
```

The client controls the same app-owned runtime. Devices started by another application remain externally managed. The bundled legacy `android-simulator` command and URL scheme remain compatible. `DROIDDOCK_APP` or `--app '/path/DroidDock.app'` selects a specific app bundle.

## Features

- Native device windows with a floating toolbar, rounded phone frame, rotation, fullscreen, and saved display scales.
- Embedded video and direct touch, drag, scroll, keyboard, and hardware controls.
- APK installation, screenshots, video-only MP4 recording, and streaming Logcat.
- Explicit clipboard transfer, snapshot management, and confirmed restart/stop/data-wipe actions.
- Diagnostics export, bounded runtime-failure reports, and app-owned process tracking.

DroidDock uses Google's Android Emulator headlessly and a native client for the bundled scrcpy server. It works with existing AVDs; managed SDK downloads and a full device-creation wizard are future capabilities.

## Build from source

Building requires the Swift 6 toolchain from Xcode or compatible Command Line Tools.

```sh
git clone https://github.com/SuryaSriramD/DroidDock.git
cd DroidDock
swift test --disable-sandbox
./scripts/build.sh
open "artifacts/DroidDock.app"
```

The build script creates an ad-hoc-signed app. To package it as a DMG, install Python 3.10 or newer, then run:

```sh
./scripts/package-dmg.sh
```

Packaging uses isolated, hash-pinned dependencies under `.build/dmg-tools`, generates Retina artwork, and verifies the image, app contents, signatures, and Finder layout. It preserves the existing app binary and writes a checksum alongside the DMG. `DROIDDOCK_DMG_PYTHON` can select a Python executable.

The internal Swift package/executable name remains `AndroidSimulator` to preserve existing identifiers. For an unpackaged development run, use `swift run AndroidSimulator` from the repository root.

## Validation and roadmap

The v0.2.0 baseline passed 175 automated tests. The v0.2.1 rename passed 25 focused tests, and the redesigned DMG passed package-integrity checks and a native Finder visual check. The uploaded installer was independently reverified on 12 September 2026. These results do not establish compatibility across all supported macOS versions, Intel support, or production-release certification.

- [Validation record](docs/VALIDATION.md)
- [Requirements audit and remaining work](docs/REQUIREMENTS_AUDIT.md)
- [Implementation plan](docs/IMPLEMENTATION_PLAN.md)
- [Detailed development notes](docs/DEVELOPMENT_NOTES.md)
- [Product and technical specifications](docs/specifications)

Generated builds, local test logs, screenshots, runtime evidence, and development caches are excluded from this repository. Historical local evidence paths in the development documents are retained as references, not public downloads.

## License

[Apache License 2.0](LICENSE). The bundled scrcpy server includes its own [license](Resources/scrcpy-LICENSE.txt) and [provenance notice](Resources/scrcpy-NOTICE.txt).
