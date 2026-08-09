// Reusable CodeMirror note editor + remark/KaTeX preview — the building block shared by the drawer
// (editor.ts) and the daily-dashboard NOTE tab (dashboard.ts). Same theme + markdown highlighting as
// the web's NotesEditor, same remark pipeline (remark-gfm + remark-math + remarkTodoTokens +
// rehype-katex) as NotesPreview. Host wires the callbacks to its own Swift bridge.

import { EditorView, keymap, placeholder as cmPlaceholder, drawSelection } from "@codemirror/view";
import { Compartment, EditorState, Prec } from "@codemirror/state";
import { history, defaultKeymap, historyKeymap, indentMore, indentLess } from "@codemirror/commands";
import { acceptCompletion, autocompletion, closeCompletion, completionStatus, startCompletion,
         type Completion, type CompletionContext, type CompletionResult } from "@codemirror/autocomplete";
import { markdown } from "@codemirror/lang-markdown";
import { HighlightStyle, syntaxHighlighting, syntaxTree } from "@codemirror/language";
import { tags as t } from "@lezer/highlight";

import { unified } from "unified";
import remarkParse from "remark-parse";
import remarkGfm from "remark-gfm";
import remarkMath from "remark-math";
import remarkRehype from "remark-rehype";
import rehypeKatex from "rehype-katex";
import rehypeStringify from "rehype-stringify";
import remarkTodoTokens from "../../../src/app/calendar/view/notes/remarkTodoTokens";
import { linesNeedingCreated, toggleTodoLine } from "../../../src/lib/assistant/tools/todos";
import { splitNote, parseManaged } from "../../../src/lib/import/managedNote";

const MONO = "var(--font-mono, Menlo, ui-monospace, SFMono-Regular, Consolas, monospace)";

const cmTheme = EditorView.theme({
  "&": { backgroundColor: "transparent", color: "var(--accent-dark)", height: "100%", fontSize: "13px" },
  "&.cm-focused": { outline: "none" },
  ".cm-scroller": { fontFamily: MONO, lineHeight: "1.55" },
  ".cm-content": { padding: "1px 0 12px", caretColor: "var(--accent-dark)" },
  ".cm-line": { padding: "0 2px 0 0" },
  ".cm-cursor, .cm-dropCursor": { borderLeftColor: "var(--accent-dark)" },
  ".cm-gutters": { display: "none" },
  ".cm-selectionBackground, &.cm-focused .cm-selectionBackground": {
    backgroundColor: "color-mix(in srgb, var(--highlight) 24%, transparent) !important",
  },
  ".cm-activeLine": { backgroundColor: "transparent" },
  ".cm-md-link": { textDecoration: "underline", textUnderlineOffset: "2px" },
});

const mdHighlight = Prec.highest(syntaxHighlighting(HighlightStyle.define([
  { tag: t.heading, fontWeight: "700", color: "var(--accent-dark)" },
  { tag: t.strong, fontWeight: "700" },
  { tag: t.emphasis, fontStyle: "italic" },
  { tag: t.strikethrough, textDecoration: "line-through" },
  { tag: [t.link, t.url], color: "var(--highlight)", class: "cm-md-link" },
  { tag: t.monospace, fontFamily: MONO, color: "var(--accent-dark)" },
  { tag: t.quote, color: "var(--accent-grey)", fontStyle: "italic" },
  { tag: [t.processingInstruction, t.contentSeparator], color: "var(--accent-grey)" },
])));

function linkAt(view: EditorView, pos: number): string | null {
  const tree = syntaxTree(view.state);
  for (let n: any = tree.resolveInner(pos, -1); n; n = n.parent) {
    if (n.name === "URL") return view.state.sliceDoc(n.from, n.to);
    if (n.name === "Link") { const u = n.getChild("URL"); if (u) return view.state.sliceDoc(u.from, u.to); }
  }
  return null;
}

function rehypeSourceLines() {
  const BLOCK = new Set(["p", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "pre", "li", "ul", "ol", "table", "hr"]);
  const walk = (node: any) => {
    if (node.type === "element" && BLOCK.has(node.tagName) && node.position?.start?.line) {
      node.properties = node.properties || {};
      node.properties.dataSrcline = node.position.start.line;
    }
    (node.children || []).forEach(walk);
  };
  return (tree: any) => walk(tree);
}

const md = unified()
  .use(remarkParse).use(remarkGfm).use(remarkMath).use(remarkTodoTokens)
  .use(remarkRehype).use(rehypeKatex).use(rehypeSourceLines).use(rehypeStringify);

