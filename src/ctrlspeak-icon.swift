import AppKit

// Renders the ctrlSPEAK app icon as a PNG iconset, which install.sh feeds to
// iconutil. Generated from source rather than checked in as a binary asset,
// matching how the recording pill is built.

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

    let background = NSGradient(
        starting: NSColor(calibratedRed: 0.16, green: 0.20, blue: 0.30, alpha: 1),
        ending: NSColor(calibratedRed: 0.05, green: 0.06, blue: 0.10, alpha: 1)
    )!
    let platePath = NSBezierPath(
        roundedRect: plate,
        xRadius: plate.width * 0.235,
        yRadius: plate.width * 0.235
    )
    background.draw(in: platePath, angle: -90)

    NSColor.white.withAlphaComponent(0.10).setStroke()
    platePath.lineWidth = 3 * scale
    platePath.stroke()

    let accent = NSColor(calibratedRed: 0.46, green: 0.70, blue: 1, alpha: 1)
    let centerX = edge / 2

    // Microphone capsule.
    let capsuleWidth = 210 * scale
    let capsuleHeight = 350 * scale
    let capsule = NSRect(
        x: centerX - capsuleWidth / 2,
        y: edge * 0.44,
        width: capsuleWidth,
        height: capsuleHeight
    )
    accent.setFill()
    NSBezierPath(
        roundedRect: capsule,
        xRadius: capsuleWidth / 2,
        yRadius: capsuleWidth / 2
    ).fill()

    // Cradle arc under the capsule.
    let cradleRadius = 165 * scale
    let cradleCenter = NSPoint(x: centerX, y: capsule.minY + 40 * scale)
    let cradle = NSBezierPath()
    cradle.appendArc(
        withCenter: cradleCenter,
        radius: cradleRadius,
        startAngle: 200,
        endAngle: 340,
        clockwise: false
    )
    cradle.lineWidth = 46 * scale
    cradle.lineCapStyle = .round
    accent.withAlphaComponent(0.85).setStroke()
    cradle.stroke()

    // Stem.
    let stem = NSBezierPath()
    stem.move(to: NSPoint(x: centerX, y: cradleCenter.y - cradleRadius))
    stem.line(to: NSPoint(x: centerX, y: edge * 0.235))
    stem.lineWidth = 46 * scale
    stem.lineCapStyle = .round
    accent.withAlphaComponent(0.85).setStroke()
    stem.stroke()

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
