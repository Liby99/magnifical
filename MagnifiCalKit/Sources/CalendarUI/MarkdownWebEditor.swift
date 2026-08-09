// The notes markdown editor: a transparent WKWebView hosting the bundled CodeMirror + remark/KaTeX
// editor (see webeditor/). Reusable — bind `text`, flip `mode` (.edit / .preview); the drawer owns
// the toggle. Background is transparent so the drawer's glass shows through.

import AppKit
import SwiftUI
import WebKit

enum NotesMode: Hashable { case edit, preview }

/// A gated web editor: exposes whether the user has actually engaged it, so the calendar's key monitor
/// can tell "typing in the notes editor" (pass keys through) from "the web view grabbed focus on load"
/// (keys still belong to the calendar). Both the drawer notes and the daily-note editors conform.
protocol FocusGatedControl: AnyObject { var focusAllowed: Bool { get } }

/// A WKWebView that does NOT grab first responder when it loads. WKWebView otherwise makes itself
/// first responder on load — even with no auto-focusing content — so simply putting the notes editor
/// on screen (e.g. opening the drawer) would steal keyboard focus into it. Here `becomeFirstResponder`
/// is refused until the user actually clicks the editor (or `enableFocus()` is called, e.g. to Tab into
/// it); after that it behaves like a normal web view.
final class FocusGatedWebView: WKWebView, FocusGatedControl {
    /// Readable so the keyboard monitor can tell "user clicked into notes" (real editing → pass keys
    /// through) from "WebKit grabbed focus on load" (its internal WKContentView became first responder
    /// even though we refuse it here — treat as NOT editing so drawer shortcuts still fire).
    private(set) var focusAllowed = false
    /// Permit focus (a real click, or an explicit programmatic focus request such as Tab-to-notes).
    func enableFocus() {
        focusAllowed = true
    }

    override func becomeFirstResponder() -> Bool {
        focusAllowed ? super.becomeFirstResponder() : false
    }

    override func mouseDown(with event: NSEvent) {
        focusAllowed = true; super.mouseDown(with: event)
    }
}

