import SwiftUI

/// A thread-first workspace with a readable transcript and a persistent in-memory composer.
struct InboxView: View {
    let model: ClientModel
    let chat: ConversationModel
    var isReminders = false
    var askAboutRun: ((Conversation) -> Void)? = nil
    @State private var showingApprovals = false
    @State private var showingUpdates = false
    @State private var showingSchedule = false
    @State private var deletionPreview: JSONValue?
    @State private var scrollState = TranscriptScrollState()
    @State private var loadingEarlier = false
    @State private var confirmingRoute = false
    @State private var searchReady = false
    @State private var expandedInstructions: Set<String> = []
    @AppStorage("chats.showToolCalls") private var showToolCalls = false
    @Environment(\.scenePhase) private var scenePhase

    /// A new client delivery for the open conversation refreshes it immediately instead of waiting.
    private struct TranscriptTrigger: Hashable {
        let thread: String?
        let deliveries: [Int]
        let revision: Int
    }

    /// Deliveries for the selected conversation's task, used to refresh it as soon as a reply arrives.
    private var assistantDeliveries: [Int] {
        guard let task = chat.selected?.latestTaskID else { return [] }
        return model.messages.filter { $0.taskID == task }.map(\.id)
    }

    /// Late inbox offers must retrigger acknowledgment even when the transcript is unchanged.
    private struct DeliveryRender: Hashable {
        let thread: String?
        let version: String?
        let offered: [Int]
        let rendered: [String]
        let active: Bool
    }

    /// Tail content, not just row counts, changes as tools finish or replies are updated in place.
    private struct TranscriptTail: Equatable {
        let thread: String?
        let message: ChatMessage?
        let call: ToolCall?
        let pending: ChatMessage?
    }

    private var transcriptTail: TranscriptTail {
        TranscriptTail(thread: chat.selectedThread, message: chat.messages.last,
                       call: showToolCalls ? chat.toolCalls.last : nil, pending: chat.pendingMessage)
    }

    /// The frame contains both content height and scroll offset, in the viewport's coordinate space.
    private struct TranscriptFrame: PreferenceKey {
        static let defaultValue = CGRect.zero
        static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
    }

