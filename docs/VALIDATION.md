# Validation record

Raw local test evidence is excluded from this public repository; inline `artifacts/` paths refer to the original local workspace. Downloads are available on [GitHub Releases](https://github.com/SuryaSriramD/DroidDock/releases).

Updated 6 October 2026. This record separates automated contracts, live Android runtime verification, native UI observations, and unmeasured release targets. The [requirements audit](REQUIREMENTS_AUDIT.md) maps this evidence to the supplied specifications.

## Mac Expo reproduction 6 October 2026

The [Mac reproduction prompt](testing/mac-expo-reproduction-prompt.md) was exercised against the installed native **0.4.4/build 11** app on an Apple M4, macOS 27.0.1 build 26A434. The source checkout was PR #1 at `3c5c25f7dbbd47bd6ffbc42028ae96bb7ec07868`. `Sources/`, `Package.swift`, and `scripts/build.sh` are unchanged from the Mac 0.4.4 source commit `adc051e2cc02c7e266aa21cb185240652ea4ad7c`; the installed bundle does not embed a Git SHA, so it is identified by version and executable hashes rather than claimed to be rebuilt from the PR head.

The existing managed phone used Android 16/API 36 **arm64-v8a**, 1080 × 2400, 2048 MB, Emulator 37.2.12.0 build 16428233, and Platform-Tools 37.0.1-15733141. The disposable project used **Expo SDK 57.0.26, Expo Go 57.0.9, Node 24.19.0, and npm 11.17.0**. Node was scoped to the test; the host's Homebrew Node 25.5.0 and terminal profiles were unchanged. The Windows baseline used x86_64, so this was not an identical hardware environment.

| Reproduction target | Result | Evidence from the Mac run |
| --- | --- | --- |
| Persistent stale native display while Android updates | **Not reproduced within this test** | One native tap changed the counter from 0 to 1; Fast Refresh appeared. Three minimize/restore and three close/reopen cycles preserved Android. Native and independent ADB screenshots matched counter 1 and frame label 1186. A static control lasted 88.689 seconds and resumed normally. |
| ADB hangs after stopping Metro | **Not reproduced within this test** | With the display connected and reverse mapping still present, force-stop completed in 0.079 seconds and device listing in 0.015 seconds, both exit 0. The original shared ADB server was preserved. |
| Windows npm/npx `.cmd` choosing the wrong Node | **Not applicable** | The native Mac run successfully used the scoped Node 24 runtime. No Windows wrapper behavior was attributed to Swift. |
| IPv6 localhost causing Expo load failure | **Not reproduced within this test** | Metro listened on `[::1]:8081` and advertised `exp://127.0.0.1:8081`, with `tcp:8081` reversed through ADB. Host IPv4 HTTP failed and IPv6 succeeded, but Expo loaded and Fast Refresh worked without an IPv4-first setting. |
| CLI interference while the GUI runs | **Not reproduced within this test** | Six simultaneous `list --json` and six `status --json` requests returned valid JSON, success=true, exit 0, empty stderr, and unique response IDs in 1.319–1.398 seconds. Chromium cache contention itself is not applicable to Swift. |

The actual installed CLI booted the phone in **17.244 seconds**. Ordinary `npx expo start --android --go --localhost` ran for **701.7 seconds**, with no `NODE_OPTIONS` workaround; Metro bundled 708 modules in 2900 ms. The foreground Android activity was `host.exp.exponent/.experience.ExperienceActivity`. A manual display reconnect preserved the emulator process and left ADB responsive. CLI stop completed in **8.939 seconds** and status returned `idle`.

Observations were periodic captures and diagnostics, not continuous recording. One cumulative presentation-timer gap reached **5303.7 ms** during the window exercise; later changing frames appeared normally. No persistent divergence between native and Android screenshots was observed, but this short run does not exclude transient stalls or intermittent failures. Native “Receive FPS” counts decoded frames, and submitted counts measure display-layer enqueue calls, not physical presentation. Raw encoded-packet counts are absent, limiting diagnosis of a future freeze. Sampled diagnostics showed no format/sample/layer errors. Early automation coordinate errors resolved after closing/reopening the window; the successful native tap and pause/resume checks were verified afterward.

Fixture lint and strict JavaScript typechecking passed. Metro, the test-only Expo Go install, its reverse mapping, and the marked temporary project/runtime/downloads were removed. The existing phone and SDK were preserved, the phone returned to its initial idle state, and the original GUI and ADB server stayed running. No production Mac code was changed. Local command results, screenshots, executable hashes, diagnostics, session/runtime logs, and the complete report are retained under `artifacts/mac-expo-20261006/`; they are not distributed with the source repository.

Windows/Linux release validation is recorded separately in the [0.5.0 release notes](https://github.com/SuryaSriramD/DroidDock/releases/tag/v0.5.0) and [release workflow](https://github.com/SuryaSriramD/DroidDock/actions/runs/37461019226), including real Android/Expo checks on Ubuntu 22.04 AppImage and Ubuntu 24.04 DEB installations.

## v0.4.4 development preview — 5 October 2026

The installed app now offers a Terminal Setup screen showing the selected Android SDK, exact PATH folders, and the managed phone location. Set Up Terminal applies the configuration; Later leaves shell files untouched. The screen is offered once and can be reopened from the app menu, sidebar, or Settings. Only successful setup enables ongoing SDK-path synchronization. Existing 0.4.3 configuration is preserved and does not implicitly enable the new preference. The screen includes progress, retry, and new-terminal/Expo guidance. Sheet presentation guards keep Android setup, terminal setup, and update dialogs from competing.

The focused warnings-as-errors suite passed **55 tests with zero failures**: 10 terminal setup/model integration cases, 14 environment installer cases, and 31 existing discovery, Android setup, app update, and CLI handler cases. Checks include no profile writes on discovery or Later across relaunch, explicit setup and persisted opt-in, SDK changes during writes, failure/retry, shutdown joining, and competing-sheet guards. No Android guest was launched. Evidence is in `artifacts/droiddock-044-20261005/`.

Release review also fixed an inherited session-identity issue: after changing SDKs or AVD configuration paths, a same-named phone can no longer reuse an unrelated active controller for launch, cold boot, wipe, or terminal actions. Fully idle mismatches are retired; active mismatches remain untouched. Eight fixture regressions verify process identity, launch counts, ownership, and phone-data preservation. Automatic update results now defer presentation until other setup/editor sheets close; a gated regression covers delayed network completion and one-time presentation. The final complete warnings-as-errors suite passed **358 tests with zero failures** (260 SimulatorKit and 98 application tests).

Native checks verified the Terminal Setup layout and SDK/PATH text, Later returning to the library with unchanged shell-file hashes, reopening from the sidebar, the ready screen, Apply Again, and Done. A fresh zsh login shell resolved all three commands and the private SDK/AVD environment, and the CLI listed the existing phone. The final rebuilt app was installed directly and reopened with the ready state preserved. Its bundle matched the verified DMG; phone configuration and shell-file hashes were unchanged by replacement. Previous copies moved to Trash and update staging was removed. No Android guest was launched by these validation actions.

The **0.4.4/build11** release bundle and DMG passed signature, full manifest, read-only mount, layout, and checksum verification. Xcode's debug-symbol generation initially failed under the filesystem sandbox; the authorized build outside that restriction succeeded. The final DMG SHA-256 is `cdf84e832764da3b1c620bf6df9555c8e0e13ef619ef9938827d2509a7816a2a`. The verification mount and temporary staging were removed. This ad-hoc-signed development preview is prepared for GitHub Releases; it is not Apple-notarized and does not establish clean-Mac or broad platform compatibility.

## Automatic terminal environment — local 0.4.3, 5 October 2026

The installed app now configures terminal access during discovery, including before any phone exists. Only the shared app model running from `/Applications` or `~/Applications` enables this behavior; development and mounted-DMG copies do not modify shell profiles. SDK changes are serialized after any pending setup, and shutdown joins profile writes. Settings shows success or an actionable failure and offers a retry. Copy Android Environment sources the same generated script when automatic setup is ready.

The installer creates `~/.local/bin/droiddock` and a marked environment script under DroidDock's Application Support directory. Marked blocks in zsh startup and Bash's applicable login/interactive profiles source that script. It preserves existing content, backs up changed profiles, refuses conflicting commands and unsafe paths, revalidates snapshots, and attempts rollback after a failed write. Bash's existing login-file precedence and inherited absolute `ZDOTDIR` are honored. The selected SDK's tool directories move to the front without accumulating duplicates. SDK transitions clear only inherited Android values that still match DroidDock's own previous exports. Android exports require the app and SDK tools to remain executable.

The focused warnings-as-errors suite passed **64 tests with zero failures**, including **14 new installer tests** and **6 new app integration tests**. Disposable homes exercised real zsh/Bash startup with spaces and quotes, existing login profiles, repeated setup, backups, SDK switching, nested-shell PATH ordering, conflicts, parent/file symlinks, and rollback after a concurrent edit. App tests verified installation-location gating, deferred SDK availability, queued changes, retry and shutdown. Compilation first caught an unreachable cleanup branch; the initial fixture run exposed macOS's `/var` alias, now accepted only with its exact verified system destination. Final and diagnostic logs are in `artifacts/droiddock-043-20261005/`.

The **0.4.3/build10** release bundle and DMG passed signature, full manifest, read-only mount, layout and checksum verification. `/Applications/DroidDock.app` was updated directly and reopened; the previous copy moved to Trash and temporary staging was removed. Automatic setup preserved the original `.zshrc` content and made a byte-matching backup. A fresh zsh login shell with inherited Android variables removed and a minimal initial PATH resolved `droiddock`, `adb`, and `emulator` to the installed app and private SDK, exported the private SDK/AVD locations, and successfully listed the existing idle Android 16/API 36 phone. Earlier CLI checks timed out; both the subsequent direct CLI and clean-shell checks succeeded without a code change or app restart, so the earlier timeout cause is unconfirmed. The install and terminal reports are in the same evidence directory. The DMG SHA-256 is `ad301f43a3d91eb6b71f5d746b6894d60152ceac77a819832888a05dcb1c2517`; this local ad-hoc-signed build has not been notarized or published.

This configures new terminal sessions; it cannot change an already-running shell. It does not add an Expo launch bridge: boot a phone through DroidDock before pressing A or Shift+A in Expo. No Android guest was launched for these tests.

## Stale emulator lock recovery — local 0.4.2, 5 October 2026

The installed 0.4.1 app rejected configuration editing after the managed phone stopped because it treated any `hardware-qemu.ini.lock` as an active emulator. The actual phone's hardware and snapshot markers both contained the terminated PID `1401` followed by NUL. Read-only host checks found no emulator process, no ADB devices, no open phone files, and no held kernel locks. The stale marker files were preserved.

The shared editing/deletion guard now recognizes bounded regular decimal-PID-plus-NUL records. It requires the recorded process to be definitively absent (`ESRCH`), unheld record/flock locks, and stable file identity/content across inspection. Live or inaccessible owners, unsupported records, symbolic links, directories and special files remain blocked. Inspection never removes a marker. Existing fresh ADB/session checks and revalidation before saving or moving a phone remain in place; these checks do not reserve a phone against another application launching it afterward.

The final focused warnings-as-errors run passed **61 tests with zero failures**, including **9 new regressions** for stale/live owner markers, held locks, malformed/unsafe files, revalidation, and data preservation. An initial test-helper cleanup stalled in Foundation's synchronous process wait; teardown now explicitly releases the helper and awaits bounded cleanup. Another run caught Darwin reporting the inspection's own flock through `F_GETLK`; the record-lock query now precedes flock acquisition. Final results and the earlier diagnostic evidence are retained in `artifacts/droiddock-042-20261005/`.

A standalone harness linked to the fixed production module successfully loaded the actual stopped phone's configuration and ran the deletion preflight. It performed no save or deletion and verified unchanged configuration and lock bytes (`live-stopped-phone-validation.json`). No Android guest or temporary test app was launched for this validation.

The release build and **0.4.2/build9** DMG passed signature, version, full bundle-manifest, read-only mount, installer-layout and checksum verification. The mounted image was detached and its temporary directory removed; the interrupted test's three-file fixture was also cleaned up. The DMG SHA-256 is `3c84231a734d25646445b0f4c3bac7e581e9da8747753afae814d32a3a14c336`. This local ad-hoc-signed installer has not been notarized or published.

At the user's subsequent request, `/Applications/DroidDock.app` was updated directly from 0.4.1/build8 to the verified 0.4.2/build9 bundle. Normal application termination completed, staged and installed manifests/signatures matched the validated build, and the installed copy reopened with a new process identity. The previous app moved to Trash and staging was removed. The phone's configuration and lock bytes were unchanged. Evidence is in `artifacts/droiddock-042-20261005/direct-update-verification.json`. This local installation does not add automatic replacement to the built-in release checker.

## Library Stop Device — local 0.4.1, 5 October 2026

The library now shows Stop Device beside Open Device and in the phone menu for an owned active, starting, or failed-display/live-runtime session. A named confirmation captures the exact session and lifecycle generation. Canonical SDK/configuration identity and the current library entry are rechecked before stopping; an old confirmation cannot stop a replacement launch. Externally managed and prior-session processes are not stopped. The library shows Stopping during cleanup and disables Start, Cold Boot, and Wipe until it finishes. A fresh discovery afterward releases stale running-device restrictions on editing/deletion.

The focused warnings-as-errors suite passed **39 tests**, including **8 new LibraryStopTests** and the existing app-model, AVD editing, session-controller and terminal-owned-stop cases. New checks cover preserved configuration/userdata/snapshot bytes, editing after refreshed discovery, startup cancellation, stale confirmations, same-name SDK/configuration collisions, external ownership, failed-display guests, duplicate Stop and concurrent Quit. Logs are in `artifacts/droiddock-041-20261005/tests.log`.

A separate app with a unique bundle identity used a disposable SDK backed by ordinary Perl processes; no real Android guest was launched. Native UI checks observed the Stop button and menu item, the named confirmation, the background phone stopping, Start Device returning, and Edit AVD Configuration/Delete Phone becoming enabled. The fixture child exited, its data sentinel was unchanged, and it launched only once. The test app was quit while the user's DroidDock stayed running. The intermediate Stopping state was too brief to capture natively; gated automated tests verify cleanup remains pending until released. Evidence is retained in `artifacts/droiddock-041-20261005/native/verification.json`.

The app/CLI version is **0.4.1, build 8**. The local DMG's mounted source/signature/plist, layout, Applications shortcut, checksums and cleanup are verified by the packaging workflow. It remains an ad-hoc-signed local development artifact, without a public release or notarization.

## Android versions and app updates — local 0.4.0, 5 October 2026

Android Versions now discovers stable Google APIs ARM64 images, presents an explicit download choice, and creates a separate phone for each API. Decimal APIs retain distinct identities. Existing phones, installed image revisions and compatible shared tools are preserved. Installed images can recreate deleted phones without a download. License consent is cleared when changing versions or reopening setup; installation rechecks current download requirements. Incompatible shared engines are explained and blocked, because this build does not implement engine upgrades.

The full warnings-as-errors XCTest run passed **303 tests** (234 SimulatorKit, 69 application tests). After the final atomic-publication and presentation-lifecycle changes, focused warnings-as-errors runs passed all **27 installer tests** and **14 setup-model tests**. The final stable-release message clarification passed all **11 release-checker tests**. The current test inventory is 308 cases. Tests cover version filtering, distinct decimal phone names, old-data preservation, compatible tool reuse, checksum failures, cancellation before/after image publication, collision preservation, download-free retry, fresh consent, stale dismissal isolation, app version comparison, trusted release URLs, offline/rate-limit handling and daily checks. Evidence is retained in `artifacts/droiddock-040-20261005/`.

A read-only harness compiled the production catalog and release-checker sources and fetched live metadata. Google returned nine stable choices: **37.0, 36.1, 36, 35, 34, 33, 32, 31 and 30**, with API 37.0 identified as Android 17. No SDK archives were downloaded. The unauthenticated GitHub latest-release endpoint returned HTTP 404, because the repository’s only release, v0.2.1, is marked as a prerelease. The final UI explains that no stable release is available yet. Stable-only filtering is working; no live newer-release download is claimed. The captured response is `live-catalog-and-update.json`; the captured first response uses the earlier no-public-release wording, now clarified to refer to stable releases.

The release app and CLI report **0.4.0, build 7**. The local DMG passed mounted source-manifest, signature, plist/version, Applications-shortcut, Finder layout, checksum and detach/cleanup checks. It is an ad-hoc-signed development build, not notarized or published. App update checks offer user-initiated DMG download and manual replacement; automatic binary installation is not implemented. Native UI verification was blocked by the locked Mac, so the new screens are not claimed as visually verified. No real phone was changed, no Android version was installed, and no new runtime boot was performed.

## Phone configuration and deletion — local 0.3.2, 5 October 2026

The device menu now offers Edit AVD Configuration (display name, memory, CPU cores, screen width/height and density) and confirmed Delete Phone. Configuration saves preserve unrelated INI content and phone data, validate input, reject concurrent file changes, and replace the file atomically. Deletion moves the exact discovery index and phone directory to macOS Trash, checks shared-folder aliases, and attempts to restore the index if moving the directory fails. Shared SDK components stay installed. Deleting the last phone refreshes the library and restores Set Up Android. Both operations reject active sessions, fresh ADB conflicts or lookup failures, and emulator lock conflicts; checks do not reserve a phone against another application starting it after the final check.

The full warnings-as-errors XCTest run passed **257 tests with zero failures** (204 SimulatorKit, 53 application tests). The 42 new cases cover configuration preservation/validation, file and lock conflicts, exact Trash targets and failure recovery, SDK preservation, active-device refusal, launch/edit concurrency, refreshed metadata, and setup availability after final-phone deletion. Tests use temporary SDKs and injected Trash destinations. Logs are retained in `artifacts/droiddock-032-20261005/tests.log`.

A separate debug test app with its own bundle identity was connected through the SDK chooser to a disposable fixture. Native checks verified the editor layout and scrollable display fields, invalid-number validation, saving a changed name and RAM value, library refresh to 4096 MB, the named-phone confirmation, actual macOS Trash deletion, and Set Up Android returning and reopening its welcome screen. The fixture's unknown INI setting and data sentinel survived editing; its SDK executables survived deletion. The test app was quit afterward while the user's DroidDock remained running. No user phone was edited or deleted, and no Android image download or fresh Android boot was performed. Evidence is recorded in `artifacts/droiddock-032-20261005/native/verification.json` and `saved-config.ini`.

The release app and CLI report **0.3.2, build 6**. The DMG passed read-only mounted application-manifest/signature/plist checks, layout and Applications-shortcut checks, checksum verification and cleanup. Build/package logs and the report are retained under `artifacts/droiddock-032-20261005/`. This is a local ad-hoc-signed installer, not a notarized or published release. Android documents automatic snapshot invalidation after AVD settings change, so the editor does not delete snapshots or force a permanent boot mode; see the [Android snapshot documentation](https://developer.android.com/studio/run/emulator-snapshots).

## Completed setup prompts — local 0.3.1, 5 October 2026

The sidebar now hides Set Up Android when discovery finds a managed runtime and at least one phone. Settings shows Android is installed, and clearing the device selection shows a selection prompt. Readiness comes from runtime/device discovery rather than the setup sheet's transient completion state. Setup remains available for a missing runtime or phone and for users opting into managed Android from an external SDK; actions wait while discovery is loading.

The focused warnings-as-errors run passed **7 tests with zero failures**: five setup-model tests and two app-model tests. The new regression exercises discovery after relaunch, cleared selection, suppression of repeated setup, phone removal/restoration, external SDK opt-in, and missing SDK recovery. The existing SDK-switch test also verifies that setup cannot open during discovery. These tests use temporary SDK fixtures and do not launch Android or modify installed SDKs.

Built and verified `artifacts/DroidDock-macOS.dmg` as **0.3.1, build 5**, with matching CLI version. The read-only mounted app matches the signed source manifest; signature, plist, image checksum, Applications shortcut, Finder layout and cleanup checks passed. Logs and the report are retained under `artifacts/droiddock-031-20261005/`. This is an ad-hoc-signed local build, not a notarized or published release. No native UI or fresh Android installation/boot was performed for this narrow change; the earlier full-suite results below remain dated evidence.

## Local 0.3.0 DMG — 4 October 2026

Built `artifacts/DroidDock-macOS.dmg` containing the managed-Android source as version **0.3.0, build 4**. The app and bundled CLI report matching versions; the bundle identifier and local command protocol remain unchanged. Installer instructions now describe in-app setup without Android Studio or Java, first-use downloads, and the default phone's command-line ID.

The release build, shell syntax check, and DMG verification passed. Verification mounted the image read-only, matched its complete application manifest against the signed source bundle, checked signatures/plist/version, verified the Applications shortcut and Finder layout/background, then detached the image and removed temporary directories. The final SHA-256 file matches both the image and verification report. Logs and the report are retained under `artifacts/droiddock-030-20261004/`. Application logic was unchanged in this packaging pass; the 214-test result below belongs to the 1 October source validation.

This is a local, ad-hoc-signed development installer. It has not been notarized or published to GitHub Releases. Fresh managed-runtime installation/boot and clean-Mac Gatekeeper acceptance remain unverified; see the setup validation below.

## Managed Android setup — 1 October 2026 source

The source now includes in-app setup for an Apple Silicon Android 16 phone without Android Studio or Java. Catalog checks selected stable Emulator 37.1.11, Platform-Tools 37.0.1, and Google APIs ARM64 API 36 revision 7 from Google's live manifests, totaling 2,283,357,573 compressed bytes. Both required licenses (`android-sdk-license` and `android-sdk-arm-dbt-license`) are displayed before installation. Small HTTP range reads confirmed the emulator/image archive roots and the current image's `data/empty_data_disk` layout; no full SDK package was downloaded during validation.

The final full XCTest run passed **214 tests with zero failures**, with warnings treated as errors (174 SimulatorKit and 40 application tests). New coverage includes catalog selection and malformed metadata, license gating, cancellation/retry, disk preflight, checksum failures, real small ZIP extraction and path/link rejection, both image layouts, installation locking, preservation of existing data, and private SDK/AVD discovery. Local evidence is in `artifacts/managed-android-20261001/tests.log` and `archive-directory-evidence.json`. The initial restricted run could not bind local fixture ports or use macOS video encoders; the final run used the required host access. A new extraction path-alias test exposed an enumeration issue that was fixed before the final run. A compiler warning in existing Logcat task captures was resolved by making the already-strong outer capture explicit.

The release app built and was ad-hoc signed successfully. Native UI inspection confirmed the existing SDK/device remained listed, Set Up Android opened its welcome screen, and Continue fetched live metadata and displayed both licenses with a 2.28 GB download and 13.43 GB free-space requirement. The acceptance checkbox was unchecked and Agree & Install Android was disabled. The setup sheet was visually checked for readable text and unclipped controls; no licenses were accepted or SDK packages installed during this check.

Fresh installation and Android boot remain unverified for this new flow: the host had about 4 GiB free before builds, below setup's computed space requirement. Fixture success and archive metadata checks do not establish clean-Mac download/boot or Gatekeeper acceptance. Runtime updates and a general device-creation wizard are outside this implementation. The published v0.2.1 DMG predates these changes.

## DMG installer redesign — 10 September 2026

The DMG now includes a deterministic Retina background, fixed app-to-Applications layout, two visible installation targets and a compact Finder window. The app remains the exact v0.2.1/build3 bundle. The packaging script verifies the mounted app manifest/signature, Finder metadata, background references and image checksums before replacing the download. The installer evidence (`artifacts/droiddock-installer-20260910/EVIDENCE.md`) records the package identity and the passing native Finder visual check; the current DMG verification (`artifacts/dmg-verification.json`) records automated checks. No application tests were rerun for the installer presentation change.

## Version 0.2.1: DroidDock name

The app is now **DroidDock**, its terminal command is `droiddock`, and its installer is `DroidDock-macOS.dmg`. The bundle identifier, preferences, runtime history and command mailbox retain their existing identities. The bundled `android-simulator` alias, previous environment variable and URL scheme remain compatible.

The focused branding run passed **25 tests with zero failures**, with warnings treated as errors, on 10 September 2026 at 19:40:31.533 Asia/Kolkata. It covers command parsing/transport, both URL schemes, app discovery order, terminal handling and diagnostics. See `droiddock-branding-focused-tests.log` (`artifacts/droiddock-branding-focused-tests.log`). This is a focused run; the earlier 175-test full-suite result below belongs to v0.2.0.

The release build succeeded. Bundle metadata and both command names passed checks, as did five temporary-directory CLI installer checks. A live read-only `droiddock list` request reached the already-running v0.2.0 app through its legacy URL scheme and returned the available device. The existing app and emulator retained the same process identities. No new native UI, Expo, input or performance run was conducted for this rename. See the branding evidence (`artifacts/droiddock-branding-20260910/EVIDENCE.md`) for exact scope and package verification.

## Version 0.2.0: Simulator-style window and terminal access

The v0.2.0 suite passed **175 tests with zero failures**, with warnings treated as errors, on 9 September 2026 at 00:46:49.574 Asia/Kolkata (87.096 seconds). See `swift-test-175.log` (`artifacts/swift-test-175.log`). The terminal transport/parser, URL receiver, bounded command cancellation, owned Stop regression and window geometry cases are included. Eight executable CLI argument/error fixtures and five installer checks passed separately. An initial 170-test run had two pre-existing recording/controller timeout cases fail; unchanged focused reruns and both later full suites (170 and 175) passed. The failed log is retained; scheduling pressure is a possible explanation, not a proven cause.

The app now uses a compact floating native toolbar, rounded phone bezel, transparent window surround, orientation-dependent window sizes, and a More menu retaining developer controls. The bundled CLI provides list/status/boot/open/stop/install/open-url through the same app-owned runtime. Settings exposes a copyable installer for a user-owned command link; shell profiles are not modified. Device data erasure is not exposed through the CLI.

The terminal and native check record is `native-chrome-cli-20260909/EVIDENCE.md` (`artifacts/native-chrome-cli-20260909/EVIDENCE.md`). Expo Go rendered the local test project in the native window after Shift+A selected the same owned AVD. Portrait/landscape window sizing, fullscreen restoration, Home, CLI install/open-url/Stop and cleanup passed; controlled CUA coordinate input remained unavailable. The record gives exact scope and identities. Current package checksums live in the JSON records above. The performance and broad native input measurements below apply to the explicitly named historical builds; the new chrome has no fresh sustained performance or physical-input benchmark.

## Earlier runtime and native evidence

The live bridge/runtime probe passed on one Apple M4 Mac and Android API 37 AVD: **59.57 decoded FPS over 61.64 seconds**, successful direct touch/text/drag, both orientations, static-screen survival, bridge replacement with preserved guest state, screenshot capture, and complete probe cleanup. That historical package had **152 automated tests**; the subsequent v0.2.0 suite had 175. The final152-test package also passed a controlled native emulator-exit/evidence/restart/Stop check. This is the user-selected local development delivery; remaining platform and release-certification limits are stated below. Recording passed a separate live MP4 export/automatic completion/cancellation run. A fresh API 36 guest also passed interactive snapshot restoration, deletion and bridge recovery with its text/counter state preserved. Two- and three-guest tests remain pending after measured host memory pressure reached warning level. Native CUA interaction verified the library, embedded Android reaching Running, Stop confirmation/Idle, app reopening, readable streaming logs and Pause, and Quit terminating the app-owned runtime/bridge. The later native pass also verified APK-picker installation, controlled typing/touch/drag, F1 mapping and restoration, fullscreen, rotation, PNG/MP4 export, diagnostic ZIP export and bridge reconnect. The 131-test retest verified a controlled clipboard round trip, snapshot-save/wipe cancellation and clean Stop/Quit. The 140-test panel retest averaged 56.01 submitted FPS over86.58seconds with Diagnostics open, and passed native Logs/Pause/filter/Copy checks. Remaining native checks and performance gates are described below.

The 59.57 FPS figure measures H.264 frames delivered by VideoToolbox. It is **not** a measurement of AppKit presentation, physical screen refresh, or input-to-visible latency. This is a locally built, ad-hoc-signed development app, not a notarized production release or a broad compatibility certification.

## Authoritative artifacts

| Evidence | Artifact and interpretation |
| --- | --- |
| Current live metrics | `artifacts/probe/metrics.json` (`artifacts/probe/metrics.json`) |
| Current run completion | `artifacts/probe/run-status.json` (`artifacts/probe/run-status.json`): `state` is `passed`; session matches metrics. |
| Probe transcript | `artifacts/probe/live-run.log` (`artifacts/probe/live-run.log`) |
| Guest-observed input events | `artifacts/probe/guest-events.log` (`artifacts/probe/guest-events.log`); events carry the current unique probe session. |
| Bridge server transcript | `artifacts/probe/bridge-events.log` (`artifacts/probe/bridge-events.log`) |
| Decoded portrait and landscape | `decoded-portrait.png` (`artifacts/probe/decoded-portrait.png`), `decoded-landscape.png` (`artifacts/probe/decoded-landscape.png`) |
| Android screenshot | `android-screenshot.png` (`artifacts/probe/android-screenshot.png`), 1280 × 2856 pixels. |
| Most recent full-suite baseline (v0.2.0) | `artifacts/swift-test-175.log` (`artifacts/swift-test-175.log`): 175 tests, 0 failures, warnings-as-errors compilation; completed 9 September 2026 00:46:49.574 Asia/Kolkata. |
| Live recording | `artifacts/recording/2ACEA284-B0CB-4AAB-AAD2-A0E7CDE7AA69/result.json` (`artifacts/recording/2ACEA284-B0CB-4AAB-AAD2-A0E7CDE7AA69/result.json`), plus validated manual and automatic MP4 files in the same directory. |
| Actual snapshot-list response | `artifacts/recording/snapshot-list.txt` (`artifacts/recording/snapshot-list.txt`); original read-only console response matches the parser; subsequent disposable snapshot mutation evidence is recorded below. |
| Local release build (v0.2.1) | `artifacts/droiddock-build.log` (`artifacts/droiddock-build.log`); bundle at `artifacts/DroidDock.app` (`artifacts/DroidDock.app`). |
| Packaged local app | Latest ZIP and DMG identities and checks are in `package-verification.json` (`artifacts/package-verification.json`) and `dmg-verification.json` (`artifacts/dmg-verification.json`). Historical hashes below identify their earlier builds. |
| Interactive snapshot recovery | `955fe272 evidence` (`artifacts/disposable-tests/955fe272-5299-47da-a2b0-de1314e206d3/EVIDENCE.md`), with matching result, frame PNGs, resource counters and cleanup record. |
| Controller orchestration | Production controller/coordinator fixtures cover recovery, ownership, cleanup, panel activity, failure evidence and discovered snapshot support; the full-suite log includes these cases. No native UI is invoked. |
| Historical native panel stall | `artifacts/native-panel-sample.txt` (`artifacts/native-panel-sample.txt`), sampled at 16:36:20 local time before the panel moved to native scrolling TextKit. This is failure-diagnosis evidence, not the final panel state. |

Current live session: `146504D5-780A-433C-800C-E24965FA4655`. Metrics and run-status timestamp: `2026-09-08T10:45:26Z`. Reusing a metrics file without checking the matching passed run-status is not evidence that a subsequent run passed. Failure-named artifacts and the `software-gpu` directory are retained troubleshooting history, not the current passing run.

The historical 152-test ZIP was repackaged after the developer-workflow additions were compiled. Its verified SHA-256 was `7471f1e891c68809456343eeecaaf91b4d17d0762f10a745e52206df1b9200eb`. Package integrity does not replace the remaining native acceptance or Developer ID/notarization.

## Tested configuration

| Property | Observed value |
| --- | --- |
| Host | Apple M4, Mac model `Mac16,12`, arm64 |
| macOS | 26.6.2, build `25G83` |
| Android Emulator | 37.1.11.0, build `15917651` |
| ADB/platform-tools | Android Debug Bridge 1.0.41; platform-tools 37.0.1-15733141 |
| AVD | `Pixel_10_Pro` |
| Guest | Android API 37, `arm64-v8a` |
| Emulator graphics | `-gpu host`; runtime reports host Vulkan/GLES and Apple M4 graphics adapter. |
| Headless process | `-no-window`, console port 5554, serial `emulator-5554`; runtime PID 43096 during the probe. |
| Transport | Pinned scrcpy server 3.3.3, H.264, native Swift client, VideoToolbox decode. |
| Decoded frame dimensions | Portrait 864 × 1920 and landscape 1920 × 864. |
| Workload | Continuously animated local verification APK; six uninterrupted sample windows, each at least 10 seconds. |

The app's declared minimum deployment target is macOS 13. This run does not establish compatibility on macOS 13, other Apple Silicon generations, Intel, other emulator versions, or other Android API/system-image combinations.

## Live runtime and bridge checks

| Check | Result | Scope |
| --- | --- | --- |
| Android boot complete | Passed; 11.286 seconds. | One launch through the manager; no equivalent direct-launch baseline, so wrapper overhead is unmeasured. |
| Sustained decoded throughput | Passed; 3,672 frames / 61.641 seconds = 59.570 FPS. | Decoder output; every sample window exceeds the probe's ≥30 FPS gate. |
| Per-window decoded FPS | 59.723, 59.430, 59.823, 59.705, 59.690, 59.036. | Minimum 59.036 FPS; approximately 10–10.65 seconds per window. |
| Receive-to-decode timing | Mean 0.808 ms; p95 1.063 ms. | Host receive timestamp to decoded pixel buffer. Excludes Android input, guest rendering/encoding, earlier transport time, AppKit submission and physical display. |
| Direct touch/text/drag | Passed, asserted by current-session guest events. | Probe sends the shared scrcpy control packets directly. Does not exercise AppKit NSEvent/IME/focus handling. |
| Rotation and coordinate target | Passed portrait → landscape → portrait; landscape hit target verified. | Uses the shared production `GuestRotation` helper (`wm user-rotation`), not a probe-only rotation workaround. AppKit resize/scale/fullscreen mapping remains a distinct check. |
| Rotation restoration | Passed. | Restored original `wm` policy `free`, foreground-user accelerometer setting `1`, and user rotation `1`. |
| Static screen | Passed; 23.657 seconds, zero new frames, no disconnect; animation resumed. | Protects against treating a legitimately idle stream as a failed connection. |
| Bridge replacement | Passed; original PID retained, frames/control recovered, guest text/counter state preserved. | Explicitly stops the old bridge and constructs a new bridge. This does not prove SessionController's automatic disconnect/retry state machine. |
| APK and screenshot | Passed. | Probe installed its local fixture, captured a valid 1280 × 2856 PNG and uninstalled its fixture. Native picker/drop/save-panel acceptance is separate. |
| Cleanup | Passed. | Original ADB forward set restored and exact app-owned emulator observed stopped. No unrelated emulator takeover. |

The native app's diagnostics now expose decoded/received FPS, frames submitted to `AVSampleBufferDisplayLayer`, receive-to-submit timing, superseded frames, SDK versions, console port, exact emulator CPU and resident memory. A submitted frame count is not a physical presentation measurement. These counters make a future native-surface benchmark possible; their existence is not a substitute for a recorded run.

## Automated checks

The historical 152-test package run in `swift-test-152.log` (`artifacts/native-exit-evidence-20260908/swift-test-152.log`) finished at `2026-09-08 23:35:17.723` local time (Asia/Kolkata), with **152 XCTest cases, 0 failures, 0 unexpected failures**. The subsequent “0 tests” message is the separate Swift Testing runner. The earlier 50-case run covered the core workflow before the developer-workflow additions. Recording fixture tests require access to the normal macOS H.264 codec service; sandbox denial is not a valid recording result.

| Suite | Coverage |
| --- | --- |
| GeometryTests | Portrait/landscape aspect fit, resize invariance, logical-point mapping, content edges, one-pixel and invalid/nonfinite geometry. |
| ProtocolTests | Touch/key/scroll/text/clipboard wire fields, bounded UTF-8, packet flags/lengths and H.264 Annex B parsing. |
| RuntimeTests | SDK validation, AVD metadata, ADB parsing, remote-shell quoting, session transition graph, headless/GPU arguments, process cancellation/timeouts/output limits, unowned-process refusal. |
| GuestRotationTests | Nine cases: original policy/settings restoration, repeated rotations/new snapshots, absent values, cancellation before/after mutation, invalid angles, whole-state retry after transient failure, retained snapshot after persistent failure, serialized concurrent operations, and rejected unrecognized policies. Uses a fake selected-device ADB executable, not an emulator. |
| LogcatStreamTests | Continuous delivery before exit, exact client stop including SIGTERM resistance, bounded line/batch/error output, split UTF-8, EOF, single-use lifecycle. |
| ProcessMetricsTests | Native memory/thread counters, CPU units against `getrusage`, multicore percentages, absent/invalid PIDs. |
| DiagnosticsJournalTests | Escaped structured events, reopening, bounded complete JSON-line retention and interrupted-record repair. |
| ClipboardReplyTests | On-demand wire request, Unicode/empty response, cancellation and timeout with delayed-reply isolation. No unsolicited Mac clipboard writes. |
| DiagnosticsBundleTests | Bounded ZIP members, omissions, safe text tails, file/path validation, cancellation and preservation on failed export. |
| EmulatorSnapshotsTests | Selected serial and operation arguments, name validation, full/partial/empty tables, malformed response, KO detection on both streams, timeout and cancellation without mutation retries. |
| ScreenRecordingTests | Exact process/boot identity, startup/finish/cancel joining, MP4 validation, destination replacement races, automatic completion and cleanup failures. |
| SessionResourcePolicyTests | Additional-session advisory, known/unknown guest RAM and RSS, physical memory and overflow handling without inventing memory pressure. |
| KeyboardMappingsTests | Configurable hardware-key choices, persisted values and invalid settings handling. |
| RuntimeLedgerTests | Nine cases covering exact native identity, disposition persistence/removal/exclusion, mismatches, corruption/reset, file type/size/permission limits, concurrent actor updates and atomic write failure. Inspection never grants ownership or signals a process. |
| PresentationDiagnosticsTests | Four cases separate timer gaps, callback work, layer backpressure and sample errors; verify monotonic clocks/reset, bounded Unicode error text and concurrent counting. |
| LogPresentationTests | Two cases verify isolated log/Pause observation and cached display versus fresh diagnostics export; a third controller case verifies rapid panel switches retire selected-device Logcat while preserving Pause. |
| FrameStorePresentationTests | Two production FrameStore cases verify per-bridge decoded/submitted baselines, ignored retired frames/inactive ticks and new-session resets, without changing lifetime counters. |
| InputFrameLatencyTrackerTests | Bounded timestamp pairing, pre-input/stale frame rejection, expiration, reset and percentile calculations for a labelled proxy. |

The `SimulatorKit` suites validate reusable contracts. The additional `AndroidSimulatorTests` target imports the real app executable module and exercises production SessionController/AppModel with temporary fake SDK executables, exact-owned ordinary child processes, and controlled bridge callbacks. It does not invoke NSApplication, windows, panels, pasteboard or a real Android guest.

Its original nine cases cover first-display recovery without replacing the booted runtime; monitoring after exhausted retries and later child exit; joined background detach with no stale status; cancelled SDK discovery; Stop after runtime launch while initial bridge startup is gated, rejecting late frames before a fresh start; deliberate leave-running with bridge/Logcat cleanup and a fresh persisted identity match; ADB degradation/recovery preserving video; retired Logcat cleanup before runtime termination; and suppression of results from an old SDK request. These are direct orchestration tests, not exhaustive native UI or live failure-injection acceptance.

The suite includes nine rotation tests plus argument-only wipe opt-in coverage. No real Wipe Data command has been run on the user's AVD. Native UI changes are evaluated by their observations below; the package suite does not itself validate views or panels.

## Developer-workflow verification

The separate recording run used an owned headless emulator PID 64942 and the production `ScreenRecording` service. Manual stop exported a decoded **720 × 1280 MP4**, **3,739,100 bytes**, **4.9848 seconds**. Automatic completion exported a valid file; cancellation exported no file. The unique guest recording directories returned to their empty baseline, cleanup reported no warnings, and the owned emulator stopped. The original throughput-probe artifacts were not replaced. No display-size or density overrides were applied; the recorder selected its own encoder output dimensions.

Android screenrecord is bounded to 180 seconds and 256 MB in this app, carries no audio, and requires fixed orientation. In the automatic three-second trial, static Android content yielded a 0.8259-second MP4 timeline; the wall-clock limit is not a guarantee of the encoded timeline's length. This service run does not verify the native recording save panel.

Snapshot list/save/load/delete is implemented with explicit mutation confirmation, selected-device console commands, bounded operations and no automatic retry. Save/load pauses input, joins logs/developer actions, restores rotation and disconnects the bridge before the command. Load waits for Android readiness before a fresh bridge connection. The original read-only `default_boot` table matches the parser. Real save/load/delete and restored interactive state now pass on a disposable API 36 guest as recorded below; native confirmation and application-level snapshot coordination remain separate checks.

Reverse clipboard transfer is explicit via **Copy Android Clipboard**. A cancelled or timed-out request cannot cause a late reply to overwrite a later request's Mac clipboard. Unit tests cover that protocol behavior, and the first disposable guest run verified direct clipboard write/read and restoration through the bridge. The earlier 131-test package also passed a controlled native round trip: a fresh token generated inside Android was copied through the native menu, pasted with Command-V into the native Logcat filter, then pasted back into Android with Command-V. Both values matched the fixture's logged token exactly. The earlier inconclusive attempt remains historical evidence.

Diagnostics ZIP export collects only the selected session's supplied diagnostics and recent logs, with per-file/archive limits and a manifest of omissions. Wipe Data is opt-in with a destructive confirmation and unchanged ownership checks. An actual production-manager wipe passed on a fresh disposable guest, and the native user-device warning was cancelled without wiping. Native F1 mapping/persistence/restoration passed; other mappings and the additional-session resource warning still require native acceptance.

Input timing now includes an **input dispatch → next submitted frame proxy**. It pairs only a frame received after an accepted input, bounds pending/sampled data, and discards stale requests. It does not prove that the frame contains the Android response, nor does it measure physical screen scanout. The PRD's input-to-visible target remains unmeasured.

## Disposable snapshot and resource evidence

The successful interactive run is `955fe272-5299-47da-a2b0-de1314e206d3`, using a fresh workspace-only API 36 ARM64 Google Play image and production manager/bridge/snapshot services. Boot took **37.879 s**; frames were **720 × 1280**. The fixture accepted text and a tap before saving, with counter 1. After changing the text and advancing to counter 3, loading the snapshot restored the original text; a fresh bridge accepted another tap and the guest reported counter 2. Both decoded screenshots were inspected and show the responsive fixture without an ANR dialog.

Save/list took **9.655 s**, load **6.309 s**, and delete/list **0.519 s**. The same runtime PID 84511 remained during restore. The final snapshot list was empty, the test APK was uninstalled, ADB forwards returned to baseline, the exact owned emulator stopped, and only its marked runtime directory was removed. The original user AVD index/config and watched SDK image metadata retained both hashes and modification times. See the evidence (`artifacts/disposable-tests/955fe272-5299-47da-a2b0-de1314e206d3/EVIDENCE.md`), result (`artifacts/disposable-tests/955fe272-5299-47da-a2b0-de1314e206d3/result.json`), and cleanup (`artifacts/disposable-tests/955fe272-5299-47da-a2b0-de1314e206d3/final-cleanup.json`).

Forty-two resource samples at roughly two-second intervals observed peak emulator RSS **6,321,668,096 bytes (5.89 GiB)** and CPU **251.94%**, where 100% denotes one core. Minimum observed disk headroom was **24.65 GiB**. Host memory pressure changed from normal level 1 to warning level 2. No second or third guest was started; their isolation and resource acceptance remains pending until adequate resources are available. A **5.091-second / 31.63 decoded FPS** observation is retained as a short measurement under this load; it is not the sustained native presentation gate or a replacement for the earlier 61.64-second core probe.

Earlier run `a7ebb70c-6b29-4f00-bbff-1b49df5cc6cd` verified file/clipboard restoration and fresh bridge control, but its restored Settings screen showed an ANR. The successful settled-fixture repeat does not establish the cause of that earlier Settings failure. A separate harness attempt `816a2c8c-89af-46af-81bb-5ee33011bf05` correctly failed after an unintended Paste mutated its focused text field; the harness was corrected and its exact runtime cleaned up. All three attempts retain separate evidence.

The subsequent disposable wipe run e2ac0dfb (`artifacts/disposable-tests/e2ac0dfb-1334-42aa-8067-99635c2d4076/EVIDENCE.md`) passed an actual wipe through the production manager: its installed fixture and unique marker were absent after boot. All exact-owned runtimes and the isolated directory were removed, forwards returned to baseline, and watched user AVD/SDK metadata stayed unchanged. Its raw direct/manager boot observations were 16.932/18.280 seconds, but used different console ports. **Zero exactly matched pairs qualified**; those times do not establish launch overhead. A new isolated repeat uses fresh worker processes, identical ports/arguments and port cooldown/readiness checks outside timing.

Runtime history now records app-started process identity after launch/boot and refreshes it before marking a deliberately retained guest. Confirmed exits remove records. Library inspection matches native PID/start time/executable, SDK, serial and AVD; it distinguishes likely interrupted previous sessions from deliberate leave-running, without adopting or stopping them. Corrupt metadata has explicit reset UI. Helper and controller fixtures verify the persistent identity/cleanup paths; native crash/relaunch, labels and reset-dialog acceptance remain pending.

## Matched runtime launch comparison

The corrected 3ad4eb4f run (`artifacts/disposable-tests/3ad4eb4f-48de-48ff-b590-8a53e4e12402/EVIDENCE.md`) completed three alternating-order pairs on one fresh API 36 guest, using the same final configuration, exact arguments, console port 5554 and readiness polling. Every observation used a fresh worker process. Both ports passed plain-bind readiness after at least 35 seconds of cooldown outside the measured interval. First-boot INI formatting and the emulator's 6 GiB userdata minimum were inspected before freezing the configuration; all six measured pre/post files were byte-identical.

| Pair/order | Direct emulator | Production manager |
| --- | --- | --- |
| 1, direct first | 17.711662 s | 17.104186 s |
| 2, manager first | 18.411205 s | 16.460632 s |
| 3, direct first | 17.523168 s | 17.508171 s |

Means were **17.882012 s direct / 17.024330 s manager**, an observed relative difference of −4.796% with only three observations per route. This is a matched service-level observation, not evidence that the manager causes faster boot or a general overhead guarantee. It excludes the native app, display bridge and first-frame readiness. The earlier e2 pair with different ports and 9a preparation-only attempt remain separate history.

The run collected 64 worker and 224 driver resource samples: pressure levels 1/2, peak emulator RSS 3.093 GiB, peak CPU 231.45%, and minimum free disk 29.433 GiB. Independent cleanup (`artifacts/disposable-tests/3ad4eb4f-48de-48ff-b590-8a53e4e12402/final-cleanup.json`) confirmed seven emulator and seven worker PIDs gone, no ADB devices/forwards, removal of the marked runtime subtree, and unchanged watched user AVD/SDK hashes and modification times.

## Native application UI acceptance

The root observed these results through CUA on 8 September 2026. The 20:51 native run (`artifacts/native-ui-20260908-2051/EVIDENCE.md`) records observations, export verification (`artifacts/native-ui-20260908-2051/artifact-verification.json`) and exact cleanup (`artifacts/native-ui-20260908-2051/final-cleanup.json`). Its app preceded the final Logcat aggregate-limit fix; the source subsequently passed 137 tests including later rendering instrumentation. The old incomplete artifacts/library.png is not current visual evidence.

| Native check | Observed outcome | Remaining limit |
| --- | --- | --- |
| Library, Settings and boot | SDK/AVD discovery, Settings, Booting with disabled controls, then Running and embedded Android. | Broader onboarding/SDK-failure cases remain. |
| APK picker and shortcut | Attached picker installed signed probe.apk; visible Installed probe.apk. Cmd-I reopened the picker with device focus and Cancel dismissed it. | Native APK drop remains unverified. |
| Input | Unique text suffix appeared; touch changed the counter; Escape dismissed the keyboard; guest log confirmed drag. | Exhaustive keys, focus-loss, IME/layout cases and physical latency remain. |
| F1 mapping | None→Home persisted through reopening Settings; F1 returned Android Home. Restored None. | Other mapping choices remain fixture-tested. |
| Fullscreen and rotation | Native View menu entered/exited fullscreen. Landscape and portrait target taps advanced the same counter; toolbar rotation updated geometry. | All sizes/scales and external-display/HiDPI matrix remain. |
| Screenshot and recording | Native save workflows exported a decoded 1280×2856 PNG and a 56.486-second, 720×1280 MP4 with 515 decodable frames. | Sustained capture performance and every export-error case remain. |
| Diagnostics | Native ZIP export succeeded with five safe fixed members and matching PID/serial/session metadata. | This was a healthy-session export, not a collected failure bundle. |
| Reconnect | Reconnecting disabled controls; Running returned with retained text/counter and the same emulator PID 94471. | Automatic native failure injection remains separate from this explicit action. |
| Clipboard | Earlier attempt was inconclusive. The current-build retest copied a fresh guest-only token to a native host field and pasted it back into Android with exact equality. | Empty/unsupported content and session-race UI cases remain; no automatic synchronization is claimed. |
| Snapshot and wipe cancellation | Current-build Wipe Data warning Cancel preserved the ordinary launch without a wipe flag. Manage Snapshots listed no loadable snapshots; Save showed the requested name and replacement warning, and Cancel left the list empty. | Native confirmed snapshot mutation/load/delete and failed-action UI remain distinct from passing disposable service tests. |
| Stop/Quit | Confirmation→Stopping→Idle; Quit exited the app. Exact PIDs 93185/94471 disappeared, ADB devices/forwards were empty, and the fixture was uninstalled. | Leave-running/crash/relaunch and simultaneous guests remain separate acceptance. |

The first typing attempt overlapped with other input. After the user explicitly handed testing back, the controlled native text/touch/drag checks passed. The earlier lock and interrupted picker run remain history: PIDs 53124/53168/53227/53327 were cleaned up then, with no fixture installed. They do not contradict the later successful picker installation.

Readable Logcat and Pause were previously observed. The final Logcat implementation retains at most 1 MiB/500 lines, caches filtered text, and avoids replacing unchanged native text; seven boundary tests cover byte/newline/Unicode limits, pause, filtering and revisions. The current-build retest exercised native Pause, filter editing and clearing, Resume, and diagnostics text export. Filter was cleared and Pause disabled before closing the panel.

The 131-test clipboard retest (`artifacts/native-ui-clipboard-20260908/EVIDENCE.md`) used app PID 19840 and emulator PID 20134 with the 131-test package. Its fixture events (`artifacts/native-ui-clipboard-20260908/fixture-events.txt`) establish the exact clipboard token and Android paste result. Native Stop reached Device stopped/Idle; Command-Q exited. Cleanup (`artifacts/native-ui-clipboard-20260908/final-cleanup.json`) confirmed both exact PIDs gone, no ADB devices/forwards and successful fixture removal. A current rendering observation showed 43 decoded/28 submitted FPS; the saved diagnostics (`artifacts/native-ui-clipboard-20260908/Pixel_10_Pro-diagnostics.txt`) later showed 18/12. Host pressure was level 2 with 18,370 MB swap used. These are short observations, not a sustained 30 FPS pass or proof that the Logcat change improved performance. The short process profile overlapped opening a native save panel and is not a controlled idle-workload profile.

During the later native run, Diagnostics sampled 5–8 submitted FPS during recording and 1–3 FPS later with the developer panel open. Host memory pressure was warning level 2 with substantial compression/swap. These samples do not satisfy the sustained native 30 FPS gate or establish its cause. The input proxy is not physical latency and excludes expired waits; its displayed medians must not be used as PRD latency acceptance.

The later 137-test build adds fixed-size presentation counters: callback tick gaps and work, layer-not-ready/no-frame outcomes, flushes and format/sample/layer failures. A single snapshot published on the existing one-second monitor includes a bridge UUID, monotonic timestamp and per-bridge decoded/submitted totals. Diagnostics hide this block when the display detaches. Six new helper/FrameStore tests passed; rendering and input behavior are unchanged. These counters support the next controlled native run and do not themselves establish an FPS improvement.

An earlier temporary AppKit harness invoked production view methods without a live guest and has no retained execution output. It remains development context, not native end-to-end proof.

## Instrumented native rendering investigation

The 137-test native run (`artifacts/native-presentation-20260908/EVIDENCE.md`) measured the real embedded surface with the continuously animated fixture on the same Pixel 10 Pro guest. The native-exported start snapshot and subsequent accessibility-observed end snapshot carry the same bridge UUID and owned PID. Over **111.851245 seconds**, the counters increased by **3,417 decoded / 3,318 submitted frames**: **30.5495 decoded FPS / 29.6644 submitted FPS**. This includes an explicit 70.0257-second interval without CUA actions, another VM, compilation or process sampling, plus the surrounding panel close/open activity. It does **not** pass a sustained native 30 FPS requirement or measure physical presentation.

With Diagnostics left open later, rolling values were 50 decoded / 8 submitted FPS. Across those later snapshots the timer ran much less frequently, with thousands of delayed callbacks, while only eight additional layer-not-ready skips and no layer/format/sample errors were recorded. This separates main-thread callback delay from display-layer backpressure. A five-second profile collected without overlapping CUA actions showed substantial SwiftUI layout work, including the segmented panel selector. These findings motivated the panel update/layout fix verified in the later 140-test run below.

The initial APK picker attempt was cancelled after inconsistent selection/disabled-Install observations; a fresh picker with keyboard selection installed the fixture successfully. Its cause is unproven. The fixture was subsequently removed; native Stop reached Idle and Command-Q quit. Exact PIDs 35551/35627 were absent, and ADB devices/forwards were empty in the cleanup record. Initial host memory pressure was level 2 with substantial swap use; this single-host run does not establish hardware capacity or broad compatibility.

## Automatic exit evidence and discovered snapshot support

The152-test source preserves immutable runtime/session identity, exit status/reason and pre-cleanup diagnostics after an unexpected owned-emulator exit, including startup and snapshot paths. The common handler joins bridge/log/developer cleanup, then preserves a local ZIP independently of task cancellation. Stop/Quit join preservation; late work cannot overwrite a new runtime. Runtime logging now exposes a bounded EOF join: if it does not finish within2seconds, the visible error and archive disclose that output may be incomplete.

Automatic bundles use eight reusable slots under `~/Library/Logs/AndroidSimulator/Failures`, with a4MiB maximum per archive and owner-only ZIP permissions. The inline combined stdout/stderr tail is at most4KiB and20lines. A failed archive write leaves the original identity/output and an actionable warning. Normal Stop does not create a failure archive. Eleven new cases cover retention, unavailable destinations, EOF/timeout/cancellation, monitored/startup/snapshot exits, Stop joining preservation and visible stopping→idle→new-running diagnostics.

An additional fixture-backed controller case verifies discovered snapshot support: only a typed unsupported console response disables snapshots for that runtime. Transient failures remain retryable, the reason remains visible after error dismissal and display reconnect, another session is unaffected, and a new runtime clears the restriction. No arbitrary emulator-version cutoff is used. The final native smoke below verifies unexpected runtime-exit preservation and the corrected Idle display.

## Native panel fix verification

The 140-test panel retest (`artifacts/native-presentation-panel-fix-20260908/EVIDENCE.md`) kept Diagnostics open throughout an **86.583988-second** interval. Matching owned PID48094 and stream UUID04DBF23F-FC61-48D1-B309-844F333A6E38 snapshots increased by **5,157 decoded /4,850 submitted frames**: **59.5607 decoded FPS /56.0150 submitted FPS**. The callback timer averaged59.1102Hz; no additional layer-not-ready skips, flushes, layer failures or format/sample errors occurred. There were26 additional gaps over50ms. At least70.0223seconds elapsed without CUA actions, compilation, profiling or a second VM. Observation overhead is included in the reported interval.

This passes the sustained average30FPS submission threshold on this configuration. It does not establish every subwindow, physical scanout, causal input latency or broad compatibility. Earlier137-test failures remain above as diagnosis evidence; their differing activity/host load precludes a controlled numerical speedup claim. Host memory pressure remained level2. The native change isolates log observation, retires the log reader outside Logs, caches displayed diagnostics at the one-second monitor, and uses a native fixed-size segmented selector.

Native accessibility actions verified both tabs, Pause, matching/nonmatching filtering and Copy: Command-V pasted the exact filtered line back into the native field. The field was cleared and Pause disabled before timing; no matching app Logcat reader remained during the post-measurement inspection. Coordinate click/drag automation returned `noWindowsAvailable` despite readable screenshots and working accessible controls. Reset did not resolve it; a loginwindow diagnostic timed out without establishing lock state. The unchanged animation fixture was therefore launched using selected-serial ADB solely as workload setup; this run adds no native guest-input acceptance.

Fixture removal succeeded; native Stop reached Device stopped/Idle, Quit exited, exact app48042/emulator48094 were absent and ADB devices/forwards empty at17:52:16.932664UTC. One cleanup observation exposed a stale displayed `State: stopping` after the actual state reachedIdle. The subsequent152-test source corrects the cache transition and adds automatic unexpected-exit evidence; these changes are outside the measured140-test package scope.

## Final local development smoke

The 152-test native smoke (`artifacts/native-exit-evidence-20260908/EVIDENCE.md`) used the packaged arm64 appPID60435 and its verified child emulatorPID60488. One controlled SIGTERM targeted that exact process after checking its parent and command. The emulator finished its own shutdown and returned normal exit status0; this was an unexpected process exit from the app's perspective, not a spontaneous crash measurement.

The native device entered Failed, showed recent combined stdout/stderr and the automatic bundle path, and retained original runtime924B9E49-DBB2-4B28-BDD4-1A8B55DEF659/session8489BB7B-CCAD-4E01-B454-F8DED4BDB6DE/PID60488/serialemulator-5554. The preserved ZIP was17,634bytes, mode0600, with five safe members, valid CRCs, matching identity/status and no evidence warning. Its workspace copy and manifest checks are retained in the evidence directory.

Native Start recovered a new runtimePID61422; Running and clear error/history were observed at18:09:46UTC. Native Stop confirmation then reached Device stopped/Idle. At18:10:21, both the footer and displayed Diagnostics saidIdle with no error, verifying the cache correction. Command-Q exited. Final cleanup at18:11:26.374543UTC confirmed all three exact PIDs absent and empty ADB device/forward lists. This run installed no APK. Normal Stop left the single automatic failure archive unchanged; the archive is intentionally retained as the feature's local evidence.

## Release targets still requiring evidence

- Native submission on other supported configurations, physical presentation, and accurate AppKit input at varied window sizes, saved scales and external/HiDPI displays. The 140-test run passed the sustained average submission gate on the documented M4/API37 configuration.
- Median physical input-to-visible latency against the PRD MVP <120 ms target; production <80 ms remains unmeasured.
- Additional live/native bridge-loss/ADB-degradation injection and external ownership/port conflicts. The final152-test native run passed one controlled owned-runtime exit and restart with preserved evidence; automated fixtures cover additional recovery and cleanup races.
- Independent simultaneous device windows and action/close/shutdown isolation; representative CPU/memory measurements for 1–3 AVDs.
- Whole-app launch/first-frame overhead, quick-boot comparisons and broader repetitions. Three matched cold-boot runtime-manager pairs now have evidence; they exclude the native app and display bridge.
- Repeated-session data for the PRD 98% MVP / 99.5% production crash-free targets.
- A broader declared host/macOS/emulator/API compatibility matrix.
- Developer ID signing, hardened-runtime/notarization validation and clean-Mac installation before production distribution.

Earlier low-throughput Settings-screen and automatic/software-GPU trials identified unsuitable workload/configuration and rotation behavior. They led to a continuously animated workload, explicit host-GPU default, persistent selected-user WindowManager rotation, and idle-stream handling. Their old results are not the current throughput outcome and are not erased from troubleshooting artifacts.

The original [disposable runtime plan](DISPOSABLE_TEST_PLAN.md) records the isolation strategy. Subsequent one-guest creation and snapshot mutation succeeded as recorded above; two- and three-session checks remain pending because of observed host memory pressure.

## Reproducing the checks

From the repository root:

```sh
swift test --disable-sandbox
./scripts/build.sh
./scripts/build-test-apk.sh
.build/debug/SimulatorProbe --run
```

The probe boots the first discovered compatible AVD, installs its verification APK, changes orientation temporarily, then restores settings, uninstalls its fixture and stops only its own emulator. Stop that AVD through its owning app before running the probe. It refuses an already-running AVD or pre-existing verification package instead of taking them over. For detailed fixture dependencies and overrides see [`Tests/Fixtures/AndroidProbe/README.md`](../Tests/Fixtures/AndroidProbe/README.md).

## Historical 0.1.0 package and final cleanup

The requested DMG was verified on 9 September 2026 local time from the same validated app, without rebuilding or re-signing it. `Android-Simulator-macOS.dmg` (`artifacts/Android-Simulator-macOS.dmg`) is 2,500,407 bytes, SHA-256 `2cb10f81eedf197133ba3c877162cc5251ac697ddf970554f162d8828b14477a`. It is a compressed read-only UDZO/HFS+ image containing Android Simulator.app, an Applications shortcut targeting `/Applications`, and Read Me.txt. Image checksums passed; a read-only mount confirmed all seven app files and their modes matched the source, and the mounted app passed strict codesign and plist checks. The verification mount was detached and temporary staging removed. See `dmg-verification.json` (`artifacts/dmg-verification.json`) and `dmg-build.log` (`artifacts/dmg-build.log`). The image contains the existing arm64/ad-hoc/non-notarized development app; DMG packaging does not confer Developer ID signing or notarization. Application source was unchanged, so packaging did not rerun the 152 application tests.

The local bundle compiled after the panel, automatic-exit evidence, Idle-cache and unsupported-snapshot changes and the matching152-test run. `codesign --verify --deep --strict`, `plutil -lint`, and ZIP integrity verification passed. The ad-hoc signed package is `artifacts/Android-Simulator-macOS.zip` (`artifacts/Android-Simulator-macOS.zip`). SHA-256: `7471f1e891c68809456343eeecaaf91b4d17d0762f10a745e52206df1b9200eb`. It has not been Developer ID signed or notarized.

The locked-screen smoke run was explicitly cleaned up: app PID 53124, its emulator PID 53168, bridge ADB PID 53227 and Logcat PID 53327 were terminated; a subsequent process check found none remaining and the ADB forward list was empty. The fixture package was not installed during that incomplete UI run. This forced cleanup is distinct from the earlier successful native Quit lifecycle test. That lock was later resolved; the newer native pass and its cleanup are recorded above.
