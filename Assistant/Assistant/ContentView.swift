import SwiftUI

/// Primary native management navigation, independent of API capability implementations.
struct ContentView: View {
    @Bindable var model: ClientModel
    @State private var selection: Destination? = .inbox
    @State private var showingConnection = false
    @State private var confirmingDiscard = false
    @State private var nextDestination: Destination?
    @State private var disconnectAfterDiscard = false
    @State private var showingStatus = false

    /// Each destination has a stable native sidebar identity.
    enum Destination: String, CaseIterable, Identifiable {
        case inbox, reminders, services, data, configuration
        var id: String { rawValue }

        /// Localized section names are collected by Xcode string extraction.
        var title: String {
            switch self {
            case .inbox: return String(localized: "Chats")
            case .reminders: return String(localized: "Reminders")
            case .configuration: return String(localized: "Settings")
            case .services: return String(localized: "Connection & Support")
            case .data: return String(localized: "Data")
            }
        }

        /// SF Symbols supplement visible labels rather than replacing them.
        var symbol: String {
            switch self {
            case .inbox: return "bubble.left.and.bubble.right"
            case .reminders: return "clock"
            case .configuration: return "gearshape"
            case .services: return "server.rack"
            case .data: return "externaldrive"
            }
        }
    }

    /// Routes only supported UI operations through the shared native model.
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 9) {
                    Image(systemName: "point.3.connected.trianglepath.dotted").foregroundStyle(Theme.accent)
                    Text("Assistant").font(.headline)
                }.padding(.horizontal, 20).padding(.top, 24).padding(.bottom, 28)
                VStack(spacing: 6) {
                    ForEach([Destination.inbox, .reminders]) { destination in
                        Button { navigate(destination) } label: {
                            Label(destination.title, systemImage: destination.symbol)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(DestinationButtonStyle(selected: selection == destination))
                        .accessibilityIdentifier("nav-\(destination.rawValue)")
                        .accessibilityAddTraits(selection == destination ? .isSelected : [])
                    }
                }.padding(.horizontal, 10)
                Spacer(minLength: 24)
            }
            .background(Theme.panel)
            .navigationSplitViewColumnWidth(min: Theme.sidebarMinimum, ideal: Theme.sidebarIdeal, max: Theme.sidebarMaximum)
            .disabled(model.configurationApplying)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 9) {
                    Divider().padding(.bottom, 3)
                    HStack {
                        statusControl
                        Spacer(minLength: 0)
                        Button { navigate(.configuration) } label: {
                            Label("Settings", systemImage: Destination.configuration.symbol).labelStyle(.iconOnly)
                        }
                        .buttonStyle(.borderless)
                        .help("Settings")
                        .accessibilityIdentifier("nav-configuration")
                        .accessibilityAddTraits(selection == .configuration ? .isSelected : [])
                    }
                }
                .foregroundStyle(Theme.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
                .padding(.top, 8)
            }
        } detail: {
            VStack(spacing: 0) {
                if model.health == nil {
                    disconnected
                } else {
                    switch selection ?? .inbox {
                    case .inbox: InboxView(model: model, chat: model.chats)
                    case .reminders:
                        InboxView(model: model, chat: model.reminderRuns, isReminders: true) { reminder in
                            model.chats.newChat(about: reminder)
                            navigate(.inbox)
                        }
                    case .configuration: ConfigurationView(model: model)
                    case .services: ServicesView(model: model)
                    case .data: DataManagementView(model: model)
                    }
                }
            }
            .background(Theme.background)
            .foregroundStyle(Theme.ink)
            .navigationTitle((selection ?? .inbox).title)
            .toolbar {
                if model.health != nil {
                    Button("Disconnect", systemImage: "network.slash") {
                        if model.configurationDirty {
                            disconnectAfterDiscard = true
                            confirmingDiscard = true
                        } else { Task { await model.disconnect() } }
                    }.disabled(model.busy || model.configurationApplying)
                } else {
                    Button("Connect", systemImage: "network") { showingConnection = true }
                        .disabled(model.busy)
                }
            }
        }
        .onChange(of: model.newChatRequest) {
            guard !model.configurationDirty, !model.configurationApplying else { return }
            selection = .inbox
            model.chats.newChat()
        }
        .onChange(of: model.setupRequired) {
            if model.setupRequired { navigate(.configuration) }
        }
        .onChange(of: model.notificationRequest) {
            guard !model.configurationDirty, !model.configurationApplying else {
                model.error = String(localized: "Save or discard your settings draft before opening this update.")
                return
            }
            selection = .inbox
            if let task = model.notificationTaskID {
                Task {
                    do {
                        let task = try await model.chats.chatTask(model, id: task)
                        let scheduled = task.threadID.hasPrefix("reminder:")
                        navigate(scheduled ? .reminders : .inbox)
                        try await (scheduled ? model.reminderRuns : model.chats).openTask(task, model: model)
                    }
                    catch { model.error = error.presentableMessage }
                }
            }
        }
        .sheet(isPresented: $showingConnection) {
            ConnectionView(model: model, isPresented: $showingConnection)
        }
        .confirmationDialog("Discard unsaved configuration changes?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button("Discard changes", role: .destructive) {
                model.configurationDirty = false
                if disconnectAfterDiscard { Task { await model.disconnect() } }
                else { selection = nextDestination }
                disconnectAfterDiscard = false
            }
            Button("Keep editing", role: .cancel) { disconnectAfterDiscard = false }
        }
    }

    /// Connection, data, and support tools stay out of the way until needed.
    private var statusControl: some View {
        Button { showingStatus.toggle() } label: {
            StatusBadge(title: model.status, tone: model.health == nil ? .gray :
                        model.error != nil || model.pollingError != nil || model.liveUpdateError != nil ? .orange : .green)
        }
        .buttonStyle(.plain)
        .help("Connection & Support")
        .accessibilityIdentifier("nav-connection")
        .popover(isPresented: $showingStatus) {
            VStack(alignment: .leading, spacing: 12) {
                if let issue = model.error ?? model.pollingError ?? model.liveUpdateError {
                    ErrorBanner(message: issue)
                    if model.error != nil { Button("Dismiss notice") { model.error = nil } }
                }
                if model.health != nil {
                    Text(model.profile.name).font(.headline)
                    Text(model.liveUpdates ? "Live updates are on" : "Checking for updates")
                        .foregroundStyle(Theme.secondary)
                    ForEach([Destination.services, .data]) { destination in
                        Button { showingStatus = false; navigate(destination) } label: {
                            Label(destination.title, systemImage: destination.symbol)
                        }.accessibilityIdentifier("nav-\(destination.rawValue)")
                    }
                } else {
                    Button("Connect") { showingStatus = false; showingConnection = true }
                }
            }
            .padding().frame(width: 340, alignment: .leading)
        }
    }

    /// Navigation does not silently destroy a configuration draft.
    private func navigate(_ destination: Destination?) {
        guard !model.configurationApplying else { return }
        guard destination != selection else { return }
        if model.configurationDirty {
            nextDestination = destination
            disconnectAfterDiscard = false
            confirmingDiscard = true
        } else { selection = destination }
    }

    /// The first launch performs no network activity until the user explicitly connects.
    private var disconnected: some View {
        VStack(spacing: 20) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 54)).foregroundStyle(Theme.accent)
            Text("Your platform. One connection.").font(.largeTitle.weight(.semibold))
            Text("Connect to Assistant through SSH, or use an installation on this Mac.")
                .foregroundStyle(Theme.secondary)
            Button("Connect to Assistant") { showingConnection = true }
                .buttonStyle(PrimaryButtonStyle()).disabled(model.busy)
                .accessibilityIdentifier("connect-button")
            StableProgress(active: model.busy)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
    }
}

