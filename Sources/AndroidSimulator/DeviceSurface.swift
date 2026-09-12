import AppKit
import AVFoundation
import SwiftUI
import SimulatorKit

struct DeviceSurface: NSViewRepresentable {
    let session: SessionController
    var cornerRadius: CGFloat = 0
    func makeNSView(context: Context) -> AndroidSurfaceView {
        let view = AndroidSurfaceView(session: session)
        view.updateCornerRadius(cornerRadius)
        return view
    }
    func updateNSView(_ view: AndroidSurfaceView, context: Context) { view.updateSessionState(); view.updateCornerRadius(cornerRadius) }
    static func dismantleNSView(_ view: AndroidSurfaceView, coordinator: ()) { view.invalidate() }
}

@MainActor
final class AndroidSurfaceView: NSView, @preconcurrency NSTextInputClient {
    private let session: SessionController
    private let videoLayer = AVSampleBufferDisplayLayer()
    private var timer: Timer?
    private var frameSize = CGSize.zero
    private var pointerDown = false
    private var pressedKeys = KeyboardPressState()
    private var lastPoint = CGPoint.zero
    private var focusObservers: [NSObjectProtocol] = []
    private let compositionLabel = NSTextField(labelWithString: "")
    private var composition = NSAttributedString(string: "")
    private var compositionSelection = NSRange(location: 0, length: 0)
    private static let androidKeys: [UInt16: UInt32] = [36:66, 48:61, 51:67, 53:4, 123:21, 124:22, 125:20, 126:19, 117:112, 115:122, 119:123]
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    init(session: SessionController) {
        self.session = session
        super.init(frame: .zero)
        wantsLayer = true; layer?.backgroundColor = NSColor.black.cgColor
        videoLayer.videoGravity = .resizeAspect
        layer?.addSublayer(videoLayer)
        compositionLabel.isHidden = true
        compositionLabel.drawsBackground = true
        compositionLabel.backgroundColor = .windowBackgroundColor
        compositionLabel.textColor = .labelColor
        compositionLabel.font = .systemFont(ofSize: 15)
        compositionLabel.maximumNumberOfLines = 1
        compositionLabel.lineBreakMode = .byTruncatingHead
        compositionLabel.setAccessibilityLabel("Text composition")
        addSubview(compositionLabel)
        setAccessibilityLabel("Android device display")
        setAccessibilityHelp("Click to focus. Type to enter text. Drag to swipe. Command shortcuts remain on your Mac.")
        timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.presentLatest() }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func invalidate() { timer?.invalidate(); timer = nil; resetInput(); removeFocusObservers() }
    func updateSessionState() { if !session.canControl { resetInput() } }
    func updateCornerRadius(_ radius: CGFloat) {
        let clippedRadius = max(0, radius.isFinite ? radius : 0)
        guard layer?.cornerRadius != clippedRadius else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer?.cornerRadius = clippedRadius
        layer?.masksToBounds = clippedRadius > 0
        CATransaction.commit()
    }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true); videoLayer.frame = bounds; CATransaction.commit()
        layoutComposition()
        inputContext?.invalidateCharacterCoordinates()
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if window !== newWindow { resetInput(); removeFocusObservers() }
        super.viewWillMove(toWindow: newWindow)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeFocusObservers()
        guard let window else { return }
        let center = NotificationCenter.default
        // A view can stay first responder while its window loses focus. Releasing
        // only in resignFirstResponder would leave guest keys/touches held.
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification] {
            focusObservers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.resetInput() }
            })
        }
        focusObservers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resetInput() }
        })
    }
    private func removeFocusObservers() {
        for observer in focusObservers { NotificationCenter.default.removeObserver(observer) }
        focusObservers.removeAll()
    }
    private func presentLatest() {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let layerStatus: PresentationDiagnostics.LayerStatus
        switch videoLayer.status {
        case .unknown: layerStatus = .unknown
        case .rendering: layerStatus = .rendering
        case .failed: layerStatus = .failed
        @unknown default: layerStatus = .unrecognized
        }
        let layerError = layerStatus == .failed ? videoLayer.error?.localizedDescription : nil
        var outcome = PresentationDiagnostics.Outcome.noFrame
        var flushCount: UInt64 = 0
        defer {
            session.frames.recordPresentationTick(at: startedAt, completedAt: ProcessInfo.processInfo.systemUptime,
                outcome: outcome, layerStatus: layerStatus, flushCount: flushCount, layerError: layerError)
        }
        if layerStatus == .failed { videoLayer.flush(); flushCount += 1 }
        // Leave the pending frame in FrameStore while the layer is busy. A newer
        // frame can replace it there, where that drop is counted accurately.
        guard videoLayer.isReadyForMoreMediaData else { outcome = .notReady; return }
        guard let frame = session.frames.take() else { return }
        let buffer = frame.pixelBuffer
        let size = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        var format: CMVideoFormatDescription?
        let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &format)
        guard formatStatus == noErr, let format else { outcome = .formatError(formatStatus); return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample)
        guard sampleStatus == noErr, let sample else { outcome = .sampleError(sampleStatus); return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [NSMutableDictionary], let first = attachments.first { first[kCMSampleAttachmentKey_DisplayImmediately] = true }
        if size != frameSize { releasePointer(); frameSize = size; videoLayer.flushAndRemoveImage(); flushCount += 1 }
        videoLayer.enqueue(sample)
        session.frames.submitted(frame)
        outcome = .enqueued
    }
    private func point(_ event: NSEvent, clamped: Bool = false) -> CGPoint? {
        let geometry = DisplayGeometry(viewSize: bounds.size, frameSize: frameSize)
        var local = convert(event.locationInWindow, from: nil)
        if clamped, !geometry.contentRect.isEmpty {
            local.x = min(max(local.x, geometry.contentRect.minX), geometry.contentRect.maxX)
            local.y = min(max(local.y, geometry.contentRect.minY), geometry.contentRect.maxY)
        }
        return geometry.devicePoint(from: local)
    }
    private func touch(_ action: UInt8, _ p: CGPoint) { session.send(.touch(action: action, x: Int(p.x.rounded()), y: Int(p.y.rounded()), width: Int(frameSize.width), height: Int(frameSize.height))) }
    override func mouseDown(with event: NSEvent) {
        guard session.canControl else { return }
        window?.makeFirstResponder(self)
        guard let p = point(event) else { return }; pointerDown = true; lastPoint = p; touch(0, p)
    }
    override func mouseDragged(with event: NSEvent) { guard pointerDown, let p = point(event, clamped: true) else { return }; lastPoint = p; touch(2, p) }
    override func mouseUp(with event: NSEvent) { releasePointer() }
    private func releasePointer() { if pointerDown { touch(1, lastPoint); pointerDown = false } }
    private func releaseKeys() { for code in pressedKeys.releaseAll() { session.send(.key(code: code, down: false)) } }
    private func resetInput() {
        releasePointer(); releaseKeys(); clearComposition()
        inputContext?.discardMarkedText()
    }
    override func resignFirstResponder() -> Bool { resetInput(); return super.resignFirstResponder() }
    override func rightMouseDown(with event: NSEvent) { session.key(4) }
    override func scrollWheel(with event: NSEvent) {
        guard session.canControl, let p = point(event) else { return }
        let divisor = event.hasPreciseScrollingDeltas ? 60.0 : 3.0
        session.send(.scroll(x: Int(p.x.rounded()), y: Int(p.y.rounded()), width: Int(frameSize.width), height: Int(frameSize.height), horizontal: Double(-event.scrollingDeltaX) / divisor, vertical: Double(event.scrollingDeltaY) / divisor))
    }
    override func keyDown(with event: NSEvent) {
        guard session.canControl else { return }
        if event.modifierFlags.contains(.command) {
            if KeyboardMappings.functionKeys.contains(where: { $0.keyCode == event.keyCode }) {
                _ = pressedKeys.keyDown(event.keyCode, mapping: nil)
            }
            if event.charactersIgnoringModifiers?.lowercased() == "v", !event.modifierFlags.contains(.control), !event.modifierFlags.contains(.option) { paste(nil) }
            else { super.keyDown(with: event) }
            return
        }
        if KeyboardMappings.functionKeys.contains(where: { $0.keyCode == event.keyCode }) {
            let unmodified = event.modifierFlags.intersection([.shift, .control, .option, .command]).isEmpty
            let canMap = unmodified && !hasMarkedText()
            let mapping = canMap ? KeyboardMappings.action(for: event.keyCode).androidKeyCode : nil
            let code = pressedKeys.keyDown(event.keyCode, mapping: mapping)
            if canMap, let code {
                session.send(.key(code: code, down: true))
            } else {
                interpretKeyEvents([event])
            }
        } else if !hasMarkedText(), let mapping = Self.androidKeys[event.keyCode],
                  let code = pressedKeys.keyDown(event.keyCode, mapping: mapping) {
            session.send(.key(code: code, down: true))
        } else {
            // AppKit handles dead keys, keyboard layouts, and IME candidate
            // navigation before delivering committed text through insertText.
            interpretKeyEvents([event])
        }
    }
    override func keyUp(with event: NSEvent) {
        if let code = pressedKeys.keyUp(event.keyCode) { session.send(.key(code: code, down: false)) }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, session.canControl,
           event.modifierFlags.intersection([.command, .control, .option]) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "v" {
            paste(nil); return true
        }
        return super.performKeyEquivalent(with: event)
    }
    @objc func paste(_ sender: Any?) {
        guard session.canControl, let text = NSPasteboard.general.string(forType: .string) else { return }
        clearComposition(); inputContext?.discardMarkedText()
        sendCommittedText(text, useClipboard: true)
    }

    // MARK: - Native text composition

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        clearComposition()
        sendCommittedText(text)
    }
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        guard session.canControl else { return }
        composition = (string as? NSAttributedString) ?? NSAttributedString(string: (string as? String) ?? "")
        let location = min(selectedRange.location, composition.length)
        compositionSelection = NSRange(location: location, length: min(selectedRange.length, composition.length - location))
        let display = NSMutableAttributedString(attributedString: composition)
        if display.length > 0 {
            display.addAttributes([.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.labelColor,
                                   .underlineStyle: NSUnderlineStyle.single.rawValue], range: NSRange(location: 0, length: display.length))
        }
        compositionLabel.attributedStringValue = display
        compositionLabel.isHidden = composition.length == 0
        layoutComposition()
        inputContext?.invalidateCharacterCoordinates()
    }
    func unmarkText() {
        let text = composition.string
        clearComposition()
        sendCommittedText(text)
    }
    func hasMarkedText() -> Bool { composition.length > 0 }
    func markedRange() -> NSRange { hasMarkedText() ? NSRange(location: 0, length: composition.length) : NSRange(location: NSNotFound, length: 0) }
    func selectedRange() -> NSRange { compositionSelection }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [.underlineStyle, .foregroundColor, .backgroundColor] }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard range.location != NSNotFound, range.location <= composition.length else {
            actualRange?.pointee = NSRange(location: NSNotFound, length: 0); return nil
        }
        let available = NSRange(location: range.location, length: min(range.length, composition.length - range.location))
        actualRange?.pointee = available
        return composition.attributedSubstring(from: available)
    }
    func characterIndex(for point: NSPoint) -> Int { NSNotFound }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        actualRange?.pointee = hasMarkedText() ? markedRange() : NSRange(location: 0, length: 0)
        guard let window else { return .zero }
        layoutComposition()
        return window.convertToScreen(convert(compositionLabel.frame, to: nil))
    }
    override func doCommand(by selector: Selector) {
        if hasMarkedText() {
            if NSStringFromSelector(selector) == "cancelOperation:" { clearComposition(); inputContext?.discardMarkedText() }
            else if NSStringFromSelector(selector) == "insertNewline:" { unmarkText() }
            return
        }
        let commands: [String: UInt32] = ["insertNewline:": 66, "insertTab:": 61,
            "deleteBackward:": 67, "deleteForward:": 112, "cancelOperation:": 4,
            "moveLeft:": 21, "moveRight:": 22, "moveDown:": 20, "moveUp:": 19,
            "moveToBeginningOfLine:": 122, "moveToEndOfLine:": 123]
        if let code = commands[NSStringFromSelector(selector)] { session.key(code) }
        else { super.doCommand(by: selector) }
    }
    private func clearComposition() {
        composition = NSAttributedString(string: "")
        compositionSelection = NSRange(location: 0, length: 0)
        compositionLabel.stringValue = ""
        compositionLabel.isHidden = true
    }
    private func layoutComposition() {
        let width = min(max(120, compositionLabel.intrinsicContentSize.width + 16), max(0, bounds.width - 32))
        compositionLabel.frame = CGRect(x: max(0, (bounds.width - width) / 2), y: max(0, bounds.height - 44), width: width, height: 28)
    }
    private func sendCommittedText(_ text: String, useClipboard: Bool = false) {
        guard session.canControl, !text.isEmpty else { return }
        // The scrcpy text-key path cannot represent all Unicode. Clipboard paste
        // preserves committed IME text, emoji, and longer inserts without the
        // text packet's 300-byte truncation.
        if useClipboard || text.utf8.count > 300 || !text.unicodeScalars.allSatisfy(\.isASCII) {
            guard text.utf8.count <= (1 << 18) - 14 else {
                session.error = "This text exceeds the device clipboard limit. Paste less than 256 KB at a time."
                return
            }
            session.send(.clipboard(text))
        } else { session.send(.text(text)) }
    }
}