function mdHtml(src: string): string { try { return String(md.processSync(src)); } catch { return ""; } }
const escHtml = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
const escAttr = (s: string) => escHtml(s).replace(/"/g, "&quot;");

/** Render a note → HTML. An imported "managed block" (§7) renders as a read-only key:value table
 *  (provenance, location, meeting link, organizer, attendees) + description, matching the web drawer;
 *  the user's own text below it renders as normal markdown. Plain notes render straight through. */
export function renderMarkdown(src: string): string {
  const { managed, user } = splitNote(src);
  if (!managed) return mdHtml(src);
  const { fields, description } = parseManaged(managed);
  const rows = fields.map((f) =>
    `<div class="cc-dw-mi-row"><span class="cc-dw-mi-key">${escHtml(f.label)}</span>` +
    `<span class="cc-dw-mi-val">${f.href
      ? `<a href="${escAttr(f.href)}" target="_blank" rel="noopener noreferrer">${escHtml(f.value)}</a>`
      : escHtml(f.value)}</span></div>`).join("");
  const desc = description ? `<div class="cc-dw-mi-desc">${mdHtml(description)}</div>` : "";
  return `<div class="cc-dw-mi">${rows}${desc}</div>${mdHtml(user)}`;
}

/** Post-process a rendered markdown container: wrap each task item's OWN inline content in
 *  `.cc-task-text` (so the done strikethrough hits the text but not nested sub-lists), and mark
 *  checked items with `.cc-task-done` on their <li>. Shared by the live preview AND the static
 *  note panels, so a checked box looks identical everywhere. */
export function decorateTaskItems(root: HTMLElement) {
  root.querySelectorAll<HTMLInputElement>('.task-list-item input[type="checkbox"]').forEach((box) => {
    const host = box.parentElement; // the <li> (tight list) or its <p> (loose list)
    if (host) {
      const wrap = document.createElement("span");
      wrap.className = "cc-task-text";
      let n: ChildNode | null = box.nextSibling;
      while (n && !(n instanceof HTMLElement && (n.tagName === "UL" || n.tagName === "OL"))) {
        const nx: ChildNode | null = n.nextSibling;
        wrap.appendChild(n);
        n = nx;
      }
      host.insertBefore(wrap, n);
    }
    box.closest("li")?.classList.toggle("cc-task-done", box.checked);
  });
}

export const TASK_RE = /^(\s*(?:[-*+]|\d+[.)])\s+)\[([ xX])\](.*)$/;

