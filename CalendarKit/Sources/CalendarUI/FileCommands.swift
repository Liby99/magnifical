// Contents of the macOS "File" menu (hosted by the app via `CommandGroup(replacing: .importExport)`):
// import an `.ics` calendar file, and import/export a `.mgc` backup (a zip mirroring the web app's data
// export — see MDCBackup). Panels + alerts are AppKit; the actual work lives on the engine.

import CalendarEngine
import SwiftUI

public struct FileCommands: View {
    let engine: CalendarEngine
    public init(engine: CalendarEngine) {
        self.engine = engine
    }

    /// The panel/alert logic lives in the shared MenuFileActions (also used by the AppKit dev-shell menu),
    /// so the two shells' File menus run one implementation. The item titles/icons come from MenuItemID.
    public var body: some View {
        Button { MenuFileActions.importICS(engine) } label: { menuLabel(.importICS) }
        Divider()
        Button { MenuFileActions.importMDC(engine) } label: { menuLabel(.importMDC) }
        Button { MenuFileActions.exportMDC(engine) } label: { menuLabel(.exportMDC) }
    }
}
