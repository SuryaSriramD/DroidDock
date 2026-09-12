import AppKit
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        let p = CGFloat(pixels)
        let shape = NSBezierPath(roundedRect: NSRect(x: p*0.05, y:p*0.05, width:p*0.9, height:p*0.9), xRadius:p*0.20, yRadius:p*0.20)
        NSGradient(starting: NSColor(calibratedRed: 0.20, green:0.47, blue:0.36, alpha:1), ending: NSColor(calibratedRed:0.07, green:0.22, blue:0.17, alpha:1))!.draw(in:shape, angle: -70)
        let rear = NSBezierPath(roundedRect: NSRect(x:p*0.31, y:p*0.23, width:p*0.41, height:p*0.61), xRadius:p*0.07,yRadius:p*0.07)
        NSColor.white.withAlphaComponent(0.28).setFill(); rear.fill()
        let phone = NSBezierPath(roundedRect:NSRect(x:p*0.25,y:p*0.18,width:p*0.40,height:p*0.62),xRadius:p*0.07,yRadius:p*0.07)
        NSColor(calibratedRed:0.87,green:0.96,blue:0.88,alpha:1).setFill();phone.fill()
        NSColor(calibratedRed:0.15,green:0.37,blue:0.28,alpha:1).setFill()
        NSBezierPath(roundedRect:NSRect(x:p*0.29,y:p*0.27,width:p*0.32,height:p*0.44),xRadius:p*0.02,yRadius:p*0.02).fill()
        NSBezierPath(roundedRect:NSRect(x:p*0.40,y:p*0.21,width:p*0.10,height:p*0.018),xRadius:p*0.009,yRadius:p*0.009).fill()
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try rep.representation(using:.png,properties:[:])!.write(to:directory.appendingPathComponent(name))
    }
}
