import AppKit
import SwiftUI
import UserNotifications

/// Native macOS shell; the management server remains independent of this app.
@main
struct AssistantApp: App {
    @State private var model: ClientModel
    @AppStorage("assistant.menuBar") private var menuBar = false
    @Environment(\.openWindow) private var openWindow
    @NSApplicationDelegateAdaptor(AppLifecycle.self) private var lifecycle

    /// Connected fixtures require an explicit Debug-only launch flag and isolated preferences.
    init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-fixture") {
            let defaults = UserDefaults(suiteName: "assistant.ui-fixture") ?? .standard
            let restoreCache = ProcessInfo.processInfo.arguments.contains("--ui-restore-cache")
            if !restoreCache { defaults.removePersistentDomain(forName: "assistant.ui-fixture") }
            let health = InstanceHealth(apiVersion: 2, instanceID: "fixture", name: "Assistant",
                                        capabilities: ["configuration.read", "configuration.structured", "configuration.sections"], readOnly: false)
            let fixture = ClientModel(defaults: defaults, api: PreviewManagementAPI(
                chatDetails: ProcessInfo.processInfo.arguments.contains("--ui-chat-details"),
                offline: restoreCache,
                liveChat: ProcessInfo.processInfo.arguments.contains("--ui-live-chat"),
                slowReads: ProcessInfo.processInfo.arguments.contains("--ui-slow-reads")), health: health)
            fixture.clientID = String(repeating: "a", count: 32)
            fixture.status = String(localized: "Local test fixture")
            if ProcessInfo.processInfo.arguments.contains("--ui-unconfirmed-action") {
                fixture.references = [OperationReference(
                    id: UUID(), instanceID: health.instanceID, key: "fixture-request", action: "task.reply",
                    operationID: nil, submittedAt: Date(timeIntervalSince1970: 1_800_000_000)
                )]
            }
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
        WindowGroup(id: "main") {
            ContentView(model: model)
                .onAppear {
                    lifecycle.model = model
                    lifecycle.showWindow = { openWindow(id: "main") }
                }
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
            ScrollView { AppPreferencesView(model: model).padding(24) }.frame(width: 520, height: 520)
        }
        MenuBarExtra("Assistant", systemImage: "point.3.connected.trianglepath.dotted", isInserted: menuBarInsertion) {
            Text(model.status)
            if let health = model.health { Text(health.name) }
            Divider()
            Button("Show Assistant") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            Button("Disconnect") { Task { await model.disconnect() } }
                .disabled(model.health == nil)
            Button("Quit Assistant") { NSApp.terminate(nil) }
        }
    }
}

/// Synchronous termination cleanup prevents orphaned OpenSSH tunnels after quitting.
@MainActor
final class AppLifecycle: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    weak var model: ClientModel?
    var showWindow: (() -> Void)?

    /// Registration alone never asks permission or enables notifications.
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
    }

    /// Open only the installation that created the notification.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let task = response.notification.request.content.userInfo["task"] as? Int
        let instance = response.notification.request.content.userInfo["instance"] as? String
        let approvals = response.notification.request.content.userInfo["category"] as? String == "approvals"
        await MainActor.run {
            guard let model else { return }
            showWindow?()
            NSApp.activate(ignoringOtherApps: true)
            guard model.health?.instanceID == instance else {
                model.error = String(localized: "Connect to the installation that created this update before opening it.")
                return
            }
            model.notificationTaskID = task
            model.notificationApprovals = approvals
            model.notificationRequest = UUID()
        }
    }
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

/// Local preferences are separate from server configuration and never require a server save.
struct AppPreferencesView: View {
    let model: ClientModel
    @AppStorage("assistant.notifications") private var notifications = false
    @AppStorage("assistant.notifications.replies") private var replies = true
    @AppStorage("assistant.notifications.approvals") private var approvals = true
    @AppStorage("assistant.notifications.errors") private var errors = true
    @AppStorage("assistant.menuBar") private var menuBar = false
    @State private var confirmingClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("On this Mac").font(.title2.weight(.semibold))
            ManagementPanel {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Notifications").font(.headline)
                    Toggle("Show macOS notifications", isOn: Binding(get: { notifications }, set: { enabled in
                        if enabled { Task { await model.enableNotifications() } }
                        else { notifications = false }
                    }))
                    Text("Private alerts while Assistant is running. Message bodies are never included. In-app updates remain available without permission.")
                        .font(.callout).foregroundStyle(Theme.secondary)
                    Toggle("Replies and completed tasks", isOn: $replies)
                    Toggle("Approval requests", isOn: $approvals)
                    Toggle("Failures and connection problems", isOn: $errors)
                }.toggleStyle(.switch)
            }
            ManagementPanel {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Keep a menu-bar item while Assistant is running", isOn: $menuBar).toggleStyle(.switch)
                        .accessibilityIdentifier("menu-bar-preference")
                    Text("Quitting closes this Mac's SSH tunnel, not the server or its running work.")
                        .font(.callout).foregroundStyle(Theme.secondary)
                    Button("Clear conversation cache…", role: .destructive) { confirmingClear = true }
                        .disabled(model.chats.sending)
                    Text("Removes cached conversations and tool details from this Mac. Server history is preserved.")
                        .font(.callout).foregroundStyle(Theme.secondary)
                }
            }
        }
        .confirmationDialog("Clear cached conversations from this Mac?", isPresented: $confirmingClear) {
            Button("Clear local cache", role: .destructive) { model.chats.clearSavedCache() }
            Button("Cancel", role: .cancel) {}
        }
    }
}