    /// Conversation reads and activity refreshes never block the connection heartbeat.
    var body: some View {
        HSplitView {
            threadList.frame(minWidth: 230, idealWidth: 260, maxWidth: 320)
            VStack(spacing: 0) {
                transcriptHeader
                Divider()
                if let error = chat.error { ErrorBanner(message: error).padding() }
                transcript.frame(maxHeight: .infinity)
                Divider()
                if isReminders {
                    HStack {
                        Label("Scheduled runs are read-only", systemImage: "lock")
                            .font(.caption).foregroundStyle(Theme.secondary)
                        Spacer()
                        if let selected = chat.selected {
                            Button("Ask about this run") { askAboutRun?(selected) }
                                .disabled(model.chats.sending)
                        }
                    }.frame(height: 32).padding(12).background(Theme.panel)
                } else {
                    composer.fixedSize(horizontal: false, vertical: true)
                }
            }.frame(minWidth: 420)
        }
        .task {
            // Returning to Chats shows the list already in memory instead of reloading it straight away.
            if model.liveRevision == 0 && chat.listIsFresh && model.messages.isEmpty {
                do { try await Task.sleep(for: ConversationModel.listRefresh) } catch { return }
            }
            while !Task.isCancelled {
                do { try await chat.loadConversations(model) }
                catch { chat.error = error.presentableMessage ?? chat.error }
                do { try await Task.sleep(for: ConversationModel.listRefresh) } catch { return }
            }
        }
        .onChange(of: model.liveRevision) { chat.refreshAfterEvent(model) }
        .task(id: TranscriptTrigger(thread: chat.selectedThread, deliveries: assistantDeliveries, revision: 0)) {
            guard chat.selectedThread != nil else { return }
            // A cached transcript is shown as-is unless it is stale or a new reply has just arrived.
            var reuseCache = model.liveRevision == 0 && !chat.noteDeliveries(assistantDeliveries)
            while !Task.isCancelled {
                let delay = chat.selected?.active == true ? ConversationModel.activeRefresh : ConversationModel.idleRefresh
                do { try await chat.refresh(model, maxAge: reuseCache ? delay : nil) }
                catch { chat.error = error.presentableMessage ?? chat.error }
                reuseCache = false
                do { try await Task.sleep(for: delay) } catch { return }
            }
        }
        .sheet(isPresented: $showingApprovals) {
            VStack {
                ApprovalsView(model: model)
                Button("Done") { showingApprovals = false }.padding()
            }.frame(width: 720, height: 600)
        }
        // Presenting from the preview itself keeps the sheet's content in sync with the value it shows.
        .sheet(isPresented: Binding(get: { deletionPreview != nil }, set: { if !$0 { deletionPreview = nil } })) {
            deletionReview
        }
        .sheet(isPresented: $showingUpdates) { updates }
        .sheet(isPresented: $showingSchedule) { ReminderScheduleView(model: model) }
        .task(id: model.notificationApprovals) {
            if model.notificationApprovals {
                showingApprovals = true
                model.notificationApprovals = false
            }
        }
        .confirmationDialog("Continue this conversation in Assistant?", isPresented: $confirmingRoute, titleVisibility: .visible) {
            Button("Continue here") { Task { await chat.send(model) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This sends your message through this client, not email or Telegram. It can change where the assistant sends future replies in this conversation.")
        }
    }

    /// Search and channel filters go to the server so older conversations remain discoverable.
    private var threadList: some View {
        @Bindable var chat = self.chat
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(isReminders ? "Run history" : "Conversations").font(.headline)
                StableProgress(active: chat.loadingList)
                Spacer()
                if !isReminders {
                    Button { chat.newChat() } label: { Image(systemName: "square.and.pencil") }
                        .help("New chat (Command-N)").accessibilityLabel("New chat")
                        .disabled(chat.sending)
                }
            }
            if isReminders {
                Button("View schedule", systemImage: "calendar") { showingSchedule = true }
            }
            TextField(isReminders ? "Search reminder runs" : "Search conversations", text: $chat.search)
                .textFieldStyle(.roundedBorder)
                .task(id: chat.search) {
                    guard searchReady else { searchReady = true; return }
                    do {
                        try await Task.sleep(for: .milliseconds(300))
                        try await chat.searchConversations(model)
                    } catch is CancellationError {}
                    catch { chat.error = error.presentableMessage ?? chat.error }
                }
            if !isReminders {
                Picker("Channel", selection: $chat.channel) {
                    Text("All channels").tag("")
                    ForEach(["client", "telegram", "email"], id: \.self) { channel in
                        Text(Conversation.channelTitle(channel)).tag(channel)
                    }
                }
                .labelsHidden()
                .onChange(of: chat.channel) { reloadConversations() }
            }
            ScrollView {
                LazyVStack(spacing: 6) {
                    if chat.conversations.isEmpty && !chat.loadingList {
                        Text(isReminders ?
                             (chat.search.isEmpty ? "Scheduled runs will appear here." : "No reminder runs match.") :
                             (chat.search.isEmpty ? "Your conversations will appear here." : "No conversations match."))
                            .foregroundStyle(Theme.secondary).font(.callout).padding(.vertical, 24)
                    }
                    ForEach(chat.conversations) { conversation in
                        ConversationRow(conversation: conversation,
                                        selected: chat.selectedThread == conversation.threadID,
                                        unread: chat.isUnread(conversation)) {
                            chat.select(conversation)
                        }
                        .disabled(chat.sending)
                        .accessibilityIdentifier("chat-thread-\(conversation.latestTaskID)")
                    }
                    if chat.conversations.count < chat.totalConversations {
                        Button(isReminders ? "Load older reminders" : "Load older conversations") {
                            Task {
                                do { try await chat.loadConversations(model, older: true) }
                                catch { chat.error = error.presentableMessage ?? chat.error }
                            }
                        }.padding(.vertical, 12)
                    }
                }
            }
            if !isReminders {
                Button(model.pendingApprovals == 0 ? String(localized: "Review approvals") :
                        String(localized: "Review approvals (\(model.pendingApprovals))"),
                       systemImage: "checkmark.shield") { showingApprovals = true }
                    .font(.callout)
                Button(model.unreadUpdates == 0 ? String(localized: "Updates") :
                        String(localized: "Updates (\(model.unreadUpdates))"), systemImage: "bell") { showingUpdates = true }
                    .font(.callout)
            }
        }.padding(16).background(Theme.panel.opacity(0.6))
    }

    /// Restarts paging whenever the search text or channel filter changes.
    private func reloadConversations() {
        Task {
            do { try await chat.searchConversations(model) }
            catch { chat.error = error.presentableMessage ?? chat.error }
        }
    }

