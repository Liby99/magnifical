// Lightweight native Markdown rendering for assistant bubbles. Block-level structure (headings,
// lists, fenced code, quotes, rules) is parsed by hand; inline styling (bold/italic/code/links)
// uses AttributedString. Deliberately NOT a web view — everything is plain SwiftUI Text, so
// bubbles stay native, theme-aware, and selectable.

import SwiftUI

struct MarkdownText: View {
    let text: String
    let theme: Theme

    var body: some View {
        let blocks = Self.parse(text)
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                render(block)
            }
        }
    }

    /// ── Rendering ─────────────────────────────────────────────────────────────────────
    @ViewBuilder private func render(_ b: Block) -> some View {
        switch b {
        case let .heading(level, t):
            Text(inline(t))
                .font(.system(size: level == 1 ? 17 : level == 2 ? 15.5 : 14.5, weight: .bold))
                .padding(.top, 2)
        case let .paragraph(t):
            Text(inline(t))
        case let .code(c):
            Text(c)
                .font(.system(size: 12, design: .monospaced))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(codeBg, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        case let .bullets(items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(items.indices, id: \.self) { i in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•")
                        Text(inline(items[i]))
                    }
                }
            }
        case let .numbered(items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(items.indices, id: \.self) { i in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(i + 1).").monospacedDigit()
                        Text(inline(items[i]))
                    }
                }
            }
        case let .quote(t):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5).fill(theme.textMuted.opacity(0.5)).frame(width: 3)
                Text(inline(t)).foregroundStyle(theme.textMuted)
            }
        case .rule:
            Divider()
        }
    }

    private var codeBg: Color {
        theme.dark ? .white.opacity(0.08) : .black.opacity(0.055)
    }

    /// Inline markdown (bold/italic/code/links) with newlines preserved.
    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        ))) ?? AttributedString(s)
    }

    /// ── Parsing ───────────────────────────────────────────────────────────────────────
    enum Block {
        case heading(Int, String)
        case paragraph(String)
        case code(String)
        case bullets([String])
        case numbered([String])
        case quote(String)
        case rule
    }

    static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var para: [String] = [], bullets: [String] = [], numbers: [String] = [], quotes: [String] = []
        var code: [String]? = nil // non-nil while inside a ``` fence

        func flushPara() {
            if !para.isEmpty {
                blocks.append(.paragraph(para.joined(separator: " "))); para = []
            }
        }
        func flushBullets() {
            if !bullets.isEmpty {
                blocks.append(.bullets(bullets)); bullets = []
            }
        }
        func flushNumbers() {
            if !numbers.isEmpty {
                blocks.append(.numbered(numbers)); numbers = []
            }
        }
        func flushQuotes() {
            if !quotes.isEmpty {
                blocks.append(.quote(quotes.joined(separator: "\n"))); quotes = []
            }
        }
        func flushAll() {
            flushPara(); flushBullets(); flushNumbers(); flushQuotes()
        }

        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)

            if code != nil { // inside a fence — verbatim until ```
                if line.hasPrefix("```") {
                    blocks.append(.code(code!.joined(separator: "\n"))); code = nil
                } else {
                    code!.append(raw)
                }
                continue
            }
            if line.hasPrefix("```") {
                flushAll(); code = []; continue
            }
            if line.isEmpty {
                flushAll(); continue
            }
            if line == "---" || line == "***" || line == "___" {
                flushAll(); blocks.append(.rule); continue
            }

            if let level = headingLevel(line) {
                flushAll()
                blocks.append(.heading(min(level, 3), String(line.dropFirst(level + 1))))
                continue
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                flushPara(); flushNumbers(); flushQuotes()
                bullets.append(String(line.dropFirst(2)))
                continue
            }
            if let m = line.range(of: #"^\d+[.)] "#, options: .regularExpression) {
                flushPara(); flushBullets(); flushQuotes()
                numbers.append(String(line[m.upperBound...]))
                continue
            }
            if line.hasPrefix("> ") || line == ">" {
                flushPara(); flushBullets(); flushNumbers()
                quotes.append(line == ">" ? "" : String(line.dropFirst(2)))
                continue
            }
            flushBullets(); flushNumbers(); flushQuotes()
            para.append(line)
        }
        if let c = code {
            blocks.append(.code(c.joined(separator: "\n")))
        } // unterminated fence
        flushAll()
        return blocks
    }

    private static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard (1 ... 6).contains(hashes), line.dropFirst(hashes).hasPrefix(" ") else { return nil }
        return hashes
    }
}
