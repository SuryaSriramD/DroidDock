# Agent control

DroidDock exposes a local MCP server for Codex and Claude Code. It controls the phones already managed by the app and uses its selected Android SDK. There are no model API keys to configure.

## Connect a client

Open Settings and choose Agent Setup. Select Codex or Claude Code and copy the registration command. Commands use the installed application's absolute path, so terminal PATH setup is optional. On Windows, paste the command into PowerShell. Move the app before registering it; moving it afterwards requires registering the new path.

Agent Setup also shows a configuration snippet. Use the `command` and `args` in your client's stdio MCP configuration if its CLI is unavailable. In Codex, put them under `[mcp_servers.droiddock]` in `config.toml`; in Claude Code, put them under `mcpServers.droiddock` in its JSON configuration. The app does not edit either file. The snippets set a 240-second tool timeout for cold boots and large installs (`tool_timeout_sec` for [Codex](https://learn.chatgpt.com/docs/extend/mcp?surface=cli), `timeout` in milliseconds for [Claude Code](https://code.claude.com/docs/en/mcp)). Apply the snippet if you register through the CLI, which may leave the client default timeout in place.

Run Test Server to check MCP initialization, tool discovery and device listing through the packaged executable. This is a local self-test. Client Connected appears only after an actual client initializes its connection. Check `codex mcp list` or `claude mcp list`, then `/mcp` inside the client. Restart the client's MCP connection if you change the installed app.

Ask the agent to list devices, boot one by ID, and call `request_control`. Review the request in DroidDock, grant full guest control and optionally select folders for APK reads and file transfers. The client name is unverified. The agent retries `request_control` to get its handle.

Remove the registration with `codex mcp remove droiddock` or `claude mcp remove --scope user droiddock`.

## Tools and access

Device listing, status and boot do not require a grant. Every other device operation requires the explicit phone ID and its current control handle.

| Tool | Behaviour |
| --- | --- |
| `list_devices`, `device_status`, `boot_device` | Discover phones, check state, boot and show a window. |
| `request_control`, `release_control` | Request an in-app grant or release it. |
| `inspect_device` | PNG screenshot, native pixel dimensions, capture time and UI nodes. Hierarchy failure still permits a screenshot. |
| `tap`, `swipe` | Android screen pixels. A tap may instead select a node from the latest inspection. |
| `type_text`, `press_key` | Unicode paste and Android navigation/editing keys. Paste replaces the guest clipboard. |
| `wait_for_element` | Exact resource ID, text or accessibility-description match. Default 10 seconds, maximum 60; ambiguous matches fail. |
| `app_action` | Install, launch, force-stop, uninstall, clear app data or open an app link. |
| `read_logs` | Bounded Logcat snapshot with priority and optional running-package PID filter. |
| `android_shell` | Guest shell argument array, including explicit `sh -c`; returns status and bounded output. |
| `transfer_file` | One file, up to 256 MiB, between the guest and approved host folders. Pull refuses existing destinations. |
| `stop_device` | Stop the owned runtime and revoke access. |

Only one agent controls a phone at a time. Different phones can have different controllers. Grants end on Stop, replacement of the runtime, explicit revocation, app exit or client disconnect. A killed or unreachable client expires within 45 seconds; heartbeats run every 15 seconds.

Revoke Control is available in the phone window and Agent Setup. Revocation cancels tracked operations and blocks further calls. It cannot undo completed Android changes or reliably stop guest processes deliberately detached through shell. Full guest shell can erase guest data and use the guest's network. It does not grant host shell execution through DroidDock.

Use the returned native screen dimensions for coordinates. Host window sizes include borders and scaling and are unsuitable for taps. Inspect again after rotation or a stale-reference error. If rotation cannot be verified, use fresh screenshots and coordinate input. UI hierarchies may omit canvas, games and custom-rendered content. A screenshot and hierarchy are captured sequentially and are not an atomic view of a changing screen.

DroidDock does not read the host clipboard for agent input. Host paths must resolve within the folders selected during approval. Screenshot and hierarchy artifacts are private, single-use files; abandoned JSON artifacts are cleaned when another connection opens after ten minutes. Operation diagnostics retain at most 100 tool names, phone IDs and timing records in memory, with no input or output payloads.

If a mutation times out, check the device before retrying. Completion may be uncertain. The server never retries a mutation automatically. Phone deletion, SDK configuration and downloads remain app actions.

## Build and verify

The shared server is in `agent/`. Install its pinned dependencies with `npm ci`, run `npm test`, then `npm run build` in that directory. Desktop packaging builds and includes the bundles. Mac packaging downloads Node 22.23.4 from nodejs.org, checks its committed SHA-256, includes its licence and signs the bundled executable. Nothing is downloaded at first use.

Mac source builds therefore need Node/npm as build tools, Python 3.9 or later, and network access on the first runtime download. End users do not need Node installed. Dependency licences are included in `THIRD-PARTY-NOTICES.json`.

Run the existing Swift suite, desktop suite and Electron smoke tests as well as `agent` tests. The shared suite includes a real SDK stdio client/server exchange. Packaging checks must verify all agent bundles and licence files.

Release acceptance still requires real Codex and Claude Code sessions on macOS, Windows and Linux. Run AndroidProbe's input checks and the [deliberately broken counter exercise](../Tests/Fixtures/AgentDebugApp/README.md). Record screenshots, logs and file-transfer results for every platform/client pair. Fixture tests and server self-tests do not establish those release gates.

This integration targets clients running on the same machine as DroidDock. Cloud execution, WSL-to-Windows connections and remote control are outside the current scope.
