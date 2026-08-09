// The drawer's notes editor: a thin entry that wires the shared CodeMirror note editor
// (noteEditor.ts) to this WKWebView's Swift bridge.
//
// Bridge: Swift → window.CK.{setValue,setMode,setTheme,focus,setCursorLine}; JS → posts to
// window.webkit.messageHandlers.ck ({type:'change'|'preview'|'openLink'|'editAt'|'ready', ...}).

import { createNoteEditor } from "./noteEditor";

function post(msg: any) { (window as any).webkit?.messageHandlers?.ck?.postMessage(msg); }

// Entity index for @project:/@person:/#tag completions — pushed from Swift (the engine's
// database-wide scan); empty until the first CK.setEntityIndex.
let entityIdx = { projects: [] as string[], people: [] as string[], tags: [] as string[] };
let dueAnchorVal: string | null = null; // the event's own moment (pushed from Swift)

const ed = createNoteEditor({
  editorEl: document.getElementById("editor")!,
  previewEl: document.getElementById("preview")!,
  placeholder: "Something to note about this event?",
  onChange: (value) => post({ type: "change", value }),
  onPreview: () => post({ type: "preview" }),
  onOpenLink: (url) => post({ type: "openLink", url }),
  onEditAt: (line) => post({ type: "editAt", line }),
  onExit: () => post({ type: "exit" }),
  completionIndex: () => entityIdx,
  dueAnchor: () => (dueAnchorVal ? { label: "this event time", value: dueAnchorVal } : null),
});

(window as any).CK = {
  setValue: ed.setValue,
  setMode: ed.setMode,
  setPlaceholder: ed.setPlaceholder, // scope-aware empty hint (All Events vs This Event)
  focus: ed.focus,
  setCursorLine: ed.setCursorLine,
  setTheme(vars: Record<string, string>) {
    const root = document.documentElement.style;
    for (const k in vars) root.setProperty(k, vars[k]);
  },
  setEntityIndex(idx: { projects?: string[]; people?: string[]; tags?: string[] }) {
    entityIdx = { projects: idx.projects ?? [], people: idx.people ?? [], tags: idx.tags ?? [] };
  },
  setDueAnchor(v: string | null) { dueAnchorVal = v || null; },
};

post({ type: "ready" });
