import SwiftUI
import AppKit
import SimulatorKit
import UniformTypeIdentifiers

struct DeviceWindowView: View {
    @ObservedObject var session: SessionController
    @AppStorage private var displayScale: Double
    private let developerPanelVisibilityChanged: (Bool) -> Void
    init(session: SessionController, developerPanelVisibilityChanged: @escaping (Bool) -> Void = { _ in }) {
        self.session = session
        self.developerPanelVisibilityChanged = developerPanelVisibilityChanged
        _displayScale = AppStorage(wrappedValue: 1.0, "displayScale.\(session.avd.id)")
    }
    @State private var showTools = false
    @State private var tab = "Logs"
    @State private var filter = ""
    @State private var dropTarget = false
    @State private var confirmStop = false
    @State private var confirmRestart = false
    @State private var showSnapshots = false
    @State private var showActionStatus = false

    var body: some View {
        VStack(spacing: 8) {
            toolbar
            GeometryReader { geometry in
                let layout = SimulatorChromeLayout(available: geometry.size, frame: session.frames.dimensions(), resolution: session.avd.resolution, scale: displayScale)
                phone(layout: layout)
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            if let error = session.error {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                    Text(error).font(.system(size: 11)).textSelection(.enabled)
                    Spacer(minLength: 4)
                    Button { session.error = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).help("Dismiss error").accessibilityLabel("Dismiss error")
                }.padding(12).background(Color(white: 0.13), in: RoundedRectangle(cornerRadius: 12))
            }
            if let warning = session.historyWarning {
                Text("Runtime history: \(warning)").font(.system(size: 11)).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12).textSelection(.enabled)
                    .background(Color(white: 0.13), in: RoundedRectangle(cornerRadius: 12))
            }
            if showTools {
                developerPanel.frame(height: 235)
                    .clipShape(RoundedRectangle(cornerRadius: 13))
                    .overlay(RoundedRectangle(cornerRadius: 13).stroke(.white.opacity(0.16), lineWidth: 0.5))
            }
        }
        .padding(8).background(Color.clear).ignoresSafeArea().preferredColorScheme(.dark)
        .alert("Stop this device?", isPresented: $confirmStop) { Button("Cancel", role: .cancel) { }; Button("Stop Device", role: .destructive) { Task { await session.stop() } } } message: { Text("This stops the emulator owned by this session. You can start it again from the library.") }
        .alert("Restart this device?", isPresented: $confirmRestart) { Button("Cancel", role: .cancel) { }; Button("Restart") { Task { await session.restart() } } } message: { Text("This restarts the emulator owned by this session using Quick Boot when available.") }
        .onChange(of: showTools) { visible in updatePanelActivity(); developerPanelVisibilityChanged(visible) }
        .onAppear { developerPanelVisibilityChanged(showTools) }
        .onChange(of: tab) { _ in updatePanelActivity() }
        .onChange(of: session.state) { state in if state == .running { updatePanelActivity() } }
        .onDisappear { session.setDeveloperPanel(nil) }
        .sheet(isPresented: $showSnapshots) { SnapshotManagerView(session: session) }
        .task(id: session.actionStatus) {
            showActionStatus = session.actionStatus != nil
            do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
            showActionStatus = false
        }
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            SimulatorWindowButtons().frame(width: 64, height: 26)
            SimulatorWindowTitle(title: session.avd.displayName, subtitle: subtitle)
                .frame(minWidth: 40, maxWidth: .infinity).frame(height: 34)
            control("Home", "house", key: 3).keyboardShortcut("h", modifiers: [.command, .shift])
            Button { session.capture() } label: { Image(systemName: "camera").frame(width: 28, height: 30) }
                .help("Save Screenshot (⇧⌘S)").accessibilityLabel("Save Screenshot")
                .keyboardShortcut("s", modifiers: [.command, .shift]).disabled(!session.canUseADB)
            Button { session.rotate() } label: { Image(systemName: "rotate.right").frame(width: 28, height: 30) }
                .help(session.recordingActive ? "Stop recording before rotating" : "Rotate device")
                .accessibilityLabel("Rotate device")
                .disabled(!session.canControl || !session.adbAvailable || session.rotating || session.recordingActive)
            Menu {
                Button("Back") { session.key(4) }.keyboardShortcut("[", modifiers: .command).disabled(!session.canControl)
                Button("Recent Apps") { session.key(187) }.disabled(!session.canControl)
                Menu("Hardware") {
                    Button("Power") { session.key(26) }
                    Button("Volume Up") { session.key(24) }
                    Button("Volume Down") { session.key(25) }
                }.disabled(!session.canControl)
                Divider()
                Button("Install APK…") { session.chooseAPK() }.keyboardShortcut("i", modifiers: .command).disabled(!session.canUseADB)
                Button("Copy Android Clipboard") { session.copyAndroidClipboard() }.disabled(!session.canControl)
                Button("Manage Snapshots…") { showSnapshots = true }.disabled(!session.canManageSnapshots)
                if session.recordingActive {
                    Button("Stop Recording") { Task { await session.finishRecording() } }
                } else {
                    Button("Record Screen…") { session.chooseRecording() }.disabled(!session.canUseADB || session.rotating)
                }
                Button("Reconnect Display") { session.retryDisplay() }.disabled(session.runtime == nil || session.snapshotBusy)
                Divider()
                Toggle("Developer Panel", isOn: $showTools).keyboardShortcut("d", modifiers: [.command, .shift])
                Menu("Display Scale") {
                    Button("Fit Window") { displayScale = 1.0 }
                    Button("75% of Window") { displayScale = 0.75 }
                    Button("50% of Window") { displayScale = 0.5 }
                }
                Divider()
                Button("Restart Device…") { confirmRestart = true }.disabled(session.runtime == nil || session.snapshotBusy)
                Button("Stop Device…", role: .destructive) { confirmStop = true }.disabled(session.runtime == nil || session.snapshotBusy)
            } label: { Image(systemName: "ellipsis").frame(width: 24, height: 30) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 26)
                .help("More controls").accessibilityLabel("More controls")
        }
        .font(.system(size: 16, weight: .regular)).buttonStyle(SimulatorToolbarButtonStyle())
        .padding(.horizontal, 16).padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: 26)
                .fill(Color(white: 0.115))
                .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 2)
        }
        .overlay(RoundedRectangle(cornerRadius: 26).stroke(.white.opacity(0.23), lineWidth: 0.75))
        .overlay(RoundedRectangle(cornerRadius: 24).inset(by: 2).stroke(.black.opacity(0.65), lineWidth: 0.5))
    }

    private var subtitle: String {
        if session.recordingActive { return "● Recording" }
        if session.state == .running && !session.adbAvailable { return "ADB unavailable" }
        if session.state != .running { return session.status }
        return session.avd.apiLevel == "Unknown" ? "Android" : "Android · API \(session.avd.apiLevel)"
    }

    private func phone(layout: SimulatorChromeLayout) -> some View {
        ZStack {
            SimulatorHardwareButton(title: "Volume Up", height: 35, enabled: session.canControl) { session.key(24) }
                .offset(x: -layout.bodySize.width / 2 - 1, y: -layout.bodySize.height * 0.21)
            SimulatorHardwareButton(title: "Volume Down", height: 35, enabled: session.canControl) { session.key(25) }
                .offset(x: -layout.bodySize.width / 2 - 1, y: -layout.bodySize.height * 0.21 + 50)
            SimulatorHardwareButton(title: "Power", height: 53, enabled: session.canControl) { session.key(26) }
                .offset(x: layout.bodySize.width / 2 + 1, y: -layout.bodySize.height * 0.16)
            RoundedRectangle(cornerRadius: layout.cornerRadius, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.47), Color(white: 0.11), Color(white: 0.32), Color(white: 0.1)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .shadow(color: .black.opacity(0.32), radius: 5, x: 0, y: 3)
                .overlay(RoundedRectangle(cornerRadius: layout.cornerRadius, style: .continuous).stroke(.black, lineWidth: 1))
                .overlay(RoundedRectangle(cornerRadius: max(0, layout.cornerRadius - 2), style: .continuous).inset(by: 2).stroke(.white.opacity(0.45), lineWidth: 0.5))
                .overlay(RoundedRectangle(cornerRadius: max(0, layout.cornerRadius - 4), style: .continuous).inset(by: 4).fill(.black))
                .frame(width: layout.bodySize.width, height: layout.bodySize.height)
            ZStack {
                DeviceSurface(session: session, cornerRadius: layout.screenCornerRadius)
                if session.state != .running { stateOverlay }
                if dropTarget {
                    RoundedRectangle(cornerRadius: layout.screenCornerRadius).stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8])).padding(5)
                    VStack(spacing: 12) { Image(systemName: "shippingbox.fill").font(.largeTitle); Text("Drop APK to install").font(.headline) }
                        .padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
                if showActionStatus, let status = session.actionStatus {
                    VStack { Spacer(); Text(status).font(.system(size: 11)).lineLimit(2).multilineTextAlignment(.center)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(.black.opacity(0.86), in: Capsule()).padding(.horizontal, 16).padding(.bottom, 20)
                    }.allowsHitTesting(false)
                }
            }
            .frame(width: layout.screenSize.width, height: layout.screenSize.height)
            .onDrop(of: [.fileURL], isTargeted: $dropTarget) { providers in
                guard session.canUseADB else { return false }
                for provider in providers {
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in guard let url else { return }; Task { @MainActor in session.install(url) } }
                }
                return !providers.isEmpty
            }
        }.frame(width: layout.bodySize.width, height: layout.bodySize.height)
    }

    private var stateOverlay: some View {
        VStack(spacing: 18) {
            if session.state == .failed { Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange) }
            else if session.state == .idle { Image(systemName: "iphone.slash").font(.largeTitle).foregroundStyle(.gray) }
            else { ProgressView().controlSize(.large).tint(.white) }
            Text(session.status).font(.system(size: 13, weight: .medium)).foregroundStyle(.white).multilineTextAlignment(.center)
            if session.state == .failed || session.state == .idle {
                Button(session.runtime == nil ? "Start Device" : "Retry Display") { session.retryDisplay() }.buttonStyle(.borderedProminent)
            }
        }.padding(24).background(.black.opacity(0.86), in: RoundedRectangle(cornerRadius: 15)).padding(14)
    }

    private func control(_ title: String, _ symbol: String, key: UInt32) -> some View {
        Button { session.key(key) } label: { Image(systemName: symbol).frame(width: 28, height: 30) }
            .help(title).accessibilityLabel(title).disabled(!session.canControl)
    }
    var developerPanel: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                DeveloperPanelPicker(selection: $tab).frame(width: 180, height: 24)
                Spacer()
                Button { session.chooseAPK() } label: { Image(systemName: "shippingbox") }.help("Install APK").disabled(!session.canUseADB)
                Button { session.capture() } label: { Image(systemName: "camera") }.help("Save screenshot").disabled(!session.canUseADB)
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(tab == "Logs" ? filteredLogs : session.diagnostics, forType: .string) } label: { Image(systemName: "doc.on.doc") }.help("Copy panel contents")
            }.padding(10)
            if tab == "Logs" {
                LogPanelView(logs: session.logPresentation, filter: $filter)
            } else {
                ScrollView { VStack(alignment: .leading, spacing: 12) { Text(session.displayedDiagnostics).font(.system(size: 10, design: .monospaced)).textSelection(.enabled); HStack { Button("Export Bundle…") { session.exportDiagnosticsBundle() }; Button("Export Text…") { exportDiagnostics() }; Button("Open Runtime Log") { if let url = session.lastRuntimeLogURL { NSWorkspace.shared.open(url) } }.disabled(session.lastRuntimeLogURL == nil) }; Text("FPS counts frames submitted to the native display layer; idle screens send fewer frames. Receive-to-submit excludes Android encoding and physical screen scanout. CPU may exceed 100% when using multiple cores.").font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading).padding(12) }
            }
        }.background(.background)
    }
    private func updatePanelActivity() {
        session.setDeveloperPanel(showTools ? (tab == "Logs" ? .logs : .diagnostics) : nil)
    }
    var filteredLogs: String { session.filteredLogText(matching: filter) }
    func exportDiagnostics() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "\(session.avd.name)-diagnostics.txt"; panel.allowedContentTypes = [.plainText]
        panel.begin { result in guard result == .OK, let url = panel.url else { return }; do { try session.diagnostics.write(to: url, atomically: true, encoding: .utf8) } catch { session.error = error.localizedDescription } }
    }
}