struct MarkdownWebEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var mode: NotesMode
    var placeholder = "Something to note about this event?" // scope-aware empty-note hint
    var theme: Theme
    // Keyboard integration (drawer): bump `focusPulse` to grab keyboard focus (switch to edit + focus
    // CodeMirror). `onExit` fires on Escape in the editor; `onSavePreview` on ⌘S — both let the host
    // return focus to the drawer's field ring.
    var focusPulse: Int = 0
    var onExit: () -> Void = {}
    var onSavePreview: () -> Void = {}
    /// Entity-index JSON provider (engine.entityIndexJSON) → @project:/@person:/#tag completions.
    /// nil → entity completion off (date completion always works).
    var entityIndex: (() -> String)?
    /// "due: this event time" completion value — the note's own moment (engine.dueAnchorString).
    var dueAnchor: (() -> String?)?

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, mode: $mode)
    }

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(context.coordinator, name: "ck")
        // Lift WebKit's 60fps rendering cap (typing/scroll feel on 120Hz displays).
        Self.liftWeb60Cap(cfg.preferences)
        let web: WKWebView = FocusGatedWebView(frame: .zero,
                                               configuration: cfg) // don't steal focus when the drawer opens
        web.setValue(false, forKey: "drawsBackground") // transparent → glass shows through
        web.navigationDelegate = context.coordinator // open link clicks in the system browser
        context.coordinator.web = web
        if let root = editorRoot {
            web.loadFileURL(root.appendingPathComponent("editor.html"), allowingReadAccessTo: root)
        }
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        let c = context.coordinator
        c.text = $text; c.mode = $mode // re-target: the bound note switches with the drawer's scope
        c.onExit = onExit; c.onSavePreview = onSavePreview
        c.apply(text: text, mode: mode, theme: themeVars(), entityIndex: entityIndex?(),
                placeholder: placeholder, dueAnchor: dueAnchor?() ?? nil)
        if focusPulse != c.lastFocusPulse {
            c.lastFocusPulse = focusPulse; c.grabFocus()
        } // keyboard: focus the editor
    }

    private var editorRoot: URL? {
        Bundle.module.resourceURL?.appendingPathComponent("editor", isDirectory: true)
    }

    private func themeVars() -> [String: String] {
        [
            "--accent-dark": cssColor(theme.text),
            "--accent-grey": cssColor(theme.accentGrey),
            "--highlight": String(format: "#%06x", AccentPref.hex), // follows Settings ▸ Accent Color
            "--check-mark": cssColor(theme.bg), // ✓ punched from the filled checkbox → window bg tone
            "color-scheme": theme.dark ? "dark" : "light",
        ]
    }

    private func cssColor(_ c: Color) -> String {
        guard let n = NSColor(c).usingColorSpace(.sRGB) else { return "#e8e8ea" }
        return String(format: "rgba(%d,%d,%d,%.3f)", Int(n.redComponent * 255), Int(n.greenComponent * 255),
                      Int(n.blueComponent * 255), n.alphaComponent)
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        // MUTABLE: the drawer hands this view a SWITCHING binding (series note vs. per-occurrence
        // note, by scope). The coordinator outlives every re-render, so a `let` captured at
        // creation kept writing the ORIGINAL target forever — typing in "This Event" scope
        // silently edited the series note. updateNSView refreshes these every pass.
        var text: Binding<String>
        var mode: Binding<NotesMode>
        weak var web: WKWebView?
        private var ready = false
        private var lastSent = "" // last value pushed to / received from JS (echo guard)
        private var lastEntityIndex = "" // dedup — the gen-cached JSON only changes on real edits
        private var lastDueAnchor: String?
        private var want: (text: String, mode: NotesMode, theme: [String: String], entityIndex: String?,
                           placeholder: String, dueAnchor: String?)?
        private var lastPlaceholder = ""
        private var pendingCursorLine: Int? // ⌘-clicked preview line → place caret after mode flip
        var onExit: () -> Void = {} // Escape in the editor → host returns focus to the ring
        var onSavePreview: () -> Void = {} // ⌘S → preview → host returns focus to the ring
        var lastFocusPulse = 0 // dedup the keyboard focus trigger (see grabFocus)
        init(text: Binding<String>, mode: Binding<NotesMode>) {
            self.text = text; self.mode = mode
        }

        /// Keyboard: switch to edit mode and focus CodeMirror. For the drawer's FocusGatedWebView we
        /// must first allow focus (it refuses it by default) and make it first responder.
        func grabFocus() {
            guard let web else { return }
            (web as? FocusGatedWebView)?.enableFocus()
            web.window?.makeFirstResponder(web)
            mode.wrappedValue = .edit
            eval("CK.setMode('edit'); CK.focus()")
        }

        func apply(text: String, mode: NotesMode, theme: [String: String], entityIndex: String?,
                   placeholder: String, dueAnchor: String?) {
            want = (text, mode, theme, entityIndex, placeholder, dueAnchor)
            guard ready else { return }
            push(theme)
            if placeholder != lastPlaceholder {
                lastPlaceholder = placeholder; eval("CK.setPlaceholder(\(jsString(placeholder)))")
            }
            if let idx = entityIndex, idx != lastEntityIndex {
                lastEntityIndex = idx; eval("CK.setEntityIndex(\(idx))")
            }
            if dueAnchor != lastDueAnchor {
                lastDueAnchor = dueAnchor
                eval("CK.setDueAnchor(\(dueAnchor.map(jsString) ?? "null"))")
            }
            if text != lastSent {
                lastSent = text; eval("CK.setValue(\(jsString(text)))")
            }
            eval("CK.setMode('\(mode == .edit ? "edit" : "preview")')")
            if mode == .edit, let ln = pendingCursorLine {
                pendingCursorLine = nil; eval("CK.setCursorLine(\(ln))")
            }
        }

        func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            switch type {
            case "ready":
                ready = true
                if let w = want {
                    push(w.theme); lastSent = w
                        .text; eval("CK.setValue(\(jsString(w.text)))"); eval(
                            "CK.setMode('\(w.mode == .edit ? "edit" : "preview")')"
                        )
                    lastPlaceholder = w.placeholder
                    eval("CK.setPlaceholder(\(jsString(w.placeholder)))")
                    if let idx = w.entityIndex {
                        lastEntityIndex = idx; eval("CK.setEntityIndex(\(idx))")
                    }
                    if let a = w.dueAnchor {
                        lastDueAnchor = a; eval("CK.setDueAnchor(\(jsString(a)))")
                    }
                }
            case "change":
                if let v = body["value"] as? String {
                    lastSent = v; text.wrappedValue = v
                }
            case "openLink":
                if let s = body["url"] as? String, let u = URL(string: s) {
                    NSWorkspace.shared.open(u)
                }
            case "editAt":
                // ⌘-click in preview → remember the line, flip to edit; apply() places the caret.
                if let line = body["line"] as? Int {
                    pendingCursorLine = line; mode.wrappedValue = .edit
                }
            case "preview":
                mode.wrappedValue = .preview // ⌘S in the editor
                onSavePreview() // …and hand focus back to the drawer's field ring
            case "exit":
                onExit() // Escape in the editor → back to the ring
            default: break
            }
        }

        /// A clicked http(s) link opens in the default browser instead of navigating the editor away.
        /// file:// (the editor bundle itself) and other schemes load normally.
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = navigationAction.request.url, let s = url.scheme?.lowercased(), s == "http" || s == "https" {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }

        private func push(_ theme: [String: String]) {
            guard !theme.isEmpty, let data = try? JSONSerialization.data(withJSONObject: theme),
                  let json = String(data: data, encoding: .utf8) else { return }
            eval("CK.setTheme(\(json))")
        }

        private func eval(_ js: String) {
            web?.evaluateJavaScript(js)
        }

        private func jsString(_ s: String) -> String {
            (try? String(data: JSONEncoder().encode(s), encoding: .utf8) ?? "\"\"") ?? "\"\""
        }
    }

    /// WebKit caps page rendering near 60fps by default; flip the private feature flag so typing
    /// and scrolling track 120Hz displays. (Moved from the retired dashboard webview, phase 4a.)
    static func liftWeb60Cap(_ prefs: WKPreferences) {
        guard ProcessInfo.processInfo.environment["CC_WEB120_OFF"] == nil else { return }
        let listSel = NSSelectorFromString("_features")
        let setSel = NSSelectorFromString("_setEnabled:forFeature:")
        guard let cls = WKPreferences.self as AnyObject as? NSObject.Type,
              cls.responds(to: listSel), prefs.responds(to: setSel),
              let features = cls.perform(listSel)?.takeUnretainedValue() as? [NSObject],
              let flag = features.first(where: {
                  ($0.value(forKey: "key") as? String) == "PreferPageRenderingUpdatesNear60FPSEnabled"
              })
        else { return }
        // _setEnabled: takes a BOOL — perform(_:with:) would box it as an object, so go
        // through the raw IMP with the proper C signature.
        typealias SetEnabled = @convention(c) (NSObject, Selector, Bool, NSObject) -> Void
        unsafeBitCast(prefs.method(for: setSel), to: SetEnabled.self)(prefs, setSel, false, flag)
    }
}
