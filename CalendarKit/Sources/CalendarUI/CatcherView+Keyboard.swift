// CatcherView's keyboard layer: the local key monitor, modal/shortcut routing (handleKey),
// the custom held-key auto-repeat, KeyToken normalization, and the undo/redo actions. The
// keyDown override itself stays in CalendarInputLayer.swift (overrides must live in the
// class body).
// Split from CalendarInputLayer.swift (audit round, 2026-08-02).

import AppKit
import CalendarEngine
import CalendarGeometry
import SwiftUI

extension CatcherView {
    func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] e in
            self?.handleKey(e) ?? e
        }
    }

    private func handleKey(_ e: NSEvent) -> NSEvent? {
        guard let w = window, e.window === w else { return e } // only our (key) window's events
        switch e.type {
        case .keyDown:
            // A blocking modal (delete confirm) owns the ENTIRE keyboard. Route only its nav keys — ←/→ move
            // the focused button, Enter confirms, Esc cancels — and swallow EVERYTHING else, INCLUDING
            // ⌘-combos, so ⌘K / ⌘F / ⌘N / etc. are all disabled while it's up. First, so it wins over the
            // command handlers below. (Menu-driven ⌘-shortcuts in the signed app are gated separately.)
            if isModalDelete?() == true {
                if !e.isARepeat, !e.modifierFlags.contains(.command) {
                    switch e.keyCode {
                    case 123: onDeleteDialogKey?(.left)
                    case 124: onDeleteDialogKey?(.right)
                    case 36, 76: onDeleteDialogKey?(.confirm)
                    case 53: onDeleteDialogKey?(.cancel)
                    default: break
                    }
                }
                return nil
            }
            // The batch-rename panel is modal WITH typing: Esc cancels (reverting the live renames)
            // from ANYWHERE — even when its text field isn't focused, where Esc would otherwise
            // zoom the calendar behind the still-open panel. Typing flows to the focused field;
            // Enter with the field unfocused still commits; every other key is swallowed
            // (modalActive already blocks the pointer).
            if isBatchRenaming?() == true {
                if e.keyCode == 53 {
                    onBatchRenameCancel?(); return nil
                }
                if isTextInputFocused() {
                    return e
                }
                if e.keyCode == 36 || e.keyCode == 76 {
                    onBatchRenameCommit?(); return nil
                }
                return nil
            }
            // The tutorial carousel likewise owns the keyboard: ←/→ page, Enter next/done, Esc closes.
            if isTutorialUp?() == true {
                if !e.isARepeat, !e.modifierFlags.contains(.command) {
                    switch e.keyCode {
                    case 123: onTutorialKey?(.left)
                    case 124: onTutorialKey?(.right)
                    case 36, 76: onTutorialKey?(.confirm)
                    case 53: onTutorialKey?(.cancel)
                    default: break
                    }
                }
                return nil
            }
            // Cmd+K → hold-to-show the shortcut guide (ignore auto-repeat; released on keyUp/flagsChanged).
            // Deliberately ABOVE the text-input check: the guide is a transient overlay that types
            // nothing, and while a note editor is focused it's how the editor's own keys are discovered.
            if e.keyCode == 40, e.modifierFlags.contains(.command) {
                if !keyGuideShown {
                    keyGuideShown = true; onKeyGuide?(true)
                }
                return nil
            }
            // A focused field/editor owns every other key: typing, native undo, and the markdown
            // editor's own bindings (Tab/⇧Tab indent, ⌥↑/⌥↓ move line, ⌘←/→ line bounds, ⌘S preview,
            // Esc exit). ALL custom hotkeys below — including ⌘F search — stand down so none of them
            // can hitch the editor.
            if isTextInputFocused() {
                return e
            }
            // Cmd+F → open the toolbar search field (works from any state; the field then owns the keys).
            if e.keyCode == 3, e.modifierFlags.contains(.command), !e.isARepeat {
                onSearch?()
                return nil
            }
            // ⌘Z / ⌘⇧Z are owned SOLELY by the Edit▸Undo/Redo menu command (one focus-aware handler). We
            // must NOT act on them here — doing so alongside the menu shortcut fired undo twice (rename +
            // create both undone on one press) — but we also must not let the catch-all `return nil` below
            // swallow them, or the menu shortcut never sees the key. So pass them straight through.
            if e.keyCode == 6, e.modifierFlags.contains(.command),
               !e.modifierFlags.contains(.option), !e.modifierFlags.contains(.control) {
                return e
            }
            // ⌘C / ⌘X / ⌘V are owned by the Edit menu's Copy/Cut/Paste items, which target this view's
            // copy(_:)/cut(_:)/paste(_:). Like ⌘Z, pass them through so the menu key equivalents fire
            // (the catch-all `return nil` below would otherwise swallow them before the menu sees them).
            if e.modifierFlags.contains(.command), !e.modifierFlags.contains(.option),
               !e.modifierFlags.contains(.control),
               let ch = e.charactersIgnoringModifiers?.lowercased(), ch == "c" || ch == "x" || ch == "v" || ch == "p" {
                return e // ⌘P → File ▸ Print… (the menu key equivalent must see the event)
            }
            // ⌘A select-all-in-viewport / ⌘D deselect-all — calendar-owned (a focused text field kept ⌘A above).
            if e.modifierFlags.contains(.command), !e.modifierFlags.contains(.option),
               !e.modifierFlags.contains(.control), !e.isARepeat,
               let ch = e.charactersIgnoringModifiers?.lowercased() {
                if ch == "a" {
                    engine?.selectAllInViewport(); return nil
                }
                if ch == "d" {
                    engine?.deselectAll(); return nil
                }
            }
            engine?.wake() // calendar-owned key → drive a render (keyboard cursor/nav)
            if let token = Self.token(for: e) {
                // ⌘T → "go to today" from ANY navigation state (not just ones whose bindings include it).
                // Handled here so it's truly global; ignore OS auto-repeat so a held ⌘T flies once.
                if token == .cmdT {
                    if !e.isARepeat {
                        engine?.enterKeyboardMode(); engine?.goToToday()
                    }
                    return nil
                }
                // ⌘L → new deadline, also global: at the block cursor in keyboard mode, else at the
                // mouse pointer's timeline slot (the engine picks; no mode switch here).
                if token == .cmdL {
                    if !e.isARepeat {
                        engine?.createDeadlineViaShortcut()
                    }
                    return nil
                }
                // Repeatable keys (arrows, ⌘/⇧-arrows): we drive the auto-repeat OURSELVES (see the held-key
                // timer below) instead of the OS. macOS only repeats the LAST key pressed and never resumes
                // an earlier still-held key — so holding ← then tapping ↓ would "stick". Ignoring the OS
                // repeat and repeating the most-recently-held key ourselves keeps ← going after ↓ releases.
                if token.repeats {
                    if e.isARepeat {
                        return nil
                    } // OS repeat suppressed; our timer drives it
                    dispatchNav(token) // fire once on the fresh press (reveal-first handled inside)
                    trackHeld(e.keyCode, token)
                    return nil
                }
                // Discrete actions (Enter/Space/Tab/Esc/…): ignore OS auto-repeat (would double-fire).
                if e.isARepeat {
                    return nil
                }
                if onKey?(token) == true {
                    engine?.enterKeyboardMode(); return nil
                } // dispatched → keyboard mode
            }
            switch e.keyCode { // fallbacks for keys the current state didn't bind
            case 53: engine?.enterKeyboardMode(); engine?.onEscape() // Esc → zoom out one level
            case 51, 117: onRequestDelete?() // Delete → raise the confirm dialog
            default: break
            }
            // Swallow any other unhandled key too. With no text field focused, the calendar owns the
            // keyboard; letting a key fall through to the window makes it emit the "funk" beep (e.g.
            // Space while the drawer is open). Command-shortcuts are handled earlier via menu key
            // equivalents, so they're unaffected. This is why we don't need to touch the window.
            return nil
        case .keyUp:
            if e.keyCode == 40, keyGuideShown {
                keyGuideShown = false; onKeyGuide?(false); return nil
            }
            if releaseHeld(e.keyCode) {
                return nil
            } // a held nav key lifted → update the repeat set
            return e
        case .flagsChanged:
            if keyGuideShown, !e.modifierFlags.contains(.command) {
                keyGuideShown = false; onKeyGuide?(false)
            }
            return e
        default: return e
        }
    }

    // ── Custom auto-repeat for held navigation keys ────────────────────────────────────────────────
    // macOS repeats only the most-recently-pressed key and never resumes a still-held earlier one. We
    // track held repeatable keys ourselves and repeat the LAST one still down, so holding ← then tapping
    // ↓ resumes ← after ↓ is released (block & band cursors, event nav, etc.).

    /// Dispatch a nav token (with reveal-first): the first arrow after mouse mode only wakes the cursor.
    private func dispatchNav(_ token: KeyToken) {
        if isTextInputFocused() {
            return
        }
        engine?.wake()
        let isArrow = token == .up || token == .down || token == .left || token == .right
        if isArrow, engine?.cursor.keyboardActive == false {
            engine?.enterKeyboardMode(); return
        }
        if onKey?(token) == true {
            engine?.enterKeyboardMode()
        }
    }

    private func trackHeld(_ kc: UInt16, _ token: KeyToken) {
        heldOrder.removeAll { $0 == kc }; heldOrder.append(kc); heldToken[kc] = token
        repeatTimer?.invalidate() // fresh press → restart the delay-then-repeat cycle
        repeatTimer = Timer
            .scheduledTimer(withTimeInterval: repeatDelay, repeats: false) { [weak self] _ in self?.beginRepeating() }
    }

    private func releaseHeld(_ kc: UInt16) -> Bool {
        guard heldToken[kc] != nil else { return false }
        heldOrder.removeAll { $0 == kc }; heldToken[kc] = nil
        if heldOrder.isEmpty {
            stopRepeat()
        } // keep firing the remaining held key(s)
        return true
    }

    private func beginRepeating() {
        repeatTimer?.invalidate()
        repeatTimer = Timer.scheduledTimer(withTimeInterval: repeatInterval, repeats: true) { [weak self] _ in
            guard let self, self.window?.isKeyWindow == true, let kc = self.heldOrder.last,
                  let token = self.heldToken[kc]
            else { self?.stopRepeat(); return }
            self.dispatchNav(token)
        }
    }

    private func stopRepeat() {
        repeatTimer?.invalidate(); repeatTimer = nil; heldOrder.removeAll(); heldToken.removeAll()
    }

    /// Is a real text-input view the first responder? Then keys belong to it (typing / native undo),
    /// so the shortcut monitor steps aside. Covers the field editor (NSText) and the notes WKWebView.
    private func isTextInputFocused() -> Bool {
        // A drawer inline editor (the date/time NSDatePicker) owns the keyboard even though its focused
        // control isn't an NSText — pass all keys (incl. Tab) to it, don't advance the drawer cycle.
        if isEditingText?() == true {
            return true
        }
        guard let r = window?.firstResponder else { return false }
        if r === self {
            return false
        }
        // If focus lives inside a notes editor, trust ITS click-gate — not the raw responder class.
        // WebKit makes the WKWebView's internal WKContentView first responder on load, so a class-name
        // match would wrongly report "editing" the moment the drawer opens and swallow drawer shortcuts.
        // Walking up to the FocusGatedWebView and reading focusAllowed tells us if the user *clicked in*.
        if let v = r as? NSView {
            var node: NSView? = v
            while let cur = node {
                // Any gated web editor (drawer notes OR the daily-note dashboard) → trust its click-gate.
                if let gated = cur as? FocusGatedControl {
                    return gated.focusAllowed
                }
                node = cur.superview
            }
        }
        if r is NSText {
            return true
        } // a field editor (NSTextField / inline title) owns the keys
        let cls = String(describing: type(of: r))
        return cls.contains("TextView") || cls.contains("TextField")
    }

    /// Normalize a raw key event into a view-independent `KeyToken` (or nil to leave it to native).
    private static func token(for e: NSEvent) -> KeyToken? {
        if e.modifierFlags.contains(.command) {
            switch e.keyCode { // ⌘+arrows → nudge the selected event
            case 126: return .cmdUp
            case 125: return .cmdDown
            case 123: return .cmdLeft
            case 124: return .cmdRight
            default:
                switch e.charactersIgnoringModifiers?.lowercased() {
                case "s": return .cmdS
                case "n": return .cmdN
                case "t": return .cmdT // ⌘T → go to today (any view)
                case "u": return .cmdU // ⌘U → toggle promote on the selected timed event
                case "l": return .cmdL // ⌘L → new deadline at pointer / block cursor
                case "=", "+": return .cmdEqual // ⌘= / ⌘+ → zoom in
                case "-", "_": return .cmdMinus // ⌘− → zoom out
                default: return nil // other ⌘-combos → menu/native
                }
            }
        }
        let shift = e.modifierFlags.contains(.shift)
        switch e.keyCode {
        case 36, 76: return .enter
        case 49: return .space
        case 53: return .escape
        case 48: return shift ? .backTab : .tab
        case 123: return shift ? .shiftLeft : .left
        case 124: return shift ? .shiftRight : .right
        case 126: return shift ? .shiftUp : .up
        case 125: return shift ? .shiftDown : .down
        case 51, 117: return .delete
        default:
            if let ch = e.charactersIgnoringModifiers?.first, ch.isLetter || ch.isNumber {
                return .char(ch)
            }
            return nil
        }
    }

    /// Standard Undo/Redo actions. These reach the CatcherView ONLY when the calendar canvas is the
    /// first responder — when a text field / editor is focused it's first in the chain and does its own
    /// text undo instead, so ⌘Z layers correctly (text edits vs calendar edits).
    @objc func undo(_ sender: Any?) {
        engine?.undo()
    }

    @objc func redo(_ sender: Any?) {
        engine?.redo()
    }
}
