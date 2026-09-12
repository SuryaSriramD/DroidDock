import AppKit
import SwiftUI
import Combine
import SimulatorKit

/// Window sizing is independent of guest input coordinates. Insets describe the
/// existing 48-point toolbar, outer padding, phone margins and bezel.
struct SimulatorWindowLayout {
    enum Orientation: Hashable {
        case portrait, landscape
        init?(display: CGSize) {
            guard display.width.isFinite, display.height.isFinite, display.width > 0, display.height > 0 else { return nil }
            self = display.width > display.height ? .landscape : .portrait
        }
    }
    static let panelHeight: CGFloat = 243 // Developer panel (235) plus stack spacing (8).
    static func minimumSize(for orientation: Orientation) -> CGSize {
        orientation == .portrait ? CGSize(width: 360, height: 480) : CGSize(width: 360, height: 260)
    }

    static func rotatedFrame(current: CGRect, previousDisplay: CGSize, visible: CGRect,
                             developerPanelVisible: Bool, restoredSize: CGSize? = nil) -> CGRect? {
        guard let previousOrientation = Orientation(display: previousDisplay),
              current.origin.x.isFinite, current.origin.y.isFinite, current.width.isFinite, current.height.isFinite,
              current.maxX.isFinite, current.maxY.isFinite,
              current.width > 0, current.height > 0, visible.origin.x.isFinite, visible.origin.y.isFinite,
              visible.maxX.isFinite, visible.maxY.isFinite,
              visible.width.isFinite, visible.height.isFinite, visible.width > 0, visible.height > 0 else { return nil }
        let panel = developerPanelVisible ? panelHeight : 0
        let oldPhone = SimulatorChromeLayout(available: CGSize(width: max(1, current.width - 16), height: max(1, current.height - 72 - panel)),
                                            frame: previousDisplay, resolution: "", scale: 1)
        var desired = CGSize(width: oldPhone.screenSize.height + 60, height: oldPhone.screenSize.width + 108 + panel)
        if let restoredSize, restoredSize.width.isFinite, restoredSize.height.isFinite,
           restoredSize.width > 0, restoredSize.height > 0 { desired = restoredSize }
        let orientation: Orientation = previousOrientation == .portrait ? .landscape : .portrait
        let minimum = minimumSize(for: orientation)
        let margin = min(8, min(visible.width, visible.height) / 4)
        let bounds = visible.insetBy(dx: margin, dy: margin)
        let factor = min(1, bounds.width / desired.width, bounds.height / desired.height)
        let size = CGSize(width: min(bounds.width, max(minimum.width, desired.width * factor)),
                          height: min(bounds.height, max(minimum.height, desired.height * factor)))
        // Keep the toolbar's top-left location unless screen edges require a move.
        let x = min(max(current.minX, bounds.minX), bounds.maxX - size.width)
        let y = min(max(current.maxY - size.height, bounds.minY), bounds.maxY - size.height)
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }
}

@MainActor
final class DeviceWindowController: NSWindowController, NSWindowDelegate {
    let session: SessionController
    unowned let model: AppModel
    private var geometrySubscription: AnyCancellable?
    private var orientation: SimulatorWindowLayout.Orientation
    private var previousDisplay: CGSize
    private var developerPanelVisible = false
    private var changingFullScreen = false
    private var orientationPreference: String { "Device-Chrome-v2-\(session.avd.id)-orientation" }
    private var savedSizes: [SimulatorWindowLayout.Orientation: (size: CGSize, panelVisible: Bool)] = [:]
    init(session: SessionController, model: AppModel) {
        self.session = session; self.model = model
        previousDisplay = SimulatorChromeLayout.displayDimensions(frame: .zero, resolution: session.avd.resolution)
        orientation = SimulatorWindowLayout.Orientation(display: previousDisplay) ?? .portrait
        let visible = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1280, height: 900)
        let initialSize = NSSize(width: min(440, visible.width - 40), height: min(900, visible.height - 30))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: initialSize), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = session.avd.displayName
        window.minSize = NSSize(width: 360, height: 480)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.appearance = NSAppearance(named: .darkAqua)
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(type)?.isHidden = true
        }
        window.collectionBehavior = [.fullScreenPrimary]
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = NSHostingView(rootView: DeviceWindowView(session: session, developerPanelVisibilityChanged: { [weak self] visible in
            self?.developerPanelVisible = visible
        }))
        window.delegate = self
        let autosave = "Device-Chrome-v2-\(session.avd.id)"
        window.setFrameAutosaveName(autosave)
        if !window.setFrameUsingName(autosave) { window.center() }
        if UserDefaults.standard.string(forKey: orientationPreference) == "landscape", orientation == .portrait {
            orientation = .landscape
            previousDisplay = CGSize(width: previousDisplay.height, height: previousDisplay.width)
        }
        savedSizes[orientation] = (window.frame.size, false)
        // FrameStore itself is intentionally not ObservableObject. Reuse the
        // existing one-second metric tick and lifecycle signals for rotation.
        geometrySubscription = session.$fps.map { _ in () }
            .merge(with: session.$rotating.map { _ in () }, session.$state.map { _ in () })
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.resizeForDisplayOrientation() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func windowWillClose(_ notification: Notification) { model.windowClosed(session.avd.id) }
    func windowWillEnterFullScreen(_ notification: Notification) {
        changingFullScreen = true
        if let window { savedSizes[orientation] = (window.frame.size, developerPanelVisible) }
    }
    func windowDidEnterFullScreen(_ notification: Notification) { changingFullScreen = false }
    func windowWillExitFullScreen(_ notification: Notification) { changingFullScreen = true }
    func windowDidExitFullScreen(_ notification: Notification) {
        changingFullScreen = false
        resizeForDisplayOrientation()
    }

    private func resizeForDisplayOrientation() {
        guard let window, !changingFullScreen, !window.styleMask.contains(.fullScreen), !window.inLiveResize else { return }
        let display = session.frames.dimensions()
        guard let next = SimulatorWindowLayout.Orientation(display: display) else { return }
        guard next != orientation else { previousDisplay = display; return }
        savedSizes[orientation] = (window.frame.size, developerPanelVisible)
        var restored = savedSizes[next]?.size
        if let saved = savedSizes[next], saved.panelVisible != developerPanelVisible {
            restored?.height += developerPanelVisible ? SimulatorWindowLayout.panelHeight : -SimulatorWindowLayout.panelHeight
        }
        let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
        guard let frame = SimulatorWindowLayout.rotatedFrame(current: window.frame, previousDisplay: previousDisplay,
            visible: visible, developerPanelVisible: developerPanelVisible, restoredSize: restored) else { return }
        orientation = next
        UserDefaults.standard.set(next == .landscape ? "landscape" : "portrait", forKey: orientationPreference)
        previousDisplay = display
        let minimum = SimulatorWindowLayout.minimumSize(for: next)
        window.minSize = CGSize(width: min(minimum.width, visible.width), height: min(minimum.height, visible.height))
        window.setFrame(frame, display: true, animate: true)
        savedSizes[next] = (frame.size, developerPanelVisible)
    }
}
