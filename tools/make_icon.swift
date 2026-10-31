import AppKit

// Docket app icon. Regenerate with: swift tools/make_icon.swift Docket/Resources/Assets.xcassets/AppIcon.appiconset
// A dark rounded square with a three-item docket. A vertical line joins the
// items like a commit graph or a PR stack; the top item is the teal "needs you" node.
func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func render(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = CGFloat(size) / 1024
    ctx.scaleBy(x: s, y: s)
    // Work in top-down coordinates on a 1024 canvas.
    ctx.translateBy(x: 0, y: 1024)
    ctx.scaleBy(x: 1, y: -1)

    // macOS icon grid: 824 square body with ~185 corner radius, centered.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    let gradient = NSGradient(starting: color(0x222324), ending: color(0x0C0C0C))!
    gradient.draw(in: body, angle: 90)
    NSGraphicsContext.restoreGraphicsState()
    color(0x434343).setStroke()
    shape.lineWidth = 6
    shape.stroke()

    let rows: [(y: CGFloat, barEnd: CGFloat, active: Bool)] = [(352, 764, true), (512, 704, false), (672, 644, false)]
    let nodeX: CGFloat = 318
    let radius: CGFloat = 48

    // Graph line behind the nodes.
    let line = NSBezierPath()
    line.move(to: CGPoint(x: nodeX, y: rows[0].y))
    line.line(to: CGPoint(x: nodeX, y: rows[2].y))
    line.lineWidth = 16
    line.lineCapStyle = .round
    color(0x434343).setStroke()
    line.stroke()

    for row in rows {
        let node = NSBezierPath(ovalIn: CGRect(x: nodeX - radius, y: row.y - radius, width: radius * 2, height: radius * 2))
        if row.active {
            color(0x38C0C7).setFill()
            node.fill()
        } else {
            color(0x1A1B1C).setFill()
            node.fill()
            node.lineWidth = 16
            color(0x5B5D5F).setStroke()
            node.stroke()
        }
        let bar = NSBezierPath(roundedRect: CGRect(x: 412, y: row.y - 30, width: row.barEnd - 412, height: 60), xRadius: 30, yRadius: 30)
        (row.active ? color(0xD6D6D7) : color(0x5B5D5F)).setFill()
        bar.fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
for size in [16, 32, 64, 128, 256, 512, 1024] {
    try! render(size: size).write(to: out.appendingPathComponent("icon_\(size).png"))
}
print("ok")
