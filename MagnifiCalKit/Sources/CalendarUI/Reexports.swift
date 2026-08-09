// The portable render layer (SceneRenderer, EventsOverlay/DeadlinesOverlay, Theme,
// BandStyle, CursorRing, Breadcrumb, WeekScrollBehavior) moved to the CalendarRender
// target so the iPhone client can link it without AppKit. Re-export it so the ~25
// CalendarUI files that use those symbols need no import changes.
@_exported import CalendarRender
