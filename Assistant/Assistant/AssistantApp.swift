import AppKit
import SwiftUI

/// Native macOS shell; the management server remains independent of this app.
@main
struct AssistantApp: App {
    @State private var model: ClientModel
    @State private var menuBar = UserDefaults.standard.bool(forKey: "assistant.menuBar")
    @State private var confirmingCacheClear = false
    @NSApplicationDelegateAdaptor(AppLifecycle.self) private var lifecycle

    /// Connected fixtures require an explicit Debug-only launch flag and isolated preferences.
    init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-fixture") {
            let defaults = UserDefaults(suiteName: "assistant.ui-fixture") ?? .standard
            let restoreCache = ProcessInfo.processInfo.arguments.contains("--ui-restore-cache")
            if !restoreCache { defaults.removePersistentDomain(forName: "assistant.ui-fixture") }
            let health = InstanceHealth(apiVersion: 2, instanceID: "fixture", name: "Assistant",
                                        capabilities: ["configuration.read"], readOnly: false)
            let fixture = ClientModel(defaults: defaults, api: PreviewManagementAPI(
                chatDetails: ProcessInfo.processInfo.arguments.contains("--ui-chat-details"),
                offline: restoreCache,
                liveChat: ProcessInfo.processInfo.arguments.contains("--ui-live-chat")), health: health)
            fixture.clientID = String(repeating: "a", count: 32)
            fixture.status = String(localized: "Local test fixture")
            _model = State(initialValue: fixture)
            return
        }
        #endif
        _model = State(initialValue: ClientModel())
    }

    /// Ignore redundant scene insertion writes instead of feeding them back through AppStorage.
    private var menuBarInsertion: Binding<Bool> {
        Binding(
            get: { menuBar },
            set: { value in
                guard menuBar != value else { return }
                menuBar = value
                UserDefaults.standard.set(value, forKey: "assistant.menuBar")
            }
        )
    }

    /// Screenshot tests override only this window's appearance, never the user's system settings.
    private var fixtureColorScheme: ColorScheme? {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-fixture") {
            return ProcessInfo.processInfo.arguments.contains("--ui-dark") ? .dark : .light
        }
        #endif
        return nil
    }

    /// Exposes native windows, settings, keyboard commands, and opt-in menu-bar presence.
    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .onAppear { lifecycle.model = model }
                .tint(Theme.accent)
                .frame(minWidth: Theme.windowMinimum.width, minHeight: Theme.windowMinimum.height)
                .preferredColorScheme(fixtureColorScheme)
        }
        .defaultSize(width: Theme.windowDefault.width, height: Theme.windowDefault.height)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New chat") { model.newChatRequest = UUID() }
                    .keyboardShortcut("n")
                    .disabled(model.health == nil || model.chats.sending || model.configurationDirty)
            }

        }
        Settings {
            Form {
                Toggle("Keep a menu-bar item while Assistant is running", isOn: menuBarInsertion)
                Text("Closing a window does not stop the server. Quitting closes this client's SSH tunnel and stops polling.")
                    .foregroundStyle(Theme.secondary)
                Text("SSH uses your macOS SSH configuration and agent. API tokens are kept only in session memory.")
                    .foregroundStyle(Theme.secondary)
                Text("Conversations and tool details are retained on this Mac until you clear the local cache. Clearing it does not delete server history.")
                    .foregroundStyle(Theme.secondary)
                Button("Clear conversation cache…", role: .destructive) { confirmingCacheClear = true }
                    .disabled(model.chats.sending)
            }
            .padding(24).frame(width: 480)
            .confirmationDialog("Clear cached conversations from this Mac?", isPresented: $confirmingCacheClear) {
                Button("Clear local cache", role: .destructive) { model.chats.clearSavedCache() }
                Button("Cancel", role: .cancel) {}
            }
        }
        MenuBarExtra("Assistant", systemImage: "point.3.connected.trianglepath.dotted", isInserted: menuBarInsertion) {
            Text(model.status)
            if let health = model.health { Text(health.name) }
            Divider()
            Button("Show Assistant") { NSApp.activate(ignoringOtherApps: true) }
            Button("Disconnect") { Task { await model.disconnect() } }
                .disabled(model.health == nil)
            Button("Quit Assistant") { NSApp.terminate(nil) }
        }
    }
}

/// Synchronous termination cleanup prevents orphaned OpenSSH tunnels after quitting.
@MainActor
final class AppLifecycle: NSObject, NSApplicationDelegate {
    weak var model: ClientModel?

    /// Quitting requires explicit consent before discarding an unsaved settings draft.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model?.configurationDirty == true else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = String(localized: "Discard unsaved configuration changes?")
        alert.informativeText = String(localized: "These changes have not been saved to the server.")
        alert.addButton(withTitle: String(localized: "Keep editing"))
        alert.addButton(withTitle: String(localized: "Discard and quit"))
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    /// Only the client-owned transport is stopped; no server lifecycle operation is submitted.
    func applicationWillTerminate(_ notification: Notification) {
        model?.terminate()
    }
}
