// File ▸ Print… (⌘P) on the YEAR view. Renders a print-specific layout — NOT the live canvas — through
// the macOS system print pipeline: two landscape-letter pages (six stacked full-width month rows each,
// a quarter gap between Q1/Q2 and Q3/Q4), white background, light theme, flat fills, no header/footer.
//
// Pipeline: PrintYearPage (plain SwiftUI, fixed 792×612pt) → ImageRenderer.render into a PDF CGContext
// (vector text/shapes) → PDFDocument → NSPrintOperation (system print panel as a window sheet).
// Dev hook: CC_PRINT_PDF=<path> writes the PDF there and skips the panel (layout verification).

import AppKit
import CalendarEngine
import CalendarGeometry
import PDFKit
import SwiftUI

@MainActor
enum PrintYear {
    static let pageW: CGFloat = 792, pageH: CGFloat = 612 // landscape US Letter, points

    /// Build the 2-page PDF for `engine.year` and hand it to the system print panel.
    static func run(engine: CalendarEngine, window: NSWindow?) {
        let year = engine.year
        let bands = engine.displayBands(for: year) // incl. recurrence, promoted ghosts, imports, tag filter
        let tracks = engine.items.trackNames
        guard let pdf = makePDF(year: year, bands: bands, tracks: tracks) else { return }

        // Dev hook: write the PDF for inspection instead of opening the (modal) print panel.
        if let out = ProcessInfo.processInfo.environment["CC_PRINT_PDF"], !out.isEmpty {
            try? pdf.write(to: URL(fileURLWithPath: out))
            return
        }
        guard let doc = PDFDocument(data: pdf) else { return }
        let info = NSPrintInfo()
        info.paperSize = NSSize(width: 612, height: 792) // letter; autoRotate turns our landscape pages
        info.orientation = .landscape
        info.topMargin = 0; info.bottomMargin = 0; info.leftMargin = 0; info.rightMargin = 0
        info.isHorizontallyCentered = true; info.isVerticallyCentered = true
        guard let op = doc.printOperation(for: info, scalingMode: .pageScaleDownToFit, autoRotate: true) else { return }
        op.showsPrintPanel = true
        if let window {
            op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            op.run()
        }
    }

    /// Two vector PDF pages (Jan–Jun, Jul–Dec) rendered from PrintYearPage.
    private static func makePDF(year: Int, bands: [BandEvent], tracks: [[String]]) -> Data? {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: pageW, height: pageH)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }
        for half in 0 ..< 2 {
            let page = PrintYearPage(year: year, firstMonth: half * 6, bands: bands, tracks: tracks)
                .frame(width: pageW, height: pageH)
            let renderer = ImageRenderer(content: page)
            renderer.proposedSize = ProposedViewSize(width: pageW, height: pageH)
            ctx.beginPDFPage(nil)
            renderer.render { _, draw in draw(ctx) }
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return data as Data
    }
}

/// One landscape-letter page mirroring the on-screen year view's structure: TWO QUARTER BLOCKS (the
/// only gap sits between them). Each quarter = one day-label strip on top + its three months stacked
/// FLUSH; each month row = the rotated month name on the far left, the track-name column (lane rules run
/// above/below each name), then the 31-slot day grid with the flat band bars. Light theme, white paper;
/// self-contained (plain data in) so ImageRenderer can snapshot it.
struct PrintYearPage: View {
    let year: Int
    let firstMonth: Int // 0 (Jan-Jun) or 6 (Jul-Dec)
    let bands: [BandEvent]
    let tracks: [[String]]

    private let theme = Theme(dark: false)
    private let pad: CGFloat = 22
    private let monthLabelW: CGFloat = 16 // the rotated month name column
    private let trackW: CGFloat = 52 // track-name column
    private let dayNumH: CGFloat = 10 // the quarter's day-label strip
    private let quarterGap: CGFloat = 18 // the ONLY vertical gap on the page

    private var gridW: CGFloat {
        PrintYear.pageW - pad * 2 - monthLabelW - trackW
    }

    private var dayW: CGFloat {
        gridW / 31
    }

    private var laneH: CGFloat {
        (PrintYear.pageH - pad * 2 - quarterGap - 2 * dayNumH) / 24
    } // 24 lanes/page

