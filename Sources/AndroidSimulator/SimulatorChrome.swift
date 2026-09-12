import AppKit
import SwiftUI
import SimulatorKit

/// Fits the phone around the guest's real aspect ratio. The video view keeps the
/// same rectangular bounds used by DisplayGeometry for touch and scroll input.
struct SimulatorChromeLayout {
    let screenSize: CGSize
    let bezel: CGFloat
    let cornerRadius: CGFloat
    var bodySize: CGSize { CGSize(width: screenSize.width + 2 * bezel, height: screenSize.height + 2 * bezel) }
    var screenCornerRadius: CGFloat { max(0, cornerRadius - bezel) }

    init(available: CGSize, frame: CGSize, resolution: String, scale: Double) {
        let dimensions = Self.displayDimensions(frame: frame, resolution: resolution)
        let width = max(1, available.width.isFinite ? available.width - 24 : 1)
        let height = max(1, available.height.isFinite ? available.height - 16 : 1)
        let edge = min(10, min(width, height) / 8)
        let fitted = DisplayGeometry(viewSize: CGSize(width: max(1, width - 2 * edge), height: max(1, height - 2 * edge)), frameSize: dimensions).contentRect.size
        let factor = CGFloat(scale.isFinite ? min(1, max(0.25, scale)) : 1)
        bezel = edge * factor
        screenSize = CGSize(width: fitted.width * factor, height: fitted.height * factor)
        cornerRadius = min(64, min(screenSize.width, screenSize.height) * 0.15 + bezel)
    }

    static func displayDimensions(frame: CGSize, resolution: String) -> CGSize {
        if frame.width.isFinite, frame.height.isFinite, frame.width > 0, frame.height > 0 { return frame }
        let pieces = resolution.lowercased().components(separatedBy: CharacterSet(charactersIn: "×x"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if pieces.count == 2, let width = Double(pieces[0]), let height = Double(pieces[1]),
           width.isFinite, height.isFinite, width > 0, height > 0 {
            return CGSize(width: width, height: height)
        }
        return CGSize(width: 1080, height: 2400)
    }
}

struct SimulatorToolbarButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white.opacity(isEnabled ? (configuration.isPressed ? 0.6 : 0.9) : 0.3))
            .background(.white.opacity(configuration.isPressed ? 0.12 : 0), in: RoundedRectangle(cornerRadius: 7))
            .contentShape(RoundedRectangle(cornerRadius: 7))
    }
}

/// Native window controls preserve the standard close, minimize, and fullscreen
/// behavior while placing the traffic lights in the floating control bar.
struct SimulatorWindowButtons: NSViewRepresentable {
    func makeNSView(context: Context) -> TrafficLightView { TrafficLightView() }
    func updateNSView(_ view: TrafficLightView, context: Context) { view.updateAvailability() }

    final class TrafficLightView: NSView {
        private var controls: [NSButton] = []
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            let kinds: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
            for (index, kind) in kinds.enumerated() {
                guard let button = NSWindow.standardWindowButton(kind, for: [.titled, .closable, .miniaturizable, .resizable]) else { continue }
                button.target = self
                button.action = #selector(activate(_:))
                button.tag = index
                button.setAccessibilityLabel(["Close device window", "Minimize device window", "Toggle Full Screen"][index])
                addSubview(button)
                controls.append(button)
            }
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override var intrinsicContentSize: NSSize { NSSize(width: 64, height: 24) }
        override func layout() {
            super.layout()
            for (index, button) in controls.enumerated() {
                button.frame = NSRect(x: CGFloat(index) * 22, y: (bounds.height - 14) / 2, width: 14, height: 14)
            }
        }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateAvailability() }
        func updateAvailability() {
            for button in controls { button.isEnabled = window != nil && !(button.tag == 1 && window?.styleMask.contains(.fullScreen) == true) }
        }
        @objc private func activate(_ sender: NSButton) {
            switch sender.tag {
            case 0: window?.performClose(sender)
            case 1: window?.performMiniaturize(sender)
            default: window?.toggleFullScreen(sender)
            }
        }
    }
}

struct SimulatorWindowTitle: NSViewRepresentable {
    let title: String
    let subtitle: String
    func makeNSView(context: Context) -> TitleView { TitleView() }
    func updateNSView(_ view: TitleView, context: Context) { view.update(title: title, subtitle: subtitle) }

    /// AppKit owns this drag region so dragging the title never becomes a guest
    /// touch. Double-click respects the user's macOS title-bar preference.
    final class TitleView: NSView {
        private let titleLabel = NSTextField(labelWithString: "")
        private let subtitleLabel = NSTextField(labelWithString: "")
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
            titleLabel.textColor = .white
            subtitleLabel.font = .systemFont(ofSize: 10)
            subtitleLabel.textColor = NSColor.white.withAlphaComponent(0.55)
            for label in [titleLabel, subtitleLabel] {
                label.lineBreakMode = .byTruncatingTail
                label.maximumNumberOfLines = 1
                addSubview(label)
            }
            setAccessibilityElement(true)
            setAccessibilityRole(.staticText)
            setAccessibilityHelp("Drag to move the device window")
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        func update(title: String, subtitle: String) {
            if titleLabel.stringValue != title { titleLabel.stringValue = title }
            if subtitleLabel.stringValue != subtitle { subtitleLabel.stringValue = subtitle }
            setAccessibilityLabel("\(title), \(subtitle)")
        }
        override func layout() {
            super.layout()
            titleLabel.frame = NSRect(x: 0, y: bounds.midY, width: bounds.width, height: 16)
            subtitleLabel.frame = NSRect(x: 0, y: bounds.midY - 13, width: bounds.width, height: 14)
        }
        override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(convert(point, from: superview)) ? self : nil }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
                case "Minimize": window?.performMiniaturize(nil)
                case "None": break
                default: window?.performZoom(nil)
                }
            } else { window?.performDrag(with: event) }
        }
    }
}

struct SimulatorHardwareButton: View {
    let title: String
    let height: CGFloat
    let enabled: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 2)
                .fill(LinearGradient(colors: [Color(white: 0.39), Color(white: 0.16), Color(white: 0.3)], startPoint: .leading, endPoint: .trailing))
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(.black.opacity(0.8), lineWidth: 0.5))
                .frame(width: 4, height: height)
                .frame(width: 12, height: height + 8)
                .contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(!enabled).help(title).accessibilityLabel(title)
    }
}
