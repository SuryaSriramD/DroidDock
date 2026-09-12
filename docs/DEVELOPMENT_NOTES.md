# DroidDock for macOS

Raw local test evidence is excluded from this public repository; inline `artifacts/` paths refer to the original local workspace. Downloads are available on [GitHub Releases](https://github.com/SuryaSriramD/DroidDock/releases).

**DroidDock** (formerly Android Simulator) is a native SwiftUI/AppKit workspace for existing Android virtual devices. Google Android Emulator runs headlessly; this app owns the device window, live video, input, hardware controls, and developer actions.

The current source includes headless lifecycle, native device windows, embedded video/input, core controls, APK install/drop, screenshots, streaming Logcat, MP4 recording, clipboard transfer in both directions on request, snapshot management, confirmed data wipe, diagnostics ZIP export, automatic bounded runtime-failure bundles, and an additional-device resource advisory. Display scale and close/quit preferences are saved; Settings provides configurable F1–F8 hardware-key mappings. A bounded runtime ledger identifies matching guests from earlier app sessions without granting ownership. The live runtime probe passed at **59.57 decoded FPS** on one Apple M4/API 37 configuration. Version **0.2.0** added the Simulator-style floating toolbar and phone frame, automatic orientation sizing, and a terminal client. Version **0.2.1** names the product **DroidDock** and its command `droiddock`. The v0.2.0 baseline passed **175 tests**; branding validation for v0.2.1 is recorded separately below. The separately measured 140-test package achieved **56.015 submitted FPS over 86.58 s** with Diagnostics open on the tested host; see the validation record for the matching test result. These results do not measure physical presentation or input-to-visible latency.

The product and technical specifications are in [`docs/specifications`](specifications). [`docs/IMPLEMENTATION_PLAN.md`](IMPLEMENTATION_PLAN.md) describes the implementation sequence, [`docs/VALIDATION.md`](VALIDATION.md) records the exact evidence and limits, and [`docs/REQUIREMENTS_AUDIT.md`](REQUIREMENTS_AUDIT.md) maps remaining work. The user selected a **local development build** for the first delivery. Public-release signing, notarization and update-feed configuration are future owner work, not blockers to this local delivery. Untested native workflows and compatibility remain disclosed limitations.

## Requirements

- macOS 13 or newer. The packaged app does not require Xcode or a Swift toolchain to run.
- The supplied DMG and ZIP contain an Apple Silicon (`arm64`) executable. Intel requires a separate build and live validation; these packages do not claim Intel support.
- An existing Android SDK containing executable `emulator/emulator` and `platform-tools/adb`.
- An existing AVD with an image compatible with the Mac. Use an `arm64-v8a` image on Apple Silicon. The source contains Intel architecture checks, but Intel compatibility needs separate live validation.
- Sufficient free memory and disk space for the selected AVDs. Android virtualization, system images, and SDK components remain managed by standard Android tooling. Host GPU is the default; Settings also offers automatic and software modes for compatibility, with potentially lower throughput.

No Accessibility permission is required for the core app. The app uses the selected SDK's ADB; it does not bundle Android SDK components or silently download system images. The bundled Android-side scrcpy server is distinct from the scrcpy desktop app.

Building from source additionally requires the Swift 6 toolchain supplied by Xcode or compatible Command Line Tools.

## Build and run

Quit the currently running version before installing. Download `DroidDock-macOS.dmg` (`artifacts/DroidDock-macOS.dmg`), open it, and drag **DroidDock.app** onto the **Applications** shortcut. Eject the disk image, then open the app from Applications. Installation instructions are also included inside the DMG. The existing Android SDK and AVD requirements above still apply.

The ZIP package (`artifacts/DroidDock-macOS.zip`) remains available. Both contain the same validated application. The app is ad-hoc signed and is not notarized; downloaded copies may be blocked by macOS. Developer ID signing and notarization are still needed for a standard public release. Packaging checks and checksums are recorded in [`docs/VALIDATION.md`](VALIDATION.md).

From this repository:

```sh
swift test --disable-sandbox
./scripts/build.sh
open "artifacts/DroidDock.app"
```

`scripts/build.sh` creates an application bundle under `artifacts` and applies an ad-hoc local signature. It does not use a Developer ID certificate or submit the app for notarization. Distribution signing and clean-Mac installation verification remain release work.

To package an existing built app as a DMG:

```sh
./scripts/package-dmg.sh
```

This preserves the app's existing signature and creates a compact, branded installer window with a Retina background, fixed app/Applications icon positions and a drag arrow. The main window shows only the two installation targets; detailed notes remain in `.support/Read Me.txt` inside the image. Packaging needs Python 3.10+ and creates an isolated `.build/dmg-tools` environment with hash-pinned build dependencies, generates the background, and verifies the compressed image, mounted app contents and Finder layout before replacing the download. Users do not need these build tools. The `.dmg.sha256` checksum and `artifacts/dmg-verification.json` (`artifacts/dmg-verification.json`) record the result.

For a development executable without packaging:

```sh
swift run AndroidSimulator
```

Run that command from the repository root so the executable can find `Resources/scrcpy-server`. The packaged app reads the server from its own resources and can be opened independently of the repository.

## Terminal and Expo

Version 0.2.1 adopts the DroidDock name and `droiddock` command. Existing settings and runtime history keep their storage identity. The bundled legacy `android-simulator` alias and URL scheme remain accepted; the new installer creates the `droiddock` command. `DROIDDOCK_APP` is the preferred app-path override, with `ANDROID_SIMULATOR_APP` retained for compatibility.

The v0.2.0 live Expo check (`artifacts/native-chrome-cli-20260909/EVIDENCE.md`) passed: boot through the terminal, choose the running AVD with Expo's Shift+A, render a local Expo Go project in the native window, and reopen it through `open-url` without replacing the emulator.

After moving the app to Applications, open **Settings → Terminal → Copy Terminal Install Command** and paste it into Terminal. The installer creates `~/.local/bin/droiddock` and prints instructions if that directory is not on your PATH. It does not edit shell profiles or replace an existing command. You can also run the installer directly:

```sh
/bin/bash "/Applications/DroidDock.app/Contents/Resources/install-cli.sh"
export PATH="$HOME/.local/bin:$PATH"
droiddock list
droiddock boot Pixel_10_Pro
```

Replace `Pixel_10_Pro` with an ID returned by `list`. Boot opens the native device window and waits until Android is ready. Running it again brings back the same owned device. In an existing Expo project:

```sh
npx expo start
# Press A to open Android, or Shift+A to choose the running device.
```

Use the same Android SDK in Expo and this app (`ANDROID_HOME` can point Expo to the path in Settings). Expo recognizes the already-running AVD through ADB. For a native development build, `npx expo run:android --device Pixel_10_Pro` selects it by name. `ANDROID_SERIAL` alone does not reliably select Expo's target. If multiple devices are available, choose this device with Shift+A. See [Expo's development workflow](https://docs.expo.dev/get-started/start-developing/) and [CLI options](https://docs.expo.dev/more/expo-cli/).

```sh
droiddock status Pixel_10_Pro --json
droiddock install Pixel_10_Pro /absolute/path/app.apk
droiddock open-url Pixel_10_Pro 'exp://127.0.0.1:8081'
droiddock stop Pixel_10_Pro
droiddock --help
```

`open` alone opens the library; `open <device>` boots/shows a device. The app owns runtime and ADB actions. Devices started by another application remain externally managed; stop them in that application first. The client supports `--app '/path/DroidDock.app'`, `--timeout` (1–600 seconds), and JSON responses. A timeout ends command waiting and cancels its pending ADB operation; a device already starting keeps booting, so check `status` before retrying. The usual additional-device memory confirmation remains in the native app. No commands erase device data.

The installed command is linked to the app location. If you move the app later, remove that link explicitly and rerun the bundled installer. For repository development, use `"artifacts/DroidDock.app/Contents/MacOS/droiddock"` directly after building. The URL scheme only wakes the app with a request ID; command arguments travel through bounded owner-only local files.

## Using the app

1. Open the app. It checks a saved SDK path, `ANDROID_HOME`, `ANDROID_SDK_ROOT`, and common macOS SDK directories. If none is usable, choose the SDK folder in Settings. An SDK path explicitly chosen by the user is validated directly.
2. Select an installed AVD and choose **Start Device**. Android boots in a separate native device window with boot and connection status. A running AVD owned by another application is marked externally managed.
3. The device opens in a Simulator-style window with a floating dark toolbar, native traffic lights, a rounded phone frame and transparent surround. Drag the device title to move it. Click the screen to focus, tap, swipe, scroll, and type normally. Right-click sends Android Back. Home, screenshot and rotation are on the toolbar; Back, Recent Apps and developer actions are under **More (…)**. Power and volume also have side buttons. Command-V sends text to Android; Command-[ sends Back and Shift-Command-H sends Home. Shift-Command-D toggles the developer panel. Other system shortcuts stay on the Mac. Configure F1–F8 hardware-key actions in Settings; these apply immediately when the Android surface has focus.
4. Use the device menu or developer panel to install an APK, save a screenshot, inspect streaming logs, or export diagnostics as text or a ZIP bundle. APK files can also be dropped on a connected device. Command-I opens the APK picker and Shift-Command-S opens the screenshot save panel. Choose a default capture folder in Settings.
5. **Record Screen** writes an MP4 after Stop or the recording limit, with up to three minutes of video and no audio. Keep Android's orientation fixed while recording. **Copy Android Clipboard** transfers Android text to the Mac on request; Command-V sends Mac text to Android. This is explicit transfer, not automatic clipboard synchronization.
6. **Manage Snapshots** lists loadable snapshots and provides confirmed save/load/delete actions. Saving an existing name replaces it; loading replaces the current guest state. Cold Boot and Wipe Data are explicit confirmed lifecycle actions. Wipe Data resets the selected device's user data. The default launch uses Quick Boot when available. Starting an additional device shows a resource advisory based on configured guest RAM, host physical RAM, and available RSS samples; it does not estimate free RAM or impose a launch cap.
7. The device menu provides saved Fit Window/75%/50% display scales and confirmed Restart/Stop actions.
8. Close the window or explicitly stop the device. Settings controls whether closing a window stops its app-owned emulator and whether quitting stops app-owned devices. The default is to keep Android running when its window closes and stop app-owned devices when the app quits. A kept-running device detaches its display bridge when its window closes and reconnects when reopened.

The library can label a matching guest as left running by an earlier app session or as a possible interrupted session. These guests remain externally managed: stop them using Android tooling, then refresh the library. The app never adopts or terminates a process because of a history match. Damaged history produces a warning and an explicit **Reset Session History** action that replaces only tracking metadata.

The library works with existing AVDs. Create images/devices through Android Studio's Device Manager or Android command-line tools before using them here. A full creation wizard and managed runtime downloads are later product capabilities.

## Architecture

| Component | Responsibility |
| --- | --- |
| `Sources/AndroidSimulator` | Native library/settings, per-device windows, session state, developer controls, AppKit focus and text composition. |
| `SDKLocator`, `AVDRepository`, `EmulatorProcessManager` | Validate SDK tools, read AVD metadata, allocate port pairs, and own only emulator processes launched by this app. |
| `RuntimeLedger` | Actor-serialized, bounded tracking metadata; matches PID, native start time, current executable, SDK, AVD and online serial. Records running/intentional leave disposition; offers no process ownership or signal API. |
| `RuntimeAdapter`, `DisplayBridge`, `ScrcpyBridge` | Replaceable transport boundary and the concrete, pinned scrcpy 3.3.3 native client. Video/control use separate channels over local ADB forwarding. |
| `VideoDecoder`, `FrameStore`, `AndroidSurfaceView`, `PresentationDiagnostics` | H.264 decoding with VideoToolbox into `CVPixelBuffer`, latest-frame presentation, and `AVSampleBufferDisplayLayer` rendering. Fixed-size counters distinguish callback delays, absent decoded frames, layer backpressure and sample errors. |
| `DisplayGeometry`, `ScrcpyControlEncoder` | Aspect-fit guest coordinates and bounded direct input packets. AppKit logical points and current decoded dimensions share the same geometry. |
| `GuestRotation` | Explicit selected-device WindowManager orientation changes, remembering the foreground user's original rotation settings/policy for restoration on stop or app quit. |
| `ProcessRunner`, `ADBService` | Asynchronous child commands, bounded output, timeout/cancellation, APK install and screenshot fallback. |
| `LogcatStream`, `SessionEventLog`, `ProcessResourceSampler` | Bounded continuous guest logs, persistent structured session events/OSLog, and native CPU/resident-memory counters for the owned emulator process. |
| `ScreenRecording` | Selected-device Android video recording, bounded duration/file size, explicit finalization/export, and exact remote process/file cleanup. |
| `EmulatorSnapshots` | Selected-serial console list/save/load/delete, safe names, finite timeouts, and explicit console failure handling even when ADB exits zero. |
| `ClipboardReplyChannel` | On-demand Android clipboard replies with bounded waiting and protection against stale replies after cancellation. |
| `RuntimeFailureEvidenceStore` | Preserves owned-runtime exit identity, bounded output and eight atomic local failure ZIP slots; incomplete log draining and collection errors remain visible. |
| `DiagnosticsBundle`, `SessionResourcePolicy` | Bounded diagnostic ZIP collection and an advisory before starting additional devices. |
| `InputFrameLatencyTracker` | Bounded host input-dispatch-to-subsequent-frame-submission proxy, wired into session diagnostics. This does not establish that Android responded to the input or that pixels appeared physically. |
| `LogTextBuffer`, `NativeLogView` | Retain at most 500 entries/1 MiB of rendered UTF-8, cache filtered text, and skip unchanged native document updates. A native scroll view contains wrapping, selectable text. |
| `SimulatorProbe`, `Tests/Fixtures/AndroidProbe` | Live validation tools and a small Android test workload. They are verification utilities, separate from the product UI. |

The bridge checks the bundled server's SHA-256 digest before upload and validates the negotiated H.264 codec and dimensions. It does not embed Google's emulator window, launch the scrcpy desktop UI, or use repeated screenshots as the interactive display.

The local protocol is pinned to scrcpy **3.3.3**. Updating the server requires reviewing its protocol, updating the checksum and tests, and repeating live validation. See [`Resources/scrcpy-NOTICE.txt`](../Resources/scrcpy-NOTICE.txt) for binary provenance and [`Resources/scrcpy-LICENSE.txt`](../Resources/scrcpy-LICENSE.txt) for its Apache 2.0 license.

## Diagnostics and verification

The v0.2.1 rename passed **25 focused automated tests**, release compilation, bundle/command metadata checks and five CLI installer checks. A read-only request from `droiddock` successfully listed the device through the running v0.2.0 app, preserving its app and emulator processes. See the DroidDock branding evidence (`artifacts/droiddock-branding-20260910/EVIDENCE.md`) for scope and package checks. The previous full-suite baseline remains the 175-test v0.2.0 run.

Use the device developer panel to copy/export diagnostics and inspect the runtime log. Emulator logs and structured session journals are stored in `~/Library/Logs/AndroidSimulator`. Diagnostics include SDK versions, ownership/ports, GPU mode, decoded and submitted frame rates, receive/decode/submit timings, emulator CPU/resident memory, and a host input-to-subsequent-frame proxy. The proxy has nine passing helper tests. A native sample showed 38.9 ms median/382.6 ms p95, but included other inputs and omitted expired waits; it does not prove a causal Android response or physical display latency. The selected SDK supplies its own standard ADB key and guest-data management; the app does not keep a separate copy of those secrets or Android application data.

Runtime history is stored at `~/Library/Application Support/AndroidSimulator/runtime-ledger.json`, capped at 64 records/256 KB and atomically written with owner-only permissions. The app refreshes identity after launch, boot and intentional leave-running cleanup, and removes a record only after the owned process exits. Current runtime IDs are excluded from prior-session labels; stale SDK discovery and old-session warning results are suppressed. Nine ledger tests passed, including native identity, PID reuse, corruption recovery, concurrent updates and failed-write preservation. They do not prove native crash/relaunch behavior.

The automated tests cover coordinate mapping, protocol limits, SDK/AVD parsing, safe command construction, timeout/cancellation, state transitions, ownership, rotation restoration, streamed logs, resource counters, and persistent diagnostics. Added P1 fixtures cover recording (12), snapshots (13), clipboard replies (4), diagnostic bundles (5), explicit wipe arguments (3), resource advisories (6), configurable key mappings (6), and input/frame timing proxies (9). The historical **152**-test result with zero failures at **23:35:17.723** local time is preserved in `swift-test-152.log` (`artifacts/native-exit-evidence-20260908/swift-test-152.log`). The later v0.2.0 baseline passed 175 tests; v0.2.1 branding validation is recorded separately. The 106-case run predates ledger/controller additions; the 124-case package used for the broader native workflow pass predates the latest Logcat change. Both are historical build scopes; the later clipboard and cancellation checks used the 131-test package. Six presentation-diagnostics cases brought the instrumentation build to 137; three later panel observation/reader-lifecycle cases brought the measured package to 140. Eleven runtime-exit/drain/cache cases and one unsupported-snapshot case brought that build to 152; the complete suite passed in 59.743 seconds. These tests do not establish end-to-end input latency, native rendering performance, or a broad host/runtime compatibility claim.

The later LogTextBuffer change caps the retained document at **500 entries and 1 MiB of UTF-8 including separators**, preserves a valid suffix for an oversized line, freezes the visible snapshot while paused, and caches filtering. Seven new tests cover successive-batch limits, Unicode/normalization, empty lines, pause/resume and cache revisions. The broader native workflow pass used the earlier package; the later clipboard and cancellation checks used the 131-test build. Neither the short samples from the 131-test build nor the earlier observations establish a performance improvement.

Presentation diagnostics now record callback gaps/work, layer readiness/status/errors, flushes and format/sample failures with stream IDs, uptime and frame counts. Four helper tests verify outcome separation, clock/reset behavior, bounded UTF-8 errors and concurrency; two FrameStore tests verify reconnect baselines and inactive/new-session scopes. The 137-test change was instrumentation only. The 140-test panel change isolates log observation, stops hidden readers, caches displayed diagnostics and uses a native segmented control. Its measured native interval passed the average submission-rate criterion below; physical latency and broader performance acceptance remain open.

Unexpected owned-runtime exits preserve PID, serial, runtime/session IDs, termination reason/status and recent stdout/stderr. The app waits up to two seconds for log EOF and explicitly warns if the tail may be incomplete. It automatically saves an atomic, owner-only ZIP in `~/Library/Logs/AndroidSimulator/Failures`: eight reusable slots of at most 4 MiB each (32 MiB of completed managed archives). The inline tail is limited to 4 KiB and 20 lines. Collection errors remain visible, ordinary Stop creates no failure archive, and Stop/Quit join preservation without old results overwriting a new session.

Snapshot availability is learned from explicit unsupported console responses for the owned runtime. The app disables further snapshot actions with the reported reason, retains that decision across display reconnects and resets it for a new runtime. Transient command failures do not disable the feature or affect another session.

Recovery now preserves a booted VM after initial display failure, keeps liveness monitoring after exhausted bridge retries, and joins hidden-window bridge cleanup and retired Logcat readers before stopping the runtime. Nine controller/coordinator cases passed across the initial seven-case run (`artifacts/controller-tests.log`) and two additional lifecycle cases (`artifacts/controller-quit-start-tests.log`). Eight execute the production SessionController with temporary SDK executables and an in-memory bridge; one verifies AppModel never publishes stale SDK-switch results. The added cases cover Stop during gated initial bridge startup and intentional leave-running cleanup followed by a fresh persisted-ledger match. These fixtures invoke no Android VM or native UI; they do not establish native crash/relaunch behavior.

The live recording service check exported decodable manual-stop and automatic-stop MP4 files, checked cancellation without export, restored temporary guest files/processes, and stopped its owned runtime. Evidence is in `artifacts/recording/2ACEA284-B0CB-4AAB-AAD2-A0E7CDE7AA69/result.json` (`artifacts/recording/2ACEA284-B0CB-4AAB-AAD2-A0E7CDE7AA69/result.json`).

The settled AndroidProbe snapshot run 955fe272-5299-47da-a2b0-de1314e206d3 (`artifacts/disposable-tests/955fe272-5299-47da-a2b0-de1314e206d3/EVIDENCE.md`) passed save/load/delete, restored text and a guest file, and accepted fresh touch input with the same emulator PID. Both captured frames show the responsive fixture with no ANR dialog. Its APK, forwards, runtime and isolated fixture were cleaned up; watched user AVD/SDK metadata stayed unchanged. The earlier a7ebb snapshot run (`artifacts/disposable-tests/a7ebb70c-6b29-4f00-bbff-1b49df5cc6cd/EVIDENCE.md`) verified file/clipboard/control restoration but showed a Settings ANR. That remains historical evidence; the settled-fixture pass does not explain its cause.

The single-guest repeat collected 42 resource samples, peaking at **5.89 GiB emulator RSS** and **251.94% emulator CPU** (100% is one core). Host memory pressure reached warning level, so no second or third guest was created or launched; simultaneous isolation and resource measurements remain pending. Its short 31.63 decoded FPS observation over 5.09 seconds does not replace the sustained core benchmark. The later native check using the 131-test package verified the clipboard round trip and cancellation of wipe and snapshot-save warnings; approved native snapshot mutations and wipe execution remain unverified.

The disposable wipe run (`artifacts/disposable-tests/e2ac0dfb-1334-42aa-8067-99635c2d4076/EVIDENCE.md`) verified the production manager's explicit wipe on a fresh API 36 guest: the installed fixture and unique marker were gone after boot. All owned guests and the isolated runtime were removed; watched user AVD/SDK metadata remained unchanged. This verifies the service. Native wipe-warning cancellation was subsequently verified; approved wipe execution through the native UI remains unverified. That run's accompanying boot observations used different ports and qualified no pairs; they remain historical. The later matched comparison below is the current service-level baseline.

The matched cold-boot baseline (`artifacts/disposable-tests/3ad4eb4f-48de-48ff-b590-8a53e4e12402/EVIDENCE.md`) completed **three exactly matched pairs** on one disposable API 36 guest, using console port 5554 and identical launch arguments/configuration. Direct and production-manager means were **17.882012 s** and **17.024330 s**, an observed ratio-of-means difference of **−4.796%** with only three observations per method. This measures launch invocation through selected-serial boot completion, excluding the native app, display bridge and presentation. It does not prove faster boot, a general overhead guarantee or whole-app acceptance. Exact cleanup and unchanged watched user metadata passed; the earlier unmatched and preparation-only attempts remain history.

The current live probe recorded 3,672 decoded frames over 61.64 seconds (59.57 FPS; every sample window above 59 FPS), guest-verified touch/text/drag, both orientations, a 23.66-second static screen, bridge replacement preserving PID and guest state, screenshot capture and clean teardown. Its `metrics.json` and `run-status.json` contain the same passed session ID. Receive-to-decode timing is not input-to-visible latency, and submitting a frame to the native display layer is not proof of physical screen presentation. Read the validation record for remaining native UI, performance and compatibility checks.

The native UI pass (`artifacts/native-ui-20260908-2051/EVIDENCE.md`) verified library/Settings, Booting→Running, attached APK installation and Cmd-I cancellation, controlled text/touch/drag, F1→Home, fullscreen landscape/portrait targets and rotation. F1 was restored to None. Shift-Cmd-S exported a decoded 1280×2856 PNG; native recording exported a fully decoded 56.49-second H.264 MP4; diagnostics export produced a verified ZIP. Manual reconnect preserved the PID and guest state. Stop/Idle and Quit completed; the fixture APK, exact app/emulator processes and forwards were cleaned up. The earlier lock and overlapping-input attempt remain historical; the later controlled input checks passed.

The native clipboard and cancellation check (`artifacts/native-ui-clipboard-20260908/EVIDENCE.md`) used the matching 131-test package. A fresh token created only by the guest fixture transferred through **Copy Android Clipboard**, pasted exactly into the native Logcat filter field, and then pasted back into Android with Command-V; fixture logs confirm the same token. Wipe-warning Cancel was followed by an ordinary launch without a wipe flag. Cancelling snapshot save left the empty list unchanged; Load/Delete stayed disabled. The filter was cleared, Pause turned off and the panel closed. Fixture uninstall, native Stop/Idle, Quit and exact process/forward cleanup passed. The earlier clipboard attempt remains inconclusive history; this test does not establish its cause.

The 140-test native panel retest (`artifacts/native-presentation-panel-fix-20260908/EVIDENCE.md`) recorded **56.015 submitted FPS and 59.561 decoded FPS over 86.583988 s** with Diagnostics open, the same app/VM/bridge, and at least 70.0223 s unattended. It passes the sustained ≥30 submitted-FPS average criterion on this configuration, under host pressure level 2. It does not prove every shorter interval, physical scanout or a broad guarantee. The fixture was installed/launched through ADB as workload setup after CUA coordinate actions were unavailable; this supplies no new native input pass. Native Logs/Diagnostics switching, Pause, matching/nonmatching filters and Copy were verified. The fixture, exact app/VM processes and forwards were cleaned up. The earlier 137-test panel-delay measurement (`artifacts/native-presentation-20260908/EVIDENCE.md`) and 124/131-build spot readings remain historical scopes.

APK drop, approved native snapshot mutations/wipe execution, exhaustive hardware keys, resize/scale/focus-loss/IME, clipboard error/race cases and simultaneous-device acceptance remain limitations. The measured 140-test package also showed cached Diagnostics saying Stopping after actual Idle. The subsequent 152-test source corrected that cache and added runtime-failure evidence and unsupported-snapshot handling. Those cases remain in the current 175-test suite. They are outside the historical performance package. The final-package native exit/recovery/cache smoke passed as recorded below.

The final 152-test package smoke (`artifacts/native-exit-evidence-20260908/EVIDENCE.md`) passed controlled unexpected-runtime-exit handling: one SIGTERM targeted the exact owned emulator, which exited normally with status 0. The native app showed Failed with original identity/output and saved a CRC-valid, owner-only 17,634-byte failure ZIP without an evidence warning. Native Start Device reached Running with a new runtime/PID and cleared the old error. Stop then showed Idle in both the footer and Diagnostics; Quit and exact process/forward cleanup passed. Normal Stop created no extra failure archive. This verifies controlled exit/recovery, not a spontaneous crash or a new performance/input benchmark.

`scripts/build-test-apk.sh` builds the optional test workload. Its defaults require Android platform 36, build-tools 36.1.0, and Android Studio's bundled JDK. Override them with `ANDROID_SDK_ROOT`, `ANDROID_STUDIO_JDK`, `ANDROID_PLATFORM_API`, and `ANDROID_BUILD_TOOLS_VERSION`. These are test-fixture dependencies, not requirements for running the macOS app with an existing AVD. See [`Tests/Fixtures/AndroidProbe/README.md`](../Tests/Fixtures/AndroidProbe/README.md) before running the probe: it boots its own instance of the first discovered AVD and temporarily installs its test APK.

## Scope

The first-release workflow is discovery → headless boot → embedded interactive Android → core controls → APK install/screenshot → safe lifecycle handling. Separate native device windows are the MVP multi-device direction.

The PRD's P1 developer workflows now have implementations: quick/cold boot and wipe/snapshots, Logcat pause/filter/copy, video export, clipboard transfer on request, and multiple windows with resource feedback/advisories. Feature-specific live and native UI acceptance remains incomplete, including simultaneous multi-device lifecycle/resource checks. Native input, fullscreen/rotation, screenshots, recording, diagnostics, reconnect, explicit clipboard transfer, Logcat filter/Pause/Copy, wipe/snapshot-save cancellation, Stop/Quit and one sustained native presentation interval now have bounded evidence; the remaining UI and performance gates are stated above.

An update feed, updater preferences, Developer ID signing, notarization, and clean-Mac release validation remain owner release-configuration work. Advanced simulation, a system-image marketplace, full AVD creation, cloud emulators, and IDE-level debugging are explicitly deferred by the specifications. Their roadmap status is separate from the implemented P1 workflows and from the remaining P0 release gates.