/// Connection profiles contain metadata only and cannot edit a live session's identity.
struct ConnectionView: View {
    @Bindable var model: ClientModel
    @Binding var isPresented: Bool

    /// Strict host trust is established in Terminal rather than silently accepted by the app.
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Connect to Assistant").font(.title2.weight(.semibold))
            if !model.profiles.isEmpty {
                Picker("Saved connection", selection: Binding(
                    get: { model.profiles.contains(where: { $0.id == model.profile.id }) ? model.profile.id : nil },
                    set: { id in
                        if let profile = model.profiles.first(where: { $0.id == id }) { model.profile = profile }
                        else { model.profile = ConnectionProfile() }
                    }
                )) {
                    Text("New connection").tag(Optional<UUID>.none)
                    ForEach(model.profiles) { Text($0.name).tag(Optional($0.id)) }
                }
            }
            Form {
                TextField("Connection name", text: $model.profile.name)
                Toggle("Installation on this Mac", isOn: $model.profile.local)
                if !model.profile.local {
                    TextField("SSH alias or user@host", text: $model.profile.host)
                    TextField("SSH port", value: $model.profile.sshPort, format: .number.grouping(.never))
                    Text("Verify this destination with ssh in Terminal first. Unknown or changed host keys and interactive password prompts are not accepted.")
                        .font(.caption).foregroundStyle(Theme.secondary)
                }
            }
            if let error = model.error { ErrorBanner(message: error) }
            HStack {
                Button("New profile") { model.profile = ConnectionProfile() }
                Spacer()
                Button("Cancel") { isPresented = false }.keyboardShortcut(.cancelAction)
                Button("Connect") {
                    Task {
                        await model.connect()
                        if model.health != nil { isPresented = false }
                    }
                }
                .buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 520)
        .disabled(model.busy)
    }
}

#Preview("Light") {
    ContentView(model: ClientModel(defaults: UserDefaults()))
        .preferredColorScheme(.light).frame(width: 1180, height: 820)
}

#Preview("Dark") {
    ContentView(model: ClientModel(defaults: UserDefaults()))
        .preferredColorScheme(.dark).frame(width: 1180, height: 820)
}

#if DEBUG
#Preview("Chat details light") {
    let health = InstanceHealth(apiVersion: 2, instanceID: "preview", name: "Assistant",
                                capabilities: ["configuration.read"], readOnly: false)
    let model = ClientModel(defaults: UserDefaults(), api: PreviewManagementAPI(chatDetails: true), health: health)
    ContentView(model: model)
        .preferredColorScheme(.light).frame(width: 1280, height: 860)
        .task {
            do {
                try await model.chats.loadConversations(model)
                if let conversation = model.chats.conversations.first { model.chats.select(conversation) }
                try await model.chats.refresh(model)
            } catch { model.error = error.presentableMessage }
        }
}
#endif
