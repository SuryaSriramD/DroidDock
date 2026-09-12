# Disposable Android runtime validation plan

Raw local test evidence is excluded from this public repository; inline `artifacts/` paths refer to the original local workspace. Downloads are available on [GitHub Releases](https://github.com/SuryaSriramD/DroidDock/releases).

Original read-only feasibility assessment, 8 September 2026. Subsequent isolated one-guest snapshot and data-wipe runs passed; see [VALIDATION.md](VALIDATION.md), snapshot evidence (`artifacts/disposable-tests/955fe272-5299-47da-a2b0-de1314e206d3/EVIDENCE.md`) and wipe evidence (`artifacts/disposable-tests/e2ac0dfb-1334-42aa-8067-99635c2d4076/EVIDENCE.md`). The procedure below records the original plan. Two- and three-guest acceptance remains pending after measured host memory pressure reached warning level. The Mac is accessible and substantial native UI checks have now passed.

## Verified prerequisites

- Installed ARM64 system images for API 36, 36.1 and 37.1; no download is required.
- Emulator, qemu-img, mkfs.ext4 and Android Studio's bundled AvdManagerCli are available. The SDK cmdline-tools/avdmanager wrapper is absent.
- Bundled AvdManagerCli displayed its general and create-avd help. This proves CLI availability, not successful AVD creation.
- Host has 24 GB RAM and approximately 30 GiB free disk at inspection time. Recheck before running.
- Prior runtime logs raised a configured 2048 MB guest to 4096 MB. Budget at least 4 GiB guest RAM plus overhead per VM.

## Isolation procedure and remaining expansion

1. Create one uniquely named workspace test directory. Place avd, Android user and emulator home directories inside it. Set ANDROID_AVD_HOME, ANDROID_USER_HOME and ANDROID_EMULATOR_HOME only in the isolated test harness environment. Never change the user's shell configuration or normal Android directories.
2. Invoke Android Studio's bundled Java with these arguments, supplied as an argument array:

```text
-Dcom.android.sdkmanager.toolsdir=<SDK>/cmdline-tools/latest
-cp
<Studio>/Contents/plugins/android/lib/*:<Studio>/Contents/lib/*
com.android.sdklib.tool.AvdManagerCli
create
avd
--name
<unique-test-name>
--path
<test-root>/avd/<unique-test-name>.avd
--package
system-images;android-36;google_apis_playstore;arm64-v8a
--abi
arm64-v8a
```

The classpath is one argument; the image package token contains semicolons and must never be interpolated unquoted into a shell command. Supply `no` plus a newline only for the custom-hardware prompt. Do not pass --force. Confirm the tool writes solely inside the isolated directories.

3. Configure only the newly created test AVD: 720×1280, two cores, 4096 MB RAM, a 4 GiB userdata partition, no SD card, and host GPU. Use the installed image's fresh userdata template; do not clone the user's existing AVD or data.
4. Launch through the production EmulatorProcessManager with the isolated environment. Test unique snapshot save/list/load/delete, state restoration, bridge reconnect and cleanup on one disposable guest. Do not use -read-only: it prevents saving snapshots. Actual data wipe tests may target only this disposable AVD.
5. Measure disk and memory usage before adding a second or third separately named writable AVD. Estimate 6–8 GiB disk per guest with snapshot headroom; three may need 18–24 GiB and at least 12 GiB guest RAM plus overhead. Keep free-space headroom, stop expansion if pressure is high, and record actual use rather than assuming feasibility proves performance.
6. Exercise selected-serial action isolation, independent stop and simultaneous lifecycle. This headless service test does not establish native window/input acceptance.
7. Stop and await only exact test-owned processes and commands, verify forwards returned to baseline, then remove only the unique directories created by this run. Retain metrics and failures separately from the already-passed core probe.

## Remaining native and release work

Native picker installation, screenshot/recording export, controlled clipboard round trip, F1 mapping/restoration, fullscreen/rotation and Stop/Quit passed. Snapshot Save and Wipe Data warnings were cancelled successfully. Remaining cases include APK drop/error, confirmed snapshot mutations, exhaustive focus/IME/scale behavior, automatic recovery and leave-running policies. Physical input-to-visible latency, broader compatibility/reliability, update distribution and production signing also remain separate gates.

The first direct/manager boot observations used different ports, so zero matched pairs qualified. The first repeat `9a7332a4-db9d-44ba-a7e9-cd653b2ec45f` stopped after its unmeasured preparation boot because Android normalized the disposable configuration. No measured pair ran, and cleanup passed. The corrected repeat `3ad4eb4f-48de-48ff-b590-8a53e4e12402` freezes the effective configuration after preparation and uses a fresh process per observation, three alternating pairs, identical launch arguments and serial, and a `2 × MSL + 5 second` cooldown with both ports bind-tested outside timing. It permits only one guest and retains explicit resource/cleanup checks. Preparation changed only the data partition from requested 4 GiB to the emulator image minimum of 6 GiB, plus INI whitespace formatting; all measured boots use the same normalized configuration.

Sources: [Android emulator storage](https://developer.android.com/studio/run/emulator-commandline), [Android environment variables](https://developer.android.com/tools/variables), [AOSP userdata initialization](https://android.googlesource.com/platform/external/qemu/+/emu-master-dev/android-qemu2-glue/main.cpp).
