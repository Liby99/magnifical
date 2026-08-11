// The refined markdown PREVIEW engine (user spec): ONE selectable NSTextView document — so the
// whole rendered note can be dragged over and copied like a page, which no SwiftUI Text stack
// can do — with bigger type, breathing room, accent links, padded quote blocks, GFM tables
// (NSTextTable), and syntax-highlighted code fences for the house languages (c, c++, rust, py,
// js, ts, ocaml, lean, haskell, java, julia). Interactivity is preserved: todo checkboxes are
// tappable attachments (cc-todo:// links), and ⌘-click anywhere jumps to the source line.
// UTF-8 is native throughout (NSAttributedString).

import AppKit
import CalendarEngine
import CalendarRender
import SwiftUI

struct MarkdownPreview: NSViewRepresentable {
    let text: String
    let theme: Theme
    /// See NativeNoteEditor.active — parked tabs must HIDE the AppKit view (cursor rects).
    var active = true
    var onToggle: ((Int) -> Void)? // 1-based source line of a tapped todo checkbox
    var onLineEdit: ((Int) -> Void)? // ⌘-click → edit at this source line

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let tv = PreviewTextView()
        tv.isEditable = false
        tv.isSelectable = true // the whole document selects/copies like a page
        tv.drawsBackground = false
        // Flush left: zero container inset + zero fragment padding (default 5!) so the text's
        // left edge sits exactly on the panel edge the dashboard headers align to. Block
        // washes still start at x=0 (their glyphs are inset by the blocks' own padding).
        tv.textContainerInset = NSSize(width: 0, height: 6)
        tv.textContainer?.lineFragmentPadding = 0
        tv.autoresizingMask = [.width]
        tv.isVerticallyResizable = true
        tv.textContainer?.widthTracksTextView = true
        tv.linkTextAttributes = [.cursor: NSCursor.pointingHand] // colors are ours (accent)
        tv.selectedTextAttributes = [ // accent selection, like the editor — not system blue
            .backgroundColor: NSColor(Theme.accent).withAlphaComponent(0.24),
        ]
        tv.delegate = context.coordinator
        context.coordinator.textView = tv
        let scroll = NSScrollView()
        scroll.documentView = tv
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        context.coordinator.rebuild(self)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        scroll.isHidden = !active // parked tab: dormant cursor rects (see `active`)
        context.coordinator.rebuild(self)
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownPreview
        weak var textView: PreviewTextView?
        private var renderedKey = "\u{0}"
        private var sweep: TodoSweep? // in-flight strikethrough sweep (one at a time)

        init(_ parent: MarkdownPreview) {
            self.parent = parent
        }

        func rebuild(_ p: MarkdownPreview) {
            parent = p
            guard let tv = textView else { return }
            let key = p.text + "|" + NSColor(p.theme.text).description
            guard key != renderedKey else { return }
            renderedKey = key
            let doc = NativeDash.diagTime("MarkdownDoc.render(\(p.text.count)ch)") {
                MarkdownDoc.render(p.text, theme: p.theme, interactive: p.onToggle != nil)
            }
            // A checkbox toggle's own re-render arrives WHILE its strike sweep animates: stash
            // it and let the sweep finish over the old content — the panels' two-copy mask
            // trick, phrased as "animate the old presentation, land the new one at the end".
            // Anything else mid-sweep (day switch, external edit) also just lands 0.26s late.
            if let sweep, sweep.active {
                sweep.pendingApply = { [weak self] in self?.apply(doc) }
                return
            }
            apply(doc)
        }

        private func apply(_ doc: MarkdownDoc.Rendered) {
            guard let tv = textView else { return }
            tv.lineMap = doc.lineMap
            tv.decor = doc.decor
            let base = NSColor(parent.theme.text)
            tv.codeBG = base.withAlphaComponent(0.055)
            tv.quoteBG = base.withAlphaComponent(0.035)
            tv.quoteBar = NSColor(Theme.accent).withAlphaComponent(0.55)
            tv.ruleColor = NSColor(parent.theme.accentGrey).withAlphaComponent(0.6)
            tv.managedBar = NSColor(Theme.accent).withAlphaComponent(0.55)
            tv.onCmdClickLine = parent.onLineEdit
            tv.textStorage?.setAttributedString(doc.string)
            tv.needsDisplay = true
        }

        func textView(_ tv: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url = link as? URL ?? (link as? String).flatMap(URL.init(string:))
            guard let url else { return false }
            if url.scheme == "cc-todo", let line = Int(url.host ?? "") {
                startSweep(line: line, clickIndex: charIndex)
                parent.onToggle?(line)
                return true
            }
            return false // real links → AppKit opens them
        }

        /// The panels' 0.26s check/uncheck sweep (NativeDashPanel.animatedTitle), phrased for a
        /// single NSTextView document: the checkbox attachment flips INSTANTLY (DashCheckbox
        /// animates instantly too), then a character front sweeps the struck+dimmed
        /// presentation across the line — left→right on check, retreating right→left on
        /// uncheck — and the toggle's real re-render (done: pill etc.) lands when the front
        /// settles. Attribute-only per frame: characters, selection, and layout are untouched.
        private func startSweep(line: Int, clickIndex: Int) {
            guard let tv = textView, let storage = tv.textStorage else { return }
            if let old = sweep {
                old.finishNow()
            } // a second click mid-sweep: land the first
            // Direction from the SOURCE line (1-based): "[x]" → currently done → unchecking.
            let src = parent.text.components(separatedBy: "\n")
            guard line >= 1, line <= src.count else { return }
            let checking = !(src[line - 1].contains("[x]") || src[line - 1].contains("[X]"))
            guard let range = tv.lineMap.first(where: { $0.line == line
                    && NSLocationInRange(clickIndex, $0.range)
            })?.range
                ?? tv.lineMap.first(where: { $0.line == line })?.range,
                NSMaxRange(range) <= storage.length else { return }
            // Flip the checkbox image in place (the attachment character survives the sweep).
            let base = NSColor(parent.theme.text)
            let accent = NSColor(Theme.accent)
            storage.enumerateAttribute(.attachment, in: range) { value, r, _ in
                guard let att = value as? NSTextAttachment,
                      let link = storage.attribute(.link, at: r.location, effectiveRange: nil)
                      as? URL, link.scheme == "cc-todo" else { return }
                att.image = MarkdownDoc.checkboxImage(checked: checking, accent: accent,
                                                      grey: base.withAlphaComponent(0.45))
                tv.layoutManager?.invalidateDisplay(forCharacterRange: r)
            }
            sweep = TodoSweep(storage: storage, range: range, checking: checking) {
                [weak self] in self?.sweep = nil
            }
        }
    }
}

