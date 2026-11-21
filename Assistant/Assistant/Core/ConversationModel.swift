import Foundation
import Observation

/// One execution in a conversation; read after sending to learn which thread the server chose.
struct ChatTask: Decodable, Identifiable, Sendable {
    let id: Int
    let threadID: String
    let taskSummary: String
    let status: String
    let updatedAt: String
    let lastError: String?
    var sourceChannel: String? = nil

    private enum CodingKeys: String, CodingKey {
        case id, taskSummary, status, updatedAt, lastError, sourceChannel
        case threadID = "threadId"
    }

    /// Deleted executions retain their transcript but cannot accept replies.
    var deleted: Bool { status == "deleted" }
    /// Terminal states do not need an activity spinner.
    var active: Bool { ["queued", "running", "waiting", "needs_review"].contains(status) }
}

/// Request and delivery IDs come from different tables, so identity includes kind and channel.
struct ChatMessage: Codable, Identifiable, Sendable, Equatable {
    let wireID: Int
    let kind: String
    let channel: String
    let body: String
    let createdAt: String
    var attachments: [ChatAttachment]? = nil
    var recipients: [String]? = nil
    var external: Bool? = nil
    var subject: String? = nil
    var id: String { "\(kind):\(channel):\(wireID)" }
    var incoming: Bool { kind == "request" }
    var scheduled: Bool { incoming && channel == "reminder" }

    private enum CodingKeys: String, CodingKey {
        case wireID = "id"
        case kind, channel, body, createdAt, attachments, recipients, external, subject
    }
}

/// A server-authorized reference to a retained attachment, not a local or remote arbitrary URL.
struct ChatAttachment: Codable, Sendable, Equatable {
    let filename: String?
    let contentType: String?
    let sizeBytes: Int64?
    let voiceNote: Bool?
    let available: Bool
    let projectID: Int?
    let fileID: Int?
    let workspacePath: String?

    private enum CodingKeys: String, CodingKey {
        case filename, contentType, sizeBytes, voiceNote, available, workspacePath
        case projectID = "projectId"
        case fileID = "fileId"
    }

    /// Voice notes and ordinary audio files share native playback controls.
    var audio: Bool { voiceNote == true || contentType?.hasPrefix("audio/") == true }
}

/// One human conversation thread, summarized by the server from its request messages.
struct Conversation: Codable, Identifiable, Sendable, Equatable {
    let threadID: String
    let channel: String
    let messageCount: Int
    let openingMessage: String
    let lastActivityAt: String
    var latestTaskID: Int
    var latestTaskStatus: String
    let latestTaskSummary: String?
    let workstreamTitle: String?
    var workstreamNameStatus: String? = nil

    var id: String { threadID }
    var scheduled: Bool { threadID.hasPrefix("reminder:") }

    private enum CodingKeys: String, CodingKey {
        case channel, messageCount, openingMessage, lastActivityAt, latestTaskStatus, latestTaskSummary
        case workstreamTitle, workstreamNameStatus
        case threadID = "threadId"
        case latestTaskID = "latestTaskId"
    }

    /// The first line of what the person asked, which reads better than a generated task summary.
    var title: String {
        if scheduled { return latestTaskSummary ?? String(localized: "Scheduled reminder") }
        let line = openingMessage.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        if !line.isEmpty { return line.count > 90 ? String(line.prefix(89)) + "…" : line }
        return latestTaskSummary ?? String(localized: "Untitled conversation")
    }

    /// Deleted executions retain their transcript but cannot accept replies.
    var deleted: Bool { latestTaskStatus == "deleted" }
    /// Work still in progress is refreshed more often than finished conversations.
    var active: Bool { ["queued", "running", "waiting", "needs_review"].contains(latestTaskStatus) }

    /// Readable channel name for list badges and filters.
    static func channelTitle(_ channel: String) -> String {
        switch channel {
        case "client": return String(localized: "Assistant client")
        case "telegram": return String(localized: "Telegram")
        case "email": return String(localized: "Email")
        default: return channel.capitalized
        }
    }