/// Plain native segment labels avoid the repeatedly measured SwiftUI label
/// hosting subtree identified in the panel-open main-thread profile.
private struct DeveloperPanelPicker: NSViewRepresentable {
    @Binding var selection: String
    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }
    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels: ["Logs", "Diagnostics"], trackingMode: .selectOne,
                                         target: context.coordinator, action: #selector(Coordinator.selectPanel(_:)))
        control.controlSize = .small
        control.segmentStyle = .rounded
        control.setWidth(88, forSegment: 0); control.setWidth(88, forSegment: 1)
        control.setAccessibilityLabel("Developer panel")
        control.selectedSegment = selection == "Diagnostics" ? 1 : 0
        return control
    }
    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        let selected = selection == "Diagnostics" ? 1 : 0
        if control.selectedSegment != selected { control.selectedSegment = selected }
    }
    @MainActor
    final class Coordinator: NSObject {
        var selection: Binding<String>
        init(selection: Binding<String>) { self.selection = selection }
        @objc func selectPanel(_ sender: NSSegmentedControl) {
            guard sender.selectedSegment == 0 || sender.selectedSegment == 1 else { return }
            selection.wrappedValue = sender.selectedSegment == 1 ? "Diagnostics" : "Logs"
        }
    }
}

private struct LogPanelView: View {
    @ObservedObject var logs: LogPresentation
    @Binding var filter: String
    var body: some View {
        let text = logs.filteredText(matching: filter)
        VStack(spacing: 0) {
            HStack {
                TextField("Filter log output", text: $filter).textFieldStyle(.roundedBorder)
                Toggle(isOn: $logs.paused) { Image(systemName: logs.paused ? "play.fill" : "pause.fill") }
                    .toggleStyle(.button).help(logs.paused ? "Resume log updates" : "Pause log updates")
            }.padding(.horizontal, 10).padding(.bottom, 8)
            NativeLogView(text: text.isEmpty ? "Log output appears while Android is connected." : text)
        }
    }
}

