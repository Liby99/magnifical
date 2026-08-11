// The Help book's content — a task-based, searchable set of topics shown by HelpView (Help ▸ MagnifiCal Help).
//
// Apple's guidance (Human Interface Guidelines ▸ Offering help / Menus): help should be task-focused,
// brief, conversational, and searchable, with the Help menu as the rightmost menu. We don't register a
// native `.help` bundle (Help Viewer / HTML) — this in-app browser is the modern equivalent, themed and
// able to reference the tutorial GIFs.
//
// Everything here is plain data; HelpView renders it. Keep topics short and action-oriented. When a topic
// would benefit from a motion demo, set `gif` to a name documented in docs/help-gif-suggestions.md (a
// missing GIF simply isn't shown).

import Foundation

/// One renderable chunk of a topic's body.
public enum HelpBlock: Equatable, Sendable {
    case paragraph(String) // a sentence or two of prose
    case steps([String]) // an ordered how-to list
    case bullets([String]) // an unordered list
    case tip(String) // a highlighted aside
    /// A still screenshot inline in the body — a tutorial-asset name resolved like the GIFs
    /// ("<name>-light/-dark.png", plain "<name>.png" fallback; produced by
    /// scripts/capture-help-shots.sh). A missing asset simply isn't shown.
    case image(String)
}

/// A keyboard shortcut worth surfacing alongside a topic (the live, per-context guide is ⌘K).
public struct HelpShortcut: Equatable, Sendable {
    public let keys: String // e.g. "⌘=" or "Space"
    public let label: String
    public init(_ keys: String, _ label: String) {
        self.keys = keys; self.label = label
    }
}

/// One help topic — a single task or concept.
public struct HelpTopic: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let summary: String // one line, shown in lists and search results
    public let keywords: [String] // extra search terms not already in title/summary/body
    public let blocks: [HelpBlock]
    public let shortcuts: [HelpShortcut]
    public let gif: String? // tutorial-asset name to illustrate the topic, if any

    public init(id: String, title: String, summary: String, keywords: [String] = [],
                blocks: [HelpBlock], shortcuts: [HelpShortcut] = [], gif: String? = nil) {
        self.id = id; self.title = title; self.summary = summary; self.keywords = keywords
        self.blocks = blocks; self.shortcuts = shortcuts; self.gif = gif
    }

    /// Flattened searchable text (title + summary + keywords + prose in blocks).
    var searchText: String {
        var parts = [title, summary] + keywords
        for b in blocks {
            switch b {
            case let .paragraph(s), let .tip(s): parts.append(s)
            case let .steps(xs), let .bullets(xs): parts.append(contentsOf: xs)
            case .image: break // asset names aren't prose
            }
        }
        return parts.joined(separator: " ").lowercased()
    }
}

/// A named group of topics, shown as a sidebar section.
public struct HelpCategory: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let symbol: String // SF Symbol
    public let topics: [HelpTopic]
    public init(id: String, title: String, symbol: String, topics: [HelpTopic]) {
        self.id = id; self.title = title; self.symbol = symbol; self.topics = topics
    }
}

public enum HelpContent {
    public static let appName = "MagnifiCal"

    public static let categories: [HelpCategory] = [
        gettingStarted, gettingAround, events, deadlines, organizing, projects, assistant, syncImport,
        keyboardTips,
    ]

    public static var allTopics: [HelpTopic] {
        categories.flatMap(\.topics)
    }

    /// Category containing a topic id (for breadcrumbs / grouping search results).
    public static func category(of topicID: String) -> HelpCategory? {
        categories.first { $0.topics.contains { $0.id == topicID } }
    }

