// The Settings/Preferences window (opened with ⌘, — see CalendarMac/main.swift).
//
// Three tabs:
//  • Account    — iCloud connectivity (real status, read from the CloudKit layer); a live
//                 macOS Apple Calendar connection (EventKit) with a per-calendar checklist; and a
//                 Google Calendar row that's a visual mockup for now.
//  • Appearance — Light / Dark / Automatic, applied live and persisted (see AppSettings.swift).
//  • Notifications — per-kind local-notification schedules (see NotifyPlan.swift +
//                 NotificationScheduler.swift in CalendarEngine); authorization status + defaults.
//  • API Keys   — the assistant's credentials (LLM provider for chat, Tavily for web search),
//                 stored in the macOS Keychain (see Keychain.swift); local to this device.
//
// Native controls throughout, tinted with the app's accent (AccentPref — MagnifiCal red by default,
// as in EventDrawer).

import CalendarEngine
import SwiftUI

public struct SettingsView: View {
    public init() {}

    public var body: some View {
        TabView {
            AccountTab()
                .tabItem { Label("Account", systemImage: "person.crop.circle") }
            AppearanceTab()
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
            NotificationsTab()
                .tabItem { Label("Notifications", systemImage: "bell.badge") }
            APIKeysTab()
                .tabItem { Label("API Keys", systemImage: "key") }
            DeveloperTab()
                .tabItem { Label("Developer", systemImage: "hammer") }
        }
        .tint(Theme.accent)
        .frame(width: 560, height: 480)
    }
}

// ── Account ───────────────────────────────────────────────────────────────────────

private struct AccountTab: View {
    @State private var iCloud: ICloudStatus? // nil = still probing
    // The ACTIVE MagnifiCal calendar, tracked LIVE via UserDefaults (the engine writes it on every
    // switch): import settings below are scoped to THIS calendar, and the whole import block
    // re-keys (.id) when it changes, so a switch mid-session can never edit the wrong calendar.
    @AppStorage(PrefKeys.calActiveId) private var activeCalId = PrefKeys.mainCalendarId

    var body: some View {
        let calName = CalendarEngine.calendarDisplayName(activeCalId)
        Form {
            Section("iCloud") {
                iCloudRow
            }
            // Import scope banner — unmistakable: everything below configures ONLY this calendar.
            Section {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "square.stack").foregroundStyle(Theme.accent).padding(.top, 2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Importing into “\(calName)”").fontWeight(.semibold)
                        Text("The Apple, Google, and Outlook calendar connections below apply only to " +
                            "the MagnifiCal calendar that is currently open — “\(calName)”. Each MagnifiCal " +
                            "calendar keeps its own import setup: switch calendars (File ▸ Calendars) " +
                            "to configure another one.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 2)
            }
            Section {
                AppleCalendarRows(calId: activeCalId)
            } header: {
                sectionHeader("macOS Apple Calendar", calName)
            }
            Section {
                FeedAddressForm(calId: activeCalId,
                                addressLabel: "Secret Calendar Address",
                                example: "https://calendar.google.com/…/basic.ics",
                                helpTopic: "google-secret-address")
            } header: {
                sectionHeader("Google Calendar", calName)
            }
            // Google's subscribed feeds — a headerless list right under its section (its wash
            // separates it from the form; Outlook's feeds live under the Outlook section below).
            Section {
                CalendarFeedList(calId: activeCalId, outlook: false)
            }
            Section {
                FeedAddressForm(calId: activeCalId,
                                addressLabel: "Published Calendar Address",
                                example: "https://outlook.live.com/owa/calendar/…/calendar.ics",
                                helpTopic: "outlook-published-address")
            } header: {
                sectionHeader("Outlook Calendar", calName)
            }
            Section {
                CalendarFeedList(calId: activeCalId, outlook: true)
            }
        }
        .formStyle(.grouped)
        .task { iCloud = await CalendarEngine.iCloudStatus() }
        .id(activeCalId) // switch → rebuild the import rows against the new calendar's keys
    }

    /// Import-section header: source name left; right, a deliberately low-key "import into <name>"
    /// (lowercase, regular weight, washed color) naming which MagnifiCal calendar it configures.
    private func sectionHeader(_ title: String, _ calName: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text("import into \(calName)")
                .fontWeight(.regular)
                .foregroundStyle(.tertiary)
        }
    }

