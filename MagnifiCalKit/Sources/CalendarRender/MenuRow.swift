// One row of a callout menu card — the shared chrome of the event context callout and the
// todo-row callout (TodoRowCallout). Moved from CalendarUI/EventContextCallout.swift to
// CalendarRender when the dashboard panels came down here (the callout needs it; CalendarUI
// keeps using it through the Reexports shim). Pure SwiftUI — compiles on both platforms.

import SwiftUI

public struct MenuRow: View {
    let label: String
    let icon: String
    let key: String?
    let destructive: Bool
    var disabled: Bool = false
    let theme: Theme
    let action: () -> Void
    @State private var hovering = false

    public init(label: String, icon: String, key: String?, destructive: Bool,
                disabled: Bool = false, theme: Theme, action: @escaping () -> Void) {
        self.label = label
        self.icon = icon
        self.key = key
        self.destructive = destructive
        self.disabled = disabled
        self.theme = theme
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 11.5))
                    .frame(width: 15)
                Text(label).font(.system(size: 12.5))
                Spacer(minLength: 12)
                if let key {
                    Text(key).font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(disabled ? theme.text.opacity(0.35) : (destructive ? Color.red : theme.text))
            .padding(.horizontal, 7).padding(.vertical, 4.5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(hovering && !disabled ? theme.text.opacity(0.09) : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovering = $0 }
    }
}