    /// Temporary Telegram names are intentional until enough context arrives; failed naming is explicit.
    var workstreamLabel: String {
        guard let workstreamTitle, !workstreamTitle.isEmpty, workstreamTitle != "New workstream" else {
            switch workstreamNameStatus {
            case "temporary": return String(localized: "Awaiting more messages to name")
            case "failed": return String(localized: "Automatic naming failed")
            case "pending", "naming": return String(localized: "Naming workstream…")
            default: return String(localized: "Organized automatically")
            }
        }
        return workstreamTitle
    }
}

/// One tool the assistant used, paired by the server with its recorded result.
struct ToolCall: Codable, Identifiable, Sendable, Equatable {
    let id: String
    let taskID: Int
    let createdAt: String
    let toolName: String
    let toolAction: String?
    let status: String
    let input: JSONValue?
    let output: JSONValue?
    let durationMS: Int?

    private enum CodingKeys: String, CodingKey {
        case id, status, input, output
        case taskID = "task_id"
        case createdAt = "created_at"
        case toolName = "tool_name"
        case toolAction = "tool_action"
        case durationMS = "duration_ms"
    }

    /// Calls without a recorded result are still running or were interrupted.
    var failed: Bool { status == "failed" }
    var running: Bool { status == "running" }

    /// One JSON document avoids stacked section headings and repeated error labels.
    var details: JSONValue? {
        if let input = distinctInput, let output {
            return .object(["input": input, "result": output])
        }
        return output ?? input
    }

    /// Results often echo terminal-tool arguments. Show only input fields not already in the result.
    var distinctInput: JSONValue? {
        guard let input else { return nil }
        if input == output { return nil }
        if case .object(let values) = input, case .object(let result) = output {
            let distinct = values.filter { result[$0.key] != $0.value }
            return distinct.isEmpty ? nil : .object(distinct)
        }
        return input
    }
}

/// The server's tool-activity envelope; `truncated` means older calls exist beyond the returned window.
/// Decoded without key conversion so tool input and output keep their original keys.
struct ToolActivity: Decodable, Sendable {
    let rows: [ToolCall]
    let truncated: Bool
}

/// A transcript position: a message, or the tool calls made between two messages.
enum TranscriptItem: Identifiable, Equatable {
    case message(ChatMessage)
    case tools([ToolCall])

    var id: String {
        switch self {
        case .message(let message): return message.id
        case .tools(let calls): return "tools:\(calls.first?.id ?? "")"
        }
    }

    /// Places each run of tool calls before the first message that was created after it.
    static func timeline(messages: [ChatMessage], calls: [ToolCall]) -> [TranscriptItem] {
        var items: [TranscriptItem] = []
        var remaining = calls[...]
        for message in messages {
            let messageDate = ServerDate.parse(message.createdAt)
            var run: [ToolCall] = []
            while let call = remaining.first, let messageDate, let callDate = ServerDate.parse(call.createdAt),
                  callDate < messageDate {
                run.append(call)
                remaining = remaining.dropFirst()
            }
            if !run.isEmpty { items.append(.tools(run)) }
            items.append(.message(message))
        }
        if !remaining.isEmpty { items.append(.tools(Array(remaining))) }
        return items
    }
}

