// Renders the MagnifiCal app icon (1024×1024 master PNG) using CoreGraphics.
// Design: minimalistic + monotone. A flat white "calendar page" card with the brand-red
// header band on top, and below it a hairline day/lane grid carrying three light red/pink
// HORIZONTAL band-event pills — the app's signature year-view band lanes.
//
// Two modes, same artwork:
//   default — macOS: Big Sur icon-grid proportions (824×824 card centered in 1024,
//             100px transparent margins, radius ≈ 0.225 · side, soft drop shadow).
//   --ios   — iOS: FULL-BLEED square, no margin/rounding/shadow (iOS masks the corners
//             itself; the mac margins would render as a black border on the home screen).
//
//   swift make-icon.swift out.png [--ios]

import AppKit

let S: CGFloat = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8,
                    bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [r / 255, g / 255, b / 255, a])!
}

/// The brand accent (#FF3B6B) at a given opacity — the pinks are just the accent, lightened.
func accent(_ a: CGFloat = 1) -> CGColor {
    rgb(255, 59, 107, a)
}

func squircle(_ rect: CGRect, radius: CGFloat) -> CGPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).cgPath
}

let ios = CommandLine.arguments.contains("--ios")
let margin: CGFloat = ios ? 0 : 100
let card = CGRect(x: margin, y: margin, width: S - 2 * margin, height: S - 2 * margin)
let radius = ios ? 0 : card.width * 0.2237
let cardPath = ios ? CGPath(rect: card, transform: nil) : squircle(card, radius: radius)

// ---- soft drop shadow under the card (macOS only — iOS is full-bleed) ----
if !ios {
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -16), blur: 40, color: rgb(0, 0, 0, 0.22))
    ctx.addPath(cardPath); ctx.setFillColor(rgb(255, 255, 255)); ctx.fillPath()
    ctx.restoreGState()
}

// Everything else clips to the card.
ctx.saveGState()
ctx.addPath(cardPath); ctx.clip()

// ---- flat white page ----
ctx.setFillColor(rgb(255, 255, 255))
ctx.fill(card)

// ---- flat accent header band (top ~26% of the card) ----
let bandH = card.height * 0.26
let headerRect = CGRect(x: card.minX, y: card.maxY - bandH, width: card.width, height: bandH)
ctx.setFillColor(accent())
ctx.fill(headerRect)

// ---- body: hairline day/lane grid (SQUARE cells, filling most of the body) ----
let body = CGRect(x: card.minX, y: card.minY, width: card.width, height: headerRect.minY - card.minY)
let cols = 4, lanes = 3
let cellS = min(body.width * 0.84 / CGFloat(cols), // ~8% side margins
                body.height * 0.82 / CGFloat(lanes)) // ~9% top/bottom gaps
let grid = CGRect(x: body.midX - cellS * CGFloat(cols) / 2,
                  y: body.minY + (body.height - cellS * CGFloat(lanes)) / 2,
                  width: cellS * CGFloat(cols), height: cellS * CGFloat(lanes))
let colW = cellS
let laneH = cellS
let hairline: CGFloat = 7
ctx.setFillColor(rgb(233, 227, 230)) // warm light gray — quiet next to the pinks
for c in 1 ..< cols { // inner vertical day lines
    let x = grid.minX + CGFloat(c) * colW
    ctx.fill(CGRect(x: x - hairline / 2, y: grid.minY, width: hairline, height: grid.height))
}

for l in 1 ..< lanes { // inner horizontal lane lines
    let y = grid.minY + CGFloat(l) * laneH
    ctx.fill(CGRect(x: grid.minX, y: y - hairline / 2, width: grid.width, height: hairline))
}

/// ---- light red/pink horizontal band events, one per lane ----
/// (startCol, endCol exclusive, lane from top, opacity) — a clean diagonal cascade: equal
/// 3-day bands stepping one column per lane, fading as they descend.
/// Together the four bars sketch a λ — the cascade is the right-leaning stroke, the
/// bottom-left bar its leg. (A calendar that likes programming languages.)
let pills: [(Int, Int, Int, CGFloat)] = [
    (0, 2, 0, 0.55),
    (1, 3, 1, 0.35),
    (2, 4, 2, 0.20),
    (0, 2, 2, 0.45),
]
let pillH = laneH * 0.58
let inset = colW * 0.13
for (c0, c1, lane, alpha) in pills {
    let y = grid.maxY - CGFloat(lane) * laneH - laneH / 2 - pillH / 2
    let x0 = grid.minX + CGFloat(c0) * colW + inset
    let x1 = grid.minX + CGFloat(c1) * colW - inset
    let r = CGRect(x: x0, y: y, width: x1 - x0, height: pillH)
    ctx.addPath(squircle(r, radius: pillH / 2))
    ctx.setFillColor(accent(alpha))
    ctx.fillPath()
}

ctx.restoreGState()

// ---- write PNG ----
let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img)
let png = rep.representation(using: .png, properties: [:])!
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