/// One in-flight checkbox strike sweep over a preview line: drives a character front at 60Hz
/// for 0.26s (the panels' easeInOut), applying/removing the struck+dimmed attributes derived
/// fresh from a base snapshot each tick (no cumulative dimming). Attachment runs (the checkbox,
/// token pills) are skipped — images can't strike; the final re-render restyles them.
@MainActor private final class TodoSweep {
    private let storage: NSTextStorage
    private let range: NSRange
    private let checking: Bool
    private let baseLine: NSAttributedString // pre-sweep attributes, ground truth per tick
    private let start = Date()
    private var timer: Timer?
    private let onDone: () -> Void
    var pendingApply: (() -> Void)?
    var active: Bool {
        timer != nil
    }

    private static let duration = 0.26 // NativeDashPanel's sweep duration

    init(storage: NSTextStorage, range: NSRange, checking: Bool,
         onDone: @escaping () -> Void) {
        self.storage = storage
        self.range = range
        self.checking = checking
        baseLine = storage.attributedSubstring(from: range)
        self.onDone = onDone
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        let p = min(1, Date().timeIntervalSince(start) / Self.duration)
        let e = p < 0.5 ? 2 * p * p : 1 - pow(-2 * p + 2, 2) / 2 // easeInOut
        // The struck region is the LEADING `strike` fraction (mask semantics of the panels):
        // checking grows it 0→1 (front moves right); unchecking shrinks it 1→0 (front retreats).
        let strike = checking ? e : 1 - e
        applyFront(struckChars: Int((Double(range.length) * strike).rounded()))
        if p >= 1 {
            finishNow()
        }
    }

    /// Land the end state immediately: stop the timer and apply the stashed re-render (or the
    /// final frame's attributes when no re-render arrived).
    func finishNow() {
        guard timer != nil else { return }
        timer?.invalidate()
        timer = nil
        if let apply = pendingApply {
            apply()
        } else {
            applyFront(struckChars: checking ? range.length : 0)
        }
        onDone()
    }

    private func applyFront(struckChars: Int) {
        guard NSMaxRange(range) <= storage.length else { finishNow(); return }
        let split = range.location + max(0, min(range.length, struckChars))
        storage.beginEditing()
        baseLine.enumerateAttributes(in: NSRange(location: 0, length: baseLine.length)) {
            attrs, r, _ in
            let abs = NSRange(location: range.location + r.location, length: r.length)
            if attrs[.attachment] != nil { // checkbox/pills: images don't strike or dim here
                storage.setAttributes(attrs, range: abs)
                return
            }
            // Both presentations derive from the base run, so the sweep is symmetric: behind
            // the front the run is struck + dimmed; ahead of it, un-struck at full strength.
            // (For a CHECK the base is already plain; for an UNCHECK it's already struck — the
            // transforms are absolute, not deltas, so either base lands on the same two looks.)
            var struck = attrs
            if let c = struck[.foregroundColor] as? NSColor {
                struck[.foregroundColor] = c.withAlphaComponent(0.45)
            }
            struck[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            var plain = attrs
            if let c = plain[.foregroundColor] as? NSColor {
                plain[.foregroundColor] = c.withAlphaComponent(1)
            }
            plain[.strikethroughStyle] = nil
            let struckLen = max(0, min(abs.length, split - abs.location))
            if struckLen > 0 {
                storage.setAttributes(struck, range: NSRange(location: abs.location,
                                                             length: struckLen))
            }
            if struckLen < abs.length {
                storage.setAttributes(plain, range: NSRange(location: abs.location + struckLen,
                                                            length: abs.length - struckLen))
            }
        }
        storage.endEditing()
    }
}

/// ⌘-click → source line (via the renderer's line map); plain clicks select as usual.
/// Also draws the ROUNDED code/quote washes (NSTextBlock can only paint rectangles): the
/// renderer hands over decoration ranges; each is unioned from its line fragments, outset by
/// the block padding, and painted under the text — code with all corners rounded, quotes with
/// the RIGHT corners rounded plus the accent bar down the square left edge.
final class PreviewTextView: NSTextView {
    var lineMap: [(range: NSRange, line: Int)] = []
    var onCmdClickLine: ((Int) -> Void)?
    var decor: [(range: NSRange, kind: MarkdownDoc.DecorKind)] = []
    var codeBG: NSColor = .black.withAlphaComponent(0.055)
    var quoteBG: NSColor = .black.withAlphaComponent(0.035)
    var quoteBar: NSColor = .systemRed
    var ruleColor: NSColor = .separatorColor // markdown --- / === divider lines
    var managedBar: NSColor = .systemRed // imported managed-block left border (accent 55%)

    override func draw(_ dirtyRect: NSRect) {
        if let lm = layoutManager, textContainer != nil {
            let origin = textContainerOrigin
            for d in decor {
                let gr = lm.glyphRange(forCharacterRange: d.range, actualCharacterRange: nil)
                guard gr.length > 0 else { continue }
                var union = NSRect.null
                lm.enumerateLineFragments(forGlyphRange: gr) { frag, _, _, _, _ in
                    union = union.union(frag)
                }
                guard !union.isNull else { continue }
                var r = union.offsetBy(dx: origin.x, dy: origin.y)
                switch d.kind {
                case .code:
                    r = NSRect(x: r.minX - 11, y: r.minY - 8,
                               width: min(r.width + 22, bounds.width - r.minX + 7), height: r.height + 16)
                    codeBG.setFill()
                    NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8).fill()
                case .quote:
                    r = NSRect(x: r.minX - 14, y: r.minY - 8,
                               width: min(r.width + 24, bounds.width - r.minX + 7), height: r.height + 16)
                    quoteBG.setFill()
                    rightRounded(r, radius: 7).fill()
                    quoteBar.setFill()
                    NSRect(x: r.minX, y: r.minY, width: 3, height: r.height).fill()
                case .rule:
                    // The web's hr: a 1px accent-grey line across the pane.
                    ruleColor.setFill()
                    NSRect(x: r.minX, y: r.midY - 0.5,
                           width: max(0, bounds.width - r.minX - 6), height: 1).fill()
                case .managed:
                    // Imported "managed block" (the web drawer's .cc-dw-mi): a 2px accent bar
                    // down the region's left edge — content is indented past it by the
                    // renderer (indentManaged / the field table's cell padding).
                    managedBar.setFill()
                    NSBezierPath(roundedRect: NSRect(x: 1, y: r.minY - 2, width: 2,
                                                     height: r.height + 6),
                                 xRadius: 1, yRadius: 1).fill()
                }
            }
        }
        super.draw(dirtyRect)
    }

