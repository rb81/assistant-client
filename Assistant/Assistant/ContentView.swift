import SwiftUI

/// Primary native management navigation, independent of API capability implementations.
struct ContentView: View {
    @Bindable var model: ClientModel
    @State private var selection: Destination? = .inbox
    @State private var showingConnection = false
    @State private var confirmingDiscard = false
    @State private var nextDestination: Destination?
    @State private var disconnectAfterDiscard = false

    /// Each destination has a stable native sidebar identity.
    enum Destination: String, CaseIterable, Identifiable {
        case inbox, services, data, configuration
        var id: String { rawValue }

        /// Localized section names are collected by Xcode string extraction.
        var title: String {
            switch self {
            case .inbox: return String(localized: "Chats")
            case .configuration: return String(localized: "Settings")
            case .services: return String(localized: "Server Health")
            case .data: return String(localized: "Data")
            }
        }

        /// SF Symbols supplement visible labels rather than replacing them.
        var symbol: String {
            switch self {
            case .inbox: return "bubble.left.and.bubble.right"
            case .configuration: return "slider.horizontal.3"
            case .services: return "server.rack"
            case .data: return "externaldrive"
            }
        }
    }

    /// Routes only supported UI operations through the shared native model.
    var body: some View {
        NavigationSplitView {
            List(Destination.allCases, selection: Binding(get: { selection }, set: navigate)) { destination in
                Label(destination.title, systemImage: destination.symbol).tag(destination)
                    .padding(.vertical, 7)
            }
            .navigationTitle("Assistant")
            .navigationSplitViewColumnWidth(min: Theme.sidebarMinimum, ideal: Theme.sidebarIdeal, max: Theme.sidebarMaximum)
            .disabled(model.configurationApplying)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 9) {
                    Divider().padding(.bottom, 3)
                    StatusBadge(title: model.status, tone: model.health == nil ? .gray : model.pollingError == nil ? .green : .orange)
                    if model.health != nil {
                        Text(model.profile.name).font(.callout.weight(.semibold)).lineLimit(1)
                        Text(model.profile.local ? String(localized: "This Mac") : model.profile.host)
                            .font(.caption).lineLimit(1).truncationMode(.middle)
                    }
                    if let lastPoll = model.lastPoll {
                        Label("Updated \(lastPoll.formatted(date: .omitted, time: .standard))", systemImage: "clock")
                            .font(.caption2).lineLimit(1)
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
                if let error = model.error { ErrorBanner(message: error).padding() }
                if let error = model.pollingError { ErrorBanner(message: error).padding() }
                if model.health == nil {
                    disconnected
                } else {
                    switch selection ?? .inbox {
                    case .inbox: InboxView(model: model)
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
                .buttonStyle(CopperButtonStyle()).disabled(model.busy)
                .accessibilityIdentifier("connect-button")
            if model.busy { ProgressView() }
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
                .buttonStyle(CopperButtonStyle()).keyboardShortcut(.defaultAction)
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
