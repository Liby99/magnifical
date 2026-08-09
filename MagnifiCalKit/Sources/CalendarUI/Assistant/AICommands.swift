// Contents of the macOS "Assistant" menu (hosted by the app via `CommandMenu("Assistant")`). Kept in CalendarUI so
// it can read the internal model catalog (AssistantModels) and drive the shared AssistantState; the app
// target just drops `AICommands(assistant:)` into its command builder.

import SwiftUI

public struct AICommands: View {
    let assistant: AssistantState
    @Environment(\.openWindow) private var openWindow
    /// The model id the assistant uses, shared with the chat window's picker (same @AppStorage key).
    @AppStorage(AssistantModels.defaultsKey) private var model = AssistantModels.fallback

    public init(assistant: AssistantState) {
        self.assistant = assistant
    }

    public var body: some View {
        Button { assistant.newChat(); openWindow(id: "assistant") } label: { Label(
            "New Conversation",
            systemImage: "square.and.pencil"
        ) }
        Button { openWindow(id: "assistant") } label: { Label("Current Conversation", systemImage: "bubble.left") }
        Divider()
        // Renders as a "Model ▸" submenu with a checkmark on the active model.
        Picker(selection: $model) {
            ForEach(AssistantModels.all) { m in Text(m.label).tag(m.id) }
        } label: {
            Label("Model", systemImage: "cpu")
        }
        Divider()
        SettingsLink { Label("Configure API Keys…", systemImage: "key") }
    }
}