    private var iCloudRow: some View {
        let (title, detail, color) = Self.describe(iCloud)
        return HStack(alignment: .top, spacing: 10) {
            Circle().fill(color).frame(width: 9, height: 9).padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    /// Human title, one-line detail, and dot color for each status. `nil` = still probing.
    private static func describe(_ s: ICloudStatus?) -> (String, String, Color) {
        switch s {
        case .available:
            ("Syncing via iCloud", "Your calendar syncs across every device signed in to the same Apple ID.", .green)
        case .localOnly:
            ("Local only", "This build isn't set up for iCloud sync — your data stays on this Mac.", .secondary)
        case .noAccount:
            ("Not signed in", "Sign in to iCloud in System Settings to sync across your devices.", .orange)
        case .restricted:
            ("Restricted", "iCloud is restricted by a configuration profile or parental controls.", .orange)
        case .unavailable:
            ("Temporarily unavailable", "iCloud is momentarily unavailable — it'll retry automatically.", .orange)
        case .unknown:
            ("Unavailable", "Couldn't determine iCloud status.", .orange)
        case nil:
            ("Checking…", "Determining iCloud status.", .secondary)
        }
    }
}

/// ── Apple Calendar connection (EventKit) ────────────────────────────────────────────
/// The Settings window is isolated from the running engine, so this talks to EventKit directly and
/// shares state with the engine through UserDefaults + a `.appleCalendarSettingsChanged` notification.
private struct AppleCalendarRows: View {
    // Apple subscription state is per MagnifiCal calendar: the parent (AccountTab) passes the LIVE
    // active id and re-keys this view (.id) on switch, so the toggles always edit that calendar.
    let calId: String
    @AppStorage private var enabled: Bool
    @Environment(\.openURL) private var openURL
    @State private var access = CalendarEngine.appleAccess
    @State private var calendars: [AppleCalendarInfo] = []
    @State private var selected: Set<String> = []
    @State private var busy = false
    private let importer = AppleCalendarImporter()

    init(calId: String) {
        self.calId = calId
        _enabled = AppStorage(wrappedValue: false, PrefKeys.appleEnabled(calId))
    }

    var body: some View {
        // Connection status + action (the section header already names it "macOS Apple Calendar").
        HStack(spacing: 10) {
            Text(statusText).font(.callout).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            trailing
        }
        .padding(.vertical, 2)
        .onAppear {
            selected = Set(UserDefaults.standard.stringArray(forKey: PrefKeys.appleCalendars(calId)) ?? [])
            access = CalendarEngine.appleAccess
            if access == .authorized {
                calendars = importer.calendars()
            }
        }

        // The user's calendars, once connected — a compact, indented checklist in the same group:
        //   [checkbox · color dot · name] left-aligned  ·  account name right-aligned.
        if enabled, access == .authorized {
            if calendars.isEmpty {
                Text("No calendars found.").font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(calendars) { c in
                    Toggle(isOn: toggle(c.id)) {
                        HStack(spacing: 8) {
                            Circle().fill(dot(c.colorHex)).frame(width: 8, height: 8)
                            Text(c.title).lineLimit(1)
                            Spacer(minLength: 10)
                            Text(c.source).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .font(.callout)
                        .padding(.leading, 7) // breathing room between the checkbox and the color dot
                    }
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .padding(.leading, 16) // indent the calendars under the connection row
                }
            }
        }
    }

    private var statusText: String {
        switch access {
        case .denied: "Calendar access is off — turn it on in System Settings ▸ Privacy."
        case .notDetermined: "Read events from the Calendar app on this Mac."
        case .authorized: enabled ? "\(selected.count) calendar\(selected.count == 1 ? "" : "s") importing." : "Choose which calendars to import."
        }
    }

    @ViewBuilder private var trailing: some View {
        if busy {
            ProgressView().controlSize(.small)
        } else if access == .denied {
            Button("Open Settings…") {
                openURL(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
            }
        } else if enabled {
            Button("Disconnect") { enabled = false; notifyEngine() }
        } else {
            Button("Connect") { connect() }
        }
    }

    private func connect() {
        busy = true
        Task {
            let ok = await importer.requestAccess()
            if ok {
                // Trust the grant result — authorizationStatus can still read stale for a beat, which
                // would hide the calendar list. Drive the UI off `ok` and ask the store directly.
                access = .authorized
                calendars = importer.calendars()
                if selected.isEmpty {
                    selected = Set(calendars.map(\.id))
                } // default: import all
                enabled = true
                save()
            } else {
                access = CalendarEngine.appleAccess // denied / restricted
            }
            busy = false
        }
    }

    private func toggle(_ id: String) -> Binding<Bool> {
        Binding(get: { selected.contains(id) },
                set: {
                    on in if on {
                        selected.insert(id)
                    } else {
                        selected.remove(id)
                    }; save()
                })
    }

    private func save() {
        UserDefaults.standard.set(Array(selected), forKey: PrefKeys.appleCalendars(calId))
        notifyEngine()
    }

    private func notifyEngine() {
        NotificationCenter.default.post(name: .appleCalendarSettingsChanged, object: nil)
    }

    private func dot(_ hex: String) -> Color {
        let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        return UInt32(s, radix: 16).map { Color(hex: $0) } ?? .secondary
    }
}

/// ── ICS feed subscriptions (read-only, no OAuth) ────────────────────────────────────
/// One provider section per source (Google / Outlook), each just this input form with its own
/// label, example, and Help topic. The subscribed feeds themselves live in one shared list
/// section (CalendarFeedList); the two stay in sync through .icsFeedsChanged. Per MagnifiCal
/// calendar (see ICSFeeds); the parent re-keys everything on switch.
private struct FeedAddressForm: View {
    let calId: String
    let addressLabel: String // "Secret Calendar Address" (Google) / "Published Calendar Address" (Outlook)
    let example: String
    let helpTopic: String // Help topic id the "How to obtain" button opens
    @State private var newURL = ""

    var body: some View {
        // Input form: label · address box · Add.
        HStack(spacing: 8) {
            Text(addressLabel).font(.callout)
            TextField("", text: $newURL)
                .textFieldStyle(.roundedBorder)
            Button("Add") {
                ICSFeeds.add(newURL, calendarId: calId) // posts .icsFeedsChanged → the list section updates
                newURL = ""
            }
            .disabled(!newURL.contains("://"))
        }
        .padding(.vertical, 2)
        // Format example + the how-to (instructions live in Help, not here).
        HStack {
            Text(verbatim: "Example: \(example)")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("How to obtain") {
                HelpNav.pending = helpTopic
                NotificationCenter.default.post(name: .openHelpTopic, object: helpTopic)
            }
            .font(.caption)
        }
    }
}

/// The subscribed feeds (all providers), one row each: the feed's calendar name (X-WR-CALNAME,
/// once fetched) with right-aligned Remove / Refresh. A separate section from the forms above.
private struct CalendarFeedList: View {
    let calId: String
    /// This list's provider slice: Outlook feeds under the Outlook section; everything else
    /// (Google + generic .ics — either could have been pasted into the Google box) under Google's.
    let outlook: Bool
    @State private var feeds: [String]
    @State private var nameGen = 0 // bumped when a fetched feed name lands (see feedTitle)

    init(calId: String, outlook: Bool) {
        self.calId = calId
        self.outlook = outlook
        _feeds = State(initialValue: ICSFeeds.list(calendarId: calId))
    }

    private var shown: [String] {
        feeds.filter { (ICSFeedProvider.label(forURL: $0) == "Outlook Calendar") == outlook }
    }

    var body: some View {
        Group {
            if shown.isEmpty {
                Text("No subscribed calendars.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(shown, id: \.self) { url in
                HStack(spacing: 8) {
                    Image(systemName: "link").font(.caption).foregroundStyle(.secondary)
                    Text(feedTitle(url)).font(.callout).lineLimit(1)
                    Spacer(minLength: 10)
                    Button("Remove") {
                        ICSFeeds.remove(url, calendarId: calId)
                        feeds = ICSFeeds.list(calendarId: calId)
                    }
                    .font(.caption)
                    Button("Refresh") {
                        // Full per-calendar re-import: importICSFeeds prunes feeds missing from the
                        // list it's given, so a single-feed call would delete the others' events.
                        NotificationCenter.default.post(name: .icsFeedsChanged, object: nil)
                    }
                    .font(.caption)
                }
                .padding(.vertical, 1)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .icsFeedsChanged)) { _ in
            feeds = ICSFeeds.list(calendarId: calId) // an Add in the section above (or elsewhere)
        }
        .onReceive(NotificationCenter.default.publisher(for: .icsFeedNamesChanged)) { _ in
            nameGen &+= 1 // a fetch stored a feed's display name → re-render the rows
        }
    }

    /// "Google Calendar — <name>" / "Outlook Calendar — <name>" once a fetch captured the feed's
    /// X-WR-CALNAME; the privacy-friendly host · key form until then.
    private func feedTitle(_ url: String) -> String {
        _ = nameGen // @State read → the rows re-render when a name arrives
        let provider = ICSFeedProvider.label(forURL: url)
        let name = UserDefaults.standard.string(forKey: PrefKeys.icsFeedName(ICSFeedKey.feedKey(url)))
        return "\(provider) — \(name ?? ICSFeeds.displayName(url))"
    }
}

// ── Appearance ────────────────────────────────────────────────────────────────────

private struct AppearanceTab: View {
    @AppStorage(appearanceDefaultsKey) private var raw = AppearanceMode.auto.rawValue

    var body: some View {
        Form {
            Section("Theme") {
                Picker("Appearance", selection: $raw) {
                    ForEach(AppearanceMode.allCases, id: \.rawValue) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: raw) { _, v in
                    applyAppearance(AppearanceMode(rawValue: v) ?? .auto)
                }
                Text("“Automatic” follows your macOS system setting. Light and Dark override it for this app only.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Accent Color") {
                AccentColorRows()
            }
        }
        .formStyle(.grouped)
    }
}

/// The accent picker: the default on its own row, the alternatives on a second row.
private struct AccentColorRows: View {
    @State private var selected: UInt32 = AccentPref.hex

    var body: some View {
        HStack(spacing: 10) {
            swatch(AccentPref.defaultHex)
            Text("MagnifiCal Red")
            Text("default").font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        HStack(spacing: 12) {
            ForEach(AccentPref.alternatives, id: \.hex) { opt in
                swatch(opt.hex).help(opt.name)
            }
            Spacer()
        }
        Text("Colors the now-line, today pill, selection, and controls across the app.")
            .font(.caption).foregroundStyle(.secondary)
    }

    private func swatch(_ hex: UInt32) -> some View {
        Button {
            selected = hex
            AccentPref.set(hex)
        } label: {
            ZStack {
                Circle().fill(Color(hex: hex)).frame(width: 22, height: 22)
                if selected == hex {
                    Circle().strokeBorder(Color.primary.opacity(0.85), lineWidth: 2)
                        .frame(width: 28, height: 28)
                }
            }
            .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
    }
}

// ── API Keys ──────────────────────────────────────────────────────────────────────

private struct APIKeysTab: View {
    @State private var selected: ProviderID? = ProviderStore.active

    var body: some View {
        Form {
            Section("AI Provider") {
                Picker("Provider", selection: $selected) {
                    Text("None").tag(ProviderID?.none)
                    ForEach(ProviderID.allCases) { id in
                        Text(id.label).tag(Optional(id))
                    }
                }
                .onChange(of: selected) { _, v in ProviderStore.active = v }
                if selected == nil {
                    Text(
                        "Pick a provider to configure it. The assistant activates once the selected provider has its key and model set. Configurations for every provider are kept, so switching back is instant."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let id = selected {
                ProviderConfigSection(id: id).id(id) // .id resets the section state per provider
            }
            Section("Web search") {
                APIKeyRow(
                    account: "tavily",
                    name: "Tavily",
                    subtitle: "Web search for the assistant",
                    placeholder: "tvly-…"
                ) { EmptyView() }
            }
            Section {
                Text(
                    "Keys are stored in your macOS Keychain on this device only — not synced. The assistant talks to whichever provider is selected above; the Tavily key powers web search."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// One provider's full configuration: its secret(s), provider-specific fields, the supported-LLM
/// picker (+ custom id escape hatch), and Test Connection. Any edit clears the tested flag —
/// the assistant only runs against a config that passed a test as-is.
private struct ProviderConfigSection: View {
    let id: ProviderID
    @State private var cfg: ProviderSettings = .init()
    @State private var customModel = ""
    @State private var testing = false
    @State private var testError: String?
    @State private var loaded = false // onAppear's programmatic cfg load must not "invalidate"

    var body: some View {
        Section(id.label) {
            // ── Secrets ──
            switch id {
            case .gateway:
                TextField("Base URL", text: $cfg.baseURL, prompt: Text("https://your-gateway.example.com"))
                    .onChange(of: cfg.baseURL) { _, _ in invalidate() }
                Text("Any OpenAI-compatible gateway (LiteLLM-style). Requests go to {base}/compat/chat/completions.")
                    .font(.caption).foregroundStyle(.secondary)
                keyRow("API Key", field: "key", placeholder: "gateway key")
            case .openai:
                keyRow("API Key", field: "key", placeholder: "sk-…")
            case .anthropic:
                keyRow("API Key", field: "key", placeholder: "sk-ant-…")
            case .bedrock:
                keyRow("Access Key ID", field: "akid", placeholder: "AKIA…")
                keyRow("Secret Access Key", field: "secret", placeholder: "AWS secret access key")
                keyRow("Session Token (optional)", field: "session", placeholder: "temporary-credentials only")
                TextField("Region", text: $cfg.region, prompt: Text("us-east-1"))
                    .onChange(of: cfg.region) { _, _ in invalidate() }
            }

            // ── Supported LLMs ──
            Picker("Model", selection: $cfg.model) {
                ForEach(id.supportedModels, id: \.id) { m in
                    Text(m.label).tag(m.id)
                }
                if !customModel.isEmpty || !id.supportedModels.contains(where: { $0.id == cfg.model }) {
                    Text("Custom: \(cfg.model)").tag(cfg.model)
                }
            }
            .onChange(of: cfg.model) { _, _ in invalidate() }
            HStack {
                TextField("Custom model id (optional)", text: $customModel)
                Button("Use") {
                    let m = customModel.trimmingCharacters(in: .whitespaces)
                    if !m.isEmpty {
                        cfg.model = m; invalidate()
                    }
                }
                .disabled(customModel.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            // ── Test Connection ──
            HStack(spacing: 10) {
                Button {
                    runTest()
                } label: {
                    if testing {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Testing…") }
                    } else {
                        Text("Test Connection")
                    }
                }
                .disabled(testing)
                if cfg.testedOK {
                    Label("Tested — this configuration verified OK", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green).font(.caption)
                } else {
                    Label("Optional — verifies the key, endpoint, and model work together",
                          systemImage: "info.circle")
                        .foregroundStyle(.secondary).font(.caption)
                }
            }
            if let testError {
                Text(testError).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .onAppear {
            cfg = ProviderStore.settings(id)
            loaded = true // arm invalidate() only for USER edits, not this programmatic load
        }
    }

    private func keyRow(_ name: String, field: String, placeholder: String) -> some View {
        APIKeyRow(account: ProviderStore.secretAccount(id, field: field), name: name,
                  subtitle: "", placeholder: placeholder, onChanged: { invalidate() }) { EmptyView() }
    }

    /// Any USER config edit → this exact combination is untested again. The `loaded` guard is
    /// load-bearing: onAppear's programmatic `cfg` load fires the same onChange handlers, and
    /// without it every visit to this section silently reset the persisted tested flag.
    private func invalidate() {
        guard loaded else { return }
        cfg.testedOK = false
        testError = nil
        ProviderStore.save(id, cfg)
    }

    private func runTest() {
        testing = true; testError = nil
        ProviderStore.save(id, cfg)
        let id = id
        let model = cfg.model
        Task { @MainActor in
            do {
                try await ProviderStore.provider(id).testConnection(model: model)
                cfg.testedOK = true
                ProviderStore.save(id, cfg)
            } catch {
                cfg.testedOK = false
                ProviderStore.save(id, cfg)
                testError = error.localizedDescription
            }
            testing = false
        }
    }
}

/// One provider's row: a masked field + Save/Remove + a status line, with optional trailing
/// picker content (model / region). The secret is persisted to the Keychain (see Keychain.swift).
private struct APIKeyRow<Extra: View>: View {
    let account: String
    let name: String
    let subtitle: String
    let placeholder: String
    var onChanged: () -> Void = {}
    @ViewBuilder var extra: () -> Extra

    @State private var value = "" // what's typed in the field (never shows the stored secret)
    @State private var saved: String? // the currently-stored secret, for the masked status

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).fontWeight(.medium)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(saved == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
            }
            HStack(spacing: 8) {
                SecureField(saved == nil ? placeholder : "Enter a new key to replace", text: $value)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.leading) // grouped Forms right-align field text by default
                Button("Save") { save() }.disabled(value.isEmpty)
                Button("Remove") { remove() }.disabled(saved == nil)
            }
            extra()
        }
        .padding(.vertical, 4)
        .onAppear { saved = Keychain.get(account: account) }
    }

    /// "••••LAST4" when a key is stored, else "Not set".
    private var statusText: String {
        guard let saved, !saved.isEmpty else { return "Not set" }
        return "••••" + String(saved.suffix(4))
    }

    private func save() {
        // Trim whitespace/newlines — a stray trailing newline from a paste would make
        // URLRequest silently drop the "Authorization: Bearer …" header (→ gateway 401).
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if Keychain.set(clean, account: account) {
            saved = clean
        }
        value = "" // don't leave the raw secret sitting in the field
        onChanged()
    }

    private func remove() {
        Keychain.delete(account: account)
        saved = nil
        value = ""
        onChanged()
    }
}

// ── Developer ─────────────────────────────────────────────────────────────────────

// ── Notifications ─────────────────────────────────────────────────────────────────

/// Per-kind local-notification schedules. Prefs live in UserDefaults (PrefKeys.notify*); every
/// change posts .notifyPrefsChanged so NotificationScheduler resyncs the pending window live.
private struct NotificationsTab: View {
    @AppStorage(PrefKeys.notifyEnabled) private var enabled = false
    @AppStorage(PrefKeys.notifyMorningHour) private var morningHour = 9
    @State private var auth: NotifyAuthStatus?

    var body: some View {
        Form {
            Section("Notifications") {
                Toggle("Enable notifications", isOn: $enabled)
                    .toggleStyle(.switch)
                    .onChange(of: enabled) { _, on in
                        if on {
                            Task { // first enable → the one-time system permission prompt
                                _ = await NotificationScheduler.shared.requestAuthorization()
                                auth = await NotificationScheduler.shared.authStatus()
                            }
                        }
                        postPrefsChanged()
                    }
                authRow
                Picker("Morning notification time", selection: $morningHour) {
                    ForEach(5 ..< 13, id: \.self) { Text(Self.hourLabel($0)).tag($0) }
                }
                .onChange(of: morningHour) { _, _ in postPrefsChanged() }
                Text("\"Day before\" and \"morning of\" notifications arrive at this time.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            KindSection(.band, "Band Events", morningHour, [.dayBefore, .dayOf])
                .disabled(!enabled)
            KindSection(.deadline, "Deadlines", morningHour, [.dayBefore, .dayOf, .h1, .m15, .atTime])
                .disabled(!enabled)
            KindSection(.timed, "Timed Events", morningHour, [.dayBefore, .dayOf, .h1, .m15, .atTime])
                .disabled(!enabled)
            KindSection(.todo, "TODOs", morningHour, [.dayBefore, .dayOf, .h1, .m15, .atTime])
                .disabled(!enabled)
            Section("Overrides & scope") {
                Text("Tag any event, band, or deadline `silent` (in its drawer) to mute it, or `notify` " +
                    "to opt it in even when its kind is off above. Todo lines use inline #silent / #notify. " +
                    "A todo needs a due date (due:2026-08-01T17:00, due:5pm, due:3d) or a parent event's " +
                    "note to inherit a date from; time-less dates ring at the morning hour. Notifications " +
                    "are scheduled by this Mac for the currently open calendar. Apple Calendar imports are " +
                    "never notified — Apple Calendar sends its own alerts.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { auth = await NotificationScheduler.shared.authStatus() }
    }

    @ViewBuilder private var authRow: some View {
        switch auth {
        case .denied:
            HStack(spacing: 10) {
                Circle().fill(.orange).frame(width: 9, height: 9)
                Text("Notifications are turned off for MagnifiCal in System Settings.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Open System Settings…") {
                    if let u = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                        NSWorkspace.shared.open(u)
                    }
                }
            }
        case .authorized where enabled:
            HStack(spacing: 10) {
                Circle().fill(.green).frame(width: 9, height: 9)
                Text("Allowed — the next two weeks are scheduled with macOS.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .unsupported:
            Text("Unavailable in this build (the process isn't an app bundle).")
                .font(.caption).foregroundStyle(.secondary)
        default:
            EmptyView() // not-determined: the prompt appears on first enable
        }
    }

    static func hourLabel(_ h: Int) -> String {
        let f = DateFormatter()
        f.timeStyle = .short; f.dateStyle = .none
        let d = Calendar.current.date(bySettingHour: h, minute: 0, second: 0, of: Date()) ?? Date()
        return f.string(from: d)
    }
}

private func postPrefsChanged() {
    NotificationCenter.default.post(name: .notifyPrefsChanged, object: nil)
}

/// One item kind's schedule: an enable toggle + the kind's applicable delivery offsets.
private struct KindSection: View {
    private let title: String
    private let morningHour: Int
    private let available: [NotifyOffset]
    @AppStorage private var on: Bool
    @AppStorage private var offsets: String

    init(_ kind: NotifyKind, _ title: String, _ morningHour: Int, _ available: [NotifyOffset]) {
        self.title = title
        self.morningHour = morningHour
        self.available = available
        _on = AppStorage(wrappedValue: NotifyPrefs.defaultKindEnabled[kind] ?? false,
                         PrefKeys.notifyKindEnabled(kind.rawValue))
        _offsets = AppStorage(wrappedValue: (NotifyPrefs.defaultOffsets[kind] ?? [])
            .map(\.rawValue).sorted().joined(separator: ","),
            PrefKeys.notifyKindOffsets(kind.rawValue))
    }

    var body: some View {
        Section(title) {
            Toggle("Notify for \(title.lowercased())", isOn: $on)
                .toggleStyle(.switch)
                .onChange(of: on) { _, _ in postPrefsChanged() }
            if on {
                ForEach(available, id: \.rawValue) { off in
                    Toggle(label(off), isOn: bind(off))
                        .toggleStyle(.checkbox)
                        .padding(.leading, 8)
                }
            }
        }
    }

    private func label(_ o: NotifyOffset) -> String {
        switch o {
        case .atTime: "At the time"
        case .m15: "15 minutes before"
        case .h1: "1 hour before"
        case .dayOf: "Morning of (\(NotificationsTab.hourLabel(morningHour)))"
        case .dayBefore: "Day before (\(NotificationsTab.hourLabel(morningHour)))"
        }
    }

    private func bind(_ o: NotifyOffset) -> Binding<Bool> {
        Binding(
            get: { Set(offsets.split(separator: ",").map(String.init)).contains(o.rawValue) },
            set: { v in
                var s = Set(offsets.split(separator: ",").map(String.init))
                if v {
                    s.insert(o.rawValue)
                } else {
                    s.remove(o.rawValue)
                }
                offsets = s.sorted().joined(separator: ",")
                postPrefsChanged()
            }
        )
    }
}

private struct DeveloperTab: View {
    @AppStorage("cc.fpsHUD") private var fpsHUD = false
    @AppStorage("cc.performanceMode") private var perfMode = true
    @State private var confirmPrune = false
    @State private var pruning = false
    @State private var pruneStatus: String?

    private func runPrune() {
        pruning = true
        pruneStatus = nil
        pruneOrphanCloudZones { result in
            DispatchQueue.main.async {
                pruning = false
                switch result {
                case let .success(names):
                    pruneStatus = names.isEmpty
                        ? "No orphaned zones found."
                        : "Pruned \(names.count) zone\(names.count == 1 ? "" : "s"): \(names.joined(separator: ", "))"
                case let .failure(e):
                    pruneStatus = "Failed: \(e.localizedDescription)"
                }
            }
        }
    }

    var body: some View {
        Form {
            Section("iCloud") {
                Button(pruning ? "Pruning…" : "Prune Orphaned iCloud Zones…") { confirmPrune = true }
                    .disabled(pruning)
                if let s = pruneStatus {
                    Text(s).font(.caption).foregroundStyle(.secondary)
                }
                Text("Deletes CloudKit zones that belong to no calendar in the registry — migration " +
                    "leftovers whose records linger invisibly on the server. Registered calendars, the " +
                    "registry, and the default zone are never touched. If you use multiple devices, let " +
                    "them all finish syncing first: a calendar created elsewhere whose registry entry " +
                    "hasn't arrived yet would look orphaned.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .confirmationDialog("Delete all orphaned iCloud zones?", isPresented: $confirmPrune) {
                Button("Prune", role: .destructive) { runPrune() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Zones not matching any registered calendar are deleted from iCloud, including " +
                    "all records inside them. This cannot be undone.")
            }
            Section("Performance") {
                Toggle("Performance Mode (flat event fills)", isOn: $perfMode)
                    .toggleStyle(.switch)
                Text("On (default): events render as flat tinted fills, and untouched events draw in a " +
                    "single canvas layer — the fast path behind the 120fps scrolling. Off: events become " +
                    "individual Liquid Glass views (real backdrop blur) from month zoom in; the year view " +
                    "keeps flat fills either way (a full year of glass is one blur pass per event). " +
                    "Expect lower frame rates and higher GPU load while it's off.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Show frame rate HUD", isOn: $fpsHUD)
                    .toggleStyle(.switch)
                Text("Overlays live render-loop frame timing in the calendar window's corner. " +
                    "The render loop pauses when the calendar is idle, so read it while scrolling or animating.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Notifications") {
                Button("Log pending notifications") {
                    NotificationScheduler.shared.dumpPending()
                }
                Text("Writes the notifications currently scheduled with macOS (the ground truth of what " +
                    "will ring) to the unified log — subsystem dev.magnifical.calendar, category notify. " +
                    "Watch it in Xcode's console, Console.app, or:\n" +
                    "log stream --predicate 'subsystem == \"dev.magnifical.calendar\" AND category == \"notify\"'")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
    }
}
