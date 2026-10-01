// Attachment preview CARDS (docs/attachments-design.md §5.3–5.4): the composed NSImages the
// markdown preview embeds as attachment glyphs. Solitary block token → a content card
// min(480, column) wide; consecutive tokens → compact ~224×128 grid cells; unknown/missing →
// the 70pt metadata card. Full type breadth (P4): images (+GIF badge), .pdf (PDFKit first
// page), EVERY readable text file self-rendered via CodeHighlight (the §5.3 language map;
// QL can't thumbnail bare source at all), .csv/.tsv as a real table, Office/RTF/iWork as
// async Quick Look first-page cards (disk-cached, sentinel on decline) — only genuinely
// opaque types get the metadata card. Rasterized per (id, width, variant, theme) and cached.

import AppKit
import CalendarEngine
import CalendarRender
import os
import PDFKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// Drag/drop tracing for the attachment pipeline (`log stream --predicate 'subsystem ==
/// "dev.magnifical.calendar" AND category == "attach"'`) — every destination logs entered/
/// prepare/perform + import outcomes, so a failing drop names its dying hop.
let attachLog = Logger(subsystem: "dev.magnifical.calendar", category: "attach")

/// A scroll view that can go HIT-TEST-INERT: visible (the drawer blurs it as background) but
/// transparent to the mouse. SwiftUI content drawn OVER a hosted NSView never wins AppKit
/// hit-testing — with the event drawer open, the weekly note's preview swallowed the mouse
/// meant for the drawer's resize handle (and its attachment cards still hovered/clicked).
@MainActor class InertableScrollView: NSScrollView {
    var inert = false
    override func hitTest(_ point: NSPoint) -> NSView? {
        inert ? nil : super.hitTest(point)
    }
}

extension NSView {
    /// PARKED dashboard panels stay mounted at SwiftUI-opacity 0 for instant swipes — but
    /// SwiftUI's opacity/allowsHitTesting gating does NOT reach AppKit's drag-destination
    /// hit-test, so an invisible neighbor panel's editor could STEAL a drop (field-traced:
    /// a pdf dragged onto today's note imported into tomorrow's). Same layer-opacity walk
    /// DashRightClickLayer uses to keep parked panels from stealing right-clicks.
    var attachDropVisible: Bool {
        guard window != nil, !isHiddenOrHasHiddenAncestor else { return false }
        var l = layer
        while let cur = l {
            if cur.opacity < 0.01 {
                return false
            }
            l = cur.superlayer
        }
        return true
    }
}

/// The shared drag-over affordance (the .ics import overlay's language): a dimmed mask, an
/// accent dashed inner ring, and a centered ＋ over "Add Attachment". Drawn by the preview's
/// own draw pass AND the editor's margin-drop overlay view — one visual, two hosts.
@MainActor enum AttachmentDropOverlay {
    static func draw(in vis: NSRect) {
        NSColor(Theme.accent).withAlphaComponent(0.04).setFill()
        vis.fill()
        NSColor.windowBackgroundColor.withAlphaComponent(0.72).setFill()
        vis.fill()
        let ringRect = vis.insetBy(dx: 12, dy: 12)
        let ring = NSBezierPath(roundedRect: ringRect, xRadius: 14, yRadius: 14)
        ring.setLineDash([12, 8], count: 2, phase: 0)
        ring.lineWidth = 3
        NSColor(Theme.accent).withAlphaComponent(0.85).setStroke()
        ring.stroke()
        let accent = NSColor(Theme.accent)
        let plusAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 40, weight: .medium), .foregroundColor: accent,
        ]
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 17, weight: .semibold), .foregroundColor: accent,
        ]
        let plus = "+" as NSString
        let label = "Add Attachment" as NSString
        let plusSize = plus.size(withAttributes: plusAttrs)
        let labelSize = label.size(withAttributes: labelAttrs)
        let totalH = plusSize.height + 6 + labelSize.height
        let top = vis.midY - totalH / 2
        plus.draw(at: NSPoint(x: vis.midX - plusSize.width / 2, y: top), withAttributes: plusAttrs)
        label.draw(at: NSPoint(x: vis.midX - labelSize.width / 2, y: top + plusSize.height + 6),
                   withAttributes: labelAttrs)
    }
}

