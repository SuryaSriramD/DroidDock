# Mac Expo reproduction prompt

Copy the prompt below into your coding agent on the Mac. Windows observations are reproduction targets, not confirmed macOS bugs. The native Swift app and the Electron Windows/Linux app have different renderers and terminal launchers.

---

Investigate whether the native macOS DroidDock app reproduces the failures observed during a Windows Expo Go test. Work in https://github.com/SuryaSriramD/DroidDock. First read applicable AGENTS.md files and inspect the working tree. Preserve uncommitted work, existing phones, SDKs, apps and terminal settings. Fetch the current PR #1 branch (`codex/windows-linux`) without resetting local changes; record the exact commit and native app version tested. Use the Swift macOS app, not the Electron implementation in `desktop/`.

The Windows test used Android 16/API 36 x86_64, Expo SDK 57.0.26, Expo Go 57.0.9 and Node 24.19.0. Reproduce with an ARM64 phone on Apple Silicon. Record the actual versions available on this Mac and explain any difference instead of silently treating it as an identical environment.

## Questions to answer

1. **Display freshness:** On Windows, DroidDock reported a connected display but kept showing an old home-screen frame while ADB screenshots showed Expo's current screen. Reconnect restored live video. Does the native Mac renderer ever freeze while Android continues running? If yes, distinguish missing encoded packets, decoding failure, presentation failure and a genuinely static Android screen.
2. **ADB responsiveness:** After stopping Metro, Windows ADB hung on both `shell am force-stop host.exp.exponent` and `devices -l`. Restarting the server restored access; the root cause was not established. Can this be reproduced on Mac, and is it associated with scrcpy traffic, Expo's port forwarding, shutdown, multiple SDKs or an ADB version conflict?
3. **Node selection:** Windows had Node 20.12.2, and npm.cmd/npx.cmd selected that binary despite another Node being first on PATH. The .cmd behavior is Windows-specific. Check the Mac's effective `node`, `npm`, `npx`, version manager and Expo Node requirements. Distinguish environment configuration from an app defect.
4. **Localhost addressing:** Windows Metro bound to `::1` while Expo sent Android to `127.0.0.1`, causing a load failure. An IPv4-first Node setting scoped to Metro resolved it. Check the actual listening address, advertised Expo URL, adb reverse mapping and guest connectivity on Mac before applying any workaround.
5. **CLI isolation:** Windows Electron CLI commands emitted Chromium cache errors while the GUI was open. The native Mac app has no Chromium cache, so do not report that exact issue as applicable. Instead verify simultaneous native CLI requests, clean stdout/JSON, stderr and exit codes while the GUI is running.

## Reproduction procedure

- Inventory macOS/hardware, app commit/version, Android ABI/API, emulator/ADB versions, SDK paths, and Node/npm/Expo versions. Use current official versioned Expo documentation. Do not print secrets or full environment dumps.
- Use an existing DroidDock-managed phone if available. If Android is not installed, obtain license acceptance before downloading it. Preserve pre-existing Expo Go and device data. Note whether the phone and app were initially running.
- Create a disposable Expo blank project under a clearly marked temporary directory. Read any generated AGENTS.md before editing. Use a supported Node runtime scoped to this shell; do not replace global Node installations or rewrite unrelated profiles.
- Add a small visible counter and a changing label. Boot with the actual installed `droiddock boot PHONE_ID` terminal command, selecting the ID from `droiddock list`. Start with ordinary `npx expo start --android --go --localhost`. Do not apply the Windows workaround in the baseline run.
- Confirm the running application on Android, not merely CLI success. Record a native DroidDock screenshot and an independent `adb exec-out screencap -p` screenshot. Verify taps increment the counter exactly once and a source edit appears through Fast Refresh. Record the foreground Android activity and Metro bundle outcome.
- Exercise backgrounding/minimizing/restoring the phone window, closing/reopening its display without stopping Android, rapid screen changes and ordinary CPU load from bundling. Repeat several times for 5–10 minutes. Include at least 30 seconds on an unchanged screen; lack of video on a static surface is not proof of a freeze.
- If the display freezes, capture native diagnostics before reconnecting: stream/session identity, received/decoded/submitted frame counts, VideoToolbox errors, presentation-layer state, timing, ADB screenshot and relevant logs. Check `Sources/SimulatorKit/ScrcpyBridge.swift`, `VideoDecoder.swift`, `Sources/AndroidSimulator/SessionController.swift` and the native display surface. Do not infer the cause from Windows code alone.
- If Expo fails to load, inspect the Metro listening socket and ADB reverse mappings. Test IPv4 and IPv6 loopback explicitly. Only if evidence shows the mismatch, retry with `NODE_OPTIONS=--dns-result-order=ipv4first` scoped to the Metro process, preserving other existing options. Record baseline and workaround results separately.
- Check ADB before/after display reconnects and Metro shutdown. Use a subprocess timeout for every diagnostic command so a hung server cannot stall the investigation indefinitely. Do not clear logs or restart ADB until evidence is saved. Do not kill a shared server or unrelated emulator without authorization. Never terminate processes by a broad name match.
- Verify `droiddock list`, `status --json`, boot and stop from Terminal while the native GUI is open. Native boot/readiness must correspond to a usable display. Compare the native CLI and runtime with the Windows observations; do not assume new Electron-only commands exist on Mac.

## Deliverables and cleanup

Write a report with one row per question: **reproduced**, **not reproduced within this test**, **not applicable**, or **blocked**. Include exact versions, commands, timings, expected/actual behavior, evidence paths and the smallest repeatable sequence. Separate verified causes from hypotheses. A successful short test is not proof that a sporadic failure cannot occur.

If source changes become appropriate, first explain the reproduced cause and proposed scope. Do not publish or merge Mac changes as part of this reproduction-only task. If checking an existing fix, run applicable `swift test --disable-sandbox` tests and the same real-device scenario; report missing Xcode/Swift prerequisites honestly.

Stop only the Metro process created by this test. Remove its ADB reverse mapping without disturbing pre-existing mappings. Uninstall Expo Go only if this test installed it into a previously clean phone. Verify the absolute temporary-project path and ownership marker before deleting that project and its dependencies. Restore the phone/app to their initial running state and keep screenshots/diagnostics outside the deleted directory. Report any cleanup that could not be completed.
