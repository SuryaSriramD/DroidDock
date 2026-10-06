<p align="center">
  <img src="docs/assets/droiddock-banner.svg" alt="DroidDock — Android devices in your desktop workspace." width="1184">
</p>

<p align="center">
  Android virtual devices in your desktop workspace.<br>
  Available for macOS, Windows, and Linux.<br>
  Control them from Terminal, test with Expo, and keep your development tools close.
</p>

<p align="center">
  <a href="#downloads">Downloads</a> ·
  <a href="#features">Features</a> ·
  <a href="#get-started">Get started</a> ·
  <a href="#terminal-and-expo">Terminal &amp; Expo</a> ·
  <a href="#build-from-source">Build from source</a> ·
  <a href="#documentation">Documentation</a>
</p>

## Downloads

| Platform | Release | Download |
| --- | --- | --- |
| **macOS 13+ · Apple Silicon** | [0.4.4 Development Preview](https://github.com/SuryaSriramD/DroidDock/releases/tag/v0.4.4) | [DMG](https://github.com/SuryaSriramD/DroidDock/releases/download/v0.4.4/DroidDock-macOS.dmg) · [SHA-256](https://github.com/SuryaSriramD/DroidDock/releases/download/v0.4.4/DroidDock-macOS.dmg.sha256) |
| **Windows 11 · x64** | [0.5.0](https://github.com/SuryaSriramD/DroidDock/releases/tag/v0.5.0) | [Windows installer](https://github.com/SuryaSriramD/DroidDock/releases/download/v0.5.0/DroidDock-0.5.0-win-x64.exe) · [SHA-256](https://github.com/SuryaSriramD/DroidDock/releases/download/v0.5.0/SHA256SUMS.txt) |
| **Ubuntu 22.04 / 24.04 · x64** | [0.5.0](https://github.com/SuryaSriramD/DroidDock/releases/tag/v0.5.0) | [DEB](https://github.com/SuryaSriramD/DroidDock/releases/download/v0.5.0/DroidDock-0.5.0-linux-amd64.deb) · [AppImage](https://github.com/SuryaSriramD/DroidDock/releases/download/v0.5.0/DroidDock-0.5.0-linux-x86_64.AppImage) · [SHA-256](https://github.com/SuryaSriramD/DroidDock/releases/download/v0.5.0/SHA256SUMS.txt) |

The native Swift macOS app and the Electron Windows/Linux app have separate releases. **0.5.0 contains Windows/Linux installers only.** On Ubuntu 24.04, use the DEB package; the AppImage was tested on Ubuntu 22.04 and requires FUSE.

> **Signing:** The macOS preview is ad-hoc signed and not Apple-notarized; macOS may block a downloaded copy. Windows/Linux installers are unsigned. See each release's notes for tested configurations and limitations.

## Features

| Separate phone windows | Android device management | Ready for Terminal |
| --- | --- | --- |
| A floating toolbar, rounded phone frame, screenshots, and rotation, with controls suited to the host platform. | Download Android versions explicitly and keep a separate phone for each selected API. | List, boot, and control devices with the `droiddock` command. |
| Interact with touch, drag, scroll, keyboard, and hardware controls. | Install APKs, start/stop phones, edit their configuration, and delete them to Trash or Recycle Bin. | Use your running Android device with Expo through the same Android SDK. |

DroidDock runs Google's Android Emulator headlessly and embeds the device display through the bundled scrcpy server. **Set Up Android** downloads a private Android runtime and creates a phone inside DroidDock. Once a phone is available, **Android Versions…** replaces the setup prompt so you can add other Android versions. Android Studio and Java are not required.

| Platform-specific tools | Availability |
| --- | --- |
| Recording, Logcat, snapshots, explicit clipboard transfer, diagnostics export, and existing SDK/AVD selection | macOS |
| `droiddock expo` with bundled Node and scoped IPv4 settings; `droiddock repair-adb`; bounded display recovery | Windows/Linux |

Windows/Linux uses DroidDock-managed x86_64 phones and does not import existing Android Studio AVDs or Mac ARM64 phones. See the [desktop guide](desktop/README.md) for the complete platform scope.

A running phone shows **Stop Device** beside **Open Device** in the library and in its **…** menu. Confirm Stop to shut it down while preserving its apps and data. **Stopping…** remains visible until cleanup finishes; editing and deletion become available afterward.

Use the phone's **…** menu to **Edit AVD Configuration…** (name, memory, CPU cores, resolution, and density) or **Delete Phone…**. Stop the phone first. Deletion requires confirmation and moves the phone's files to the system Trash or Recycle Bin while keeping the shared Android runtime. Deleting the last phone restores **Set Up Android** so you can create one again.

## Get started

### Windows 11 and Ubuntu

1. Install the Windows `.exe` or Ubuntu `.deb` from [Downloads](#downloads). For an AppImage, make it executable and keep it in a persistent location.
2. Enable **Windows Hypervisor Platform (WHPX)** on Windows, or **KVM** with access to `/dev/kvm` on Linux. DroidDock checks acceleration before boot. See [Google's acceleration guide](https://developer.android.com/studio/run/emulator-acceleration).
3. Open **Set Up Android**, select an Android version, review the download size and Google licenses, then choose **Agree & Download**.
4. Choose **Start Device**. A separate DroidDock phone window opens while Android boots. Closing that window keeps Android running; **Open Device** restores it, and **Stop Device** shuts it down.
5. Opt into **Terminal Setup**, then open a new terminal to use DroidDock with your development tools.

The [Windows/Linux setup guide](desktop/README.md) covers installation, terminal integration, Expo, recovery, and storage. Keep the Chromium sandbox enabled; Ubuntu 24.04 users should use the installed DEB rather than disable sandbox protections for an AppImage.

### macOS

#### 1. Prepare your Mac

| Requirement | What you need |
| --- | --- |
| **Mac** | Apple Silicon running macOS 13 or newer. The download is an `arm64` build; Intel support has not been validated. |
| **Android runtime** | Let DroidDock install the runtime, or connect an existing SDK with Android Emulator and Platform-Tools. |
| **Virtual device** | Choose an Android version to create its phone, or use an existing `arm64-v8a` AVD. |
| **Resources** | Enough free memory and disk space for your virtual device. |

Android setup does not require Android Studio or Java. It downloads Android components directly from Google after you review and accept their licenses. Setup needs an internet connection and additional free disk space for downloads, extraction, and device data. You do not need Xcode or Python to run the packaged app.

#### 2. Install DroidDock

1. [Download the preview DMG](https://github.com/SuryaSriramD/DroidDock/releases/download/v0.4.4/DroidDock-macOS.dmg) and quit any running copy of DroidDock or the older Android Simulator app.
2. Open the disk image and drag **DroidDock → Applications**.
3. Eject the disk image, then open **DroidDock** from Applications.

The **Terminal Setup** screen lets you review and enable terminal commands. Choose **Later** to continue without changing terminal files; you can return to setup from the app menu, library sidebar, or Settings.

#### 3. Start your device

Choose **Set Up Android**, open the available versions, and choose **Download…** beside the version you want. Review the download size and licenses, then choose **Agree & Download**. Each version creates its own phone with Google APIs (without the Google Play Store). Open the device library and choose **Start Device**. The installed runtime can run offline; apps inside Android may still require a network connection.

For an existing SDK, use **Use an Existing Android SDK** or choose its path in Settings, select a device, and choose **Start Device**.

Managed components and device data live under `~/Library/Application Support/DroidDock/Android`. Setup supports cancellation and retry, checks download integrity, and keeps existing SDKs and AVDs separate. The **Android Versions…** screen reads Google’s current stable Google APIs ARM64 catalog (API 30 onward). New APIs appear there without an app release and download only when selected. Decimal APIs such as 36.1 and 37.0 keep distinct phones. Compatible installed tools are reused; existing images, phones and their data are preserved. Deleting a phone lets you recreate it from its installed image without downloading it again. This flow does not replace installed image revisions or upgrade the shared emulator engine; an image requiring newer tools is blocked with an explanation.

### App updates by platform

**macOS:** **DroidDock → Check for Updates…** checks stable releases from this repository. **Settings → DroidDock updates** controls automatic checks, performed when the app opens at most once a day. A newer compatible release offers its DMG download and release notes; newer installed builds are never offered a downgrade. App updates currently use a downloaded DMG and manual replacement in Applications. Signed automatic installation is not implemented. The checker excludes prereleases, including **v0.4.4 Development Preview**; download preview updates directly from [Releases](https://github.com/SuryaSriramD/DroidDock/releases). If a newer release has no Mac installer, the app explains that and links to its notes; Windows/Linux 0.5.0 does not replace the Mac preview.

**Windows/Linux:** **SDK Settings → DroidDock Releases** opens the release page. Download the installer for your platform, quit DroidDock, and install the update. Automatic app replacement is not implemented. Android phones and SDK downloads stay in DroidDock's data directory. Android version downloads remain a separate, explicit choice on every platform.

## Terminal and Expo

Windows/Linux users should follow [their Terminal Setup instructions](desktop/README.md#terminal-and-expo). Windows setup updates the current user's environment; Linux setup adds backed-up, marked shell-profile blocks. Both require a new terminal after setup.

### Set up Terminal on macOS

Opening the installed app from `/Applications` or `~/Applications` first presents **Terminal Setup**. Review the selected Android SDK and the directories that will be added to your PATH, then choose **Set Up Terminal**. Choose **Later** to skip without changing terminal files. You can reopen Terminal Setup from the DroidDock app menu, the library sidebar, or Settings.

After you enable it, setup makes `droiddock` available in new zsh and Bash terminals. With an Android SDK selected, it also supplies that SDK's Android environment and the `adb` and `emulator` commands. Later SDK selections keep this enabled environment current.

Setup creates `~/.local/bin/droiddock` and adds a marked block to the shell profiles that sources `~/Library/Application Support/DroidDock/Terminal/environment.sh`. Existing profile content is preserved, and profiles changed by setup are backed up under `~/Library/Application Support/DroidDock/Terminal/Backups`. Copies opened from a disk image or the source tree do not configure terminal tools.

Open a new terminal after setup. **Settings → Terminal** shows the setup status and lets you reopen the setup screen. For an already-open project terminal, **Copy Android Environment** supplies the selected SDK's environment commands to paste before starting Expo.

<details>
<summary><strong>Optional manual macOS command setup</strong></summary>

Choose **Settings → Terminal → Copy Terminal Install Command** and run the copied command. For an app installed in Applications, you can also run:

```sh
/bin/bash "/Applications/DroidDock.app/Contents/Resources/install-cli.sh"
export PATH="$HOME/.local/bin:$PATH"
```

This fallback script creates `~/.local/bin/droiddock` and leaves existing conflicting commands unchanged. It does not edit shell profiles; add `~/.local/bin` to your shell's PATH yourself if you use this manual setup.

</details>

### Launch an Android device

```sh
droiddock list
droiddock boot PHONE_ID
```

Replace `PHONE_ID` in these commands with an ID returned by `droiddock list`, such as `DroidDock_Phone_API_36` on Mac or `DroidDock_Phone_API_36_x86_64` on Windows/Linux. The boot command starts the device, opens its DroidDock window, and waits until Android is ready.

### Connect your Expo project

Boot the phone through `droiddock boot` first, then start Expo from your project directory:

```sh
npx expo start
```

Press **Shift+A** to choose the running DroidDock phone, or **A** when it is the only suitable device. Expo finds the running phone through ADB using the Android environment configured above. Terminal Setup does not route Expo's own emulator launches through DroidDock, so starting the phone with `droiddock boot` remains necessary for its DroidDock window. The managed runtime includes emulator components; native Android builds may need additional SDK build packages.

**Windows/Linux Expo Go shortcut:** after installing your project's dependencies, run `droiddock expo PHONE_ID` from the project directory, replacing `PHONE_ID` with an ID from `droiddock list`. This boots the phone and runs the project's Expo CLI with DroidDock's bundled Node and scoped IPv4/SDK settings. Ctrl+C stops Metro and leaves Android running. If ADB becomes unresponsive, `droiddock repair-adb` explicitly restarts the shared ADB server with ownership checks; other Android tools using that server also reconnect. These two commands are not part of the native macOS CLI. See the [desktop Expo guide](desktop/README.md#terminal-and-expo) for custom ports, external Node requirements, and recovery behavior.

<details>
<summary><strong>More terminal commands</strong></summary>

```sh
# Check device state in scripts
droiddock status PHONE_ID --json

# Install a local APK
droiddock install PHONE_ID /absolute/path/app.apk

# Open a URL in the device
droiddock open-url PHONE_ID 'https://example.com'

# Stop the device
droiddock stop PHONE_ID

# Browse available commands
droiddock --help
```

The terminal client controls the same app-owned runtime as the UI. Devices started by another application remain externally managed. On macOS, set `DROIDDOCK_APP` or pass `--app '/path/DroidDock.app'` to select a specific app bundle.

</details>

## Build from source

### macOS

Use the **Swift 6 toolchain** from Xcode or compatible Command Line Tools.

```sh
git clone https://github.com/SuryaSriramD/DroidDock.git
cd DroidDock
swift test --disable-sandbox
./scripts/build.sh
open "artifacts/DroidDock.app"
```

The build script creates an ad-hoc-signed macOS app.

<details>
<summary><strong>Package a DMG</strong></summary>

After building the app, install Python 3.10 or newer and run:

```sh
./scripts/package-dmg.sh
```

The packager creates `artifacts/DroidDock-macOS.dmg` and its SHA-256 checksum. It uses isolated, hash-pinned dependencies under `.build/dmg-tools`, generates Retina installer artwork, and verifies the disk image, app contents, signatures, and Finder layout. The existing app binary is preserved. Set `DROIDDOCK_DMG_PYTHON` to select a Python executable.

</details>

<details>
<summary><strong>Development names and upgrade compatibility</strong></summary>

The internal Swift package and executable are still named `AndroidSimulator`. For an unpackaged development run, use `swift run AndroidSimulator` from the repository root.

The app retains its existing bundle and storage identifiers, preserving preferences and runtime history across the rename to DroidDock. The legacy `android-simulator` command and URL scheme remain compatible.

</details>

### Windows and Linux

Build on the target operating system with Node.js 22 or newer and npm:

```sh
git clone https://github.com/SuryaSriramD/DroidDock.git
cd DroidDock/desktop
npm ci
npm test
npm start
```

The [desktop build guide](desktop/README.md#build-and-run) covers native installer packaging, UI smoke tests, Linux dependencies, and optional Android/Expo release checks.

## Project status

**Windows/Linux 0.5.0** is published for Windows 11 x64 and Ubuntu 22.04/24.04 x64. The [release workflow](https://github.com/SuryaSriramD/DroidDock/actions/runs/37461019226) passed unit tests, UI/video smoke tests, native packaging, and packaged CLI checks. Real Android 16/Expo Go checks passed on KVM-backed Ubuntu 22.04 AppImage and Ubuntu 24.04 DEB installations. The [release notes](https://github.com/SuryaSriramD/DroidDock/releases/tag/v0.5.0) also record local Windows WHPX testing and remaining limitations.

**macOS 0.4.4** remains an Apple Silicon development preview. On 6 October 2026, a scoped native Mac test with Expo SDK 57.0.26, Expo Go 57.0.9, Node 24.19.0, and Android 16 ARM64 passed input, Fast Refresh, display reopening, concurrent CLI requests, and ADB checks after Metro shutdown. The persistent Windows display/ADB failures were not reproduced in that approximately 12-minute run; it does not exclude intermittent failures. See the [Mac reproduction results](docs/VALIDATION.md#mac-expo-reproduction-6-october-2026).

A full device-creation wizard and upgrades to the shared emulator engine remain planned work. Fresh installation and boot on a clean Mac remain validation requirements.

On macOS, video recording exports video-only MP4 files, up to three minutes per recording. Clipboard transfer is explicit rather than continuous synchronization. Recording, Logcat, snapshot UI, and external SDK selection are not included in Windows/Linux 0.5.0.

Automated tests, package-integrity checks, and scoped live and native UI checks are recorded in the [validation record](docs/VALIDATION.md). These checks do not establish compatibility across every macOS version, Android image, or Expo project. Intel hardware, Developer ID signing, and Apple notarization remain outside this preview's validation.

## Documentation

| Resource | Purpose |
| --- | --- |
| [Windows/Linux guide](desktop/README.md) | Installation, prerequisites, Expo, CLI recovery, packaging, and platform scope. |
| [Validation record](docs/VALIDATION.md) | Test results, manual checks, and known limitations. |
| [Mac reproduction prompt](docs/testing/mac-expo-reproduction-prompt.md) | Repeat the Expo scenarios while distinguishing Windows-specific behavior from native Mac behavior. |
| [Requirements audit](docs/REQUIREMENTS_AUDIT.md) | Implemented requirements and remaining work. |
| [Implementation plan](docs/IMPLEMENTATION_PLAN.md) | Architecture, delivery stages, and development scope. |
| [Development notes](docs/DEVELOPMENT_NOTES.md) | Detailed implementation and historical verification notes. |
| [Product requirements](docs/specifications/Android_Simulator_macOS_PRD.txt) | Original product definition. |
| [Technical requirements](docs/specifications/Android_Simulator_macOS_TRD.txt) | Original technical specification. |

Builds, caches, local logs, and runtime evidence are excluded from source control. Historical evidence paths in the development documents refer to local files; downloadable installers are published under [Releases](https://github.com/SuryaSriramD/DroidDock/releases).

## License

DroidDock is distributed under the [Apache License 2.0](LICENSE). The bundled scrcpy server includes its own [license](Resources/scrcpy-LICENSE.txt) and [provenance notice](Resources/scrcpy-NOTICE.txt).