@MainActor enum AttachmentCards {
    // nonisolated: referenced from nonisolated default-argument position (MarkdownDoc.render).
    nonisolated static let solitaryMaxW: CGFloat = 480
    nonisolated static let gridCellW: CGFloat = 224
    nonisolated static let gridCellH: CGFloat = 128
    nonisolated static let metaH: CGFloat = 70
    private static let corner: CGFloat = 8

    /// Size-class caps for SOLITARY cards (`size:` token; height is the size's main effect).
    /// Rescaled 2026-09-21: big = the original default card, medium = the old small, and
    /// small is a genuinely small chip-like card (half medium's width, ~3/4 its height).
    nonisolated static func maxW(_ size: AttachmentSize) -> CGFloat {
        switch size {
        case .small: 170
        case .medium: 340
        case .big: solitaryMaxW // 480
        }
    }

    nonisolated static func maxH(_ size: AttachmentSize) -> CGFloat {
        switch size {
        case .small: 105
        case .medium: 140
        case .big: 240
        }
    }

    nonisolated static func textLines(_ size: AttachmentSize) -> Int {
        switch size {
        case .small: 3
        case .medium: 5
        case .big: 8
        }
    }

    private static let cache = NSCache<NSString, NSImage>()

    /// The composed card for one token. `width` = the target card width (already clamped by
    /// the caller); `compact` = grid-cell variant.
    static func card(for token: AttachmentToken, store: AttachmentStore, width: CGFloat,
                     compact: Bool, theme: Theme) -> NSImage {
        // The waiting card (blob not local yet — token synced before its NoteFile) and the
        // doc family's "rendering…" placeholder are NEVER cached: each must become the
        // content card the moment its pixels exist, and the cache key can't see arrival.
        guard store.url(forId: token.id) != nil else {
            return compose(token: token, store: store, width: width, compact: compact, theme: theme).img
        }
        let key = "\(token.id)|\(Int(width))|\(compact)|\(theme.dark)|\(token.size.rawValue)" as NSString
        if let hit = cache.object(forKey: key) {
            return hit
        }
        let (img, cacheable) = compose(token: token, store: store, width: width,
                                       compact: compact, theme: theme)
        if cacheable {
            cache.setObject(img, forKey: key)
        }
        return img
    }

