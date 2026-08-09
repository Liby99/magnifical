// Renders the DMG volume icon: a clean, drawn-in-code disk drive with the MagnifiCal app icon
// composited on its face — the classic "disk with the app inside" a mounted MagnifiCal.dmg shows.
//
// The drive is OUR artwork (make-icon.swift house style: minimal, monotone grays, hairlines) —
// NSWorkspace.icon(for: .diskImage) was tried first and rejected: its small representations
// (16–256px, exactly what Finder shows on the desktop/in lists) are the generic folded-corner
// document icon, so the composite read as "app icon on a piece of paper".
//
//   swift make-dmg-icon.swift <app-icon.(icns|png)> <out.icns>
//
// Writes a full iconset (16…512@2x) — the artwork redraws at native pixels per size — and
// compiles it with iconutil.

import AppKit

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write(Data("usage: make-dmg-icon.swift <app-icon> <out.icns>\n".utf8))
    exit(1)
}

guard let appIcon = NSImage(contentsOfFile: args[1]) else {
    FileHandle.standardError.write(Data("cannot load app icon: \(args[1])\n".utf8))
    exit(1)
}

// ── Artwork (in 1024-space; every size redraws through a scaled transform, so edges stay crisp) ──
// A landscape-ish silver drive: soft shadow, light body, darker bottom chin — the familiar
// external-drive silhouette, monotone so the colorful app icon on its face carries the identity.
let S: CGFloat = 1024
let bodyRect = NSRect(x: 112, y: 172, width: 800, height: 680)
let bodyRadius: CGFloat = 72
let chinHeight: CGFloat = 132
let overlayScale: CGFloat = 0.52 // app icon size relative to the full edge

func gray(_ w: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(calibratedWhite: w, alpha: a)
}

func drawDisk(appIcon: NSImage, px: Int, to url: URL) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    let u = CGFloat(px) / S
    let t = NSAffineTransform()
    t.scale(by: u)
    t.concat()

    // Soft drop shadow under the body (skip at tiny sizes — it just muddies 16/32px).
    if px >= 64 {
        let sh = NSShadow()
        sh.shadowColor = NSColor.black.withAlphaComponent(0.22)
        sh.shadowBlurRadius = 26
        sh.shadowOffset = NSSize(width: 0, height: -14)
        NSGraphicsContext.saveGraphicsState()
        sh.set()
        NSBezierPath(roundedRect: bodyRect, xRadius: bodyRadius, yRadius: bodyRadius).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
    // Body: light silver with a hairline edge.
    let body = NSBezierPath(roundedRect: bodyRect, xRadius: bodyRadius, yRadius: bodyRadius)
    gray(0.95).setFill()
    body.fill()
    // Bottom chin: darker strip sharing the body's bottom corners (clip to the body shape).
    NSGraphicsContext.saveGraphicsState()
    body.addClip()
    gray(0.83).setFill()
    NSRect(x: bodyRect.minX, y: bodyRect.minY, width: bodyRect.width, height: chinHeight).fill()
    gray(0.72).setFill() // hairline seam above the chin
    NSRect(x: bodyRect.minX, y: bodyRect.minY + chinHeight, width: bodyRect.width, height: 4).fill()
    NSGraphicsContext.restoreGraphicsState()
    gray(0.66).setStroke()
    body.lineWidth = 3
    body.stroke()

    // The app icon, centered on the face (the region above the chin).
    let faceMidY = bodyRect.minY + chinHeight + (bodyRect.height - chinHeight) / 2
    let a = S * overlayScale
    appIcon.draw(in: NSRect(x: (S - a) / 2, y: faceMidY - a / 2, width: a, height: a))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

let fm = FileManager.default
let tmp = fm.temporaryDirectory.appendingPathComponent("dmgicon-\(ProcessInfo.processInfo.processIdentifier).iconset")
try! fm.createDirectory(at: tmp, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    drawDisk(appIcon: appIcon, px: size, to: tmp.appendingPathComponent("icon_\(size)x\(size).png"))
    drawDisk(appIcon: appIcon, px: size * 2, to: tmp.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}

let out = URL(fileURLWithPath: args[2])
try? fm.removeItem(at: out)
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", tmp.path, "-o", out.path]
try! task.run()
task.waitUntilExit()
try? fm.removeItem(at: tmp)
guard task.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(1)
}

print("wrote \(out.path)")