    /// Simple, forgiving search: every whitespace-separated term must appear somewhere in the topic's text.
    /// Ranked title-hits first, then summary, then body. Empty query → all topics in book order.
    public static func search(_ query: String) -> [HelpTopic] {
        let terms = query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !terms.isEmpty else { return allTopics }
        func rank(_ t: HelpTopic) -> Int? {
            let title = t.title.lowercased(), summary = t.summary.lowercased(), all = t.searchText
            var score = 0
            for term in terms {
                if title.contains(term) {
                    score += 3
                } else if summary.contains(term) {
                    score += 2
                } else if all.contains(term) {
                    score += 1
                } else {
                    return nil
                } // every term must match somewhere
            }
            return score
        }
        return allTopics.compactMap { t in rank(t).map { (t, $0) } }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    // ─────────────────────────────────────────────────────────────────────────────────
    // MARK: Getting started

    /// ─────────────────────────────────────────────────────────────────────────────────
    static let gettingStarted = HelpCategory(id: "start", title: "Getting Started", symbol: "sparkles", topics: [
        HelpTopic(
            id: "welcome", title: "What is MagnifiCal?",
            summary: "A zoomable calendar that keeps your schedule, notes, and to-dos together.",
            keywords: ["overview", "intro", "introduction", "about", "semantic zoom"],
            blocks: [
                .paragraph(
                    "MagnifiCal is a calendar you move through by zooming. One continuous canvas holds a whole year, and you zoom in to a month, a week, or a single day — the layout re-forms at each level instead of switching to a different screen."
                ),
                .paragraph(
                    "Alongside the schedule, every event and every day can hold Markdown notes and to-do items, and a built-in AI assistant can read and change your calendar for you."
                ),
                .tip("New here? Open Help ▸ Welcome to MagnifiCal for a quick visual tour of the main gestures."),
            ]
        ),
        HelpTopic(
            id: "zoom-levels", title: "The four zoom levels",
            summary: "Year, Month, Week, and Day — the same calendar at four scales.",
            keywords: ["year", "month", "week", "day", "levels", "scale"],
            blocks: [
                .paragraph("The calendar has four levels of detail:"),
                .bullets([
                    "Year — every month as a horizontal track lane; best for multi-day events and the big picture.",
                    "Month — one month's weeks; a good overview of what's coming.",
                    "Week — seven day-columns with an hourly timeline for timed events.",
                    "Day — a single day's timeline plus its dashboard of to-dos and notes.",
                ]),
                .paragraph(
                    "You can move between levels with a pinch, with ⌘= / ⌘−, or by clicking into a period to drill in."
                ),
            ],
            shortcuts: [.init("⌘=", "Zoom in"), .init("⌘−", "Zoom out")], gif: "pinch-zoom"
        ),
        HelpTopic(
            id: "first-event", title: "Create your first event",
            summary: "Drag on the calendar to make an event, then name it.",
            keywords: ["quick start", "new event", "getting started"],
            blocks: [
                .steps([
                    "Zoom to Week or Day view (pinch out, or press ⌘=).",
                    "Press and drag down a day's timeline to cover the time you want.",
                    "Type a title while it's selected, then click away to save.",
                ]),
                .tip(
                    "Prefer to describe it in words? Open the AI assistant with ⌘I and say “add lunch with Sam tomorrow at noon.”"
                ),
            ], gif: "timed-week"
        ),
    ])

    // ─────────────────────────────────────────────────────────────────────────────────
    // MARK: Getting around

    /// ─────────────────────────────────────────────────────────────────────────────────
    static let gettingAround = HelpCategory(
        id: "around",
        title: "Getting Around",
        symbol: "arrow.up.left.and.arrow.down.right",
        topics: [
            HelpTopic(
                id: "zooming", title: "Zoom between year, month, week, and day",
                summary: "Pinch, use ⌘= / ⌘−, or click into a period to change scale.",
                keywords: ["zoom", "pinch", "scale", "drill in", "navigate"],
                blocks: [
                    .paragraph(
                        "Zooming keeps you oriented — the period you're looking at stays centered as the calendar re-forms around it."
                    ),
                    .bullets([
                        "Pinch on a trackpad to zoom smoothly toward the pointer.",
                        "Press ⌘= to zoom in one level, ⌘− to zoom out.",
                        "Click a month, week, or day to drill straight into it.",
                    ]),
                    .tip(
                        "Zoom targets whatever is under the pinch (or the selection), so pinch over the week or day you actually want to open."
                    ),
                ],
                shortcuts: [.init("⌘=", "Zoom in"), .init("⌘−", "Zoom out")], gif: "pinch-zoom"
            ),
            HelpTopic(
                id: "navigate-dates", title: "Move through dates",
                summary: "Scroll or swipe to page through weeks and months.",
                keywords: ["scroll", "swipe", "next", "previous", "page", "months", "weeks"],
                blocks: [
                    .paragraph(
                        "Scroll (or two-finger swipe) to page through time at the current level: months in Year and Month view, weeks in Week view, days in Day view."
                    ),
                    .paragraph(
                        "With the keyboard, use ⌘← and ⌘→ to page backward and forward, and ⌘↑ / ⌘↓ to move between rows."
                    ),
                ],
                shortcuts: [.init("⌘←", "Previous period"), .init("⌘→", "Next period")]
            ),
            HelpTopic(
                id: "today", title: "Jump to today",
                summary: "The Today button (or ⌘T) returns to the current date.",
                keywords: ["today", "now", "current date", "return"],
                blocks: [
                    .paragraph(
                        "Click Today in the toolbar, or press ⌘T, to bring the current day back into view at whatever level you're on. Today is always marked so you can spot it at a glance."
                    ),
                ],
                shortcuts: [.init("⌘T", "Go to today")]
            ),
            HelpTopic(
                id: "daily-dashboard", title: "The dashboard",
                summary: "Day, week, and month views pair the calendar with a to-do and notes panel.",
                keywords: ["dashboard", "day view", "week view", "month view", "todo", "notes", "panel",
                           "notepad", "weekly note", "monthly note"],
                blocks: [
                    .paragraph(
                        "In Day view, the panel beside the timeline is the day's dashboard; week and month views have their own (deadlines, to-dos, and a note scoped to that week or month). It has three tabs:"
                    ),
                    .bullets([
                        "To-Do — every checkbox from the range's notes and its events, gathered in one list.",
                        "Note — a free-form Markdown scratchpad for that day, week, or month.",
                        "Proj — your projects' life cycles, one gantt chart per project.",
                    ]),
                    .paragraph(
                        "Check items off directly in the To-Do tab; they stay in sync with the notes they came from."
                    ),
                    .paragraph(
                        "⌘B focuses the To-Do tab, ⌘E the Note editor, and ⌘J the Projects tab. In week or month view they also open the panel if it's closed, flip between tabs, and — pressed again on their own tab — put it away."
                    ),
                ],
                shortcuts: [.init("⌘B", "Focus the To-Do list"), .init("⌘E", "Focus the Note editor"),
                            .init("⌘J", "Focus the Projects tab")],
                gif: "daily-dashboard"
            ),
            HelpTopic(
                id: "todo-syntax", title: "Todo & note syntax",
                summary: "The full token language: checkboxes, dates, priorities, tags, people, and projects.",
                keywords: ["todo", "syntax", "tokens", "due", "priority", "tags", "project", "person",
                           "followup", "created", "done", "start", "markdown", "dsl", "autocomplete"],
                blocks: [
                    .paragraph(
                        "Every note is plain Markdown, and any list line with a checkbox — \"- [ ] task\" — becomes a TODO. The markdown stays the single source of truth: checking a box anywhere (the To-Do list, a note preview, a Projects chart) rewrites that exact line. Notes live in five places, and their todos all pool into the same index: an event's note, a recurring event's per-occurrence \"This Event\" note, and the daily, weekly, and monthly notes."
                    ),
                    .paragraph(
                        "Indent a task under another to make a sub-task (Tab / ⇧Tab in the editor nest and un-nest). Sub-tasks fold under their parent in the To-Do list (←/→ on a focused row) and never chart on their own in Projects."
                    ),
                    .paragraph(
                        "Tokens are words you drop anywhere on the task line; they render as badges in previews and are stripped from the displayed text. Date-valued tokens share one grammar: an explicit 2026-07-30 (optionally T17:00), the keywords today / tomorrow / yesterday, or an offset like 3d, 2w, -1m, 1y."
                    ),
                    .bullets([
                        "p:! … p:!!!!! — priority, one to five bangs; ranks the item in every list.",
                        "due:<date> — the deadline. Also takes a bare time (due:5pm, due:17:00 → today at that time). Without a due:, the item inherits its note's own date (the event's day, or the daily note's day).",
                        "tz:<zone> — the due date's timezone: tz:AOE or an IANA id like tz:America/New_York.",
                        "start:<date> — defer: the item stays out of the daily lists until that date, and the Projects chart draws its bar from it (planning ahead: created today, starting next week).",
                        "created:<datetime> — when the item entered the list. Auto-stamped on top-level items when an editing session ends, so you rarely type it; it anchors the left end of Projects bars.",
                        "done:<datetime> — completion time. Auto-stamped when you tick a checkbox (and stripped when you untick); the right end of a finished Projects bar.",
                        "followup:30d or followup:<date> — a follow-up reminder: a duration counts from the event's END date. Surfaces under \"Remember to Followup\" and goes overdue like a due date.",
                        "color:<name> — override this item's badge color (an event-palette name).",
                        "#tag — freeform tags; searchable (⌘F), shown on rows. Two are special: #silent mutes this item's notifications, #notify opts it in even when its kind is off in Settings.",
                        "@name or @person:name — a person reference; @<type>:name works for any entity type.",
                        "@project:name (or project:name) — attach this item to a project (see below).",
                        "[label](url) and bare URLs — links; clickable in previews, ⌘-clickable in the editor.",
                    ]),
                    .paragraph(
                        "Projects (⌘J): a top-level todo tagged @project:name becomes a row on that project's gantt — its bar runs from start:/created: to done: (or to now while open), the portion past its due: hatches, and an unreached due: draws as a small tick. Two more forms extend the chart: a bare @project:name line in a DEADLINE's note marks that deadline as the project's milestone (a vertical rule), and in a band event's note (or a recurring band's This Event note) it draws the event as a box spanning the tracks."
                    ),
                    .paragraph(
                        "Autocomplete does the typing: @ suggests people and the project:/person: namespaces, @project: lists your existing projects, # your existing tags. After due:, created:, done:, or start:, a date dropdown offers now / today / tomorrow, weekday names (any prefix — due:th → next Thursday), month-days (july-5, 7/5), offsets (3d, 2w) — each shown with its resolved date — plus \"this event time\" in an event's note and \"this day time\" in a daily note. Enter or Tab inserts the concrete value; Esc closes the dropdown."
                    ),
                    .tip(
                        "The To-Do list sorts itself from these tokens: due/overdue/followup windows, priority, then completion recency — so a well-tokenized line files itself. And since done:/created: are stamped automatically, an accurate project history usually costs you nothing but the @project: tag."
                    ),
                ],
                shortcuts: [.init("⌘S", "Editor → preview"), .init("Tab", "Accept completion / indent"),
                            .init("Esc", "Close dropdown, then exit editor")]
            ),
            HelpTopic(
                id: "note-editor", title: "The note editor & preview",
                summary: "Writing notes: line numbers, list continuation, line moves, and the rendered preview.",
                keywords: ["editor", "preview", "markdown", "line numbers", "monospace", "checkbox",
                           "indent", "swap lines", "option arrow", "save", "escape", "table", "code"],
                blocks: [
                    .paragraph(
                        "Every note — the dashboard's daily/weekly/monthly notes and an event's drawer note — opens in the same editor: monospaced, line-numbered, with the active line highlighted. Arriving at a note picks the mode by content: an empty note opens in the editor (there is nothing to preview), a written one opens in the preview. The pencil/eye toggle at the panel's bottom right switches at any time."
                    ),
                    .bullets([
                        "Enter on a list line continues it — \"- [ ] \" carries to the next line so a checklist types itself; Enter on an empty item ends the list.",
                        "Tab / ⇧Tab indent and un-indent the current line (nesting sub-tasks).",
                        "⌥↑ / ⌥↓ move the current line up or down a row.",
                        "⌘S stamps the editing session (created: on new items) and flips to the preview.",
                        "Esc closes an open completion dropdown first; pressed again it leaves the editor (previewing if the note has content).",
                    ]),
                    .paragraph(
                        "The preview renders the full Markdown: headings, tables (⌘-selectable like any text), fenced code with syntax highlighting for the mainstream languages, quote blocks, links, and every token as its badge — priorities, due/done dates, #tags, @people, and @project chips inline in the prose."
                    ),
                    .bullets([
                        "Click a checkbox in the preview to toggle it — the source line is rewritten in place (and done: stamped), no need to enter the editor.",
                        "⌘-click anywhere on a rendered line to jump into the editor at that exact line.",
                    ]),
                ],
                shortcuts: [.init("⌥↑ / ⌥↓", "Move line up / down"), .init("Tab / ⇧Tab", "Indent / un-indent"),
                            .init("⌘S", "Stamp + preview"), .init("⌘-click", "Edit at that line (in preview)")]
            ),
        ]
    )

    // ─────────────────────────────────────────────────────────────────────────────────
    // MARK: Events

    /// ─────────────────────────────────────────────────────────────────────────────────
    static let events = HelpCategory(id: "events", title: "Events", symbol: "calendar", topics: [
        HelpTopic(
            id: "create-timed", title: "Create a timed event",
            summary: "Drag down a day's timeline in Week or Day view.",
            keywords: ["timed", "meeting", "appointment", "hourly", "create", "new"],
            blocks: [
                .steps([
                    "Zoom to Week or Day view.",
                    "Press on the start time in a day column and drag down to the end time.",
                    "Release, type a title, and click away to save.",
                ]),
                .tip("Drag the top or bottom edge of an event later to change its start or end time."),
            ],
            shortcuts: [.init("⌘N", "New event at the cursor")], gif: "timed-week"
        ),
        HelpTopic(
            id: "create-band", title: "Create a multi-day event (band)",
            summary: "Drag across days in Year or Month view to make a bar.",
            keywords: ["band", "multi-day", "all day", "range", "trip", "conference", "track", "lane"],
            blocks: [
                .paragraph(
                    "A band is a bar that spans several days on one of a month's track lanes — useful for trips, conferences, or focus blocks. A band shows where something sits in the month; it doesn't imply the event runs all day."
                ),
                .steps([
                    "In Year or Month view, press on the first day of a lane.",
                    "Drag sideways across the days it should cover.",
                    "Release and give it a title.",
                ]),
            ], gif: "band-year"
        ),
        HelpTopic(
            id: "edit-event", title: "Edit an event",
            summary: "Double-click an event to open its editor drawer.",
            keywords: ["edit", "drawer", "change", "title", "time", "color", "details"],
            blocks: [
                .paragraph(
                    "Double-click any event to open its drawer on the right. There you can change the title, date and time, color, repeat rule, and notes. Changes save as you make them."
                ),
                .tip(
                    "A single click selects an event (and lets you type a new title); double-click opens the full drawer."
                ),
            ], gif: "edit-drawer"
        ),
        HelpTopic(
            id: "move-resize", title: "Move or resize an event",
            summary: "Drag an event to move it; drag its edge to resize.",
            keywords: ["move", "drag", "resize", "reschedule", "stretch"],
            blocks: [
                .bullets([
                    "Move — drag the middle of an event to another time or day.",
                    "Resize a timed event — drag its top or bottom edge.",
                    "Resize a band — drag its left or right end to change the day range.",
                ]),
                .tip("Made a mistake? ⌘Z undoes the last move or resize."),
            ], gif: "move-resize"
        ),
        HelpTopic(
            id: "delete-event", title: "Delete an event",
            summary: "Select it and press Delete; confirm when asked.",
            keywords: ["delete", "remove", "trash"],
            blocks: [
                .paragraph(
                    "Select an event and press Delete, or use the trash button in its drawer. MagnifiCal asks you to confirm before removing it."
                ),
                .paragraph(
                    "For a repeating event, you can delete just one occurrence (a single skip) or the whole series — choose when prompted."
                ),
            ],
            shortcuts: [.init("⌫", "Delete the selected event")]
        ),
        HelpTopic(
            id: "recurring", title: "Repeat an event",
            summary: "Set a repeat rule in the drawer — daily, weekly, and more.",
            keywords: ["recurring", "repeat", "weekly", "daily", "series", "until", "recurrence"],
            blocks: [
                .paragraph(
                    "Open an event's drawer and set its Repeat rule under Configuration. You can repeat daily, on chosen weekdays, or on other schedules, and set an end date."
                ),
                .bullets([
                    "Skip one date — delete that single occurrence; the rest of the series stays.",
                    "Change the series — edit the event and the change applies to every occurrence.",
                ]),
            ], gif: "recurring"
        ),
    ])

    // ─────────────────────────────────────────────────────────────────────────────────
    // MARK: Deadlines

    /// ─────────────────────────────────────────────────────────────────────────────────
    static let deadlines = HelpCategory(id: "deadlines", title: "Deadlines", symbol: "flag", topics: [
        HelpTopic(
            id: "add-deadline", title: "Add a deadline",
            summary: "A deadline is a single due-moment, not a block of time.",
            keywords: ["deadline", "due", "cfp", "submission", "moment"],
            blocks: [
                .paragraph(
                    "A deadline marks one exact moment something is due, rather than an event that occupies a span of time. Deadlines appear as a marked line on the timeline."
                ),
                .steps([
                    "Zoom to Week or Day view and hover over a day's timeline.",
                    "Click the “+” that appears near the day's edge to create a deadline there.",
                    "Give it a title and set the exact due time in its drawer.",
                ]),
            ], gif: "deadline-add"
        ),
        HelpTopic(
            id: "aoe", title: "Anywhere-on-Earth & time zones",
            summary: "Give a deadline a time zone — including AOE — so it lands correctly.",
            keywords: ["aoe", "anywhere on earth", "timezone", "time zone", "utc", "conference"],
            blocks: [
                .paragraph(
                    "Conference and paper deadlines are often stated as “Anywhere on Earth” (AOE) — 23:59 in the last time zone on Earth. A deadline can carry its own time zone so it shows at the right local moment for you."
                ),
                .tip(
                    "For a CFP that says AOE, set the deadline's time zone to AOE and its time to 23:59 on the due date."
                ),
            ]
        ),
    ])

    // ─────────────────────────────────────────────────────────────────────────────────
    // MARK: Organizing

    /// ─────────────────────────────────────────────────────────────────────────────────
    static let organizing = HelpCategory(id: "organize", title: "Organizing", symbol: "tag", topics: [
        HelpTopic(
            id: "colors", title: "Color-code your events",
            summary: "Pick a color in the drawer to group events by meaning.",
            keywords: ["color", "colour", "palette", "category"],
            blocks: [
                .paragraph(
                    "Every event has a color you set from the swatches at the top of its drawer. Colors are personal — pick a consistent scheme (say, teaching in blue, research in purple) and your week reads at a glance."
                ),
                .tip(
                    "The assistant reuses your existing colors: ask it to add an event “like my other classes” and it matches the color you already use."
                ),
            ]
        ),
        HelpTopic(
            id: "tags", title: "Tag your events",
            summary: "Tag events by typing #tags in their notes.",
            keywords: ["tags", "labels", "categorize", "hashtag", "filter"],
            blocks: [
                .paragraph(
                    "Tags are markdown: type #tag anywhere in an event's note (letters, digits, - and _ — a space after # makes a heading instead). They render as chips in the preview, and they're searchable — type a tag in the search bar (⌘F) to pull up everything you've labeled that way."
                ),
                .paragraph(
                    "To declutter the calendar by tag, open the tag filter (the tag button in the toolbar, View ▸ Filter by Tags…, or ⌘G) and un-check the tags you want hidden. An event stays visible while ANY of its tags is still on."
                ),
            ],
            shortcuts: [.init("⌘G", "Toggle the tag filter")]
        ),
        HelpTopic(
            id: "notes-todos", title: "Notes & to-do lists",
            summary: "Every event and day holds Markdown notes with checkboxes.",
            keywords: ["notes", "markdown", "todo", "to-do", "checkbox", "tasks", "priority", "due"],
            blocks: [
                .paragraph(
                    "Open an event's drawer (or a day's Note tab) and write in Markdown. A line beginning with a checkbox becomes a to-do that also appears in the day's To-Do list."
                ),
                .paragraph("To-do lines accept extra tokens after the text:"),
                .bullets([
                    "due:2026-07-01 — a due date (also accepts today, tomorrow, 3d, 5pm).",
                    "p:!!! — a priority (more “!” means higher).",
                    "#tag and @person — labels and people.",
                ]),
                .paragraph(
                    "Switch between the raw Markdown and the rendered preview with the pencil / eye buttons at the bottom of the editor."
                ),
            ], gif: "markdown-notes"
        ),
        HelpTopic(
            id: "tracks-promote", title: "Tracks & promoting events",
            summary: "Name a month's lanes, and mirror a deadline onto one.",
            keywords: ["track", "lane", "promote", "gutter", "rename", "mirror"],
            blocks: [
                .paragraph(
                    "In Year and Month view each month has a few horizontal lanes (tracks). Click a lane's name in the left gutter to rename it — for example Teaching, Research, Service, Travel."
                ),
                .paragraph(
                    "A deadline or timed event can be “promoted” to a track so it also shows as a ghost bar on that lane — handy for seeing a submission date in the month overview without duplicating it. Set the promote lane in the event's drawer."
                ),
            ], gif: "promote"
        ),
    ])

    // ─────────────────────────────────────────────────────────────────────────────────
    // MARK: Projects & to-dos

    /// ─────────────────────────────────────────────────────────────────────────────────
    static let projects = HelpCategory(
        id: "projects",
        title: "Projects & To-Dos",
        symbol: "chart.bar.xaxis",
        topics: [
            HelpTopic(
                id: "projects-gantt", title: "Projects & Gantt charts",
                summary: "Tag todos with @project:name and the Proj tab charts each project's life cycle.",
                keywords: ["project", "gantt", "chart", "proj", "milestone", "timeline", "bars",
                           "quick add", "pin", "hatch", "overdue", "sprint"],
                blocks: [
                    .paragraph(
                        "Tag any top-level todo with @project:name and it becomes a row on that project's gantt chart. Open the dashboard's Proj tab (⌘J) in day, week, or month view — one chart per project, drawn from the todos you already have."
                    ),
                    .image("proj-gantt"),
                    .paragraph("Reading a chart:"),
                    .bullets([
                        "Every row is the todo itself — its checkbox ticks the real item, and clicking a title jumps to the line it came from.",
                        "A row's bar runs from its start: (or created:) date to its done: date — or to the now line while the item is open.",
                        "Run past a due: date and the overdue stretch hatches; a due date still ahead draws as a small tick on the track.",
                        "The red now line marks the current moment, and the grey band frames the week or month you're viewing.",
                        "A deadline with a bare @project:name line in its note becomes the project's milestone — a dashed vertical rule in the deadline's color.",
                        "A multi-day band event with @project:name in its note draws as an outlined box across the chart — sprints, trips, review periods.",
                    ]),
                    .paragraph(
                        "Busy charts show their most relevant rows and fold the rest — the chevron next to a project's name expands it. Tag an item #proj-pinned to keep it on top with the accent pin (or right-click the row and choose Pin)."
                    ),
                    .paragraph(
                        "To add work without leaving the chart, type into the “new todo...” row above the tasks: the item lands in this scope's note already project-tagged, pinned, and created-stamped. Right-clicking any row offers color, priority, pin, hide, Go to Definition, and delete."
                    ),
                    .tip(
                        "The tokens driving all of this — start:, created:, due:, done: — are mostly stamped for you as you work. See “Todo & note syntax” for the grammar and “How tokens show up” for the full display map."
                    ),
                ],
                shortcuts: [.init("⌘J", "Focus the Projects tab")]
            ),
            HelpTopic(
                id: "token-display", title: "How tokens show up",
                summary: "Where start:, created:, due:, and done: surface — list rows, gantt bars, preview pills.",
                keywords: ["tokens", "display", "chips", "pills", "badges", "due", "start", "created",
                           "done", "priority", "followup", "pinned", "overdue", "surfaces", "mapping"],
                blocks: [
                    .paragraph(
                        "One tokenized todo line renders in three places: its row in the To-Do list, its bar on a Projects chart, and its line in the note preview. The grammar itself lives in “Todo & note syntax” — this topic is where each token appears."
                    ),
                    .paragraph("In the To-Do list:"),
                    .image("todo-panel"),
                    .bullets([
                        "due: shows as the row's relative date (“in 3d”, “today”) and ranks the item; overdue turns red — and in Day view files it under Overdue. Without a due:, the note's own date stands in.",
                        "start: displays nothing — it works by absence, keeping the item out of the daily lists until its day arrives.",
                        "created: is invisible on the row; it orders the Pinned section, newest first.",
                        "done: flips the row into the Completed section with a green “✓ finished …” stamp, and the other badges drop away.",
                        "p: renders its bangs in red — levels !!!! and !!!!! as a white-on-red badge — and boosts the row's rank.",
                        "followup: shows “↪ follow up in …” in teal, turning red once it comes due.",
                        "#pinned adds the accent pin and a Pinned section on top; @project draws an accent-outlined pill; other #tags show in the accent color.",
                        "Rows gathered from another note or an event carry a grey provenance prefix — “Grant review · ”, “Daily note · 2026-08-05”.",
                    ]),
                    .paragraph(
                        "On a Projects chart the date tokens become geometry: start:/created: is the bar's left end, done: its right (open bars run to the now line), and due: either hatches the overrun or draws a tick ahead of the bar. p: raises a row's rank there too, and #proj-pinned pins it to the top of the chart."
                    ),
                    .paragraph("In the note preview:"),
                    .image("note-preview"),
                    .bullets([
                        "Value tokens render as small labeled pills on the line — DUE, FROM (that's start:), and DONE with their dates; created: is bookkeeping and shows no pill.",
                        "p: keeps its bangs (white-on-red at !!!! and up), followup: its teal pill, and #tags, @people, and @project their colored chips.",
                        "Ticking a preview checkbox strikes the line, dims its pills, and stamps done: on the source line — the same line everywhere else updates with it.",
                    ]),
                    .tip(
                        "done: and created: stamp themselves as you tick boxes and finish editing sessions, so the history your charts draw from usually costs you nothing but the @project: tag."
                    ),
                ]
            ),
        ]
    )

    // ─────────────────────────────────────────────────────────────────────────────────
    // MARK: The AI assistant

    /// ─────────────────────────────────────────────────────────────────────────────────
    static let assistant = HelpCategory(id: "ai", title: "The AI Assistant", symbol: "wand.and.stars", topics: [
        HelpTopic(
            id: "assistant-intro", title: "Meet MagnifiCal AI",
            summary: "A chat assistant that can read and change your calendar.",
            keywords: ["ai", "assistant", "chat", "magical ai", "sparkles"],
            blocks: [
                .paragraph(
                    "MagnifiCal AI is a chat panel that understands your calendar. Ask it questions in plain language and it can answer, or make the change for you."
                ),
                .paragraph(
                    "Open it from the sparkles button in the toolbar, or press ⌘I. Type a request and press Return."
                ),
            ],
            shortcuts: [.init("⌘I", "Open the assistant")], gif: "ai-assistant"
        ),
        HelpTopic(
            id: "assistant-use", title: "Ask the assistant to manage your calendar",
            summary: "Create, edit, find, and plan — in words.",
            keywords: ["create", "edit", "find", "schedule", "plan", "web search"],
            blocks: [
                .paragraph("Things you can ask:"),
                .bullets([
                    "“Add a coffee chat with Sam on Wednesday at 3pm.”",
                    "“What's on my radar this week?”",
                    "“Move my 1:1 to Friday morning.”",
                    "“Add a to-do to submit the abstract, due next Monday.”",
                    "“When is the NeurIPS deadline?” — it can look things up on the web.",
                ]),
                .paragraph("After it makes a change, the calendar jumps to show you the result."),
            ]
        ),
        HelpTopic(
            id: "assistant-safety", title: "How the assistant keeps things safe",
            summary: "Edits are checked, and deletions always ask first.",
            keywords: ["safety", "auditor", "confirm", "delete", "blocked", "permission"],
            blocks: [
                .paragraph(
                    "Every create or edit the assistant proposes is checked by a separate safety review before it's applied. If something is blocked, the assistant tells you why instead of doing it."
                ),
                .paragraph(
                    "Deletions are never automatic — the assistant queues them and you confirm in the chat before anything is removed. And ⌘Z undoes changes the assistant made, just like your own."
                ),
            ]
        ),
        HelpTopic(
            id: "assistant-memory", title: "What the assistant remembers",
            summary: "It saves durable preferences to reuse next time.",
            keywords: ["memory", "remember", "preferences", "privacy"],
            blocks: [
                .paragraph(
                    "When you tell the assistant a lasting preference — a color convention, a default meeting length, a standing constraint — it can remember it so future sessions don't have to re-ask. It doesn't memorize one-off chatter."
                ),
                .paragraph("If a remembered fact is wrong, just correct the assistant and it updates or drops it."),
            ]
        ),
        HelpTopic(
            id: "assistant-models", title: "Choosing a model & API keys",
            summary: "Pick the AI model; add keys in Settings ▸ API Keys.",
            keywords: ["model", "api key", "keys", "gateway", "openai", "anthropic", "settings"],
            blocks: [
                .paragraph(
                    "Use the model menu at the top of the assistant window to choose which AI model answers you."
                ),
                .paragraph(
                    "The assistant needs an API key for its provider. Add yours in Settings ▸ API Keys (⌘,) — keys are stored securely in your Keychain and never leave your Mac except to call the service you chose."
                ),
            ],
            shortcuts: [.init("⌘,", "Open Settings")]
        ),
    ])

    // ─────────────────────────────────────────────────────────────────────────────────
    // MARK: Syncing & importing

    /// ─────────────────────────────────────────────────────────────────────────────────
    static let syncImport = HelpCategory(
        id: "sync",
        title: "Syncing & Importing",
        symbol: "arrow.triangle.2.circlepath",
        topics: [
            HelpTopic(
                id: "icloud", title: "iCloud sync",
                summary: "Your calendar syncs across your Macs through iCloud.",
                keywords: ["icloud", "sync", "cloudkit", "backup", "devices"],
                blocks: [
                    .paragraph(
                        "When you're signed in to iCloud, MagnifiCal keeps your events, deadlines, notes, and track names in sync across your Macs automatically. You can see the current status in Settings ▸ Account."
                    ),
                    .paragraph(
                        "Sync runs on its own, but you can nudge it any time with Connectivity ▸ Sync Now (⌘R) — that also re-imports your Apple Calendar events."
                    ),
                    .tip("Sync status and the time of the last sync also appear in the toolbar's status menu."),
                ],
                shortcuts: [.init("⌘R", "Sync now")]
            ),
            HelpTopic(
                id: "apple-calendar", title: "Show your Apple Calendar events",
                summary: "Bring in events from macOS Calendar, read-only.",
                keywords: ["apple calendar", "eventkit", "macos calendar", "import", "subscribe"],
                blocks: [
                    .paragraph(
                        "MagnifiCal can display events from the macOS Calendar app so everything sits in one place. Turn it on and pick which calendars to include in Settings ▸ Account."
                    ),
                    .paragraph(
                        "Imported events are read-only — edit them in Calendar.app — but you can still add your own notes (with #tags), and track placement to them here."
                    ),
                ]
            ),
            HelpTopic(
                id: "google-secret-address", title: "Connect Google Calendar with a secret address",
                summary: "Subscribe to a Google calendar's secret iCal address.",
                keywords: ["google", "google calendar", "secret address", "ical", "feed", "subscribe",
                           "import", "basic.ics"],
                blocks: [
                    .paragraph(
                        "MagnifiCal can subscribe directly to a Google calendar through its secret iCal address — no sign-in needed. Events appear read-only with an imported badge, and the feed refreshes automatically (Google updates secret feeds with a few minutes' delay)."
                    ),
                    .steps([
                        "Open Google Calendar in your browser and go to Settings (the gear icon).",
                        "Under “Settings for my calendars”, pick the calendar you want to show in MagnifiCal.",
                        "Scroll to “Integrate calendar” and copy the “Secret address in iCal format” — it starts with https://calendar.google.com/…/private-…/basic.ics.",
                        "In MagnifiCal, open Settings ▸ Account ▸ Google Calendar, paste the address, and press Add.",
                    ]),
                    .paragraph(
                        "The secret address grants read access to that calendar to anyone who holds it, so MagnifiCal keeps it only in your macOS Keychain. Subscriptions are per MagnifiCal calendar: a feed you add applies to the calendar that's open at the time."
                    ),
                    .tip(
                        "Alternative: add your Google account in macOS System Settings ▸ Internet Accounts with Calendars enabled — your Google events then arrive through the Apple Calendar connection, kept fresh by macOS."
                    ),
                ]
            ),
            HelpTopic(
                id: "outlook-published-address", title: "Connect Outlook Calendar with a published address",
                summary: "Subscribe to an Outlook calendar's published ICS address.",
                keywords: ["outlook", "microsoft", "office 365", "exchange", "published", "ics",
                           "feed", "subscribe", "import"],
                blocks: [
                    .paragraph(
                        "MagnifiCal can subscribe to an Outlook calendar through its published ICS address — no sign-in needed. Events appear read-only with an imported badge and refresh automatically."
                    ),
                    .steps([
                        "Open Outlook on the web (outlook.live.com for a personal account, outlook.office365.com for work or school) and go to Calendar settings.",
                        "Under “Shared calendars”, find “Publish a calendar” and pick the calendar and permission level.",
                        "Publish it and copy the ICS link (ends in calendar.ics).",
                        "In MagnifiCal, open Settings ▸ Account ▸ Outlook Calendar, paste the address, and press Add.",
                    ]),
                    .paragraph(
                        "Work and school accounts can publish only if the organization allows it — if the “Publish a calendar” option is missing or grayed out, that's an admin policy. The published address grants read access to anyone who holds it, so MagnifiCal keeps it only in your macOS Keychain, scoped to the MagnifiCal calendar that's open when you add it."
                    ),
                    .tip(
                        "Microsoft refreshes published feeds on its own schedule — updates can lag by a few hours (Google's secret feeds update within minutes). For faster, richer sync, add the account in macOS System Settings ▸ Internet Accounts instead; its events then arrive through the Apple Calendar connection."
                    ),
                ]
            ),
            HelpTopic(
                id: "hidden-imported", title: "Hide or show imported events",
                summary: "Declutter by hiding imported events you don't need.",
                keywords: ["hide", "show", "imported", "hidden", "view menu", "declutter"],
                blocks: [
                    .paragraph(
                        "You can hide individual imported events you don't want cluttering the view. To bring them back, turn on View ▸ Show Hidden Imported Events — hidden events reappear as dotted gray bars you can unhide."
                    ),
                ]
            ),
            HelpTopic(
                id: "ics", title: "Import an .ics file",
                summary: "Add events from a standard calendar file.",
                keywords: ["ics", "icalendar", "file", "import", "invite"],
                blocks: [
                    .paragraph(
                        "MagnifiCal can import a standard .ics calendar file, adding its events to yours. This is additive — it brings the new events in without touching what you already have."
                    ),
                    .tip(
                        "This is available from the File menu once it's enabled — see the note in Backing up & restoring."
                    ),
                ]
            ),
            HelpTopic(
                id: "backup", title: "Back up & restore",
                summary: "Save everything to a .mgc file, or restore from one.",
                keywords: ["backup", "restore", "export", "mgc", "mdc", "archive", "save"],
                blocks: [
                    .paragraph(
                        "Export a complete backup of your calendar — events, deadlines, notes, and track names — to a single .mgc file, and restore from it later or on another Mac (legacy .mdc and web .zip backups import too)."
                    ),
                    .paragraph(
                        "Restoring replaces your current data with the backup's contents; MagnifiCal warns you first, and ⌘Z can undo it."
                    ),
                    .tip(
                        "Import and export live in the File menu. Note: in the current build the File menu isn't installed yet — this is a known gap we're wiring up."
                    ),
                ]
            ),
        ]
    )

    // ─────────────────────────────────────────────────────────────────────────────────
    // MARK: Keyboard & tips

    /// ─────────────────────────────────────────────────────────────────────────────────
    static let keyboardTips = HelpCategory(id: "keys", title: "Keyboard & Tips", symbol: "keyboard", topics: [
        HelpTopic(
            id: "shortcuts", title: "Keyboard shortcuts",
            summary: "Hold ⌘K to see the shortcuts for whatever you're doing.",
            keywords: ["keyboard", "shortcuts", "keys", "guide", "cmd k", "hotkeys"],
            blocks: [
                .paragraph(
                    "MagnifiCal is fully keyboard-drivable. Because the useful keys change with what's selected, hold ⌘K to pop up a live guide of exactly the shortcuts available right now."
                ),
                .paragraph("Some shortcuts that work almost everywhere:"),
                .bullets([
                    "⌘= / ⌘−  — zoom in / out",
                    "⌘T  — go to today",
                    "⌘F  — search",
                    "⌘I  — open the assistant",
                    "⌘Z / ⇧⌘Z  — undo / redo",
                    "Arrow keys  — move the selection or cursor",
                ]),
                .tip("Open Help ▸ Keyboard Shortcuts to pin the guide open without holding ⌘K."),
            ],
            shortcuts: [.init("⌘K", "Hold for the live shortcut guide")]
        ),
        HelpTopic(
            id: "search", title: "Search your calendar",
            summary: "Press ⌘F to find events by name, tag, notes, or date.",
            keywords: ["search", "find", "filter", "fuzzy", "lookup"],
            blocks: [
                .paragraph(
                    "Press ⌘F (or click the magnifying glass) and start typing. Search is fuzzy and looks across titles, tags, and notes, and it understands dates."
                ),
                .bullets([
                    "Type several words to narrow down — each must match, e.g. coffee wed.",
                    "Search by date concepts: jul, wednesday, 2026-09-01, or 8/1.",
                    "Results favor what's near today, so an event years ago won't bury a nearby one.",
                ]),
                .paragraph("Use ↑ / ↓ to move through results and Return to jump to the selected event."),
            ],
            shortcuts: [.init("⌘F", "Search")], gif: "search-demo"
        ),
        HelpTopic(
            id: "undo", title: "Undo & redo",
            summary: "⌘Z and ⇧⌘Z reverse almost anything.",
            keywords: ["undo", "redo", "mistake", "revert"],
            blocks: [
                .paragraph(
                    "Nearly every change — creating, moving, resizing, editing, deleting, even an assistant's edit or a backup restore — can be undone with ⌘Z and redone with ⇧⌘Z."
                ),
            ],
            shortcuts: [.init("⌘Z", "Undo"), .init("⇧⌘Z", "Redo")]
        ),
        HelpTopic(
            id: "appearance", title: "Light, dark & appearance",
            summary: "Choose Light, Dark, or Automatic in Settings.",
            keywords: ["appearance", "theme", "dark mode", "light mode", "automatic"],
            blocks: [
                .paragraph(
                    "Set how MagnifiCal looks in Settings ▸ Appearance (⌘,): Light, Dark, or Automatic to follow the system."
                ),
            ],
            shortcuts: [.init("⌘,", "Open Settings")]
        ),
        HelpTopic(
            id: "timezones", title: "Show a second time zone",
            summary: "Display an alternate time zone alongside your own.",
            keywords: ["timezone", "time zone", "second", "alternate", "travel", "utc"],
            blocks: [
                .paragraph(
                    "If you work across time zones, MagnifiCal can show an alternate time zone next to your local one on the timeline, so you can read both at once."
                ),
            ]
        ),
    ])
}