    private static func compose(token: AttachmentToken, store: AttachmentStore, width: CGFloat,
                                compact: Bool, theme: Theme) -> (img: NSImage, cacheable: Bool) {
        guard let url = store.url(forId: token.id), let meta = store.meta(forId: token.id) else {
            return (metaCard(name: token.name, detail: "waiting for iCloud…",
                             icon: NSWorkspace.shared.icon(for: .data), width: width, theme: theme),
                    false)
        }
        let ext = (meta.name as NSString).pathExtension.lowercased()
        let family = AttachmentStore.kind(forUTI: meta.uti, name: meta.name)
        switch family {
        case .image:
            if let img = NSImage(contentsOf: url) {
                return (imageCard(img, badge: ext == "gif" ? "GIF" : nil, name: token.name,
                                  width: width, size: token.size, compact: compact, theme: theme),
                        true)
            }
        case .pdf:
            if let doc = PDFDocument(url: url), let page = doc.page(at: 0) {
                return (pdfCard(page, pages: doc.pageCount, name: token.name, bytes: meta.bytes,
                                width: width, size: token.size, compact: compact, theme: theme),
                        true)
            }
        case .code, .data:
            // P4 full breadth: EVERY readable text file gets a content card — known
            // extensions syntax-colored, csv/tsv as a real table, the rest plain mono.
            if ["csv", "tsv"].contains(ext), let text = textPrefix(of: url) {
                return (tableCard(text, tab: ext == "tsv", name: token.name, bytes: meta.bytes,
                                  width: width, size: token.size, compact: compact, theme: theme),
                        true)
            }
            if let text = textPrefix(of: url) {
                return (textCard(text, ext: ext, name: token.name, bytes: meta.bytes,
                                 width: width, size: token.size, compact: compact, theme: theme),
                        true)
            }
        case .doc:
            // Office/RTF/iWork: a real first-page card via Quick Look (§5.5 verified the
            // system renders genuine pages even without Office installed). Async on first
            // sight — placeholder now, thumb lands on disk, the arrival bump repaints.
            switch docThumb(url: url, token: token, store: store, width: width, compact: compact) {
            case let .ready(page):
                return (pageCard(page, name: token.name, bytes: meta.bytes, width: width,
                                 size: token.size, compact: compact, theme: theme), true)
            case .rendering:
                return (metaCard(name: token.name, detail: "rendering preview…",
                                 icon: NSWorkspace.shared.icon(for: UTType(meta.uti) ?? .data),
                                 width: width, theme: theme), false)
            case .unavailable:
                break // QL declined (icon-only/failed) → the metadata card, permanently
            }
        case .file:
            // Unknown TEXT types (UTI-decided: .ini, .log, …) still get a plain-mono content
            // card — "never just an icon" (§5.3). Opaque binaries fall through.
            if UTType(meta.uti)?.conforms(to: .text) == true, let text = textPrefix(of: url) {
                return (textCard(text, ext: ext, name: token.name, bytes: meta.bytes,
                                 width: width, size: token.size, compact: compact, theme: theme),
                        true)
            }
        }
        return (metaCard(name: token.name, detail: detailLine(meta),
                         icon: NSWorkspace.shared.icon(for: UTType(meta.uti) ?? .data),
                         width: width, theme: theme),
                true)
    }

    /// Extension → CodeHighlight language (§5.3's full map). Absent = plain monospace.
    private static let codeLang: [String: String] = [
        "js": "js", "jsx": "js", "json": "js", "ts": "ts", "tsx": "ts",
        "c": "c", "h": "c", "cpp": "cpp", "hpp": "cpp",
        "rs": "rust", "go": "go", "py": "python", "jl": "julia", "swift": "swift",
        "java": "java", "kt": "kotlin", "rb": "ruby", "sh": "shell", "sql": "sql",
        "tex": "tex", "css": "css", "xml": "xml", "html": "xml", "htm": "xml",
        "yaml": "yaml", "yml": "yaml", "toml": "toml",
    ]

    // ── Card bodies ───────────────────────────────────────────────────────────────────