    /// Rounded on the RIGHT corners only; the left edge (under the accent bar) stays square.
    private func rightRounded(_ r: NSRect, radius: CGFloat) -> NSBezierPath {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: r.minX, y: r.minY))
        p.line(to: NSPoint(x: r.maxX - radius, y: r.minY))
        p.appendArc(withCenter: NSPoint(x: r.maxX - radius, y: r.minY + radius), radius: radius,
                    startAngle: -90, endAngle: 0)
        p.line(to: NSPoint(x: r.maxX, y: r.maxY - radius))
        p.appendArc(withCenter: NSPoint(x: r.maxX - radius, y: r.maxY - radius), radius: radius,
                    startAngle: 0, endAngle: 90)
        p.line(to: NSPoint(x: r.minX, y: r.maxY))
        p.close()
        return p
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), let onCmdClickLine {
            let pt = convert(event.locationInWindow, from: nil)
            let idx = characterIndexForInsertion(at: pt)
            if let hit = lineMap.last(where: { $0.range.location <= idx }) {
                onCmdClickLine(hit.line)
                return
            }
        }
        super.mouseDown(with: event)
    }
}

// ── The document builder ─────────────────────────────────────────────────────────────────────

enum MarkdownDoc {
    enum DecorKind { case code, quote, managed, rule }

    struct Rendered {
        let string: NSAttributedString
        let lineMap: [(range: NSRange, line: Int)]
        let decor: [(range: NSRange, kind: DecorKind)]
    }

    // Type scale (the "bigger, better" pass): body 13.5, headings 19/16.5/15/14.
    static let bodySize: CGFloat = 13.5
    static func bodyFont(_ weight: NSFont.Weight = .regular) -> NSFont {
        .systemFont(ofSize: bodySize, weight: weight)
    }

    /// CommonMark ATX heading: 1–6 `#`s followed by a space/tab (or nothing — `##` alone is a
    /// valid empty heading). `#tag` — no space — is NOT a heading (same rule as the tag grammar
    /// and the live editor's `^#{1,6} ` highlighter): it falls through to prose, where the chip
    /// renderer picks it up. Before this check, `#some-long-tag` at line start rendered as
    /// an h1 instead of a tag chip.
    static func isAtxHeading(_ line: String) -> Bool {
        let hashes = line.prefix(while: { $0 == "#" })
        guard (1 ... 6).contains(hashes.count) else { return false }
        let after = line.dropFirst(hashes.count)
        return after.isEmpty || after.first == " " || after.first == "\t"
    }

    static func headingFont(_ level: Int) -> NSFont {
        switch level {
        case 1: .systemFont(ofSize: 19, weight: .bold)
        case 2: .systemFont(ofSize: 16.5, weight: .bold)
        case 3: .systemFont(ofSize: 15, weight: .semibold)
        default: .systemFont(ofSize: 14, weight: .semibold)
        }
    }

    static let codeFont = NSFont(name: "Menlo", size: 12.5)
        ?? .monospacedSystemFont(ofSize: 12.5, weight: .regular)

