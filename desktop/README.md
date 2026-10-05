# DroidDock for Windows and Linux

This is the Windows/Linux development preview, alongside the existing native Swift macOS app. It targets **Windows 11 x64** and **Ubuntu 22.04/24.04 x64**. It uses Electron for the desktop window, Google's Android Emulator for Android, and the pinned scrcpy Android server for a dedicated DroidDock phone window. Android Studio and Java are not required.

The preview includes:

- Explicit Android version downloads, Google license review, checksum verification, cancellation, and a separate x86_64 phone for each API.
- A library matching the macOS layout, plus separate phone windows with touch/keyboard/scroll, Back/Home/Recents, rotation, APK installation, and Stop.
- A visible phone window during boot, persistent display errors with Reconnect, and first-frame confirmation before Start/CLI boot reports success.
- Configuration editing and confirmed deletion to the system Trash/Recycle Bin while keeping downloaded Android images.
- Guided terminal setup and `droiddock list`, `boot`, `status`, `stop`, `install`, and `open-url` commands.
- Windows NSIS installer and Linux AppImage/DEB packaging, with native CI checks.

The macOS release remains in the repository root. Windows/Linux installers produced by CI are **unsigned development artifacts**, not a stable release. Real accelerated emulator boot and installer testing on Windows 11 and both Ubuntu targets remain required before general release. The Windows CI runner uses Windows Server 2022; that does not establish Windows 11 hardware compatibility.

## Build and run

Install Node.js 22 or newer and npm, then run from the repository root:

```sh
cd desktop
npm ci
npm test
npm start
```

`npm start` supports Windows/Linux x64. The native macOS application continues to use Swift. Source runs do not modify terminal profiles; terminal setup is available in an installed packaged app.

Package on the target operating system:

```sh
# Windows: NSIS installer
npm run dist -- --win --x64 --publish never

# Ubuntu: AppImage and DEB
npm run dist -- --linux --x64 --publish never
```

Outputs are under `desktop/dist`. For Linux packaging install `fakeroot`; headless CI additionally uses Xvfb and the GTK/NSS/audio/GBM dependencies listed in [the workflow](../.github/workflows/desktop.yml). The app and its Chromium renderer sandbox stay enabled. Ubuntu 24.04 may restrict unprivileged user namespaces for unpackaged/AppImage applications; use a correctly installed package with its Chromium sandbox helper, or an administrator-approved AppArmor policy. Do not run the app as root or disable its sandbox.

`npm run smoke` opens an isolated temporary app profile, checks the renderer/preload boundary, exercises Start Device before boot completes, decodes a fixture H.264 frame in the separate phone window, and checks close/reopen, reconnect errors, and CLI readiness. It also exercises Terminal Setup without writing real shell profiles. The fixture runtime does not boot Android. CI runs tests and UI smoke on Windows and Ubuntu 22.04/24.04, creates installers on Windows/Ubuntu 22.04, and verifies the packaged Windows CLI wrapper. Fixtures clean up after themselves.

## First use