    /// Destructive actions use the currently selected server execution and a fresh deletion preview.
    private var transcriptHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(chat.selected?.title ?? (isReminders ? String(localized: "Scheduled reminders") : String(localized: "A fresh conversation")))
                    .font(.headline).lineLimit(1)
                if let selected = chat.selected {
                    Text("\(Conversation.channelTitle(selected.channel)) · \(selected.workstreamLabel)")
                        .font(.caption).foregroundStyle(Theme.secondary).lineLimit(1)
                } else if !isReminders {
                    Text("Assistant keeps related work organized automatically.")
                        .font(.caption).foregroundStyle(Theme.secondary)
                }
            }
            Spacer()
            if chat.selected != nil {
                Toggle(isOn: $showToolCalls) { Label("Tool calls", systemImage: "wrench.and.screwdriver") }
                    .toggleStyle(.button).labelStyle(.iconOnly)
                    .help(showToolCalls ? "Hide tool calls" : "Show tool calls")
                    .accessibilityLabel("Show tool calls")
            }
            if let selected = chat.selected {
                StatusBadge(title: selected.latestTaskStatus.replacingOccurrences(of: "_", with: " ").capitalized,
                            tone: selected.deleted ? .gray : selected.active ? .orange : .green)
                if !selected.deleted && !isReminders {
                    Button(role: .destructive) {
                        Task {
                            do {
                                deletionPreview = try await model.read("tasks/\(selected.latestTaskID)/deletion-preview")
                            } catch { chat.error = error.presentableMessage ?? chat.error }
                        }
                    } label: { Image(systemName: "trash") }
                    .help("Delete task data; preserve conversation and shared files")
                    .accessibilityLabel("Delete selected chat task data")
                    .disabled(chat.sending)
                }
            }
        }.padding(20)
    }

    /// Native Markdown never executes scripts or loads remote image resources.
    private var transcript: some View {
        ScrollViewReader { reader in
            GeometryReader { viewport in
                ScrollView {
                    transcriptRows.frame(minHeight: viewport.size.height, alignment: .top)
                }
                .coordinateSpace(name: "chat-transcript")
                .defaultScrollAnchor(.bottom)
                .id(chat.selectedThread ?? "new")
                .overlay { transcriptPlaceholder }
                .overlay(alignment: .bottomTrailing) {
                    if !scrollState.followsLatest {
                        Button("Latest", systemImage: "arrow.down") {
                            scrollState.followsLatest = true
                            reader.scrollTo("transcript-end", anchor: .bottom)
                        }
                        .buttonStyle(.bordered).padding(16)
                    }
                }
                .onPreferenceChange(TranscriptFrame.self) { frame in
                    scrollState.update(frame: frame, viewportHeight: viewport.size.height)
                }
                .onChange(of: transcriptTail) { old, new in
                    if old.thread != new.thread {
                        scrollState = TranscriptScrollState()
                    } else if new.pending != nil && old.pending != new.pending {
                        scrollState.followsLatest = true
                    }
                    if scrollState.followsLatest && !loadingEarlier {
                        reader.scrollTo("transcript-end", anchor: .bottom)
                    }
                }
            }
            .task(id: DeliveryRender(thread: chat.selectedThread, version: chat.renderedVersion,
                                     offered: model.offeredIDs, rendered: chat.messages.map(\.id),
                                     active: scenePhase == .active)) {
                if scenePhase == .active { chat.markRendered() }
                let rendered = Set(chat.messages.filter { $0.channel == "client" && !$0.incoming }.map(\.wireID))
                await model.acknowledgeRendered(ids: model.offeredIDs.filter(rendered.contains))
            }
        }
    }

    /// Loading is an overlay, so scrolling never moves the placeholder offscreen.
    @ViewBuilder private var transcriptPlaceholder: some View {
        if chat.loadingTranscript {
            ProgressView("Loading conversation…")
                .accessibilityIdentifier("transcript-loading")
        } else if chat.selectedThread != nil && chat.timeline.isEmpty {
            VStack(spacing: 12) {
                Text(chat.error == nil ? "No messages in this conversation yet." : "Conversation could not be loaded.")
                    .foregroundStyle(Theme.secondary)
                if chat.error != nil {
                    Button("Retry loading conversation") {
                        Task {
                            do { try await chat.refresh(model) }
                            catch { chat.error = error.presentableMessage ?? chat.error }
                        }
                    }
                }
            }
        }
    }

    private var transcriptRows: some View {
        VStack(alignment: .leading, spacing: 24) {
            if isReminders && chat.selectedThread == nil {
                ContentUnavailableView("Select a reminder", systemImage: "clock",
                                       description: Text("See what Assistant did and where it sent the result."))
            } else if chat.selectedThread == nil && chat.pendingMessage == nil {
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: "sparkle").font(.system(size: 34)).foregroundStyle(Theme.accent)
                    Text("What shall we work on?").font(Theme.pageTitle)
                    Text("Ask a question, explore an idea, or hand over a task.")
                        .foregroundStyle(Theme.secondary)
                }.padding(.vertical, 60)
            }
            if chat.messages.count < chat.totalMessages {
                Button("Load earlier messages") {
                    Task {
                        loadingEarlier = true
                        defer { loadingEarlier = false }
                        do { try await chat.refresh(model, moreMessages: true) }
                        catch { chat.error = error.presentableMessage ?? chat.error }
                    }
                }.disabled(loadingEarlier)
            }
            if showToolCalls && chat.activityTruncated {
                Text("Earlier tool calls in this conversation are not shown.")
                    .font(.caption).foregroundStyle(Theme.secondary)
            }
            ForEach(chat.timeline) { item in
                switch item {
                case .message(let message): messageView(message)
                case .tools(let calls): if showToolCalls { ToolRunView(calls: calls) }
                }
            }
            if chat.selected?.deleted == true {
                Label("Deleted task. Conversation and shared data are preserved. This chat is read-only.",
                      systemImage: "lock").font(.callout).foregroundStyle(Theme.secondary)
            }
            Color.clear.frame(height: 1).id("transcript-end")
        }
        .frame(maxWidth: Theme.contentWidth, alignment: .leading)
        .padding(28).frame(maxWidth: .infinity)
        .background {
            GeometryReader { content in
                Color.clear.preference(key: TranscriptFrame.self,
                                       value: content.frame(in: .named("chat-transcript")))
            }
        }
    }

    /// One message: who sent it, when, and its rendered body.
    private func messageView(_ message: ChatMessage) -> some View {
        let external = message.external == true && !message.incoming
        let pending = message.wireID == -1
        return VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label(message.scheduled ? String(localized: "Scheduled run") :
                        message.incoming ? String(localized: "You") : model.health?.name ?? "Assistant",
                      systemImage: message.scheduled ? "clock" :
                        message.incoming ? "person.crop.circle" : external ? "envelope.badge" : "sparkle")
                    .font(.callout.weight(.semibold))
                if external {
                    Text("Sent externally").font(.caption.weight(.semibold)).foregroundStyle(.orange)
                }
                if message.channel != "client" {
                    Text(Conversation.channelTitle(message.channel)).font(.caption).foregroundStyle(Theme.secondary)
                }
                Spacer()
                Text(Self.timestamp(message.createdAt)).font(.caption2).foregroundStyle(Theme.secondary)
            }
            if let recipients = message.recipients, !recipients.isEmpty {
                Text("To: \(recipients.joined(separator: ", "))")
                    .font(.caption).foregroundStyle(Theme.secondary).textSelection(.enabled)
            }
            if let subject = message.subject, !subject.isEmpty { Text(subject).font(.callout.weight(.medium)) }
            if message.scheduled {
                let expanded = expandedInstructions.contains(message.id)
                Button(expanded ? "Hide run instructions" : "Show run instructions",
                       systemImage: expanded ? "chevron.down" : "chevron.right") {
                    if expanded { expandedInstructions.remove(message.id) }
                    else { expandedInstructions.insert(message.id) }
                }.buttonStyle(.plain).foregroundStyle(Theme.secondary)
                if expanded { MarkdownContent(text: message.body).padding(.top, 6) }
            } else if let value = try? JSONValue.parse(message.body),
               message.body.trimmingCharacters(in: .whitespacesAndNewlines).first.map({ $0 == "{" || $0 == "[" }) == true {
                ChatJSON(value: value)
            } else {
                MarkdownContent(text: message.body)
            }
            ForEach(Array((message.attachments ?? []).enumerated()), id: \.offset) { _, attachment in
                ChatAttachmentView(model: model, attachment: attachment)
            }
            if pending {
                HStack(spacing: 8) {
                    if chat.sending {
                        ProgressView().controlSize(.mini).accessibilityLabel("Sending")
                    } else if chat.pendingUnconfirmed {
                        Label("Not confirmed — inspect operation history before retrying", systemImage: "exclamationmark.circle")
                            .font(.caption).foregroundStyle(Theme.secondary)
                    } else {
                        Text("Sent — waiting for transcript").font(.caption).foregroundStyle(Theme.secondary)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(message.incoming ? Theme.panel : Theme.panel.opacity(0.4),
                    in: RoundedRectangle(cornerRadius: Theme.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius)
            .stroke(external ? Color.orange.opacity(0.5) : Theme.secondary.opacity(0.18)))
    }

    /// Local date and time for a server timestamp, falling back to the raw value.
    private static func timestamp(_ value: String) -> String {
        guard let date = ServerDate.parse(value) else {
            return String(value.prefix(16)).replacingOccurrences(of: "T", with: " ")
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    /// Installation notices are not chat threads, but still need visible delivery and acknowledgment.
    private var updates: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeading(title: "Updates", subtitle: "Notices from your Assistant installation.")
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if model.messages.filter({ $0.taskID == nil }).isEmpty &&
                        !model.activityUpdates.contains(where: { $0.instanceID == model.health?.instanceID }) {
                        Text("No updates to show.").foregroundStyle(Theme.secondary)
                    }
                    ForEach(model.activityUpdates.filter { $0.instanceID == model.health?.instanceID }) { update in
                        Button {
                            model.notificationTaskID = update.taskID
                            model.notificationApprovals = update.category == "approvals"
                            model.notificationRequest = UUID()
                            showingUpdates = false
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(update.title).font(.callout.weight(.medium))
                                Text(update.createdAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(Theme.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain)
                    }
                    ForEach(model.messages.filter { $0.taskID == nil }) { message in
                        ManagementPanel {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(message.purpose.capitalized).font(.headline)
                                MarkdownContent(text: message.body)
                                if let error = message.error { ErrorBanner(message: error) }
                            }
                        }
                    }
                }
            }
            HStack {
                Button("Earlier updates") {
                    Task {
                        do { try await model.loadHistory(older: true) }
                        catch { chat.error = error.presentableMessage ?? chat.error }
                    }
                }.disabled(model.historyCursor == nil)
                Spacer()
                Button("Done") { showingUpdates = false }
            }
        }
        .padding(24).frame(width: 700, height: 600)
        .onAppear { model.markUpdatesSeen() }
        .onChange(of: model.activityUpdates.count) { model.markUpdatesSeen() }
        .task(id: model.offeredIDs) {
            let ids = Set(model.messages.filter { $0.taskID == nil }.map(\.id))
            await model.acknowledgeRendered(ids: model.offeredIDs.filter(ids.contains))
        }
    }

    /// The composer needs no task IDs or workstream controls, and supports a keyboard send action.
    private var composer: some View {
        @Bindable var chat = self.chat
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                StableProgress(active: chat.selected?.active == true && !chat.sending)
                Text(chat.selected?.active == true ? String(localized: "Working…") :
                        chat.selected?.channel != "client" && chat.selected != nil ?
                        String(localized: "Reply destination: this Assistant client") : "")
                    .font(.caption).foregroundStyle(Theme.secondary)
            }.frame(height: 20)
            TextEditor(text: $chat.draft).font(.body).scrollContentBackground(.hidden)
                .frame(minHeight: 65, maxHeight: 140)
                .accessibilityLabel("Message Assistant")
            HStack {
                if chat.selectedThread == nil {
                    Toggle("Deep research", isOn: $chat.research).toggleStyle(.checkbox)
                } else {
                    Text("Reply to this conversation").font(.caption).foregroundStyle(Theme.secondary)
                }
                Spacer()
                Button {
                    if let selected = chat.selected, selected.channel != "client" { confirmingRoute = true }
                    else { Task { await chat.send(model) } }
                } label: {
                    if chat.sending { Text("Sending…") }
                    else { Label("Send", systemImage: "arrow.up") }
                }
                .buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.return, modifiers: .command)
                .disabled(chat.sending || chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                          model.clientID == nil || chat.selected?.deleted == true)
            }
        }
        .padding(16).background(Theme.panel)
        .disabled(chat.sending || chat.selected?.deleted == true)
    }

    /// Blockers and preservation promises come from the server, not a local optimistic delete.
    private var deletionReview: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Delete task data?").font(.title2.weight(.semibold))
            Text("The conversation, attachments, and workstream are kept. Execution details are removed and replaced with a read-only deletion marker.")
            if let deletionPreview {
                if deletionPreview["deletable"] != .bool(true) {
                    ErrorBanner(message: String(localized: "Deletion is blocked while related work is active."))
                    PreviewText(value: deletionPreview["blockers"] ?? .array([]))
                }
                HStack {
                    Spacer()
                    Button("Cancel") { self.deletionPreview = nil }
                    Button("Delete task data", role: .destructive) {
                        guard let task = deletionPreview["task_id"],
                              let digest = deletionPreview["preview_digest"] else { return }
                        self.deletionPreview = nil
                        Task {
                            chat.sending = true
                            defer { chat.sending = false }
                            do {
                                _ = try await model.perform(.object([
                                    "operation": .string("task.delete"), "task_id": task,
                                    "preview_digest": digest, "confirmed": .bool(true)
                                ]))
                                try await chat.loadConversations(model)
                                try await chat.refresh(model)
                            } catch { chat.error = error.presentableMessage ?? chat.error }
                        }
                    }.disabled(deletionPreview["deletable"] != .bool(true))
                }
            }
        }.padding(24).frame(width: 560)
    }
}