/// Server timestamps arrive in several ISO 8601 shapes, including microsecond fractions.
enum ServerDate {
    /// Parses ISO 8601 with or without fractional seconds; fractions beyond milliseconds are dropped.
    static func parse(_ text: String) -> Date? {
        var value = text.replacingOccurrences(of: " ", with: "T")
        if let dot = value.firstIndex(of: ".") {
            let digits = value[value.index(after: dot)...].prefix(while: \.isNumber)
            if digits.count > 3 {
                let start = value.index(dot, offsetBy: 4)
                value.removeSubrange(start..<value.index(start, offsetBy: digits.count - 3))
            }
        }
        let precise = ISO8601DateFormatter()
        precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return precise.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

/// A conversation's last loaded transcript, shown immediately when the conversation is reopened.
private struct CachedTranscript: Codable, Sendable {
    var messages: [ChatMessage]
    var totalMessages: Int
    var messagePages: Int
    var toolCalls: [ToolCall]
    var activityTruncated: Bool
    var fetchedAt: Date
    var conversationVersion: String? = nil
}

/// Disk snapshots are partitioned by verified installation identity and contain no transport credentials.
private struct ConversationCache: Codable, Sendable {
    var conversations: [Conversation]
    var transcripts: [String: CachedTranscript]
    var readVersions: [String: String]? = nil
    var scope: String? = nil
}

/// Serializes and decodes conversation payloads away from the UI actor.
private actor ConversationCodec {
    func decode<T: Decodable & Sendable>(_ value: JSONValue, as type: T.Type, wire: Bool = true) throws -> T {
        let data = try JSONEncoder().encode(value)
        return try (wire ? Wire.decoder() : JSONDecoder()).decode(type, from: data)
    }

    func encode(_ cache: ConversationCache) throws -> Data {
        try JSONEncoder().encode(cache)
    }
}

/// Server-backed conversations retain unsent text only in this connection's memory.
@MainActor @Observable
final class ConversationModel {
    static let messagePageSize = 50
    /// Refresh cadence for the selected conversation while the assistant is working, and once it is idle.
    static let activeRefresh: Duration = .seconds(5)
    static let idleRefresh: Duration = .seconds(30)
    static let listRefresh: Duration = .seconds(30)
    var conversations: [Conversation] = []
    var selectedThread: String?
    var draft = ""
    var research = false
    var search = ""
    var channel = "" {
        didSet {
            if let cacheKey { defaults.set(channel, forKey: "\(cacheKey).scope") }
        }
    }
    var messages: [ChatMessage] = []
    var toolCalls: [ToolCall] = []
    var activityTruncated = false
    var error: String?
    var sending = false
    var pendingMessage: ChatMessage?
    var pendingUnconfirmed = false
    var unconfirmedSend: Bool { pendingUnconfirmed && pendingThread == selectedThread }
    private var pendingThread: String?
    private var pendingRequestID: Int?
    var loadingList = false
    var loadingTranscript = false
    var totalConversations = 0
    var totalMessages = 0
    private var listPage = 0
    private var listFetchedAt: ContinuousClock.Instant?
    private var messagePages = 1
    private var drafts: [String: String] = [:]
    private var cache: [String: CachedTranscript] = [:]
    private var savedConversations: [String: Conversation] = [:]
    private var readVersions: [String: String] = [:]
    private var manuallyUnreadSelection: String?
    private let defaults: UserDefaults
    private var cacheKey: String?
    private let codec = ConversationCodec()
    private var cacheWriteVersion = 0
    private var generation = UUID()
    private var refreshVersion = 0
    private var liveRefreshTask: Task<Void, Never>?
    private var liveRefreshPending = false
    private var transcriptLoaded = false
    private(set) var renderedVersion: String?
    private var deliveries: [String: [Int]] = [:]
    /// Older servers have no activity endpoint; stop asking once that is known.
    private var activityUnsupported = false

    /// Injectable preferences keep tests and UI fixtures separate from the user's cached conversations.
    private let reminderHistory: Bool

    init(defaults: UserDefaults = .standard, reminderHistory: Bool = false) {
        self.defaults = defaults
        self.reminderHistory = reminderHistory
        channel = reminderHistory ? "" : "client"
    }

    /// Reconnect and relaunch restore transcripts only after the server identity has been verified.
    func restoreCache(instance: String) throws {
        let key = "assistant.chatCache.\(instance)" + (reminderHistory ? ".reminders" : "")
        guard cacheKey != key else { return }
        clear()
        cacheKey = key
        let defaultScope = reminderHistory ? "" : "client"
        let savedScope = defaults.string(forKey: "\(key).scope") ?? defaultScope
        channel = ["", "client", "telegram", "email"].contains(savedScope) ? savedScope : defaultScope
        let savedReads = defaults.data(forKey: "\(key).readVersions")
        if let savedReads {
            readVersions = try JSONDecoder().decode([String: String].self, from: savedReads)
        }
        guard let data = defaults.data(forKey: key) else { return }
        let saved = try JSONDecoder().decode(ConversationCache.self, from: data)
        cache = saved.transcripts
        if savedReads == nil {
            readVersions = saved.readVersions ?? [:]
            try persistReadVersions()
        }
        conversations = (saved.scope ?? "") == channel ? saved.conversations.filter { $0.scheduled == reminderHistory } : []
        savedConversations = Dictionary(uniqueKeysWithValues: conversations.map { ($0.threadID, $0) })
        totalConversations = conversations.count
    }

    /// Clearing local history never deletes server messages; the next read fetches them again.
    func clearSavedCache() {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("assistant.chatCache.") {
            defaults.removeObject(forKey: key)
        }
        generation = UUID()
        refreshVersion += 1
        cache = [:]
        savedConversations = [:]
        readVersions = [:]
    }

    private func persistCache() async throws {
        guard let cacheKey else { return }
        cacheWriteVersion += 1
        let version = cacheWriteVersion
        let current = generation
        let snapshot = ConversationCache(conversations: conversations, transcripts: cache, scope: channel)
        let data = try await codec.encode(snapshot)
        guard current == generation, version == cacheWriteVersion else { return }
        defaults.set(data, forKey: cacheKey)
    }

    /// Read controls write only their small metadata map, not every retained transcript.
    private func persistReadVersions() throws {
        guard let cacheKey else { return }
        defaults.set(try JSONEncoder().encode(readVersions), forKey: "\(cacheKey).readVersions")
    }

    var selected: Conversation? { conversations.first { $0.threadID == selectedThread } }

    /// Local read state is separate from the server's delivery acknowledgments.
    func isUnread(_ conversation: Conversation) -> Bool {
        guard let read = readVersions[conversation.threadID] else { return true }
        return !Self.covers(read, version: Self.readVersion(conversation))
    }

    /// Called only once the selected transcript is rendered, never when a list row is clicked.
    func markRendered() {
        guard transcriptLoaded, let selected, let version = renderedVersion else { return }
        guard manuallyUnreadSelection != selected.threadID else { return }
        if let read = readVersions[selected.threadID], Self.covers(read, version: version) { return }
        readVersions[selected.threadID] = version
        do { try persistReadVersions() }
        catch { self.error = error.presentableMessage }
    }

    /// Explicit local read controls never acknowledge a delivery or change server conversation data.
    func setRead(_ read: Bool, conversation: Conversation) {
        if read {
            let version = Self.readVersion(conversation)
            if !(readVersions[conversation.threadID].map({ Self.covers($0, version: version) }) ?? false) {
                readVersions[conversation.threadID] = version
            }
            if manuallyUnreadSelection == conversation.threadID { manuallyUnreadSelection = nil }
        } else {
            readVersions.removeValue(forKey: conversation.threadID)
            if selectedThread == conversation.threadID { manuallyUnreadSelection = conversation.threadID }
        }
        do { try persistReadVersions() }
        catch { self.error = error.presentableMessage }
    }

    private static func readVersion(_ conversation: Conversation) -> String {
        "\(conversation.lastActivityAt)|\(conversation.messageCount)|\(conversation.latestTaskID)"
    }

    /// Equivalent timestamp formats and older snapshots cannot move a read watermark backwards.
    private static func covers(_ read: String, version: String) -> Bool {
        if read == version { return true }
        let lhs = read.split(separator: "|")
        let rhs = version.split(separator: "|")
        guard lhs.count == 3, rhs.count == 3,
              let readDate = ServerDate.parse(String(lhs[0])), let date = ServerDate.parse(String(rhs[0])),
              let readCount = Int(lhs[1]), let count = Int(rhs[1]),
              let readTask = Int(lhs[2]), let task = Int(rhs[2]) else { return false }
        return readDate >= date && readCount >= count && readTask >= task
    }

    private static func newestFirst(_ lhs: Conversation, _ rhs: Conversation) -> Bool {
        let left = ServerDate.parse(lhs.lastActivityAt) ?? .distantPast
        let right = ServerDate.parse(rhs.lastActivityAt) ?? .distantPast
        return left == right ? lhs.latestTaskID > rhs.latestTaskID : left > right
    }

    /// Messages and tool calls in the order they happened.
    var timeline: [TranscriptItem] {
        let confirmed = pendingRequestID.map { request in
            messages.contains { $0.incoming && $0.channel == "client" && $0.wireID == request }
        } ?? false
        return TranscriptItem.timeline(messages: messages, calls: toolCalls) +
            (pendingThread == selectedThread && !confirmed && !pendingUnconfirmed ?
             pendingMessage.map { [.message($0)] } ?? [] : [])
    }

    /// Resets all remote content when connection identity changes.
    func clear() {
        liveRefreshTask?.cancel()
        liveRefreshPending = false
        generation = UUID()
        refreshVersion += 1
        conversations = []; selectedThread = nil; draft = ""
        cacheKey = nil
        search = ""; channel = reminderHistory ? "" : "client"; research = false
        totalConversations = 0; listPage = 0; listFetchedAt = nil; error = nil
        drafts = [:]; cache = [:]; savedConversations = [:]; readVersions = [:]; cacheKey = nil
        deliveries = [:]; activityUnsupported = false
        pendingMessage = nil; pendingThread = nil; pendingRequestID = nil
        pendingUnconfirmed = false; sending = false
        manuallyUnreadSelection = nil
        resetTranscript()
    }

    /// New chats deliberately omit a workstream identifier.
    func newChat(about reminder: Conversation? = nil) {
        manuallyUnreadSelection = nil
        refreshVersion += 1
        drafts[selectedThread ?? "new"] = draft
        selectedThread = nil
        draft = drafts["new"] ?? ""
        if let reminder {
            let reference = String(localized: "About scheduled run #\(reminder.latestTaskID) (\(reminder.title)): ")
            draft = draft.isEmpty ? reference : draft + "\n\n" + reference
        }
        resetTranscript()
    }

    /// Selection shows the cached transcript at once, or clears stale content before the first read.
    func select(_ conversation: Conversation) {
        guard conversation.threadID != selectedThread else { return }
        manuallyUnreadSelection = nil
        refreshVersion += 1
        drafts[selectedThread ?? "new"] = draft
        selectedThread = conversation.threadID
        draft = drafts[conversation.threadID] ?? ""
        if let cached = cache[conversation.threadID] {
            messages = cached.messages; totalMessages = cached.totalMessages; messagePages = cached.messagePages
            toolCalls = cached.toolCalls; activityTruncated = cached.activityTruncated
            transcriptLoaded = true
            renderedVersion = cached.conversationVersion
            loadingTranscript = false
        } else {
            resetTranscript()
            loadingTranscript = true
        }
    }

    private func resetTranscript() {
        messages = []; toolCalls = []; totalMessages = 0; messagePages = 1; activityTruncated = false
        transcriptLoaded = false
        renderedVersion = nil
        loadingTranscript = false
    }

    /// Records the deliveries seen for the selected conversation; true when new ones arrived since last time.
    func noteDeliveries(_ ids: [Int]) -> Bool {
        guard let thread = selectedThread else { return false }
        let previous = deliveries.updateValue(ids, forKey: thread)
        return previous != nil && previous != ids
    }

    /// Whether the conversation list was read recently enough to skip an immediate reload.
    var listIsFresh: Bool {
        guard let listFetchedAt else { return false }
        return ContinuousClock.now - listFetchedAt < Self.listRefresh
    }

    /// Reads one page of conversations; refreshing keeps already loaded older pages in place.
    func loadConversations(_ model: ClientModel, older: Bool = false) async throws {
        let current = generation
        let filter = (search, channel)
        let page = older ? listPage + 1 : 0
        var components = URLComponents()
        components.queryItems = [URLQueryItem(name: "page", value: String(page)),
                                 URLQueryItem(name: "query", value: search),
                                 URLQueryItem(name: "channel", value: reminderHistory ? "reminder" : channel.isEmpty ? "chat" : channel)]
        loadingList = true
        defer { loadingList = false }
        let result: JSONValue
        do {
            result = try await model.read("conversations?\(components.percentEncodedQuery ?? "")")
        } catch let error as ClientError where error.httpStatus == 404 || error.httpStatus == 422 {
            throw ClientError.serverOutdated(String(localized: "separate chats and reminder history"))
        }
        let decoded = try await codec.decode(result, as: Page<Conversation>.self)
        guard current == generation, filter == (search, channel) else { return }
        for conversation in decoded.rows { savedConversations[conversation.threadID] = conversation }
        let incoming = Set(decoded.rows.map(\.threadID))
        var updated: [Conversation]
        if older {
            updated = conversations.filter { !incoming.contains($0.threadID) } + decoded.rows
            listPage = page
        } else if listPage > 0 {
            updated = decoded.rows + conversations.filter { !incoming.contains($0.threadID) }
        } else {
            updated = decoded.rows
        }
        updated.sort(by: Self.newestFirst)
        totalConversations = decoded.total
        listFetchedAt = .now
        if conversations != updated {
            conversations = updated
            try await persistCache()
        }
    }

    /// Search and channel changes start a fresh page set instead of filtering a partial local list.
    func searchConversations(_ model: ClientModel) async throws {
        listPage = 0
        conversations = []
        try await loadConversations(model)
    }

    /// Bursts enqueue one follow-up refresh instead of repeatedly cancelling a slow in-flight read.
    func refreshAfterEvent(_ model: ClientModel) {
        liveRefreshPending = true
        guard liveRefreshTask == nil else { return }
        let current = generation
        liveRefreshTask = Task { [weak self] in
            guard let self else { return }
            defer { liveRefreshTask = nil }
            do {
                try await Task.sleep(for: .milliseconds(150))
                repeat {
                    liveRefreshPending = false
                    try await loadConversations(model)
                    guard generation == current, !Task.isCancelled else { return }
                    try await refresh(model)
                } while liveRefreshPending && generation == current && !Task.isCancelled
            } catch {
                if generation == current { self.error = error.presentableMessage ?? self.error }
            }
        }
    }

    /// Loads the newest transcript pages and tool calls for the selected conversation.
    /// - Parameter maxAge: when set, a cached transcript younger than this is shown without reading.
    func refresh(_ model: ClientModel, moreMessages: Bool = false, maxAge: Duration? = nil) async throws {
        // Until the receipt supplies a request ID, a refresh cannot reconcile the optimistic row safely.
        guard pendingMessage == nil || !sending || pendingRequestID != nil else { return }
        guard let selected else { return }
        let thread = selected.threadID
        if let maxAge, !moreMessages, let cached = cache[thread],
           cached.conversationVersion == Self.readVersion(selected),
           Duration.seconds(Date().timeIntervalSince(cached.fetchedAt)) < maxAge {
            return
        }
        refreshVersion += 1
        let version = refreshVersion
        let task = selected.latestTaskID
        if moreMessages { messagePages += 1 }
        loadingTranscript = !transcriptLoaded && messages.isEmpty && pendingMessage == nil
        defer {
            if selectedThread == thread, version == refreshVersion { loadingTranscript = false }
        }
        if !moreMessages, messagePages == 1, model.health?.capabilities.contains("tasks.snapshot") == true {
            let snapshot = try await model.read("tasks/\(task)/snapshot")
            guard selectedThread == thread, version == refreshVersion else { return }
            guard let messageData = snapshot["messages"], let activityData = snapshot["activity"],
                  let taskData = snapshot["task"] else { throw ClientError.malformedResponse }
            let page = try await codec.decode(messageData, as: Page<ChatMessage>.self)
            let activity = try await codec.decode(activityData, as: ToolActivity.self, wire: false)
            let status = try await codec.decode(taskData, as: ChatTask.self)
            guard selectedThread == thread, version == refreshVersion else { return }
            if messages != page.rows { messages = page.rows }
            totalMessages = page.total
            if toolCalls != activity.rows { toolCalls = activity.rows }
            activityTruncated = activity.truncated
            transcriptLoaded = true; loadingTranscript = false
            renderedVersion = Self.readVersion(selected)
            if let index = conversations.firstIndex(where: { $0.threadID == thread && $0.latestTaskID == status.id }) {
                conversations[index].latestTaskStatus = status.status
            }
            if selected.active && !status.active {
                await model.addUpdate(id: "task:\(status.id):\(status.status)",
                                      title: status.status == "completed" ? String(localized: "Task completed") :
                                        String(localized: "Task needs attention"),
                                      taskID: status.id, category: status.status == "completed" ? "replies" : "errors")
            }
            if let pendingRequestID, pendingThread == thread,
               messages.contains(where: { $0.incoming && $0.channel == "client" && $0.wireID == pendingRequestID }) {
                pendingMessage = nil
            }
            guard selectedThread == thread, version == refreshVersion else { return }
            try await remember(thread)
            guard selectedThread == thread, version == refreshVersion else { return }
            error = nil
            return
        }
        // Start from the last known page so a quiet conversation costs one read per refresh.
        var lastPage = max(0, (totalMessages - 1) / Self.messagePageSize)
        var latest = try await messagePage(model, task: task, page: lastPage)
        let actualLast = max(0, (latest.total - 1) / Self.messagePageSize)
        if actualLast != lastPage {
            lastPage = actualLast
            latest = try await messagePage(model, task: task, page: lastPage)
        }
        var transcript = latest.rows
        for page in stride(from: lastPage - 1, through: max(0, lastPage - messagePages + 1), by: -1) {
            transcript = try await messagePage(model, task: task, page: page).rows + transcript
        }
        guard selectedThread == thread, version == refreshVersion else { return }
        if messages != transcript { messages = transcript }
        totalMessages = latest.total
        transcriptLoaded = true
        renderedVersion = Self.readVersion(selected)
        loadingTranscript = false
        if let pendingRequestID, pendingThread == thread,
           transcript.contains(where: { $0.incoming && $0.channel == "client" && $0.wireID == pendingRequestID }) {
            self.pendingMessage = nil
        }
        if cache[thread]?.messages != messages || cache[thread]?.totalMessages != totalMessages {
            try await remember(thread)
        }
        // Message rendering must not wait for the slower activity or task-status endpoints.
        let since = transcript.count < latest.total ? transcript.first?.createdAt : nil
        let activity = try await self.activity(model, task: task, since: since)
        guard selectedThread == thread, version == refreshVersion else { return }
        if toolCalls != activity.rows { toolCalls = activity.rows }
        activityTruncated = activity.truncated
        if selected.active { try await refreshStatus(model) }
        guard selectedThread == thread, version == refreshVersion else { return }
        try await remember(thread)
        guard selectedThread == thread, version == refreshVersion else { return }
        error = nil
    }

    private func remember(_ thread: String) async throws {
        let previous = cache[thread]
        cache[thread] = CachedTranscript(messages: messages, totalMessages: totalMessages, messagePages: messagePages,
                                         toolCalls: toolCalls, activityTruncated: activityTruncated,
                                         fetchedAt: Date(), conversationVersion: renderedVersion)
        if let selected { savedConversations[thread] = selected }
        if previous?.messages != messages || previous?.toolCalls != toolCalls ||
            previous?.totalMessages != totalMessages || previous?.messagePages != messagePages ||
            previous?.activityTruncated != activityTruncated || previous?.conversationVersion != renderedVersion {
            try await persistCache()
        }
    }

    /// Tool calls across the whole conversation; an older server without the endpoint shows none.
    private func activity(_ model: ClientModel, task: Int, since: String?) async throws -> ToolActivity {
        guard !activityUnsupported else { return ToolActivity(rows: [], truncated: false) }
        var components = URLComponents()
        if let since { components.queryItems = [URLQueryItem(name: "since", value: since)] }
        let query = components.percentEncodedQuery.map { "?\($0)" } ?? ""
        do {
            let result = try await model.read("tasks/\(task)/activity\(query)")
            return try await codec.decode(result, as: ToolActivity.self, wire: false)
        } catch let error as ClientError where error.httpStatus == 404 {
            activityUnsupported = true
            return ToolActivity(rows: [], truncated: false)
        }
    }

    /// Updates the selected conversation's task status without reloading the whole list.
    private func refreshStatus(_ model: ClientModel) async throws {
        guard let selected else { return }
        let task = try await chatTask(model, id: selected.latestTaskID)
        guard let index = conversations.firstIndex(where: {
            $0.threadID == selected.threadID && $0.latestTaskID == task.id
        }) else { return }
        conversations[index].latestTaskStatus = task.status
    }

    private func messagePage(_ model: ClientModel, task: Int, page: Int) async throws -> Page<ChatMessage> {
        let result = try await model.read("tasks/\(task)/messages?page=\(page)")
        return try await codec.decode(result, as: Page<ChatMessage>.self)
    }

    func chatTask(_ model: ClientModel, id: Int) async throws -> ChatTask {
        let record = try await model.read("records/tasks/\(id)")
        guard let row = record["rows"]?.array?.first else { throw ClientError.malformedResponse }
        return try await codec.decode(row, as: ChatTask.self)
    }

    /// Opens an update's task even when its conversation is outside the current list page.
    func openTask(_ task: ChatTask, model: ClientModel) async throws {
        if let existing = conversations.first(where: { $0.threadID == task.threadID }) {
            select(existing)
        } else {
            let row = Conversation(threadID: task.threadID, channel: task.sourceChannel ?? "unknown", messageCount: 0,
                                   openingMessage: "", lastActivityAt: task.updatedAt, latestTaskID: task.id,
                                   latestTaskStatus: task.status, latestTaskSummary: task.taskSummary, workstreamTitle: nil)
            conversations.insert(row, at: 0)
            select(row)
        }
        try await refresh(model)
    }

    /// Submits new requests or replies with the current client identity, never replaying an uncertain write.
    func send(_ model: ClientModel) async {
        guard !sending, !reminderHistory, selectedThread?.hasPrefix("reminder:") != true,
              let clientID = model.clientID else { return }
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, selected?.deleted != true else { return }
        let submittedDraft = draft
        let draftKey = selectedThread ?? "new"
        sending = true
        draft = ""
        refreshVersion += 1
        let current = generation
        pendingUnconfirmed = false
        pendingThread = selectedThread
        pendingRequestID = nil
        pendingMessage = ChatMessage(wireID: -1, kind: "request", channel: "client", body: body,
                                     createdAt: ISO8601DateFormatter().string(from: Date()))
        var accepted = false
        defer { if generation == current { sending = false } }
        var payload: [String: JSONValue] = ["client_id": .string(clientID), "confirmed": .bool(true)]
        if let selected {
            payload["operation"] = .string("task.reply")
            payload["task_id"] = .integer(Int64(selected.latestTaskID))
            payload["body"] = .string(body)
        } else {
            payload["operation"] = .string(research ? "research.start" : "task.start")
            payload[research ? "question" : "body"] = .string(body)
        }
        do {
            let result = try await model.perform(.object(payload))
            guard generation == current else { return }
            accepted = true
            pendingRequestID = result["request_id"]?.integer.map(Int.init)
            drafts[draftKey] = nil
            guard let id = result["task_id"]?.integer else { throw ClientError.malformedResponse }
            let task = try await chatTask(model, id: Int(id))
            if let index = conversations.firstIndex(where: { $0.threadID == task.threadID }) {
                conversations[index].latestTaskID = task.id
                conversations[index].latestTaskStatus = task.status
            } else {
                // A brand-new request can reach its task before the list query sees it.
                conversations.insert(Conversation(
                    threadID: task.threadID, channel: "client", messageCount: 1, openingMessage: body,
                    lastActivityAt: task.updatedAt, latestTaskID: task.id, latestTaskStatus: task.status,
                    latestTaskSummary: task.taskSummary, workstreamTitle: nil
                ), at: 0)
            }
            selectedThread = task.threadID
            pendingThread = task.threadID
            try await refresh(model)
            try await loadConversations(model)
            error = nil
        } catch {
            guard generation == current else { return }
            pendingUnconfirmed = !accepted || pendingRequestID == nil
            if !accepted {
                draft = submittedDraft
                drafts[draftKey] = submittedDraft
            }
            self.error = error.presentableMessage ?? self.error
        }
    }
}

/// The server's standard paged-rows envelope.
struct Page<Row: Decodable & Sendable>: Decodable, Sendable {
    let rows: [Row]
    let total: Int
}
