// A SwiftUI `Label`/`Text` built from a MenuItemID's shared title + SF Symbol. Used by every SwiftUI
// menu renderer (FileCommands, AICommands, and the CalendarApp Commands adapter) so item labels come
// from the one declaration in AppMenu.swift.

import SwiftUI

@ViewBuilder public func menuLabel(_ id: MenuItemID) -> some View {
    if let icon = id.icon {
        Label(id.title, systemImage: icon)
    } else {
        Text(id.title)
    }
}
