#!/usr/bin/env swift
import AppKit

// Run from the project root:
// swift scripts/make-dmg-background.swift [Resources/DMG]
// All geometry uses top-left logical coordinates. Both TIFF representations
// have a 720 × 460 point size, preserving Finder layout on Retina displays.
let canvas = CGSize(width: 720, height: 460)
let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Resources/DMG", isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
}
let evergreen = color(24, 60, 43)
let secondary = color(91, 113, 99)
let accent = color(67, 127, 90)

func rect(_ x: CGFloat, _ top: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
    CGRect(x: x, y: canvas.height - top - height, width: width, height: height)
}
func text(_ string: String, x: CGFloat, top: CGFloat, width: CGFloat, height: CGFloat,
          size: CGFloat, weight: NSFont.Weight = .regular, foreground: NSColor,
          alignment: NSTextAlignment = .left) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = alignment
    paragraph.lineBreakMode = .byClipping
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: foreground,
        .paragraphStyle: paragraph
    ]
    (string as NSString).draw(in: rect(x, top, width, height), withAttributes: attributes)
}

func render(scale: Int) throws -> NSBitmapImageRep {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
        pixelsWide: Int(canvas.width) * scale, pixelsHigh: Int(canvas.height) * scale,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "DroidDockDMG", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create the installer background canvas."])
    }
    bitmap.size = canvas
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    defer { NSGraphicsContext.restoreGraphicsState() }
    graphics.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
    graphics.cgContext.setShouldAntialias(true)

    let background = NSBezierPath(rect: CGRect(origin: .zero, size: canvas))
    NSGradient(colors: [color(235, 245, 236), color(248, 250, 247)])!
        .draw(in: background, angle: 90)

    // A small signature stroke supplies the brand accent without competing
    // with the real, draggable app icon supplied by Finder.
    accent.setFill()
    NSBezierPath(roundedRect: rect(56, 43, 34, 4), xRadius: 2, yRadius: 2).fill()
    text("Install DroidDock", x: 54, top: 66, width: 612, height: 46,
         size: 34, weight: .semibold, foreground: evergreen)
    text("Drag the app into Applications.", x: 56, top: 116, width: 608, height: 26,
         size: 15, foreground: secondary)

    // The 112-point Finder icons are centered at (190, 246) and (530, 246).
    // These wells include the real labels below the icons. No app art or
    // imitation labels are embedded in the installer background.
    for center in [CGFloat(190), CGFloat(530)] {
        let well = NSBezierPath(roundedRect: rect(center - 96, 170, 192, 180), xRadius: 28, yRadius: 28)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = evergreen.withAlphaComponent(0.035)
        shadow.shadowBlurRadius = 20
        shadow.shadowOffset = CGSize(width: 0, height: -4)
        shadow.set()
        NSColor.white.withAlphaComponent(0.75).setFill()
        well.fill()
        NSGraphicsContext.restoreGraphicsState()
        color(215, 231, 219).setStroke()
        well.lineWidth = 1
        well.stroke()
    }

    // Direction is centered on the icon pair and stays outside both icon hit
    // regions. Rounded strokes remain crisp at both backing resolutions.
    let arrow = NSBezierPath()
    arrow.lineWidth = 2.25
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    let middleY = canvas.height - 246
    arrow.move(to: CGPoint(x: 338, y: middleY))
    arrow.line(to: CGPoint(x: 382, y: middleY))
    arrow.move(to: CGPoint(x: 374, y: middleY + 8))
    arrow.line(to: CGPoint(x: 382, y: middleY))
    arrow.line(to: CGPoint(x: 374, y: middleY - 8))
    accent.withAlphaComponent(0.85).setStroke()
    arrow.stroke()

    color(212, 227, 215).setFill()
    // Keep essential copy inside the first 400 points: Finder may preserve a
    // user's path/status bars even when the image requests them hidden.
    NSBezierPath(rect: rect(56, 360, 608, 1)).fill()
    text("Then open DroidDock from Applications.", x: 56, top: 375, width: 608, height: 22,
         size: 13, foreground: secondary, alignment: .center)
    graphics.flushGraphics()
    return bitmap
}

var representations: [NSBitmapImageRep] = []
for scale in [1, 2] {
    let bitmap = try render(scale: scale)
    let name = scale == 1 ? "background.png" : "background@2x.png"
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "DroidDockDMG", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not encode \(name)."])
    }
    try data.write(to: output.appendingPathComponent(name), options: .atomic)
    representations.append(bitmap)
}
// TIFF compression value 5 is lossless LZW. Finder can choose the matching
// 72-DPI or 144-DPI representation while retaining the same logical canvas.
guard let tiff = NSBitmapImageRep.representationOfImageReps(in: representations, using: .tiff,
    properties: [.compressionMethod: 5]) else {
    throw NSError(domain: "DroidDockDMG", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not encode the multi-resolution TIFF."])
}
try tiff.write(to: output.appendingPathComponent("background.tiff"), options: .atomic)
let geometry: [String: Any] = [
    "logicalSize": [720, 460], "retinaPixelSize": [1440, 920],
    "coordinateOrigin": "top-left", "iconSize": 112,
    "iconCenters": [[190, 246], [530, 246]],
    "iconWells": [[94, 170, 192, 180], [434, 170, 192, 180]],
    "titleRect": [54, 66, 612, 46], "subtitleRect": [56, 116, 608, 26],
    "footerRect": [56, 375, 608, 22],
    "finderBackground": "background.tiff",
    "generator": "scripts/make-dmg-background.swift"
]
let json = try JSONSerialization.data(withJSONObject: geometry, options: [.prettyPrinted, .sortedKeys])
try json.write(to: output.appendingPathComponent("geometry.json"), options: .atomic)
print("Generated \(output.path)/background.png, background@2x.png and background.tiff (720 × 460 points).")