/// Shows scheduled reminders, including those that haven't run yet.
private struct ReminderScheduleView: View {
    let model: ClientModel
    @Environment(\.dismiss) private var dismiss
    @State private var reminders: [Reminder] = []
    @State private var page = 0
    @State private var total = 0
    @State private var loading = false
    @State private var error: String?

    private struct Reminder: Decodable, Identifiable {
        let id: Int
        let title: String
        let runAt: String
        let status: String
        let metadata: JSONValue?

        var channel: String? { metadata?["delivery"]?["primary"]?["channel"]?.string }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeading(title: "Reminder schedule", subtitle: "See when Assistant is due to run your reminders.")
            if let error { ErrorBanner(message: error) }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if reminders.isEmpty && !loading && error == nil {
                        Text("No reminders yet. Ask Assistant in chat to schedule one.")
                            .foregroundStyle(Theme.secondary)
                    }
                    ForEach(reminders) { reminder in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(reminder.title).font(.headline)
                            if reminder.status == "scheduled", let date = ServerDate.parse(reminder.runAt) {
                                Text("Next run: \(date.formatted(date: .abbreviated, time: .shortened))")
                            } else {
                                Text(reminder.status.replacingOccurrences(of: "_", with: " ").capitalized)
                            }
                            if let channel = reminder.channel {
                                Text("Delivery: \(Conversation.channelTitle(channel))").foregroundStyle(Theme.secondary)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Divider()
                    }
                }
            }
            HStack {
                StableProgress(active: loading)
                if reminders.count < total || error != nil {
                    Button(error == nil ? "Load more" : "Retry") {
                        Task { await load(page: reminders.isEmpty ? 0 : page + 1) }
                    }.disabled(loading)
                }
                Spacer()
                Button("Done") { dismiss() }
            }
        }
        .padding(24).frame(width: 520, height: 460)
        .task { await load(page: 0) }
    }

    private func load(page: Int) async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let result = try await model.read("records/reminders?page=\(page)")
            let decoded = try Wire.decoder().decode(Page<Reminder>.self, from: JSONEncoder().encode(result))
            if page == 0 { reminders = decoded.rows }
            else {
                let known = Set(reminders.map(\.id))
                reminders.append(contentsOf: decoded.rows.filter { !known.contains($0.id) })
            }
            self.page = page
            total = decoded.total
            error = nil
        } catch { self.error = error.presentableMessage ?? self.error }
    }
}

/// One conversation in the sidebar: what was asked, where, when, and whether work is ongoing.
private struct ConversationRow: View {
    let conversation: Conversation
    let selected: Bool
    let unread: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(conversation.title).font(.system(.body, weight: unread ? .bold : .medium)).lineLimit(2)
                    Spacer(minLength: 0)
                    if unread {
                        Image(systemName: "circle.fill").font(.system(size: 7))
                            .foregroundStyle(Theme.accent).accessibilityLabel("Unread")
                    }
                }
                HStack(spacing: 6) {
                    Image(systemName: conversation.deleted ? "trash" : conversation.active ? "circle.dotted" : "bubble.left")
                    Text(Conversation.channelTitle(conversation.channel))
                    Text(verbatim: "·")
                    Text(Self.relative(conversation.lastActivityAt)).lineLimit(1)
                }.font(.caption).foregroundStyle(Theme.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(selected ? Theme.accent.opacity(0.13) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Server timestamps are ISO 8601; fall back to the raw date when parsing fails.
    static func relative(_ timestamp: String) -> String {
        guard let date = ServerDate.parse(timestamp) else {
            return String(timestamp.prefix(10))
        }
        return date.formatted(.relative(presentation: .named))
    }
}
