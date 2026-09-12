# Android verification fixture

`ProbeActivity` is a local test app for the native display bridge. It provides a
known tap target, text field, continuous drag target, and continuously animated
surface. Every geometry/input event includes the unique session passed by the
host probe, so previous Logcat entries cannot satisfy a new run accidentally.
F1 pauses/resumes the animation for the idle-video regression check.

The **Set test clipboard** button creates a fresh `ProbeClip-<UUID>` value inside
Android, displays it, and logs `CLIPBOARD_SET`. It never reads the prior clipboard.
For a controlled native clipboard check, click that button in the embedded
device, choose **Copy Android Clipboard**, and use Command-V in the native Logcat
filter. Compare the exact token, clear the filter, then paste into the fixture's
Android text field with Command-V and compare its `TEXT` event. This avoids a
temporary host-clipboard helper supplying or restoring the expected value.
Launching the fixture manually labels its events `SESSION=manual`; use the fresh
token plus timestamps to identify that test, rather than accepting older events.

Build it from the project root:

```sh
bash scripts/build-test-apk.sh
```

The script uses the installed Android SDK, Android Studio's JDK, platform 36 and
build-tools 36.1.0. Override `ANDROID_SDK_ROOT`, `ANDROID_STUDIO_JDK`,
`ANDROID_PLATFORM_API`, or `ANDROID_BUILD_TOOLS_VERSION` when needed. The generated
APK and its local debug signing key stay under `artifacts/test-apk/`; this test APK
is not bundled with the macOS app.

Run the native probe from the project root after building `SimulatorProbe`:

```sh
.build/debug/SimulatorProbe --run
```

The probe launches its own headless emulator from the first discovered AVD,
refuses to replace a pre-existing copy of this fixture, installs it, verifies
direct scrcpy input and both orientations, measures six ten-second windows of
decoded video, waits 23 seconds on a static screen, reconnects the bridge, and
verifies state preservation. It uninstalls the fixture and stops only the runtime
it owns. The geometry test uses selected-serial ADB `wm user-rotation` to lock the
requested orientation. Original rotation preferences and free/lock mode are
restored during cleanup and recorded in metrics. It does not use scrcpy's
temporary freeze/thaw rotation command.
Metrics, guest events and screenshots are written under
`artifacts/probe/`. Check that `run-status.json` says `passed` and its session
matches `metrics.json`; a metrics file from a prior run does not establish that
the latest run passed.

The throughput gate requires an average and every ten-second window of at least
30 decoded frames/second. These metrics measure VideoToolbox output and do not
measure AppKit presentation or input-to-visible latency. The separate native UI
workflow must validate presentation, window geometry and focus handling.
