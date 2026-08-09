// Inline title editors positioned over the clicked item: track (lane) names, band titles,
// and timed-event titles. Commit on Return/blur, dismiss on Esc.
// Split from CalendarView.swift (file diet).

import AppKit
import CalendarEngine
import CalendarGeometry
import SwiftUI

/// Inline editor for a track (lane) name, placed over the clicked gutter slot. Updates
/// the shared name live across all months; commits/dismisses on Return, Esc, or blur.
struct TrackNameEditor: View {
    let engine: CalendarEngine
    let target: TrackEdit
    let theme: Theme
    var onDone: () -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        let r = target.rect
        TextField("Track", text: $text)
            .textFieldStyle(.plain)
            .font(.custom("Comic Sans MS", size: 13))
            .foregroundStyle(theme.text)
            .focused($focused)
            .padding(.leading, 10)
            .frame(width: r.width, height: max(18, r.height - 6), alignment: .leading)
            .position(x: r.midX + Layout.padLeft, y: r.midY)
            .onAppear {
                let names = target.month < engine.items.trackNames.count ? engine.items.trackNames[target.month] : []
                text = target.track < names.count ? names[target.track] : ""
                focused = true
            }
            .onChange(of: text) { _, v in engine.setTrackName(target.month, target.track, v) }
            .onChange(of: focused) {
                _, f in if !f {
                    onDone()
                }
            }
            .onSubmit { onDone() }
            .onExitCommand { onDone() }
    }
}

/// Inline editor for a band's title, placed over the band. Its leading matches the
/// selected band's title (bar inset + selected bar width + gap). Commits live.
struct BandTitleEditor: View {
    let engine: CalendarEngine
    let target: BandEdit
    let theme: Theme
    var onDone: () -> Void
    @State private var text = ""
    @State private var original = "" // title before editing — restored if the field is left empty
    @FocusState private var focused: Bool

    // Commit: strip whitespace; a title that's empty after stripping reverts to the pre-edit title
    // (an event may never have a blank title).
    private func commit() {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        engine.setBandTitle(target.id, s.isEmpty ? original : s)
        onDone()
    }

    var body: some View {
        let r = target.rect
        TextField("Event", text: $text)
            .textFieldStyle(.plain)
            .font(.custom("Comic Sans MS", size: BandStyle.titleSize))
            .foregroundStyle(theme.text)
            .focused($focused)
            .padding(.leading, BandStyle.accentInset + BandStyle.accentWidthSelected + BandStyle.barTextGap)
            .padding(.trailing, BandStyle.titleTrailing)
            .frame(width: r.width, height: r.height, alignment: .leading)
            .position(x: r.midX + Layout.padLeft, y: r.midY)
            .onAppear { let t = engine.band(target.id)?.title ?? ""; text = t; original = t; focused = true }
            .onChange(of: text) { _, v in engine.setBandTitle(target.id, v) } // live (as typed)
            .onChange(of: focused) {
                _, f in if !f {
                    commit()
                }
            }
            .onSubmit { commit() }
            .onExitCommand { commit() } // strip; revert to original if blank
    }
}

/// Inline title editor for a TIMED event — the sibling of BandTitleEditor. Opened by the keyboard
/// "Enter → edit title" (see KeyboardModel) or by clicking an already-selected event's body. Writes
/// the title live through the engine (coalesced into one undo step); commits on Return / blur / Esc.
struct TimedTitleEditor: View {
    let engine: CalendarEngine
    let target: TimedEdit
    let theme: Theme
    var onDone: () -> Void
    @State private var text = ""
    @State private var original = "" // title before editing — restored if the field is left empty
    @FocusState private var focused: Bool

    private func commit() {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        engine.update(target.id) { $0.title = s.isEmpty ? original : s }
        onDone()
    }

    var body: some View {
        let r = target.rect
        TextField("Event", text: $text)
            .textFieldStyle(.plain)
            .font(.custom("Comic Sans MS", size: 13)) // matches EventSticker's title font
            .foregroundStyle(theme.text)
            .focused($focused)
            .padding(.leading, BandStyle.accentInset + BandStyle.accentWidthSelected + BandStyle.barTextGap)
            .padding(.trailing, BandStyle.titleTrailing)
            .padding(.top, 3) // match EventSticker's .padding(.vertical, 3) so the field sits on the title
            .frame(width: r.width, height: r.height, alignment: .topLeading)
            .position(x: r.midX + Layout.padLeft, y: r.midY)
            .onAppear {
                let t = engine.event(target.id)?.title ?? ""; text = t; original = t; focused = true
                // Select the whole title so typing replaces it (matches the drawer's rename behavior).
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    (NSApp.keyWindow?.firstResponder as? NSText)?.selectAll(nil)
                }
            }
            .onChange(of: text) { _, v in engine.update(target.id) { $0.title = v } } // live (as typed)
            .onChange(of: focused) {
                _, f in if !f {
                    commit()
                }
            }
            .onSubmit { commit() }
            .onExitCommand { commit() } // strip; revert to original if blank
    }
}
