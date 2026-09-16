// Attachment preview CARDS (docs/attachments-design.md §5.3–5.4, P0): the composed NSImages
// the markdown preview embeds as attachment glyphs. Solitary block token → a content card
// min(480, column) wide; consecutive tokens → compact ~224×150 grid cells; unknown/missing →
// the 70pt metadata card. P0 starter set: images (+GIF badge), .pdf (PDFKit first page),
// simple text (.txt .json .md .js .c) self-rendered via CodeHighlight — everything else gets
// the metadata card until P4. Cards are rasterized per (id, width, variant, theme) and cached.

import AppKit
import CalendarEngine
import CalendarRender
import PDFKit
import UniformTypeIdentifiers

@MainActor enum AttachmentCards {
    // nonisolated: referenced from nonisolated default-argument position (MarkdownDoc.render).
    nonisolated static let solitaryMaxW: CGFloat = 480
    nonisolated static let gridCellW: CGFloat = 224
    nonisolated static let gridCellH: CGFloat = 128
    nonisolated static let metaH: CGFloat = 70
    private static let imageMaxH: CGFloat = 240
    private static let corner: CGFloat = 8

    private static let cache = NSCache<NSString, NSImage>()

    /// The composed card for one token. `width` = the target card width (already clamped by
    /// the caller); `compact` = grid-cell variant.
    static func card(for token: AttachmentToken, store: AttachmentStore, width: CGFloat,
                     compact: Bool, theme: Theme) -> NSImage {
        let key = "\(token.id)|\(Int(width))|\(compact)|\(theme.dark)" as NSString
        if let hit = cache.object(forKey: key) {
            return hit
        }
        let img = compose(token: token, store: store, width: width, compact: compact, theme: theme)
        cache.setObject(img, forKey: key)
        return img
    }

    private static func compose(token: AttachmentToken, store: AttachmentStore, width: CGFloat,
                                compact: Bool, theme: Theme) -> NSImage {
        guard let url = store.url(forId: token.id), let meta = store.meta(forId: token.id) else {
            return metaCard(name: token.name, detail: "missing — not on this Mac yet",
                            icon: NSWorkspace.shared.icon(for: .data), width: width, theme: theme)
        }
        let ext = (meta.name as NSString).pathExtension.lowercased()
        let family = AttachmentStore.kind(forUTI: meta.uti, name: meta.name)
        switch family {
        case .image:
            if let img = NSImage(contentsOf: url) {
                return imageCard(img, badge: ext == "gif" ? "GIF" : nil, name: token.name,
                                 width: width, compact: compact, theme: theme)
            }
        case .pdf:
            if let doc = PDFDocument(url: url), let page = doc.page(at: 0) {
                return pdfCard(page, pages: doc.pageCount, name: token.name, bytes: meta.bytes,
                               width: width, compact: compact, theme: theme)
            }
        case .code, .data:
            if Self.starterTextExts.contains(ext),
               let text = textPrefix(of: url) {
                return textCard(text, ext: ext, name: token.name, bytes: meta.bytes,
                                width: width, compact: compact, theme: theme)
            }
        case .doc, .file:
            break // P4 upgrades doc to a QL page card; P0 metadata card below
        }
        return metaCard(name: token.name, detail: detailLine(meta),
                        icon: NSWorkspace.shared.icon(for: UTType(meta.uti) ?? .data),
                        width: width, theme: theme)
    }

    /// P0 starter set for self-rendered text cards (design §10 P0).
    private static let starterTextExts: Set<String> = ["txt", "json", "md", "js", "c"]
    private static let codeLang: [String: String] = ["js": "js", "c": "c", "json": "js"]

    // ── Card bodies ───────────────────────────────────────────────────────────────────

    private static func imageCard(_ img: NSImage, badge: String?, name: String, width: CGFloat,
                                  compact: Bool, theme: Theme) -> NSImage {
        let px = img.size
        guard px.width > 0, px.height > 0 else {
            return metaCard(name: name, detail: "unreadable image",
                            icon: NSWorkspace.shared.icon(for: .image), width: width, theme: theme)
        }
        let size: NSSize
        if compact {
            size = NSSize(width: gridCellW, height: gridCellH)
        } else {
            let scale = min(width / px.width, imageMaxH / px.height, 1)
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
                                width: CGFloat, compact: Bool, theme: Theme) -> NSImage {
        let footerH: CGFloat = compact ? 24 : 28
        let bounds = page.bounds(for: .mediaBox)
        let aspect = bounds.height > 0 ? bounds.width / bounds.height : 0.77
        let size: NSSize
        if compact {
            size = NSSize(width: gridCellW, height: gridCellH)
        } else {
            let pageH = min(imageMaxH, width / max(aspect, 0.1))
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
                                 width: CGFloat, compact: Bool, theme: Theme) -> NSImage {
        let headerH: CGFloat = compact ? 24 : 28
        let lineCount = compact ? 4 : 8
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
        ["js": "JavaScript", "c": "C", "json": "JSON", "md": "Markdown", "txt": "Text"][ext]
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
