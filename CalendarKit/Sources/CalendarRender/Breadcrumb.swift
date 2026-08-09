// Year › Month › Week › Day breadcrumb, progressive by zoom level (matches the web).
// Lives in CalendarRender (not CalendarUI) so the iPhone client can reuse it — it is pure
// SwiftUI over the engine's @Observable chrome, no AppKit. Split from CalendarChromeViews.swift.

import CalendarEngine
import CalendarGeometry
import SwiftUI

/// The Year crumb is a menu that jumps between selectable years.
public struct Breadcrumb: View {
    let engine: CalendarEngine
    private var chrome: CalendarChrome {
        engine.chrome
    }

    public init(engine: CalendarEngine) {
        self.engine = engine
    }

    public var body: some View {
        let atYear = chrome.level == 0
        HStack(spacing: 5) {
            // At the yearly view the "Year" crumb is a native Menu (system dropdown) whose
            // label includes our own caret — so clicking the text OR the caret opens it.
            // Deeper in, it's a plain button that zooms back out to the year.
            if atYear {
                Menu {
                    Picker("Year", selection: Binding(get: { chrome.year }, set: { engine.selectYear($0) })) {
                        ForEach(engine.yearOptions, id: \.self) { y in Text(verbatim: "\(y)").tag(y) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } label: {
                    yearLabel(atYear: true)
                }
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
            } else {
                Button { engine.zoomToYear() } label: { yearLabel(atYear: false) }
                    .buttonStyle(.plain)
            }
            if chrome.level >= 1 {
                sep; crumbButton(MONTH_LONG[chrome.displayFocus], active: chrome.level == 1) { engine.zoomToMonth() }
            }
            if chrome.level >= 2 {
                sep; crumbButton("Week \(Int(chrome.week.rounded()) + 1)", active: chrome.level == 2) {
                    engine.zoomToWeek()
                }
            }
            if chrome.level >= 3, let r = resolveDate(chrome.year, chrome.displayFocus, chrome.displayDom) {
                // Phone (compact gutter): just the ordinal ("21st") — the weekday lives in the
                // day column's own header, and the tight trail (2026 › July › Week 4 › 21st)
                // must fit the bottom capsule. Desktop keeps the full "Monday, 21st".
                sep
                if Layout.isCompactGutter {
                    crumb("\(r.day)\(ordinal(r.day))", active: true)
                } else {
                    crumb("\(WD_LONG[dayOfWeek(r.year, r.month, r.day)]), \(r.day)\(ordinal(r.day))",
                          active: true)
                }
            }
        }
        .padding(.horizontal, 18)
    }

    private func yearLabel(atYear: Bool) -> some View {
        HStack(spacing: 0) {
            // Phone (compact gutter): past the yearly view the level is implied by the trail
            // (2026 › July › …), and the bare number keeps the bottom capsule tight. Desktop
            // keeps "Year 2026" at every level.
            crumb(atYear || !Layout.isCompactGutter ? "Year \(chrome.year)" : "\(chrome.year)",
                  active: atYear).fixedSize()
            if atYear {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 5)
            }
        }
    }

    private var sep: some View {
        Text("›").font(.system(size: 12)).foregroundStyle(.tertiary)
            .padding(.horizontal, 3) // a little more breathing room around the "›"
    }

    private func crumb(_ text: String, active: Bool) -> some View {
        Text(text)
            .font(.system(size: 13, weight: active ? .semibold : .regular))
            .foregroundStyle(active ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
    }

    /// A crumb that navigates when clicked (Month / Week). Kept clickable even when it's the active
    /// level — clicking then just re-settles that view.
    private func crumbButton(_ text: String, active: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { crumb(text, active: active) }
            .buttonStyle(.plain)
    }

    private func ordinal(_ n: Int) -> String {
        if (n % 100) / 10 == 1 {
            return "th"
        }
        switch n % 10 { case 1: return "st"; case 2: return "nd"; case 3: return "rd"; default: return "th" }
    }
}
