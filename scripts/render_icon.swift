// Read app icon renderer (issue #102).
//
// Usage:
//   swiftc -framework AppKit -o /tmp/render_icon scripts/render_icon.swift
//   /tmp/render_icon assets/icon/Read.iconset
//   iconutil -c icns assets/icon/Read.iconset -o assets/icon/Read.icns
//
// Draws the vector master at every icon size (no upscaling): a dark
// rounded tile in the app palette (#121212) with an IBM Plex Serif "R"
// (bundled under assets/fonts, registered process-local so CI renders
// byte-identically) and a link-blue reading rule beneath it — the same
// accent the reader uses for links. Full-bleed tile with a hairline
// edge so it reads on both light and dark Docks.
import AppKit
import CoreText

let fm = FileManager.default
let args = CommandLine.arguments
guard args.count == 2 else {
    fputs("usage: render_icon <out.iconset>\n", stderr)
    exit(1)
}
let outDir = args[1]
try? fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)

// Register the bundled brand fonts (process scope, no system install).
let fontsDir = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("assets/fonts")
if let ttf = try? fm.contentsOfDirectory(at: fontsDir, includingPropertiesForKeys: nil) {
    for u in ttf where u.pathExtension.lowercased() == "ttf" {
        CTFontManagerRegisterFontsForURL(u as CFURL, .process, nil)
    }
}

func serifR(size: CGFloat) -> NSFont {
    let px = size * 0.60
    for name in ["IBMPlexSerif", "IBMPlexSerif-Regular"] {
        if let f = NSFont(name: name, size: px) { return f }
    }
    return NSFont(name: "Georgia", size: px) ?? NSFont.systemFont(ofSize: px)
}

func drawIcon(size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { img.unlockFocus(); return img }
    let s = size
    // Tile: subtle top-lit gradient on the app background shade.
    let tile = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: s, height: s),
                            xRadius: s * 0.225, yRadius: s * 0.225)
    let top = NSColor(calibratedRed: 0x1E / 255.0, green: 0x1E / 255.0, blue: 0x21 / 255.0, alpha: 1)
    let bottom = NSColor(calibratedRed: 0x12 / 255.0, green: 0x12 / 255.0, blue: 0x12 / 255.0, alpha: 1)
    if let grad = NSGradient(starting: top, ending: bottom) {
        ctx.saveGState()
        tile.addClip()
        grad.draw(from: NSPoint(x: s / 2, y: s), to: NSPoint(x: s / 2, y: 0), options: [])
        ctx.restoreGState()
    } else {
        bottom.setFill()
        tile.fill()
    }
    NSColor(white: 1.0, alpha: 0.16).setStroke()
    tile.lineWidth = max(1.0, s * 0.004)
    tile.stroke()
    // Serif R, optically centered (cap sits a hair high).
    let str = "R" as NSString
    let font = serifR(size: s)
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor(calibratedRed: 0xED / 255.0, green: 0xEB / 255.0, blue: 0xE6 / 255.0, alpha: 1),
    ]
    let tw = str.size(withAttributes: attrs)
    str.draw(at: NSPoint(x: (s - tw.width) / 2, y: s * 0.30), withAttributes: attrs)
    // Reading rule: link-accent bar under the cap (dark-theme link color).
    let rule = NSBezierPath(roundedRect: NSRect(x: s * 0.30, y: s * 0.235,
                                               width: s * 0.40, height: max(1.5, s * 0.032)),
                            xRadius: s * 0.016, yRadius: s * 0.016)
    NSColor(calibratedRed: 96 / 255.0, green: 165 / 255.0, blue: 250 / 255.0, alpha: 1).setFill()
    rule.fill()
    img.unlockFocus()
    return img
}

// Standard macOS iconset members (1x + 2x for each point size).
let members: [(points: Int, scale: Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
    (256, 1), (256, 2), (512, 1), (512, 2),
]
for m in members {
    let px = m.points * m.scale
    let name = m.scale == 1
        ? String(format: "icon_%dx%d.png", m.points, m.points)
        : String(format: "icon_%dx%d@2x.png", m.points, m.points)
    let img = drawIcon(size: CGFloat(px))
    guard let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        fputs("render failed at \(px)\n", stderr)
        exit(1)
    }
    try png.write(to: URL(fileURLWithPath: outDir + "/" + name))
}
print("iconset written to \(outDir)")