    private let frameGray = Color(white: 0.5) // month/quarter boundaries
    private let ruleGray = Color(white: 0.84) // inner lane + day rules

    /// The horizontal lane rules for one month strip, on half-point centers. `boundary` selects the outer
    /// frame lines (top; bottom only on the quarter's LAST month — inner month boundaries are drawn once,
    /// by the month below, so flush months don't double-stroke) vs the inner lane rules.
    private func laneRulePath(width: CGFloat, isLast: Bool, boundary: Bool) -> Path {
        Path { p in
            for t in 0 ... 4 {
                if t == 4 && !isLast {
                    continue
                } // the next month's top rule draws this boundary
                let edge = t == 0 || t == 4
                guard edge == boundary else { continue }
                let y = (laneH * CGFloat(t)).rounded() + (t == 4 ? -0.4 : 0.4)
                p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: width, y: y))
            }
        }
    }

    /// The vertical day-column rules for one month strip, half-point centers. Every month spans the full
    /// 31 slots; the frame lines (dark) sit at 0, the month's real end (`dim`), and 31 — the dead region
    /// between dim and 31 is hatched separately.
    private func dayRulePath(dim: Int, stripH: CGFloat, boundary: Bool) -> Path {
        Path { p in
            for d in 0 ... 31 {
                let edge = d == 0 || d == dim || d == 31
                guard edge == boundary else { continue }
                let x = (CGFloat(d) * dayW).rounded() + (d == 31 ? -0.4 : 0.4)
                p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: stripH))
            }
        }
    }

    /// The app's dead-day hatch (SceneRenderer's `.dim` recipe): 45° lines every 6pt, bottom-left→top-right.
    private func hatchPath(w: CGFloat, h: CGFloat) -> Path {
        Path { p in
            var x = -h
            while x < w {
                p.move(to: CGPoint(x: x, y: h)); p.addLine(to: CGPoint(x: x + h, y: 0))
                x += 6
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            quarter(firstMonth)
            Spacer().frame(height: quarterGap)
            quarter(firstMonth + 3)
        }
        .padding(pad)
        .frame(width: PrintYear.pageW, height: PrintYear.pageH, alignment: .topLeading)
        .background(Color.white)
        .environment(\.colorScheme, .light)
    }

    /// One quarter block: the day-label strip, then three months flush (no gaps).
    private func quarter(_ start: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Spacer().frame(width: monthLabelW + trackW)
                ZStack(alignment: .topLeading) {
                    ForEach(1 ... 31, id: \.self) { d in
                        Text("\(d)")
                            .font(.system(size: 5.5)).foregroundStyle(theme.textMuted)
                            .frame(width: dayW, height: dayNumH)
                            .offset(x: CGFloat(d - 1) * dayW)
                    }
                }
                .frame(width: gridW, height: dayNumH, alignment: .topLeading)
            }
            ForEach(0 ..< 3, id: \.self) { i in
                monthStrip(start + i, isFirst: i == 0, isLast: i == 2)
            }
        }
    }

    /// One month row: rotated name | track names (rules above/below each) | the day grid + bands.
    private func monthStrip(_ m: Int, isFirst: Bool, isLast: Bool) -> some View {
        let dim = daysInMonth(year, m)
        let stripH = laneH * 4
        let monthBands = bands.filter { $0.month == m }
        return HStack(alignment: .top, spacing: 0) {
            // The month name, rotated 90° like the on-screen gutter — its cell carries top/bottom borders
            // and a vertical rule separating it from the track names.
            ZStack(alignment: .topLeading) {
                Text(MONTH_NAMES[m].lowercased())
                    .font(.system(size: 9, weight: .bold)).foregroundStyle(theme.text)
                    .fixedSize()
                    .rotationEffect(.degrees(-90))
                    .frame(width: monthLabelW, height: stripH)
                laneRulePath(width: monthLabelW, isLast: isLast, boundary: true).stroke(frameGray, lineWidth: 0.8)
                Path { p in
                    let x = monthLabelW - 0.4
                    p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: stripH))
                }
                .stroke(frameGray, lineWidth: 0.8)
            }
            .frame(width: monthLabelW, height: stripH, alignment: .topLeading)

            // Track names, with the lane rules running above and below each name.
            ZStack(alignment: .topLeading) {
                ForEach(0 ..< 4, id: \.self) { t in
                    Text(tracks.indices.contains(m) && tracks[m].indices.contains(t) ? tracks[m][t] : "")
                        .font(.system(size: 6)).foregroundStyle(theme.textMuted)
                        .lineLimit(1)
                        .frame(width: trackW - 6, height: laneH, alignment: .leading)
                        .offset(y: laneH * CGFloat(t))
                }
                laneRulePath(width: trackW, isLast: isLast, boundary: false).stroke(ruleGray, lineWidth: 0.8)
                laneRulePath(width: trackW, isLast: isLast, boundary: true).stroke(frameGray, lineWidth: 0.8)
            }
            .frame(width: trackW, height: stripH, alignment: .topLeading)

            // The day grid, stroked as explicit vector Paths on half-point centers (offset rectangles
            // proved unreliable — whole strips' rules could drop out of the render). Every month spans the
            // full 31 slots; days past the month's end get the app's dimmed 45°-hatch treatment.
            ZStack(alignment: .topLeading) {
                if dim < 31 {
                    let deadW = dayW * CGFloat(31 - dim)
                    ZStack(alignment: .topLeading) {
                        Rectangle().fill(theme.dimFill)
                        hatchPath(w: deadW, h: stripH)
                            .stroke(theme.accentGrey.opacity(0.5), lineWidth: 0.6)
                    }
                    .frame(width: deadW, height: stripH)
                    .clipped()
                    .offset(x: dayW * CGFloat(dim))
                }
                dayRulePath(dim: dim, stripH: stripH, boundary: false).stroke(ruleGray, lineWidth: 0.8)
                laneRulePath(width: dayW * 31, isLast: isLast, boundary: false).stroke(ruleGray, lineWidth: 0.8)
                dayRulePath(dim: dim, stripH: stripH, boundary: true).stroke(frameGray, lineWidth: 0.8)
                laneRulePath(width: dayW * 31, isLast: isLast, boundary: true).stroke(frameGray, lineWidth: 0.8)
                // Flat light-theme band bars (the app's Performance-Mode look; glass doesn't print),
                // inset slightly from the day-column borders on both sides.
                ForEach(monthBands, id: \.id) { b in
                    let x = CGFloat(b.startDay - 1) * dayW + 1
                    let w = max(dayW - 2, CGFloat(b.endDay - b.startDay + 1) * dayW - 2)
                    let y = laneH * CGFloat(max(0, min(3, b.track))) + 1.5
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2.5).fill(theme.eventFill(b.color))
                        RoundedRectangle(cornerRadius: 2.5).strokeBorder(theme.eventBorder(b.color), lineWidth: 0.8)
                        Rectangle().fill(theme.eventBorder(b.color)).frame(width: 1.6).padding(.vertical, 1.5)
                    }
                    .frame(width: w, height: laneH - 3)
                    .offset(x: x, y: y)
                }
                // Titles above the bars — NOT clipped to the bar: they run until the nearest LATER-STARTING
                // bar on the same lane (else the month's end), the on-screen year view's clipping rule.
                ForEach(monthBands, id: \.id) { b in
                    let x = CGFloat(b.startDay - 1) * dayW
                    let y = laneH * CGFloat(max(0, min(3, b.track))) + 1.5
                    let nextStart = monthBands
                        .filter { $0.track == b.track && $0.startDay > b.startDay }
                        .map(\.startDay).min()
                    let clipX = nextStart.map { CGFloat($0 - 1) * dayW } ?? CGFloat(dim) * dayW
                    Text(b.title)
                        .font(.custom("Comic Sans MS", size: 6.5))
                        .foregroundStyle(theme.text)
                        .lineLimit(1)
                        .frame(width: max(0, clipX - x - 7), height: laneH - 3, alignment: .leading)
                        .offset(x: x + 5, y: y) // bar inset (+1) + text lead-in (+4)
                }
            }
            .frame(width: gridW, height: stripH, alignment: .topLeading)
        }
        .frame(height: stripH)
    }
}