    static func render(_ text: String, theme: Theme, interactive: Bool) -> Rendered {
        var out = NSMutableAttributedString()
        var lineMap: [(NSRange, Int)] = []
        var decor: [(NSRange, DecorKind)] = []
        let base = NSColor(theme.text)
        let accent = NSColor(Theme.accent)

        let (managedRaw, userText) = ManagedNote.splitNote(text)
        if !managedRaw.isEmpty {
            // The whole managed region — key:value fields AND the imported description — draws
            // behind a 2px accent left border (the web drawer's .cc-dw-mi treatment), content
            // indented past the bar.
            let managedStart = out.length
            appendManaged(managedRaw, to: &out, decor: &decor, base: base, accent: accent,
                          theme: theme)
            let managedRange = NSRange(location: managedStart, length: out.length - managedStart)
            if managedRange.length > 0 {
                indentManaged(&out, in: managedRange)
                linkifyEmails(&out, in: managedRange, accent: accent)
                decor.append((managedRange, .managed))
            }
        }
        let startLine = managedRaw.isEmpty ? 1 : userStartLine(userText, in: text)
        appendBlocks(userText, startLine: startLine, to: &out, lineMap: &lineMap, decor: &decor,
                     base: base, accent: accent, theme: theme, interactive: interactive)
        // Bottom breathing room (user spec): a trailing spacer paragraph — inset is symmetric,
        // so the extra tail lives in the document itself.
        let tail = NSMutableParagraphStyle()
        tail.minimumLineHeight = 26
        out.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: tail]))
        return Rendered(string: out, lineMap: lineMap, decor: decor)
    }

    private static func userStartLine(_ user: String, in text: String) -> Int {
        guard !user.isEmpty, let r = text.range(of: user, options: .backwards) else { return 1 }
        return text[..<r.lowerBound].reduce(into: 1) {
            if $1 == "\n" {
                $0 += 1
            }
        }
    }

    // ── Block walk ───────────────────────────────────────────────────────────────────────────

    private static func appendBlocks(_ source: String, startLine: Int,
                                     to out: inout NSMutableAttributedString,
                                     lineMap: inout [(NSRange, Int)],
                                     decor: inout [(NSRange, DecorKind)],
                                     base: NSColor, accent: NSColor, theme: Theme,
                                     interactive: Bool) {
        let lines = source.components(separatedBy: "\n")
        var i = 0
        var codeLang = ""
        var codeLines: [String]? = nil
        var codeStart = 0
        var paraBuf: [String] = []
        var paraLine = 0
        var quoteBuf: [String] = []
        var quoteLine = 0

        func mark(_ from: Int, line: Int) {
            lineMap.append((NSRange(location: from, length: out.length - from), line))
        }

        /// SOFT BREAKS (user spec, standard markdown): a lone newline does NOT start a new
        /// paragraph — consecutive text lines merge with a space; only a BLANK line (or a
        /// structural block) breaks the paragraph. Same for consecutive "> " lines.
        func flushPara() {
            guard !paraBuf.isEmpty else { return }
            let from = out.length
            let para = paragraph(spacing: 9)
            out.append(inline(paraBuf.joined(separator: " "), font: bodyFont(), color: base,
                              accent: accent, para: para))
            out.append(newline(para))
            mark(from, line: paraLine)
            paraBuf = []
        }
        func flushQuote() {
            guard !quoteBuf.isEmpty else { return }
            let from = out.length
            appendQuote(quoteBuf.joined(separator: " "), to: &out, decor: &decor,
                        base: base, accent: accent, theme: theme)
            mark(from, line: quoteLine)
            quoteBuf = []
        }
        func flushText() {
            flushPara()
            flushQuote()
        }

        while i < lines.count {
            let srcLine = startLine + i
            let raw = lines[i]
            let line = raw.trimmingCharacters(in: .whitespaces)
            defer { i += 1 }

            if let open = codeLines {
                if line.hasPrefix("```") {
                    let from = out.length
                    appendCode(open.joined(separator: "\n"), lang: codeLang, to: &out,
                               decor: &decor, base: base, theme: theme)
                    mark(from, line: codeStart)
                    codeLines = nil
                } else {
                    codeLines!.append(raw)
                }
                continue
            }
            if line.hasPrefix("```") {
                flushText()
                codeLang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                codeLines = []
                codeStart = srcLine
                continue
            }
            if line.isEmpty {
                flushText()
                continue
            }

            // Divider: a line of only --- (or ===, *** , ___; 3+): a thin horizontal rule
            // drawn by the text view (custom decor — a text-block border can't span the pane).
            if line.count >= 3,
               line.allSatisfy({ $0 == "-" }) || line.allSatisfy({ $0 == "=" })
               || line.allSatisfy({ $0 == "*" }) || line.allSatisfy({ $0 == "_" }) {
                flushText()
                let from = out.length
                let para = paragraph(spacing: 9)
                para.minimumLineHeight = 11 // a slim strip for the rule to center in
                para.maximumLineHeight = 11
                out.append(NSAttributedString(string: "\u{00A0}\n", attributes: [
                    .font: NSFont.systemFont(ofSize: 4), .paragraphStyle: para,
                ]))
                decor.append((NSRange(location: from, length: out.length - from), .rule))
                mark(from, line: srcLine)
                continue
            }

            // GFM table: a pipe row followed by the separator row.
            if line.hasPrefix("|"), i + 1 < lines.count,
               lines[i + 1].trimmingCharacters(in: .whitespaces)
               .range(of: #"^\|?[\s:|-]+\|?$"#, options: .regularExpression) != nil,
               lines[i + 1].contains("-") {
                flushText()
                let from = out.length
                var rows: [[String]] = [tableCells(line)]
                var j = i + 2
                while j < lines.count {
                    let r = lines[j].trimmingCharacters(in: .whitespaces)
                    if r.hasPrefix("|") {
                        rows.append(tableCells(r)); j += 1
                    } else {
                        break
                    }
                }
                appendTable(rows, to: &out, base: base, accent: accent, theme: theme)
                mark(from, line: srcLine)
                i = j - 1
                continue
            }

            if let (done, rest) = todoLine(line) {
                flushText()
                let from = out.length
                appendTodo(rest, done: done, line: srcLine, indent: indentDepth(raw),
                           to: &out, base: base, accent: accent, interactive: interactive)
                mark(from, line: srcLine)
            } else if isAtxHeading(line) {
                flushText()
                let from = out.length
                let level = line.prefix(while: { $0 == "#" }).count
                let body = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                let para = paragraph(spacingBefore: out.length == 0 ? 2 : 14, spacing: 7)
                out.append(inline(body, font: headingFont(level), color: base,
                                  accent: accent, para: para))
                out.append(newline(para))
                mark(from, line: srcLine)
            } else if let rest = strip(line, ["- ", "* ", "+ "]) {
                flushText()
                let from = out.length
                appendListItem("•", rest, indent: indentDepth(raw), to: &out,
                               base: base, accent: accent)
                mark(from, line: srcLine)
            } else if let m = line.range(of: #"^\d+[.)] "#, options: .regularExpression) {
                flushText()
                let from = out.length
                appendListItem(String(line[..<m.upperBound]).trimmingCharacters(in: .whitespaces),
                               String(line[m.upperBound...]), indent: indentDepth(raw),
                               to: &out, base: base, accent: accent)
                mark(from, line: srcLine)
            } else if let rest = strip(line, ["> "]) {
                flushPara()
                if quoteBuf.isEmpty {
                    quoteLine = srcLine
                }
                quoteBuf.append(rest)
            } else {
                flushQuote()
                if paraBuf.isEmpty {
                    paraLine = srcLine
                }
                paraBuf.append(line)
            }
        }
        flushText()
        if let open = codeLines { // unterminated fence
            let from = out.length
            appendCode(open.joined(separator: "\n"), lang: codeLang, to: &out,
                       decor: &decor, base: base, theme: theme)
            mark(from, line: codeStart)
        }
    }

    // ── Block renderers ──────────────────────────────────────────────────────────────────────

    private static func appendTodo(_ text: String, done: Bool, line: Int, indent: Int,
                                   to out: inout NSMutableAttributedString,
                                   base: NSColor, accent: NSColor, interactive: Bool) {
        let para = paragraph(spacing: 6)
        let ind = CGFloat(indent) * 18
        para.firstLineHeadIndent = ind
        para.headIndent = ind + 22
        let att = NSTextAttachment()
        att.image = checkboxImage(checked: done, accent: accent, grey: base.withAlphaComponent(0.45))
        att.bounds = CGRect(x: 0, y: -3.5, width: 15, height: 15)
        let box = NSMutableAttributedString(attachment: att)
        if interactive {
            box.addAttributes([.link: URL(string: "cc-todo://\(line)")!,
                               .cursor: NSCursor.pointingHand],
                              range: NSRange(location: 0, length: box.length))
        }
        box.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: box.length))
        out.append(box)
        out.append(NSAttributedString(string: "  ", attributes: [
            .font: bodyFont(), .paragraphStyle: para,
        ]))
        let tok = TodoIndex.tokenizeLine(text)
        // Pinned rows (#pinned / #proj-pinned): a small accent pin between the checkbox and
        // the body text — the panels' pin prefix, as a tinted, cached image attachment.
        if TodoFeed.hasPinTag(tok.tags) {
            let pinAtt = NSTextAttachment()
            let pin = pinImage(accent: accent)
            let h: CGFloat = 11
            pinAtt.image = pin
            pinAtt.bounds = CGRect(x: 0, y: -1.5,
                                   width: pin.size.width * h / max(1, pin.size.height), height: h)
            let a = NSMutableAttributedString(attachment: pinAtt)
            a.append(NSAttributedString(string: " ", attributes: [.font: bodyFont()]))
            a.addAttribute(.paragraphStyle, value: para,
                           range: NSRange(location: 0, length: a.length))
            out.append(a)
        }
        let body = inline(tok.text, font: bodyFont(), color: done ? base.withAlphaComponent(0.45) : base,
                          accent: accent, para: para)
        if done {
            let m = NSMutableAttributedString(attributedString: body)
            m.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue,
                           range: NSRange(location: 0, length: m.length))
            out.append(m)
        } else {
            out.append(body)
        }
        // Token PILLS — the web previewer's .cc-todo-tok badges, as rendered attachments:
        // mono micro-pills with per-kind hues, faint uppercase prefixes on value tokens,
        // priority white-on-red at level 4+, teal followup; all dimmed on a completed task.
        let alpha: CGFloat = done ? 0.55 : 1
        func pill(_ spec: ChipSpec) {
            let att = NSTextAttachment()
            let img = chipImage(spec, alpha: alpha)
            att.image = img
            att.bounds = CGRect(x: 0, y: -3, width: img.size.width, height: img.size.height)
            let a = NSMutableAttributedString(string: " ", attributes: [.font: bodyFont(),
                                                                        .paragraphStyle: para])
            a.append(NSAttributedString(attachment: att))
            a.addAttribute(.paragraphStyle, value: para,
                           range: NSRange(location: 0, length: a.length))
            out.append(a)
        }
        let grey = ChipSpec.greyStyle(base: base)
        if let p = tok.priority {
            pill(ChipSpec.priority(level: p, accent: accent))
        }
        if let due = tok.due {
            pill(grey.with(prefix: "DUE", text: due))
        }
        if let st = tok.start {
            pill(grey.with(prefix: "FROM", text: st))
        }
        if let d = tok.done {
            pill(grey.with(prefix: "DONE", text: d, extraDim: true))
        }
        if let f = tok.followup {
            pill(ChipSpec.followup(f))
        }
        for tag in tok.tags {
            pill(ChipSpec.tag("#" + tag, accent: accent))
        }
        for person in tok.entities["person"] ?? [] {
            pill(ChipSpec.person("@" + person))
        }
        for proj in tok.entities["project"] ?? [] {
            pill(ChipSpec.project("@" + proj))
        }
        out.append(newline(para))
    }

    private static func appendListItem(_ marker: String, _ text: String, indent: Int,
                                       to out: inout NSMutableAttributedString,
                                       base: NSColor, accent: NSColor) {
        let para = paragraph(spacing: 6)
        let ind = CGFloat(indent) * 18
        para.firstLineHeadIndent = ind
        para.headIndent = ind + 18
        out.append(NSAttributedString(string: marker + "  ", attributes: [
            .font: bodyFont(), .foregroundColor: base.withAlphaComponent(0.5),
            .paragraphStyle: para,
        ]))
        out.append(inline(text, font: bodyFont(), color: base, accent: accent, para: para))
        out.append(newline(para))
    }

    private static func appendQuote(_ text: String, to out: inout NSMutableAttributedString,
                                    decor: inout [(NSRange, DecorKind)],
                                    base: NSColor, accent: NSColor, theme: Theme) {
        // The "> " block: layout via NSTextBlock (padding + top margin), VISUALS custom-drawn
        // by PreviewTextView (accent bar + wash with ROUNDED RIGHT corners — NSTextBlock can
        // only paint rectangles).
        let block = NSTextBlock()
        // PADDING (wash edge → text) even top/bottom; MARGIN (wash → neighbors) even and
        // roomy — and the paragraph spacing is ZERO so nothing stacks on the bottom margin.
        block.setWidth(8, type: .absoluteValueType, for: .padding, edge: .minY)
        block.setWidth(8, type: .absoluteValueType, for: .padding, edge: .maxY)
        block.setWidth(14, type: .absoluteValueType, for: .padding, edge: .minX)
        block.setWidth(10, type: .absoluteValueType, for: .padding, edge: .maxX)
        block.setWidth(14, type: .absoluteValueType, for: .margin, edge: .minY)
        block.setWidth(14, type: .absoluteValueType, for: .margin, edge: .maxY)
        block.setContentWidth(100, type: .percentageValueType) // else the block collapses → 1-char lines
        let para = paragraph(spacing: 0)
        para.textBlocks = [block]
        let from = out.length
        out.append(inline(text, font: bodyFont(), color: base.withAlphaComponent(0.65),
                          accent: accent, para: para))
        out.append(newline(para))
        decor.append((NSRange(location: from, length: out.length - from), .quote))
    }

    private static func appendCode(_ code: String, lang: String,
                                   to out: inout NSMutableAttributedString,
                                   decor: inout [(NSRange, DecorKind)],
                                   base: NSColor, theme: Theme) {
        let block = NSTextBlock() // layout only; the ROUNDED wash is custom-drawn (see decor)
        for edge in [NSRectEdge.minX, .maxX, .minY, .maxY] {
            block.setWidth(edge == .minX || edge == .maxX ? 11 : 8,
                           type: .absoluteValueType, for: .padding, edge: edge)
        }
        block.setWidth(14, type: .absoluteValueType, for: .margin, edge: .minY) // even margins;
        block.setWidth(14, type: .absoluteValueType, for: .margin, edge: .maxY) // spacing = 0
        block.setContentWidth(100, type: .percentageValueType) // same collapse guard as quotes
        let para = paragraph(spacing: 0)
        para.textBlocks = [block]
        para.lineSpacing = 1.5
        let highlighted = CodeHighlight.highlight(code, lang: lang, base: base, font: codeFont)
        let m = NSMutableAttributedString(attributedString: highlighted)
        m.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: m.length))
        let from = out.length
        out.append(m)
        out.append(newline(para))
        decor.append((NSRange(location: from, length: out.length - from), .code))
    }

    private static func appendTable(_ rows: [[String]], to out: inout NSMutableAttributedString,
                                    base: NSColor, accent: NSColor, theme: Theme) {
        guard let cols = rows.map(\.count).max(), cols > 0 else { return }
        let table = NSTextTable()
        table.numberOfColumns = cols
        table.setContentWidth(100, type: .percentageValueType)
        for (r, row) in rows.enumerated() {
            for c in 0 ..< cols {
                let cell = NSTextTableBlock(table: table, startingRow: r, rowSpan: 1,
                                            startingColumn: c, columnSpan: 1)
                // Open sides (user spec): horizontal rules everywhere, vertical rules only
                // BETWEEN columns — no left/right outer frame. Thinner + darker lines.
                cell.setBorderColor(base.withAlphaComponent(0.32))
                // Single rules between rows/columns (leading edges only — adjacent cells
                // would double them), PLUS the table's outer top and bottom borders; only the
                // left/right outer frame stays open.
                cell.setWidth(0.33, type: .absoluteValueType, for: .border, edge: .minY)
                cell.setWidth(r == rows.count - 1 ? 0.33 : 0, type: .absoluteValueType,
                              for: .border, edge: .maxY)
                cell.setWidth(c > 0 ? 0.33 : 0, type: .absoluteValueType, for: .border, edge: .minX)
                cell.setWidth(0, type: .absoluteValueType, for: .border, edge: .maxX)
                for edge in [NSRectEdge.minX, .maxX] {
                    cell.setWidth(8, type: .absoluteValueType, for: .padding, edge: edge)
                }
                for edge in [NSRectEdge.minY, .maxY] {
                    cell.setWidth(4.5, type: .absoluteValueType, for: .padding, edge: edge)
                }
                if r == 0 {
                    cell.backgroundColor = base.withAlphaComponent(0.06)
                }
                let para = paragraph(spacing: 0)
                para.textBlocks = [cell]
                let text = c < row.count ? row[c] : ""
                out.append(inline(text, font: r == 0 ? bodyFont(.semibold) : bodyFont(),
                                  color: base, accent: accent, para: para))
                out.append(newline(para))
            }
        }
    }

    private static func appendManaged(_ raw: String, to out: inout NSMutableAttributedString,
                                      decor: inout [(NSRange, DecorKind)],
                                      base: NSColor, accent: NSColor, theme: Theme) {
        let parsed = ManagedNote.parseManaged(raw)
        if !parsed.fields.isEmpty {
            let table = NSTextTable()
            table.numberOfColumns = 2
            for (r, f) in parsed.fields.enumerated() {
                for c in 0 ... 1 {
                    let cell = NSTextTableBlock(table: table, startingRow: r, rowSpan: 1,
                                                startingColumn: c, columnSpan: 1)
                    cell.setWidth(c == 0 ? 12 : 6, type: .absoluteValueType, for: .padding, edge: .minX)
                    cell.setWidth(2.5, type: .absoluteValueType, for: .padding, edge: .minY)
                    cell.setWidth(2.5, type: .absoluteValueType, for: .padding, edge: .maxY)
                    if c == 0 {
                        cell.setContentWidth(96, type: .absoluteValueType)
                    }
                    let para = paragraph(spacing: 0)
                    para.textBlocks = [cell]
                    if c == 0 {
                        out.append(NSAttributedString(string: f.label, attributes: [
                            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                            .foregroundColor: base.withAlphaComponent(0.5),
                            .paragraphStyle: para,
                        ]))
                    } else if let href = f.href, let url = URL(string: href) {
                        out.append(NSAttributedString(string: f.value, attributes: [
                            .font: bodyFont(), .foregroundColor: accent,
                            .underlineStyle: NSUnderlineStyle.single.rawValue,
                            .link: url, .cursor: NSCursor.pointingHand,
                            .paragraphStyle: para,
                        ]))
                    } else {
                        out.append(NSAttributedString(string: f.value, attributes: [
                            .font: bodyFont(), .foregroundColor: base.withAlphaComponent(0.85),
                            .paragraphStyle: para,
                        ]))
                    }
                    out.append(newline(para))
                }
            }
        }
        if !parsed.description.isEmpty {
            var lineMapScratch: [(NSRange, Int)] = []
            appendBlocks(parsed.description, startLine: -100_000, to: &out,
                         lineMap: &lineMapScratch, decor: &decor, base: base, accent: accent,
                         theme: theme, interactive: false) // vendor text: no line actions
        }
    }

    /// Vendor text is full of bare addresses (organizer, attendees, "reply to x@y.z"): any
    /// email in the managed region becomes a tappable mailto: link — unless the run already
    /// carries a link (a field href, a markdown link in the description).
    private static let emailRe = try! NSRegularExpression(
        pattern: "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}"
    )

    private static func linkifyEmails(_ out: inout NSMutableAttributedString, in range: NSRange,
                                      accent: NSColor) {
        let text = out.string as NSString
        for m in emailRe.matches(in: out.string, range: range).reversed() {
            guard out.attribute(.link, at: m.range.location, effectiveRange: nil) == nil,
                  let url = URL(string: "mailto:" + text.substring(with: m.range)) else { continue }
            out.addAttributes([
                .link: url, .cursor: NSCursor.pointingHand,
                .foregroundColor: accent, .underlineStyle: NSUnderlineStyle.single.rawValue,
            ], range: m.range)
        }
    }

    /// Shift every paragraph of the managed region right by the border inset (12px), so the
    /// 2px accent bar sits left of ALL of it — including description blocks that carry their
    /// own indents (additive). Table cells indent via their own block padding instead.
    private static func indentManaged(_ out: inout NSMutableAttributedString, in range: NSRange) {
        out.enumerateAttribute(.paragraphStyle, in: range) { value, r, _ in
            guard let p = value as? NSParagraphStyle,
                  let m = p.mutableCopy() as? NSMutableParagraphStyle else { return }
            guard m.textBlocks.isEmpty else { return } // table cells: block padding handles it
            m.firstLineHeadIndent += 12
            m.headIndent += 12
            out.addAttribute(.paragraphStyle, value: m, range: r)
        }
    }

    // ── Inline + helpers ─────────────────────────────────────────────────────────────────────

    /// Inline spans through Foundation's markdown parser, re-attributed for AppKit: bold,
    /// italic, ~~strike~~, `code` (Menlo + wash), [links](…) in the ACCENT color, underlined.
    static func inline(_ s: String, font: NSFont, color: NSColor, accent: NSColor,
                       para: NSParagraphStyle) -> NSAttributedString {
        let parsed = (try? AttributedString(
            markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ))
            ?? AttributedString(s)
        let out = NSMutableAttributedString()
        for run in parsed.runs {
            let piece = String(parsed[run.range].characters)
            var attrs: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: color, .paragraphStyle: para,
            ]
            let intent = run.inlinePresentationIntent ?? []
            if intent.contains(.stronglyEmphasized) {
                attrs[.font] = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            }
            if intent.contains(.emphasized) {
                attrs[.obliqueness] = 0.16
            }
            if intent.contains(.strikethrough) {
                attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if intent.contains(.code) {
                attrs[.font] = NSFont(name: "Menlo", size: font.pointSize - 1.5)
                    ?? .monospacedSystemFont(ofSize: font.pointSize - 1.5, weight: .regular)
                attrs[.backgroundColor] = color.withAlphaComponent(0.08)
            }
            if let link = run.link {
                attrs[.link] = link
                attrs[.foregroundColor] = accent
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
                attrs[.cursor] = NSCursor.pointingHand
                out.append(NSAttributedString(string: piece, attributes: attrs))
            } else if intent.contains(.code) {
                out.append(NSAttributedString(string: piece, attributes: attrs))
            } else {
                // Prose refs (the web's locked scope): #tag and @person / @type:slug chip
                // ANYWHERE in a note — prose, headings, list items — not just todo lines.
                // Links and code spans are exempt (handled above).
                out.append(chippedText(piece, attrs: attrs, para: para))
            }
        }
        return out
    }

    /// TAG_RE + ENTITY_RE over a text run, non-token text kept verbatim, tokens as pills.
    private static let proseTagRe = try! NSRegularExpression(
        pattern: #"(^|\s)#([A-Za-z0-9_][\w-]*)(?=\s|$)"#
    )
    private static let proseEntityRe = try! NSRegularExpression(
        pattern: #"(^|\s)@(?:([A-Za-z][\w-]*):)?([A-Za-z0-9_][\w-]*)(?=\s|$)"#
    )

    private static func chippedText(_ text: String, attrs: [NSAttributedString.Key: Any],
                                    para: NSParagraphStyle) -> NSAttributedString {
        let ns = text as NSString
        let all = NSRange(location: 0, length: ns.length)
        var matches: [(NSRange, String, ChipSpec)] = [] // full range (incl. boundary), boundary, chip
        let accent = (attrs[.foregroundColor] as? NSColor).map { _ in NSColor(Theme.accent) }
            ?? NSColor(Theme.accent)
        for m in proseTagRe.matches(in: text, range: all) {
            let slug = ns.substring(with: m.range(at: 2))
            matches.append((m.range, ns.substring(with: m.range(at: 1)),
                            ChipSpec.tag("#" + slug, accent: accent)))
        }
        for m in proseEntityRe.matches(in: text, range: all) {
            let type = m.range(at: 2).location == NSNotFound
                ? "person" : ns.substring(with: m.range(at: 2)).lowercased()
            let slug = ns.substring(with: m.range(at: 3))
            let label = type == "person" ? "@" + slug : "@" + type + ":" + slug
            let chip: ChipSpec = switch type {
            case "person": .person(label)
            case "project": .project(label)
            default: ChipSpec(prefix: nil, text: label,
                              fg: NSColor(calibratedRed: 0xD6 / 255, green: 0x9A / 255,
                                          blue: 0x5C / 255, alpha: 1),
                              border: NSColor(calibratedRed: 0xEC / 255, green: 0x98 / 255,
                                              blue: 0x46 / 255, alpha: 0.5),
                              bg: NSColor(calibratedRed: 0xEC / 255, green: 0x98 / 255,
                                          blue: 0x46 / 255, alpha: 0.14))
            }
            matches.append((m.range, ns.substring(with: m.range(at: 1)), chip))
        }
        guard !matches.isEmpty else { return NSAttributedString(string: text, attributes: attrs) }
        matches.sort { $0.0.location < $1.0.location }
        let out = NSMutableAttributedString()
        var pos = 0
        for (range, boundary, spec) in matches {
            guard range.location >= pos else { continue } // overlapping match (tag inside entity)
            if range.location > pos {
                out.append(NSAttributedString(
                    string: ns.substring(with: NSRange(location: pos, length: range.location - pos)),
                    attributes: attrs
                ))
            }
            if !boundary.isEmpty {
                out.append(NSAttributedString(string: boundary, attributes: attrs))
            }
            let att = NSTextAttachment()
            let img = chipImage(spec, alpha: 1)
            att.image = img
            att.bounds = CGRect(x: 0, y: -3, width: img.size.width, height: img.size.height)
            let a = NSMutableAttributedString(attachment: att)
            a.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: a.length))
            out.append(a)
            pos = NSMaxRange(range)
        }
        if pos < ns.length {
            out.append(NSAttributedString(string: ns.substring(from: pos), attributes: attrs))
        }
        return out
    }

    private static func paragraph(spacingBefore: CGFloat = 0, spacing: CGFloat)
        -> NSMutableParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.paragraphSpacingBefore = spacingBefore
        p.paragraphSpacing = spacing
        p.lineSpacing = 1.5
        return p
    }

    private static func newline(_ para: NSParagraphStyle) -> NSAttributedString {
        NSAttributedString(string: "\n", attributes: [.paragraphStyle: para])
    }

    private static func todoLine(_ line: String) -> (Bool, String)? {
        for p in ["- [ ] ", "* [ ] ", "+ [ ] "] where line.hasPrefix(p) {
            return (false, String(line.dropFirst(p.count)))
        }
        for p in ["- [x] ", "- [X] ", "* [x] ", "* [X] ", "+ [x] ", "+ [X] "] where line.hasPrefix(p) {
            return (true, String(line.dropFirst(p.count)))
        }
        return nil
    }

    private static func strip(_ line: String, _ prefixes: [String]) -> String? {
        for p in prefixes where line.hasPrefix(p) {
            return String(line.dropFirst(p.count))
        }
        return nil
    }

    private static func indentDepth(_ raw: String) -> Int {
        raw.prefix(while: { $0 == " " || $0 == "\t" })
            .reduce(0) { $0 + ($1 == "\t" ? 2 : 1) } / 2
    }

    private static func tableCells(_ line: String) -> [String] {
        var l = line
        if l.hasPrefix("|") {
            l.removeFirst()
        }
        if l.hasSuffix("|") {
            l.removeLast()
        }
        return l.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// ── Token pills (the web's .cc-todo-tok badges) ─────────────────────────────────────────
    struct ChipSpec {
        var prefix: String? // faint uppercase key ("DUE", "FROM", "↪ FOLLOWUP")
        var text: String
        var fg: NSColor
        var border: NSColor
        var bg: NSColor
        var bold = false
        var extraDim = false

        static func greyStyle(base: NSColor) -> ChipSpec {
            ChipSpec(prefix: nil, text: "", fg: base.withAlphaComponent(0.8),
                     border: base.withAlphaComponent(0.25), bg: base.withAlphaComponent(0.06))
        }

        func with(prefix: String, text: String, extraDim: Bool = false) -> ChipSpec {
            var c = self
            c.prefix = prefix
            c.text = text
            c.extraDim = extraDim
            return c
        }

        static func priority(level: Int, accent: NSColor) -> ChipSpec {
            level >= 4
                ? ChipSpec(prefix: nil, text: String(repeating: "!", count: level),
                           fg: .white, border: accent, bg: accent, bold: true)
                : ChipSpec(prefix: nil, text: String(repeating: "!", count: level),
                           fg: accent, border: accent.withAlphaComponent(0.45),
                           bg: accent.withAlphaComponent(0.12), bold: true)
        }

        static func followup(_ v: String) -> ChipSpec {
            let teal = NSColor(calibratedRed: 0x2F / 255, green: 0x8A / 255, blue: 0x8A / 255, alpha: 1)
            return ChipSpec(prefix: "↪ FOLLOWUP", text: v, fg: teal,
                            border: teal.withAlphaComponent(0.42), bg: teal.withAlphaComponent(0.11))
        }

        static func tag(_ t: String, accent: NSColor) -> ChipSpec {
            ChipSpec(prefix: nil, text: t, fg: accent,
                     border: accent.withAlphaComponent(0.38), bg: accent.withAlphaComponent(0.09))
        }

        static func person(_ t: String) -> ChipSpec {
            let hue = NSColor(calibratedRed: 0x7F / 255, green: 0x95 / 255, blue: 0xD8 / 255, alpha: 1)
            return ChipSpec(prefix: nil, text: t, fg: hue,
                            border: hue.withAlphaComponent(0.5), bg: hue.withAlphaComponent(0.12))
        }

        static func project(_ t: String) -> ChipSpec {
            let hue = NSColor(calibratedRed: 0x7F / 255, green: 0xAE / 255, blue: 0x6B / 255, alpha: 1)
            return ChipSpec(prefix: nil, text: t, fg: hue,
                            border: hue.withAlphaComponent(0.5), bg: hue.withAlphaComponent(0.12))
        }
    }

    private static var chipCache: [String: NSImage] = [:]
    static func chipImage(_ spec: ChipSpec, alpha: CGFloat) -> NSImage {
        let key = "\(spec.prefix ?? "")|\(spec.text)|\(spec.fg.description)|\(spec.bg.description)|\(spec.bold)|\(spec.extraDim)|\(alpha)"
        if let hit = chipCache[key] {
            return hit
        }
        let mono = NSFont(name: spec.bold ? "Menlo-Bold" : "Menlo", size: 10)
            ?? .monospacedSystemFont(ofSize: 10, weight: spec.bold ? .bold : .regular)
        let prefixFont = NSFont(name: "Menlo-Bold", size: 8.2) ?? mono
        let a = alpha * (spec.extraDim ? 0.7 : 1)
        let fg = spec.fg.withAlphaComponent(spec.fg.alphaComponent * a)
        let textAttrs: [NSAttributedString.Key: Any] = [.font: mono, .foregroundColor: fg]
        let prefixAttrs: [NSAttributedString.Key: Any] = [
            .font: prefixFont, .foregroundColor: fg.withAlphaComponent(fg.alphaComponent * 0.6),
        ]
        let textSize = (spec.text as NSString).size(withAttributes: textAttrs)
        let prefixSize = spec.prefix.map { ($0 as NSString).size(withAttributes: prefixAttrs) }
        let gap: CGFloat = prefixSize != nil ? 3.5 : 0
        let padX: CGFloat = 6.5
        let h: CGFloat = 15.5
        let w = padX * 2 + (prefixSize?.width ?? 0) + gap + textSize.width
        let img = NSImage(size: NSSize(width: ceil(w), height: h), flipped: false) { _ in
            let rect = NSRect(x: 0.5, y: 0.5, width: ceil(w) - 1, height: h - 1)
            let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2,
                                    yRadius: rect.height / 2)
            spec.bg.withAlphaComponent(spec.bg.alphaComponent * a).setFill()
            path.fill()
            spec.border.withAlphaComponent(spec.border.alphaComponent * a).setStroke()
            path.lineWidth = 1
            path.stroke()
            var x = padX
            if let p = spec.prefix, let ps = prefixSize {
                (p as NSString).draw(at: NSPoint(x: x, y: (h - ps.height) / 2),
                                     withAttributes: prefixAttrs)
                x += ps.width + gap
            }
            (spec.text as NSString).draw(at: NSPoint(x: x, y: (h - textSize.height) / 2),
                                         withAttributes: textAttrs)
            return true
        }
        if chipCache.count > 512 {
            chipCache.removeAll()
        }
        chipCache[key] = img
        return img
    }

    // ── Checkbox images (the house DashCheckbox look, as attachments) ──
    private static var checkboxCache: [String: NSImage] = [:]
    fileprivate static func checkboxImage(checked: Bool, accent: NSColor, grey: NSColor) -> NSImage {
        let key = "\(checked)|\(accent.description)|\(grey.description)"
        if let hit = checkboxCache[key] {
            return hit
        }
        let img = NSImage(size: NSSize(width: 15, height: 15), flipped: false) { _ in
            let r = NSRect(x: 0.75, y: 0.75, width: 13.5, height: 13.5)
            let path = NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5)
            if checked {
                accent.setFill()
                path.fill()
                let check = NSBezierPath()
                check.move(to: NSPoint(x: 4, y: 7.6))
                check.line(to: NSPoint(x: 6.4, y: 5.2))
                check.line(to: NSPoint(x: 11, y: 10))
                check.lineWidth = 1.8
                check.lineCapStyle = .round
                check.lineJoinStyle = .round
                NSColor.white.setStroke()
                check.stroke()
            } else {
                grey.setStroke()
                path.lineWidth = 1.5
                path.stroke()
            }
            return true
        }
        checkboxCache[key] = img
        return img
    }

    // ── Pin prefix image (the panels' accent pin, as an attachment) ──
    private static var pinCache: [String: NSImage] = [:]
    fileprivate static func pinImage(accent: NSColor) -> NSImage {
        let key = accent.description
        if let hit = pinCache[key] {
            return hit
        }
        // Tint by drawing the SF symbol into an offscreen image and flood-filling sourceAtop
        // (symbol images ignore a plain draw-time fill color) — checkboxImage's cache pattern.
        let sym = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        let size = sym?.size ?? NSSize(width: 11, height: 11)
        let img = NSImage(size: size, flipped: false) { rect in
            sym?.draw(in: rect)
            accent.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        pinCache[key] = img
        return img
    }
}
