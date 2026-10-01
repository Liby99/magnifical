// Native, selectable markdown for the iPhone detail sheet. The note text becomes real
// SwiftUI views — headings, todo rows, bullet/numbered lists, blockquotes, code blocks,
// paragraphs — with inline spans (links, bold/italic/code) parsed via AttributedString's
// markdown support, so links are TAPPABLE and every run is SELECTABLE (.textSelection).
// Read-only for now: todo rows show their checked state but don't toggle — the client is
// cloudReadOnly, and a local toggle would silently diverge from the Mac until the phone
// write-path lands.

import CalendarEngine
import CalendarRender
import QuickLook
import SwiftUI

struct PhoneMarkdown: View {
    let text: String
    let accent: Color // the event's color — checked todos and quote bars pick it up
    let theme: Theme
    /// The attachment blob store — `![@kind:name](ccfile:…)` tokens render as cards when
    /// present (blobs arrive via the same CloudSync the notes ride). nil = chips only.
    var attachments: AttachmentStore?
    @State private var quickLookURL: URL? // tapped card → the system Quick Look sheet

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks()) { b in
                blockView(b)
            }
        }
        .textSelection(.enabled)
        .quickLookPreview($quickLookURL)
    }

    // ── Block model ──────────────────────────────────────────────────────────────────

    private enum Kind {
        case heading(Int) // 1…3+ (# ## ###)
        case todo(done: Bool)
        case bullet
        case ordered(Int) // the item's own number, as written
        case quote
        case code // a whole fenced block, text = joined lines
        case para
        case attachment(AttachmentToken) // a block ccfile token → tappable card
    }

    private struct Block: Identifiable {
        let id: Int
        let kind: Kind
        let text: String
    }

    /// Line-oriented block parse: code fences accumulate verbatim; every other line maps to
    /// one block. Deliberately simple — the app's notes are line-structured (todo lists,
    /// headings, short paragraphs), not deeply nested documents.
    private func blocks() -> [Block] {
        var out: [Block] = []
        var codeLines: [String]? = nil // non-nil while inside a ``` fence
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let lines = codeLines {
                    out.append(Block(id: out.count, kind: .code, text: lines.joined(separator: "\n")))
                    codeLines = nil
                } else {
                    codeLines = []
                }
                continue
            }
            if codeLines != nil {
                codeLines!.append(raw)
                continue
            }
            if line.isEmpty {
                continue // spacing comes from the stack
            }
            if attachments != nil, let token = AttachmentTokens.blockToken(line: line) {
                out.append(Block(id: out.count, kind: .attachment(token), text: line))
                continue
            }
            if let rest = strip(line, ["- [x] ", "- [X] ", "* [x] ", "* [X] "]) {
                out.append(Block(id: out.count, kind: .todo(done: true), text: rest))
            } else if let rest = strip(line, ["- [ ] ", "* [ ] "]) {
                out.append(Block(id: out.count, kind: .todo(done: false), text: rest))
            } else if line.hasPrefix("#") {
                let level = line.prefix(while: { $0 == "#" }).count
                let rest = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                out.append(Block(id: out.count, kind: .heading(level), text: rest))
            } else if let rest = strip(line, ["- ", "* ", "+ "]) {
                out.append(Block(id: out.count, kind: .bullet, text: rest))
            } else if let dot = line.firstIndex(of: "."), let n = Int(line[line.startIndex ..< dot]),
                      line.index(after: dot) < line.endIndex, line[line.index(after: dot)] == " " {
                out.append(Block(id: out.count, kind: .ordered(n),
                                 text: String(line[line.index(dot, offsetBy: 2)...])))
            } else if let rest = strip(line, ["> "]) {
                out.append(Block(id: out.count, kind: .quote, text: rest))
            } else {
                out.append(Block(id: out.count, kind: .para, text: line))
            }
        }
        if let lines = codeLines { // unterminated fence — show what's there
            out.append(Block(id: out.count, kind: .code, text: lines.joined(separator: "\n")))
        }
        return out
    }

    private func strip(_ line: String, _ prefixes: [String]) -> String? {
        for p in prefixes where line.hasPrefix(p) {
            return String(line.dropFirst(p.count))
        }
        return nil
    }

    // ── Rendering ────────────────────────────────────────────────────────────────────

    /// Inline spans through Foundation's markdown parser: [links](…), **bold**, *italic*,
    /// `code`. Links carry the .link attribute, which SwiftUI Text renders tappable.
    private func inline(_ s: String) -> AttributedString {
        // Mid-line attachment tokens read as chips (📎 name) — Foundation's parser would
        // otherwise swallow the image syntax into confusing bare text.
        var s = s
        for m in AttachmentTokens.matches(in: s).reversed() {
            if let r = Range(m.range, in: s) {
                s.replaceSubrange(r, with: "📎 \(m.token.name)")
            }
        }
        return (try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(s)
    }

    /// One attachment card: images render inline (aspect-fit, tap → Quick Look); everything
    /// else is an icon + name/size row. A referenced blob that hasn't synced down yet shows
    /// the waiting row — CloudSync's adoption repaints via noteEdits.gen, which every host
    /// of this view already observes.
    @ViewBuilder private func attachmentCard(_ token: AttachmentToken) -> some View {
        if let store = attachments, let url = store.url(forId: token.id),
           let meta = store.meta(forId: token.id) {
            let display = store.displayURL(forId: token.id) ?? url
            if AttachmentStore.kind(forUTI: meta.uti, name: meta.name) == .image,
               let ui = UIImage(contentsOfFile: url.path) {
                Button {
                    quickLookURL = display
                } label: {
                    Image(uiImage: ui)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 340, maxHeight: token.size == .small ? 90
                            : token.size == .big ? 220 : 140)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(theme.text.opacity(0.22), lineWidth: 1))
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    quickLookURL = display
                } label: {
                    attachmentRow(name: token.name, detail: fmtBytes(meta.bytes), waiting: false)
                }
                .buttonStyle(.plain)
            }
        } else {
            attachmentRow(name: token.name, detail: "waiting for iCloud…", waiting: true)
        }
    }

    private func attachmentRow(name: String, detail: String, waiting: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: waiting ? "icloud.and.arrow.down" : "doc")
                .font(.system(size: 20))
                .foregroundStyle(waiting ? Color.secondary : accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.callout.weight(.medium)).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.text.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(theme.text.opacity(0.15), lineWidth: 1))
    }

    private func fmtBytes(_ n: Int) -> String {
        n < 1000 ? "\(n) B"
            : n < 1_000_000 ? String(format: "%.0f KB", Double(n) / 1000)
            : String(format: "%.1f MB", Double(n) / 1_000_000)
    }

    @ViewBuilder private func blockView(_ b: Block) -> some View {
        switch b.kind {
        case let .attachment(token):
            attachmentCard(token)
        case let .heading(level):
            Text(inline(b.text))
                .font(level <= 1 ? .title3.weight(.semibold)
                    : level == 2 ? .headline
                    : .subheadline.weight(.semibold))
                .padding(.top, 4)
        case let .todo(done):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: done ? "checkmark.square.fill" : "square")
                    .font(.system(size: 15))
                    .foregroundStyle(done ? accent : Color.secondary)
                Text(inline(b.text))
                    .font(.callout)
                    .strikethrough(done, color: .secondary)
                    .foregroundStyle(done ? Color.secondary : Color.primary)
            }
        case .bullet:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").font(.callout).foregroundStyle(.secondary)
                Text(inline(b.text)).font(.callout)
            }
        case let .ordered(n):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(n).").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                Text(inline(b.text)).font(.callout)
            }
        case .quote:
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(accent.opacity(0.6))
                    .frame(width: 3)
                Text(inline(b.text)).font(.callout).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .code:
            Text(verbatim: b.text)
                .font(.system(.caption, design: .monospaced))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(theme.text.opacity(0.06)))
        case .para:
            Text(inline(b.text)).font(.callout)
        }
    }
}
