# Agent debugging exercise

This disposable app has an intentional bug: tapping "Add one" increases the counter by two. Keep it broken in the repository. Run the exercise in a temporary checkout so the agent can change and rebuild it.

Build with the same JDK and Android build-tools prerequisites as AndroidProbe:

```sh
scripts/build-test-apk.sh --agent-debug
```

The APK is written to `artifacts/agent-debug/debug.apk`. On Linux, set `ANDROID_STUDIO_JDK` to your JDK directory. The build script requires Bash; a Windows build host can build this simple Activity with its normal Android build tooling instead.

Give Codex or Claude Code this task:

> Use DroidDock's MCP tools to boot a disposable phone and request control. Install the Agent Debug Sample APK and launch dev.droiddock.agentdebug. Inspect the screen, tap Add one once, and capture the wrong count and Logcat evidence. Fix the counter in DebugActivity.java, rebuild, reinstall, clear only this sample app's data and repeat the test. Confirm the screen says Count: 1 after one tap, then release control. Do not change any other app or delete the phone.

Approve the running phone in Agent Setup and select this checkout as an allowed host folder. A passing exercise includes before/after screenshots, the initial `count=2` log, the final `count=1` log, and the one-line code change. Passing this sample does not replace the AndroidProbe checks for text, swipes, rotation or files.