/** Wall-clock `created:` stamp — floating local time, minute precision (like the app's times). */
function localStamp(): string {
  const d = new Date(), p2 = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${p2(d.getMonth() + 1)}-${p2(d.getDate())}T${p2(d.getHours())}:${p2(d.getMinutes())}`;
}

export interface NoteEditorHandle {
  setValue(v: string): void;
  setMode(mode: "edit" | "preview"): void;
  focus(): void;
  setCursorLine(line: number): void;
  selectLine(line: number): void;       // select a whole source line (todo-row jump landing)
  setPlaceholder(text: string): void;   // scope-aware empty-note hint (Daily/Weekly/Monthly)
}
export interface NoteEditorOpts {
  editorEl: HTMLElement;
  previewEl: HTMLElement;
  placeholder?: string;
  /// Live entity index for @project: / @person: / #tag completions (non-persistent — the host
  /// derives it from its in-memory data). Omitted → entity completion off; DATE completion
  /// (due:/created:/done:) needs no index and always works.
  completionIndex?: () => { projects: string[]; people: string[]; tags: string[] };
  /// Context anchor offered after `due:` — the note's OWN moment ("this event time" with the
  /// event's datetime in the drawer; "this day time" with the day's date in a daily note).
  dueAnchor?: () => { label: string; value: string } | null;
  onChange: (value: string) => void;
  onPreview: () => void;                 // ⌘S in the editor
  onOpenLink: (url: string) => void;     // ⌘-click a link
  onEditAt: (line: number) => void;      // ⌘-click a preview block → edit at that line
  onExit?: () => void;                   // Escape in the editor → hand focus back to the host
  emptyPreview?: () => string;           // HTML for preview mode when the note is empty (else blank)
}

// ── Autocomplete ────────────────────────────────────────────────────────────────────────────────
// Entities from the host's live index (@project:, @person:, bare @, #tag) + date concretization
// after due:/created:/done: — "now", "today", "3d", "2w", "july-5", "7/5" all resolve to real
// date(-time) strings, shown in the dropdown and inserted on Enter/Tab.

const MONTHS_LC = ["january", "february", "march", "april", "may", "june", "july", "august",
                   "september", "october", "november", "december"];
const p2c = (n: number) => String(n).padStart(2, "0");
const dayIso = (d: Date) => `${d.getFullYear()}-${p2c(d.getMonth() + 1)}-${p2c(d.getDate())}`;
const minuteIso = (d: Date) => `${dayIso(d)}T${p2c(d.getHours())}:${p2c(d.getMinutes())}`;

/// Loose date grammar → a concrete Date. `dueOriented` picks the NEXT occurrence for bare
/// month-day forms ("july-5"); created/done resolve within THIS year (they describe the past).
function parseLooseDate(s: string, now: Date, dueOriented: boolean): Date | null {
  s = s.toLowerCase();
  let m = s.match(/^(\d+)(d|w|m)$/); // relative: 3d, 2w, 1m (from now)
  if (m) {
    const n = +m[1], d = new Date(now);
    if (m[2] === "d") d.setDate(d.getDate() + n);
    else if (m[2] === "w") d.setDate(d.getDate() + 7 * n);
    else d.setMonth(d.getMonth() + n);
    return d;
  }
  m = s.match(/^([a-z]{3,9})[-/ ]?(\d{1,2})$/); // month-day: july-5, jul5, march 12
  if (m) {
    const mi = MONTHS_LC.findIndex((x) => x.startsWith(m![1]));
    const day = +m[2];
    if (mi < 0 || day < 1 || day > 31) return null;
    let d = new Date(now.getFullYear(), mi, day);
    if (dueOriented && d.getTime() < now.getTime() - 86_400_000) {
      d = new Date(now.getFullYear() + 1, mi, day);
    }
    return d;
  }
  m = s.match(/^(\d{1,2})[-/](\d{1,2})$/); // numeric month-day: 7-5, 7/5
  if (m) {
    const mo = +m[1], day = +m[2];
    if (mo < 1 || mo > 12 || day < 1 || day > 31) return null;
    let d = new Date(now.getFullYear(), mo - 1, day);
    if (dueOriented && d.getTime() < now.getTime() - 86_400_000) {
      d = new Date(now.getFullYear() + 1, mo - 1, day);
    }
    return d;
  }
  return null;
}

function dateSource(o: NoteEditorOpts) {
  return (ctx: CompletionContext): CompletionResult | null => {
  const m = ctx.matchBefore(/(?:due|created|done|start):[\w/-]*$/);
  if (!m) return null;
  const text = ctx.state.sliceDoc(m.from, m.to);
  const ci = text.indexOf(":");
  const key = text.slice(0, ci), partial = text.slice(ci + 1);
  const now = new Date();
  const wantTime = key === "created" || key === "done"; // stamps carry minutes; due/start are dates
  const futureOriented = key === "due" || key === "start"; // planning tokens point forward
  const conc = (d: Date) => (wantTime ? minuteIso(d) : dayIso(d));
  const opts: Completion[] = [];
  const push = (label: string, d: Date, boost = 0) =>
    opts.push({ label, detail: `→ ${conc(d)}`, apply: conc(d), type: "constant", boost });
  const parsed = parseLooseDate(partial, now, futureOriented);
  if (parsed) {
    push(partial, parsed, 3); // the typed freeform, concretized, on top
  }
  // due:/start: weekday names (any prefix — "thu", "th", even "t") → the NEXT such weekday after
  // today. Ambiguous prefixes list every match ("t" → tue + thu), each with its resolved date.
  if (futureOriented && /^[a-z]+$/i.test(partial)) {
    const WD_LC = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"];
    const pl = partial.toLowerCase();
    WD_LC.forEach((w, i) => {
      if (w.startsWith(pl)) {
        const d = new Date(now);
        d.setDate(d.getDate() + (((i - now.getDay()) + 7) % 7 || 7)); // strictly future
        push(w.slice(0, 3), d, 2);
      }
    });
  }
  const statics: [string, Date][] = [
    ["now", now], ["today", now], ["tomorrow", new Date(now.getTime() + 86_400_000)],
    ["3d", new Date(now.getTime() + 3 * 86_400_000)], ["1w", new Date(now.getTime() + 7 * 86_400_000)],
  ];
  for (const [l, d] of statics) {
    if (l.startsWith(partial.toLowerCase()) && l !== partial) {
      push(l, d);
    }
  }
  // The note's own moment — "this event time" in the drawer, "this day time" in a daily note.
  if (key === "due") {
    const anchor = o.dueAnchor?.();
    if (anchor && (!partial || anchor.label.startsWith(partial.toLowerCase()))) {
      opts.push({ label: anchor.label, detail: `→ ${anchor.value}`, apply: anchor.value,
                  type: "constant", boost: 2 });
    }
  }
  if (!opts.length) return null;
  return { from: m.from + ci + 1, options: opts, filter: false };
  };
}

function entitySource(o: NoteEditorOpts) {
  return (ctx: CompletionContext): CompletionResult | null => {
    const idx = o.completionIndex?.();
    if (!idx) return null;
    const list = (from: number, xs: string[], type: string): CompletionResult | null =>
      xs.length ? { from, options: xs.map((x): Completion => ({ label: x, type })),
                    validFor: /^[\w-]*$/ } : null;
    let m = ctx.matchBefore(/@project:[\w-]*$/);
    if (m) return list(m.from + 9, idx.projects, "keyword");
    m = ctx.matchBefore(/@person:[\w-]*$/);
    if (m) return list(m.from + 8, idx.people, "constant");
    m = ctx.matchBefore(/@[\w-]*$/); // bare @ = person, plus the two namespace prefixes
    if (m) {
      const reopen = (view: EditorView, _c: Completion, from: number, to: number, ins: string) => {
        view.dispatch({ changes: { from, to, insert: ins } });
        startCompletion(view); // "@project:" placed → immediately offer the keys
      };
      const options: Completion[] = [
        ...idx.people.map((x): Completion => ({ label: x, type: "constant" })),
        { label: "project:", type: "keyword", boost: -1,
          apply: (v, c, f, t2) => reopen(v, c, f, t2, "project:") },
        { label: "person:", type: "keyword", boost: -1,
          apply: (v, c, f, t2) => reopen(v, c, f, t2, "person:") },
      ];
      return { from: m.from + 1, options, validFor: /^[\w-]*$/ };
    }
    m = ctx.matchBefore(/#[\w-]*$/);
    if (m) return list(m.from + 1, idx.tags, "type");
    return null;
  };
}

export function createNoteEditor(o: NoteEditorOpts): NoteEditorHandle {
  const { editorEl, previewEl } = o;
  let applyingRemote = false;   // suppress the change echo while the host sets the value
  let sessionDirty = false;     // the user edited THIS note since it was loaded / last stamped
  const phComp = new Compartment();   // placeholder is retargetable (setPlaceholder) per scope

  // ── "Start time marking" ───────────────────────────────────────────────────────────────────────
  // When an editing session ends (Esc / ⌘S / focus loss / switch to preview), every TOP-LEVEL task
  // line without a `created:` token gets one, stamped with the session-end wall clock. Guarded by
  // `sessionDirty` so merely opening or previewing a note never back-stamps old items — only notes
  // the user actually edited. Per-line insertions through the view keep undo history + the cursor
  // intact, and the normal updateListener → onChange path persists the rewrite.
  function stampCreated() {
    if (!sessionDirty) return;
    const doc = view.state.doc;
    const lines = linesNeedingCreated(doc.toString());
    if (lines.length) {
      const stamp = ` created:${localStamp()}`;
      view.dispatch({
        changes: lines.map((n) => {
          const ln = doc.line(n);
          return { from: ln.from + ln.text.replace(/\s+$/, "").length, to: ln.to, insert: stamp };
        }),
      });
    }
    sessionDirty = false;   // after the dispatch — its own change re-marks dirty, so clear last
  }

  const openLinks = EditorView.domEventHandlers({
    mousedown(e, view) {
      if (!(e.metaKey || e.ctrlKey) || (e as MouseEvent).button !== 0) return false;
      const pos = view.posAtCoords({ x: (e as MouseEvent).clientX, y: (e as MouseEvent).clientY });
      if (pos == null) return false;
      const raw = linkAt(view, pos);
      if (!raw) return false;
      e.preventDefault();
      o.onOpenLink(/^[a-z][a-z0-9+.-]*:/i.test(raw) ? raw : `https://${raw}`);
      return true;
    },
  });

  const view = new EditorView({
    parent: editorEl,
    state: EditorState.create({
      doc: "",
      extensions: [
        history(),
        // Tab/⇧Tab indent/outdent the line(s) — never native focus traversal; nested `- [ ]` items are
        // how sub-tasks are made. Enter already continues list/task markers (markdown()'s own keymap)
        // and ⌥↑/⌥↓ move lines, ⌘←/→ jump line bounds (defaultKeymap).
        // Tab ACCEPTS an open completion first (returns false when none → falls through to indent).
        keymap.of([{ key: "Tab", run: acceptCompletion },
                   { key: "Tab", run: indentMore, shift: indentLess }, ...defaultKeymap, ...historyKeymap]),
        // Entity + date autocomplete (the package's own keymap adds Enter-accept / arrows / Esc).
        autocompletion({ override: [entitySource(o), dateSource(o)], icons: false }),
        drawSelection(),
        EditorView.lineWrapping,
        markdown(),
        cmTheme,
        mdHighlight,
        openLinks,
        Prec.highest(keymap.of([
          { key: "Mod-s", preventDefault: true, stopPropagation: true, run: () => { stampCreated(); o.onPreview(); return true; } },
          { key: "Escape", preventDefault: true, stopPropagation: true, run: (v) => {
            if (completionStatus(v.state)) {
              return closeCompletion(v); // first Esc dismisses the dropdown, not the editor
            }
            stampCreated(); o.onExit?.(); return true;
          } },
        ])),
        // Focus loss (clicking away, tabbing out, the overlay hiding) also ends the session.
        EditorView.domEventHandlers({ blur: () => { stampCreated(); return false; } }),
        phComp.of(cmPlaceholder(o.placeholder ?? "Something to note…")),
        EditorView.updateListener.of((u) => {
          if (u.docChanged && !applyingRemote) { sessionDirty = true; o.onChange(u.state.doc.toString()); }
        }),
      ],
    }),
  });

  function renderPreview() {
    const src = view.state.doc.toString();
    if (!src.trim() && o.emptyPreview) { previewEl.innerHTML = o.emptyPreview(); return; }
    try { previewEl.innerHTML = renderMarkdown(src); }   // managed block → key:value table (§7)
    catch { previewEl.textContent = src; return; }
    decorateTaskItems(previewEl); // .cc-task-text wrap + .cc-task-done (strikethrough styling)
    const taskLines: number[] = [];
    src.split("\n").forEach((ln, i) => { if (TASK_RE.test(ln)) taskLines.push(i); });
    previewEl.querySelectorAll<HTMLInputElement>('input[type="checkbox"]').forEach((box, i) => {
      box.disabled = false;
      const lineIdx = taskLines[i];
      if (lineIdx == null) return;
      box.addEventListener("change", () => toggleTask(lineIdx));
    });
  }

  // Checking in preview = the SAME soft-link write the dashboard uses: flip the checkbox AND
  // stamp/strip the `done:` token, so a preview tick records WHEN it was finished too.
  function toggleTask(lineIdx: number) {
    const src = view.state.doc.toString();
    const next = toggleTodoLine(src, lineIdx + 1, undefined, localStamp());
    if (next == null || next === src) return;
    view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: next } });
    renderPreview();
  }

  previewEl.addEventListener("click", (e) => {
    if (!(e.metaKey || e.ctrlKey)) return;
    const target = e.target as HTMLElement;
    if (target.closest("a, input")) return;
    const el = target.closest("[data-srcline]");
    const line = el ? Number(el.getAttribute("data-srcline")) : 0;
    if (line) { e.preventDefault(); o.onEditAt(line); }
  });

  return {
    setPlaceholder(text: string) {
      view.dispatch({ effects: phComp.reconfigure(cmPlaceholder(text)) });
    },
    setValue(v: string) {
      if (v === view.state.doc.toString()) return;
      applyingRemote = true;
      view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: v } });
      applyingRemote = false;
      sessionDirty = false;   // a host-driven swap starts a fresh session for the new note
      if (previewEl.style.display !== "none") renderPreview();
    },
    setMode(mode: "edit" | "preview") {
      const edit = mode === "edit";
      editorEl.style.display = edit ? "" : "none";
      previewEl.style.display = edit ? "none" : "";
      if (!edit) { stampCreated(); renderPreview(); }
      // CodeMirror measures its scroll geometry lazily; if it was built while the tab was hidden
      // (display:none) it has stale/zero metrics and won't scroll. Re-measure whenever it's shown.
      else queueMicrotask(() => { view.requestMeasure(); view.focus(); });
    },
    focus() { view.focus(); },
    setCursorLine(line: number) {
      const ln = Math.max(1, Math.min(view.state.doc.lines, Math.round(line)));
      const pos = view.state.doc.line(ln).from;
      view.dispatch({ selection: { anchor: pos }, scrollIntoView: true });
      view.focus();
    },
    selectLine(line: number) {
      const ln = Math.max(1, Math.min(view.state.doc.lines, Math.round(line)));
      const l = view.state.doc.line(ln);
      view.dispatch({ selection: { anchor: l.from, head: l.to }, scrollIntoView: true });
      view.focus();
    },
  };
}
