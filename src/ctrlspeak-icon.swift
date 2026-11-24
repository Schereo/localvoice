import AppKit

// Renders the LocalVoice app icon for the legacy .icns build path.
// The matching unmasked artwork for Icon Composer lives in design/.

let outputDirectory = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

func drawIcon(edge: CGFloat) -> NSBitmapImageRep {
    let scale = edge / 1024
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(edge), pixelsHigh: Int(edge),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: edge, height: edge)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // macOS leaves the outer margin to the app; 1024 art sits in ~824.
    let inset: CGFloat = 100 * scale
    let plate = NSRect(x: inset, y: inset, width: edge - inset * 2, height: edge - inset * 2)

    NSColor(srgbRed: 200.0 / 255, green: 204.0 / 255, blue: 189.0 / 255, alpha: 1).setFill()
    let platePath = NSBezierPath(
        roundedRect: plate,
        xRadius: plate.width * 0.22,
        yRadius: plate.width * 0.22
    )
    platePath.fill()

    let unit = plate.width * (1.18 * 0.9 / 32)
    let barWidth = 4 * unit
    NSColor(srgbRed: 34.0 / 255, green: 39.0 / 255, blue: 33.0 / 255, alpha: 1).setFill()
    for (index, height) in ([6, 18, 10] as [CGFloat]).enumerated() {
        let barHeight = height * unit
        let centerX = plate.midX + CGFloat(index - 1) * 6 * unit
        let bar = NSRect(x: centerX - barWidth / 2, y: plate.midY - barHeight / 2,
                         width: barWidth, height: barHeight)
        NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// The sizes iconutil expects in an .iconset.
let variants: [(String, CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for (name, edge) in variants {
    let rep = drawIcon(edge: edge)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("could not encode \(name)\n".utf8))
        exit(1)
    }
    try! data.write(to: URL(fileURLWithPath: "\(outputDirectory)/\(name).png"))
}