/// A log is a document viewport, not an intrinsically sized SwiftUI Text.
/// TextKit lays out only the visible portion, so long Android diagnostics cannot
/// force the parent device window to repeatedly measure thousands of lines.
private struct NativeLogView: NSViewRepresentable {
    let text: String
    final class Coordinator { var renderedText: String? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let view = NSTextView(frame: scroll.contentView.bounds)
        view.isEditable = false; view.isSelectable = true; view.isRichText = false
        view.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        view.textColor = .textColor; view.backgroundColor = .textBackgroundColor
        view.textContainerInset = NSSize(width: 10, height: 10)
        view.isHorizontallyResizable = false; view.isVerticallyResizable = true
        view.autoresizingMask = [.width]
        view.minSize = .zero; view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard context.coordinator.renderedText != text, let view = scroll.documentView as? NSTextView else { return }
        let followsTail = context.coordinator.renderedText?.isEmpty != false || scroll.contentView.bounds.maxY >= view.bounds.maxY - 24
        let previousOrigin = scroll.contentView.bounds.origin
        view.string = text
        context.coordinator.renderedText = text
        if followsTail { view.scrollToEndOfDocument(nil) }
        else { scroll.contentView.scroll(to: previousOrigin); scroll.reflectScrolledClipView(scroll.contentView) }
    }
}
