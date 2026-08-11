// Shared bits that outlived the retired WKWebView markdown editor (MarkdownWebEditor — the
// app's last webview, removed 2026-08 along with its ~3MB bundled JS and the webeditor/
// build workspace): the edit/preview mode enum the drawer + dashboard note editors key on,
// and the focus-gating protocol the keyboard catcher consults.

import AppKit

/// Editor mode for the notes surfaces (drawer + dashboards): raw markdown vs rendered preview.
enum NotesMode: Hashable { case edit, preview }

/// A control that may sit under the pointer without owning the keyboard until clicked into.
/// Currently unadopted — its only conformer was the retired web editor — but the keyboard
/// catcher's responder walk still consults it, and any future embedded control re-adopts.
protocol FocusGatedControl: AnyObject { var focusAllowed: Bool { get } }