    private static func imageCard(_ img: NSImage, badge: String?, name: String, width: CGFloat,
                                  size cardSize: AttachmentSize, compact: Bool, theme: Theme) -> NSImage {
        let px = img.size
        guard px.width > 0, px.height > 0 else {
            return metaCard(name: name, detail: "unreadable image",
                            icon: NSWorkspace.shared.icon(for: .image), width: width, theme: theme)
        }
        let size: NSSize
        if compact {
            size = NSSize(width: gridCellW, height: gridCellH)
        } else {
            let scale = min(width / px.width, maxH(cardSize) / px.height, 1)
            size = NSSize(width: max(90, px.width * scale), height: max(60, px.height * scale))
        }
        return draw(size: size, theme: theme) { rect in
            let clip = NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner)
            clip.addClip()
            if compact {
                // aspect-FILL the fixed cell
                let s = max(rect.width / px.width, rect.height / px.height)
                let w = px.width * s, h = px.height * s
                img.draw(in: NSRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h))
                captionBar(name, in: rect, theme: theme)
            } else {
                img.draw(in: rect)
            }
            if let badge {
                badgePill(badge, in: rect, theme: theme)
            }
        }
    }

    private static func pdfCard(_ page: PDFPage, pages: Int, name: String, bytes: Int,
                                width: CGFloat, size cardSize: AttachmentSize, compact: Bool,
                                theme: Theme) -> NSImage {
        let footerH: CGFloat = compact ? 24 : 28
        let bounds = page.bounds(for: .mediaBox)
        let aspect = bounds.height > 0 ? bounds.width / bounds.height : 0.77
        let size: NSSize
        if compact {
            size = NSSize(width: gridCellW, height: gridCellH)
        } else {
            let pageH = min(maxH(cardSize), width / max(aspect, 0.1))
            size = NSSize(width: width, height: pageH + footerH)
        }
        let thumbW = size.width
        let thumb = page.thumbnail(of: NSSize(width: thumbW * 2, height: thumbW * 2 / max(aspect, 0.1)),
                                   for: .mediaBox)
        return draw(size: size, theme: theme) { rect in
            NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner).addClip()
            NSColor.white.setFill() // a PDF page is a page — white ground in both themes
            rect.fill()
            let pageRect = NSRect(x: 0, y: footerH, width: rect.width, height: rect.height - footerH)
            // top-align the page (crop the bottom when the card is shorter than the page)
            let h = pageRect.width / max(aspect, 0.1)
            thumb.draw(in: NSRect(x: 0, y: pageRect.maxY - h, width: pageRect.width, height: h))
            footerBar("\(name) · \(pages) page\(pages == 1 ? "" : "s") · \(fmtBytes(bytes))",
                      icon: "doc.richtext", height: footerH, in: rect, theme: theme)
        }
    }

    private static func textCard(_ text: String, ext: String, name: String, bytes: Int,
                                 width: CGFloat, size cardSize: AttachmentSize, compact: Bool,
                                 theme: Theme) -> NSImage {
        let headerH: CGFloat = compact ? 24 : 28
        let lineCount = compact ? 4 : textLines(cardSize)
        let font = NSFont(name: "Menlo", size: compact ? 9 : 11)
            ?? NSFont.monospacedSystemFont(ofSize: compact ? 9 : 11, weight: .regular)
        let lines = text.components(separatedBy: "\n").prefix(lineCount).joined(separator: "\n")
        let body: NSAttributedString = {
            if let lang = codeLang[ext] {
                return CodeHighlight.highlight(lines, lang: lang, base: NSColor(theme.text), font: font)
            }
            return NSAttributedString(string: lines, attributes: [
                .font: font, .foregroundColor: NSColor(theme.text).withAlphaComponent(0.9),
            ])
        }()
        let lineH = (font.ascender - font.descender + font.leading) * 1.25
        let size = compact ? NSSize(width: gridCellW, height: gridCellH)
            : NSSize(width: width, height: headerH + CGFloat(min(lineCount, max(1, text.components(separatedBy: "\n").count))) * lineH + 18)
        return draw(size: size, theme: theme) { rect in
            NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner).addClip()
            NSColor(theme.text).withAlphaComponent(0.045).setFill() // the code-fence wash
            rect.fill()
            body.draw(in: NSRect(x: 10, y: 8, width: rect.width - 20,
                                 height: rect.height - headerH - 12))
            footerBar("\(name) · \(langLabel(ext)) · \(fmtBytes(bytes))", icon: "chevron.left.forwardslash.chevron.right",
                      height: headerH, in: rect, atTop: true, theme: theme)
        }
    }

    /// CSV/TSV: the first rows drawn as an actual table — header row emphasized, hairline
    /// separators. Naive split (quoted commas aren't parsed); the card is a preview, the
    /// file opens real apps.
    private static func tableCard(_ text: String, tab: Bool, name: String, bytes: Int,
                                  width: CGFloat, size cardSize: AttachmentSize, compact: Bool,
                                  theme: Theme) -> NSImage {
        let footerH: CGFloat = compact ? 24 : 28
        let maxRows = compact ? 4 : min(6, textLines(cardSize))
        let maxCols = compact ? 3 : 4
        let rows = text.components(separatedBy: "\n").prefix(maxRows).map { line in
            line.split(separator: tab ? "\t" : ",", omittingEmptySubsequences: false)
                .prefix(maxCols).map { $0.trimmingCharacters(in: .whitespaces) }
        }.filter { !$0.isEmpty }
        guard !rows.isEmpty else {
            return metaCard(name: name, detail: "empty file",
                            icon: NSWorkspace.shared.icon(for: .commaSeparatedText),
                            width: width, theme: theme)
        }
        let cols = rows.map(\.count).max() ?? 1
        let rowH: CGFloat = compact ? 18 : 22
        let size = compact ? NSSize(width: gridCellW, height: gridCellH)
            : NSSize(width: width, height: CGFloat(rows.count) * rowH + footerH + 10)
        return draw(size: size, theme: theme) { rect in
            NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner).addClip()
            NSColor(theme.text).withAlphaComponent(0.045).setFill()
            rect.fill()
            let table = NSRect(x: 8, y: 6, width: rect.width - 16,
                               height: rect.height - footerH - 10)
            let colW = table.width / CGFloat(cols)
            let line = NSColor(theme.text).withAlphaComponent(0.14)
            for (r, cells) in rows.enumerated() {
                let y = table.maxY - CGFloat(r + 1) * rowH
                guard y >= table.minY - 1 else { break }
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: compact ? 9 : 10.5,
                                             weight: r == 0 ? .semibold : .regular),
                    .foregroundColor: NSColor(theme.text)
                        .withAlphaComponent(r == 0 ? 0.95 : 0.75),
                ]
                for (c, cell) in cells.enumerated() {
                    let x = table.minX + CGFloat(c) * colW
                    (truncate(cell, width: colW - 12, attrs: attrs) as NSString)
                        .draw(at: NSPoint(x: x + 4, y: y + (rowH - 14) / 2), withAttributes: attrs)
                }
                if r > 0 { // hairline above every data row
                    line.setFill()
                    NSRect(x: table.minX, y: y + rowH - 0.5, width: table.width, height: 0.5).fill()
                }
            }
            for c in 1 ..< cols {
                line.setFill()
                NSRect(x: table.minX + CGFloat(c) * colW, y: table.minY,
                       width: 0.5, height: table.height).fill()
            }
            footerBar("\(name) · \(tab ? "TSV" : "CSV") · \(fmtBytes(bytes))",
                      icon: "tablecells", height: footerH, in: rect, atTop: true, theme: theme)
        }
    }

    // ── Doc family: Quick Look first-page thumbs (async, disk-cached) ────────────────

    private enum DocThumb {
        case ready(NSImage)
        case rendering
        case unavailable
    }

    /// Thumbs live at `files/thumbs/<hash>@<width>.png` (content-addressed → immutable;
    /// removed with the blob). A `.noThumb` sentinel remembers QL declining, so a file the
    /// system can't page-render costs exactly one attempt, ever. Pages are theme-neutral
    /// rasters — no theme in the key.
    private static var thumbsInFlight: Set<String> = []

    private static func docThumb(url: URL, token: AttachmentToken, store: AttachmentStore,
                                 width: CGFloat, compact: Bool) -> DocThumb {
        guard let hash = store.resolveHash(forId: token.id) else { return .unavailable }
        let w = Int(compact ? gridCellW : width)
        let stem = "\(hash)@\(w)"
        let thumbURL = store.thumbsDir.appendingPathComponent("\(stem).png")
        let sentinel = store.thumbsDir.appendingPathComponent("\(stem).noThumb")
        if let img = NSImage(contentsOf: thumbURL) {
            return .ready(img)
        }
        if FileManager.default.fileExists(atPath: sentinel.path) {
            return .unavailable
        }
        if !thumbsInFlight.contains(stem) {
            thumbsInFlight.insert(stem)
            let req = QLThumbnailGenerator.Request(
                fileAt: url, size: CGSize(width: CGFloat(w), height: CGFloat(w) * 1.4),
                scale: 2, representationTypes: .thumbnail // .thumbnail ONLY: an icon-only
            ) //                                             answer arrives as an error, §5.5
            QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { rep, err in
                Task { @MainActor in
                    thumbsInFlight.remove(stem)
                    try? FileManager.default.createDirectory(at: store.thumbsDir,
                                                             withIntermediateDirectories: true)
                    if let cg = rep?.cgImage,
                       let png = NSBitmapImageRep(cgImage: cg)
                       .representation(using: .png, properties: [:]) {
                        try? png.write(to: thumbURL)
                    } else {
                        attachLog.notice("""
                        doc thumb declined for \(token.name, privacy: .public): \
                        \(err.map { "\($0)" } ?? "nil rep", privacy: .public)
                        """)
                        try? Data().write(to: sentinel)
                    }
                    // Repaint: generation is IN the preview's rebuild key (without the bump
                    // the placeholder never recomposes), attachmentsDidArrive is the wake
                    // that makes SwiftUI re-evaluate the hosting views at all.
                    store.thumbsDidChange()
                    CalendarEngine.mainInstance?.attachmentsDidArrive()
                }
            }
        }
        return .rendering
    }

    /// A rendered first page + footer — the pdf card's shape, fed by a QL raster.
    private static func pageCard(_ page: NSImage, name: String, bytes: Int, width: CGFloat,
                                 size cardSize: AttachmentSize, compact: Bool,
                                 theme: Theme) -> NSImage {
        let footerH: CGFloat = compact ? 24 : 28
        let px = page.size
        let aspect = px.height > 0 ? px.width / px.height : 0.77
        let size: NSSize
        if compact {
            size = NSSize(width: gridCellW, height: gridCellH)
        } else {
            let pageH = min(maxH(cardSize), width / max(aspect, 0.1))
            size = NSSize(width: width, height: pageH + footerH)
        }
        return draw(size: size, theme: theme) { rect in
            NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner).addClip()
            NSColor.white.setFill() // a document page is a page — white ground in both themes
            rect.fill()
            let pageRect = NSRect(x: 0, y: footerH, width: rect.width, height: rect.height - footerH)
            let h = pageRect.width / max(aspect, 0.1)
            page.draw(in: NSRect(x: 0, y: pageRect.maxY - h, width: pageRect.width, height: h))
            footerBar("\(name) · \(fmtBytes(bytes))", icon: "doc.text",
                      height: footerH, in: rect, theme: theme)
        }
    }

    private static func metaCard(name: String, detail: String, icon: NSImage, width: CGFloat,
                                 theme: Theme) -> NSImage {
        draw(size: NSSize(width: width, height: metaH), theme: theme) { rect in
            NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner).addClip()
            NSColor(theme.text).withAlphaComponent(0.045).setFill()
            rect.fill()
            icon.draw(in: NSRect(x: 12, y: rect.midY - 22, width: 44, height: 44))
            let nameAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: NSColor(theme.text),
            ]
            let detailAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor(theme.text).withAlphaComponent(0.55),
            ]
            let textX: CGFloat = 68
            (name as NSString).draw(in: NSRect(x: textX, y: rect.midY + 2,
                                               width: rect.width - textX - 10, height: 18),
                                    withAttributes: nameAttrs)
            (detail as NSString).draw(in: NSRect(x: textX, y: rect.midY - 18,
                                                 width: rect.width - textX - 10, height: 16),
                                      withAttributes: detailAttrs)
        }
    }

    // ── Shared chrome ─────────────────────────────────────────────────────────────────

    /// Rasterize at 2x with a hairline border — the shared card ground.
    private static func draw(size: NSSize, theme: Theme,
                             _ body: @escaping (NSRect) -> Void) -> NSImage {
        let img = NSImage(size: size, flipped: false) { rect in
            body(rect)
            NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                         xRadius: corner, yRadius: corner).setClip()
            NSColor(theme.text).withAlphaComponent(0.22).setStroke()
            let border = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                                      xRadius: corner, yRadius: corner)
            border.lineWidth = 1
            border.stroke()
            return true
        }
        return img
    }

    private static func footerBar(_ text: String, icon: String, height: CGFloat, in rect: NSRect,
                                  atTop: Bool = false, theme: Theme) -> Void {
        let bar = NSRect(x: rect.minX, y: atTop ? rect.maxY - height : rect.minY,
                         width: rect.width, height: height)
        (theme.dark ? NSColor.black : NSColor.white).withAlphaComponent(0.75).setFill()
        bar.fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .medium),
            .foregroundColor: NSColor(theme.text).withAlphaComponent(0.8),
        ]
        var x = bar.minX + 9
        if let sym = NSImage(systemSymbolName: icon, accessibilityDescription: nil) {
            let side: CGFloat = 12
            sym.draw(in: NSRect(x: x, y: bar.midY - side / 2, width: side, height: side))
            x += side + 5
        }
        (truncate(text, width: bar.width - x - 8, attrs: attrs) as NSString)
            .draw(at: NSPoint(x: x, y: bar.midY - 7), withAttributes: attrs)
    }

    private static func captionBar(_ name: String, in rect: NSRect, theme: Theme) {
        footerBar(name, icon: "photo", height: 22, in: rect, theme: theme)
    }

    private static func badgePill(_ label: String, in rect: NSRect, theme: Theme) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        let w = (label as NSString).size(withAttributes: attrs).width + 12
        let pill = NSRect(x: rect.maxX - w - 8, y: rect.maxY - 24, width: w, height: 16)
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 8, yRadius: 8).fill()
        (label as NSString).draw(at: NSPoint(x: pill.minX + 6, y: pill.minY + 2),
                                 withAttributes: attrs)
    }

    // ── Helpers ───────────────────────────────────────────────────────────────────────

    private static func textPrefix(of url: URL, cap: Int = 65536) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let data = try? handle.read(upToCount: cap) else { return nil }
        try? handle.close()
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    private static func langLabel(_ ext: String) -> String {
        ["js": "JavaScript", "jsx": "JavaScript", "ts": "TypeScript", "tsx": "TypeScript",
         "c": "C", "h": "C", "cpp": "C++", "hpp": "C++", "rs": "Rust", "go": "Go",
         "py": "Python", "jl": "Julia", "swift": "Swift", "java": "Java", "kt": "Kotlin",
         "rb": "Ruby", "sh": "Shell", "sql": "SQL", "tex": "LaTeX", "css": "CSS",
         "html": "HTML", "htm": "HTML", "json": "JSON", "md": "Markdown", "txt": "Text"][ext]
            ?? ext.uppercased()
    }

    private static func detailLine(_ meta: AttachmentMeta) -> String {
        let type = UTType(meta.uti)?.localizedDescription
            ?? (meta.name as NSString).pathExtension.uppercased()
        return "\(type) · \(fmtBytes(meta.bytes))"
    }

    static func fmtBytes(_ n: Int) -> String {
        n < 1000 ? "\(n) B"
            : n < 1_000_000 ? String(format: "%.0f KB", Double(n) / 1000)
            : String(format: "%.1f MB", Double(n) / 1_000_000)
    }

    private static func truncate(_ s: String, width: CGFloat,
                                 attrs: [NSAttributedString.Key: Any]) -> String {
        var t = s
        while (t as NSString).size(withAttributes: attrs).width > width, t.count > 4 {
            t = String(t.dropLast(4)) + "…"
        }
        return t
    }
}