1. Install the Windows `.exe`, or the Ubuntu `.deb`. An AppImage can run from a persistent location after making it executable; moving it afterward requires rerunning Terminal Setup.
2. Open **Set Up Android**, choose an API, review its size and licenses, and select **Agree & Download**. Downloads come directly from Google's stable Google APIs x86_64 catalog.
3. Enable hardware virtualization in firmware. Windows uses **Windows Hypervisor Platform (WHPX)**; Linux needs **KVM** and permission to access `/dev/kvm`. Reboot if enabling a Windows feature requires it. DroidDock checks acceleration before starting a phone. See [Google's acceleration instructions](https://developer.android.com/studio/run/emulator-acceleration).
4. Choose **Start Device**. DroidDock immediately opens a separate phone window and boots Android headlessly. The window shows startup progress until the first video frame arrives. **Stop Device** shuts Android down; closing the phone window disconnects only its display and keeps Android running. Choose **Open Device** to reopen it. A display error stays visible with **Reconnect Display**.
5. Use **Edit** or **Delete** after stopping the phone. A phone in use by an external emulator is protected from mutation. An unresolved shutdown retains the session and reports the problem.

New Android versions appear when you open **Android Versions**. Each download creates a separate phone; no background multi-gigabyte downloads occur. Compatible installed tools are reused. Existing images are preserved; upgrading the shared emulator engine and replacing installed image revisions are not implemented. The first preview manages only its own SDK and phones; it does not import existing Android Studio AVDs or Mac ARM64 phones.

## Terminal and Expo

**Terminal Setup** shows the directories and settings it will change. Select **Set Up Terminal** to opt in or **Later** to skip.

- **Windows:** creates a `droiddock.cmd` launcher and updates the current user's PATH and Android environment variables. Machine environment settings are unchanged. Existing user values are backed up.
- **Linux:** creates a launcher and environment script, then adds a marked source block to `.profile`, `.bashrc`, and `.zshrc`. Existing profile contents are preserved and backed up.

Open a new terminal after setup. Enabling integration before Android is installed makes the command available; finishing Android setup refreshes the environment when integration was previously enabled.

```sh
droiddock list
droiddock boot DroidDock_Phone_API_36_x86_64
npx expo start
```

Use an ID from `droiddock list`. Press **A** in Expo, or **Shift+A** to choose the running phone. Start the phone through DroidDock first so DroidDock owns the session. Expo's own emulator launches are external sessions; DroidDock does not silently take them over. Building native Android projects can require additional Android SDK build packages.

```sh
droiddock status DroidDock_Phone_API_36_x86_64 --json
droiddock stop DroidDock_Phone_API_36_x86_64
droiddock install DroidDock_Phone_API_36_x86_64 /absolute/path/app.apk
droiddock open-url DroidDock_Phone_API_36_x86_64 https://example.com
```

Use an absolute Windows path for APK installation on Windows. CLI requests are authenticated over a loopback-only endpoint and control the same runtime as the app.

## Storage and recovery

| Platform | Private Android data |
| --- | --- |
| Windows | `%LOCALAPPDATA%\DroidDock\Android` |
| Linux | `$XDG_DATA_HOME/DroidDock/Android`, or `~/.local/share/DroidDock/Android` |

The root contains `sdk`, `avd`, `user-home`, and `terminal`. Changed shell files are backed up beside the originals with a `.droiddock-backup-*` suffix; Windows user environment backups are under `terminal/user-environment-backup-*.json`. Uninstalling the app does not erase Android phones or SDK downloads. Delete phones from DroidDock when you want their data moved to the system Trash/Recycle Bin.

Install and phone operations use exclusive operation directories under `.locks`. If DroidDock crashes during an operation, it refuses to guess whether the owner is still active. After confirming DroidDock and the affected emulator are stopped, an advanced user can inspect the corresponding `owner.json` before removing that specific stale operation directory. Existing unrecognized SDK/phone directories are never overwritten.

**DroidDock Releases** opens GitHub for app updates. Automatic app replacement, recording, Logcat, snapshot UI, external SDK selection, and ARM Windows/Linux builds are not included in this first port. The native macOS app retains its existing features.

## Release validation still required

Before a Windows/Linux public release, run this on clean target machines:

1. Install, review licenses, download Android, and verify paths belong to DroidDock.
2. Enable WHPX/KVM, boot, interact with the separate phone window, rotate, and reconnect it.
3. Stop during boot and after boot; confirm QEMU exits, device data survives, and edit/delete unblock.
4. Set up a new terminal, boot by CLI, install an APK, and connect an Expo project.
5. Delete/recreate a phone and add a second API without modifying the first phone.
6. Exercise offline downloads, cancellation, low disk space, Windows paths with spaces, Linux Trash, and the target's sandbox behavior.

The bundled scrcpy server and Electron/Chromium dependencies have their own licenses; packaging includes the existing scrcpy provenance and license files. Android components are downloaded only after explicit Google license acceptance.
