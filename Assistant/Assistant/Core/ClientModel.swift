import Foundation
import Observation
import AppKit
import UserNotifications

/// Non-secret service snapshots are scoped to a verified installation.
private struct ServiceSnapshot: Codable {
    let services: [JSONValue]
    let updatedAt: Date
}

/// Shared native state; views never retain tokens or construct SSH commands.
@MainActor @Observable
final class ClientModel {
    /// Local feedback retains activation state, not server configuration values.
    enum ActivationState: String {
        case active, pending, unknown
    }
    var activationState = ActivationState.active
    var profiles: [ConnectionProfile] = []
    var profile = ConnectionProfile()
    var health: InstanceHealth?
    var status = String(localized: "Disconnected")
    var error: String?
    var pollingError: String?
    var messages: [ClientMessage] = []
    var offeredIDs: [Int] = []
    var historyCursor: Int?
    var clientID: String?
    var lastPoll: Date?
    var operations: [ManagementOperation] = []
    var references: [OperationReference] = []
    var busy = false
    var configurationDirty = false
    var chats: ConversationModel
    let reminderRuns: ConversationModel
    var newChatRequest = UUID()
    var configurationApplying = false
    var liveRevision = 0
    var liveUpdates = false
    var liveUpdateError: String?
    var notificationTaskID: Int?
    var notificationApprovals = false
    var pendingApprovals = 0
    var notificationRequest = UUID()
    var activityUpdates: [ActivityUpdate] = []
    var updatesSeenAt = Date.distantPast
    var setupRequired = false
    private(set) var services: [JSONValue] = []
    private(set) var servicesUpdatedAt: Date?
    private(set) var servicesLoading = false
    private(set) var servicesError: String?
    private(set) var api: (any ManagementAPI)?
    private let connection = SSHConnection()
    private let defaults: UserDefaults
    private var pollTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var approvalTask: Task<Void, Never>?
    private var approvalRefreshPending = false
    private var lastApprovalRefresh: Date?
    private var notificationIDs: Set<String> = []
    private var notificationOrder: [String] = []
    private var generation = UUID()

    /// Loads only non-secret metadata and reports malformed local state explicitly.
    init(defaults: UserDefaults = .standard, api: (any ManagementAPI)? = nil, health: InstanceHealth? = nil) {
        self.defaults = defaults
        self.chats = ConversationModel(defaults: defaults)
        self.reminderRuns = ConversationModel(defaults: defaults, reminderHistory: true)
        self.api = api
        self.health = health
        do {
            if let data = defaults.data(forKey: "assistant.profiles") {
                profiles = try JSONDecoder().decode([ConnectionProfile].self, from: data)
            }
            if let data = defaults.data(forKey: "assistant.operations") {
                references = try JSONDecoder().decode([OperationReference].self, from: data)
            }
            if let first = profiles.first { profile = first }
            if let health { try chats.restoreCache(instance: health.instanceID) }
            if let health { try restoreServices(instance: health.instanceID) }
            if let health {
                activationState = ActivationState(rawValue: defaults.string(forKey: "assistant.activation.\(health.instanceID)") ?? "") ?? .active
                updatesSeenAt = Date(timeIntervalSince1970: defaults.double(forKey: "assistant.updatesSeen.\(health.instanceID)"))
            }
            if let data = defaults.data(forKey: "assistant.activity") {
                activityUpdates = try JSONDecoder().decode([ActivityUpdate].self, from: data)
            }
            notificationOrder = defaults.stringArray(forKey: "assistant.notified") ?? []
            notificationIDs = Set(notificationOrder)
        } catch {
            self.error = String(localized: "Saved connection metadata could not be read: \(error.localizedDescription)")
        }
    }

    /// Saves an editable profile without API tokens, private keys, or conversation content.
    func saveProfile() throws {
        try profile.validate()
        var updated = profiles.filter { $0.id != profile.id }
        updated.append(profile)
        defaults.set(try JSONEncoder().encode(updated), forKey: "assistant.profiles")
        profiles = updated
    }

    /// Starts a cancellable connection and independent native polling scheduler.
    func connect() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        await disconnect()
        let current = generation
        status = String(localized: "Connecting")
        error = nil
        do {
            let (api, health) = try await connection.connect(profile)
            guard current == generation else { return }
            self.api = api
            self.health = health
            activationState = ActivationState(rawValue: defaults.string(forKey: "assistant.activation.\(health.instanceID)") ?? "") ?? .active
            updatesSeenAt = Date(timeIntervalSince1970: defaults.double(forKey: "assistant.updatesSeen.\(health.instanceID)"))
            profile.instanceID = health.instanceID
            try saveProfile()
            do { try chats.restoreCache(instance: health.instanceID) }
            catch { chats.error = String(localized: "Saved conversations could not be read: \(error.localizedDescription)") }
            do { try restoreServices(instance: health.instanceID) }
            catch { servicesError = String(localized: "Saved service statuses could not be read: \(error.localizedDescription)") }
            status = String(localized: "Connected")
            if health.capabilities.contains("configuration.structured") {
                do {
                    let catalog = try await api.read("configuration/catalog", as: JSONValue.self)
                    guard generation == current else { return }
                    guard case .bool(let complete)? = catalog["setup_complete"] else { throw ClientError.malformedResponse }
                    setupRequired = !complete
                } catch {
                    if generation == current { self.error = error.presentableMessage }
                }
            }
            let instance = health.instanceID
            pollTask = Task { [weak self] in
                await self?.runPolling(instance: instance, generation: current)
            }
            startEvents(generation: current)
        } catch {
            if current == generation {
                self.error = error.presentableMessage
                status = String(localized: "Connection failed")
                self.api = nil
                health = nil
                await connection.disconnect()
            }
        }
    }

    /// Cancels outstanding session work and closes only the client-owned tunnel.
    func disconnect() async {
        guard !configurationDirty else {
            error = String(localized: "Save or discard the configuration draft before disconnecting.")
            return
        }
        generation = UUID()
        pollTask?.cancel()
        pollTask = nil
        eventTask?.cancel(); eventTask = nil
        approvalTask?.cancel(); approvalTask = nil
        approvalRefreshPending = false; lastApprovalRefresh = nil; pendingApprovals = 0
        eventCursor = nil
        liveUpdates = false; liveUpdateError = nil
        api = nil
        health = nil
        clientID = nil
        messages = []
        chats.clear()
        reminderRuns.clear()
        offeredIDs = []
        historyCursor = nil
        pollingError = nil
        operations = []
        lastPoll = nil
        services = []; servicesUpdatedAt = nil; servicesError = nil; servicesLoading = false
        activationState = .active
        setupRequired = false
        status = String(localized: "Disconnected")
        await connection.disconnect()
    }

    /// Called synchronously when macOS terminates the application.
    func terminate() {
        pollTask?.cancel()
        eventTask?.cancel()
        approvalTask?.cancel()
        connection.terminate()
    }

    /// Exposes typed JSON reads without exposing transport credentials to views.
    func read(_ resource: String) async throws -> JSONValue {
        guard let api else { throw ClientError.unavailable }
        let current = generation
        let result = try await api.read(resource, as: JSONValue.self)
        guard generation == current else { throw CancellationError() }
        return result
    }

    /// Keeps the last successful inventory visible while checking current health.
    func refreshServices() async {
        guard !servicesLoading, let instance = health?.instanceID else { return }
        let current = generation
        servicesLoading = true
        defer { if current == generation { servicesLoading = false } }
        do {
            let result = try await read("services?details=true")
            guard current == generation else { return }
            guard let rows = result["services"]?.array else { throw ClientError.malformedResponse }
            let updatedAt = Date()
            let data = try JSONEncoder().encode(ServiceSnapshot(services: rows, updatedAt: updatedAt))
            defaults.set(data, forKey: "assistant.services.\(instance)")
            services = rows; servicesUpdatedAt = updatedAt; servicesError = nil
        } catch {
            if current == generation, let message = error.presentableMessage { servicesError = message }
        }
    }

    private func restoreServices(instance: String) throws {
        guard let data = defaults.data(forKey: "assistant.services.\(instance)") else { return }
        let snapshot = try JSONDecoder().decode(ServiceSnapshot.self, from: data)
        services = snapshot.services; servicesUpdatedAt = snapshot.updatedAt
    }

    /// Records explicit activation outcomes separately from whether a draft has been saved.
    func recordActivation(_ state: ActivationState) {
        guard let instance = health?.instanceID else { return }
        activationState = state
        defaults.set(state.rawValue, forKey: "assistant.activation.\(instance)")
    }

    /// Unread updates remain visible independently of the active conversation filter.
    var unreadUpdates: Int {
        activityUpdates.filter { $0.instanceID == health?.instanceID && $0.createdAt > updatesSeenAt }.count
    }

    /// Opening Updates acknowledges local presentation, not server delivery or approval decisions.
    func markUpdatesSeen() {
        guard let instance = health?.instanceID else { return }
        updatesSeenAt = Date()
        defaults.set(updatesSeenAt.timeIntervalSince1970, forKey: "assistant.updatesSeen.\(instance)")
    }

    /// Performs side-effect-free configuration previews and typed domain queries.
    func query(_ resource: String, payload: JSONValue) async throws -> JSONValue {
        guard let api, ["query", "configuration/preview"].contains(resource) else { throw ClientError.unavailable }
        let current = generation
        let data = try await api.request(resource, body: payload, key: nil)
        guard generation == current else { throw CancellationError() }
        return try Wire.decoder().decode(JSONValue.self, from: data)
    }

    /// Persists submission intent before sending; failed/unknown writes are never silently replayed.
    func perform(_ payload: JSONValue) async throws -> JSONValue {
        guard let api, let health, let action = payload["operation"]?.string else {
            throw ClientError.unavailable
        }
        let current = generation
        let reference = OperationReference(
            id: UUID(), instanceID: health.instanceID, key: UUID().uuidString,
            action: action, operationID: nil, submittedAt: Date()
        )
        references.append(reference)
        try saveReferences()
        var operation: ManagementOperation
        do {
            operation = try await api.submit(payload, key: reference.key)
        } catch let error as ClientError where [401, 409, 422].contains(error.httpStatus ?? 0) {
            references.removeAll { $0.id == reference.id }
            try saveReferences()
            throw error
        } catch {
            throw ClientError.operationFailed(String(localized:
                "Submission outcome is unresolved. Inspect server operations before resubmitting. \(error.localizedDescription)"
            ))
        }
        if let index = references.firstIndex(where: { $0.id == reference.id }) {
            references[index].operationID = operation.id
            try saveReferences()
        }
        let deadline = Date().addingTimeInterval(3600)
        while operation.pending {
            guard current == generation else { throw CancellationError() }
            updateOperation(operation)
            guard Date() < deadline else {
                throw ClientError.operationFailed(String(localized: "Operation \(operation.id) is still pending. Inspect Operations before retrying."))
            }
            try await Task.sleep(for: .seconds(1))
            operation = try await api.read("operations/\(operation.id)", as: ManagementOperation.self)
        }
        guard current == generation else { throw CancellationError() }
        updateOperation(operation)
        references.removeAll { $0.id == reference.id }
        try saveReferences()
        guard operation.state == "succeeded" else {
            throw ClientError.operationFailed(
                operation.error ?? String(localized: "Operation \(operation.id) ended as \(operation.state). Inspect current state before retrying.")
            )
        }
        if action == "service.lifecycle", payload["service"] == nil,
           ["start", "apply"].contains(payload["action"]?.string ?? "") {
            recordActivation(.active)
        }
        guard let result = operation.result else { return .null }
        return result
    }

    /// Reloads retained server statuses; unresolved submissions stay visible separately.
    func refreshOperations() async throws {
        guard let api else { throw ClientError.unavailable }
        let current = generation
        let statuses = try await api.read("operations", as: [ManagementOperation].self)
        guard current == generation else { throw CancellationError() }
        operations = statuses
        references.removeAll { reference in
            reference.instanceID == health?.instanceID &&
                statuses.contains { $0.id == reference.operationID && !$0.pending }
        }
        try saveReferences()
    }

    /// Loads the first or an older page without repeatedly fetching history on every heartbeat.
    func loadHistory(older: Bool = false) async throws {
        guard let api, let clientID else { throw ClientError.unavailable }
        let current = generation
        var resource = "clients/\(clientID)/history"
        if older {
            guard let historyCursor else { return }
            resource += "?before_id=\(historyCursor)"
        }
        let history = try await api.read(resource, as: ClientHistory.self)
        guard generation == current else { throw CancellationError() }
        merge(history.messages)
        historyCursor = history.nextBeforeID
    }

    /// Called by the rendered inbox; delivery acknowledgments are not human read receipts.
    func acknowledgeRendered(ids renderedIDs: [Int]? = nil) async {
        guard let api, let clientID, !offeredIDs.isEmpty else { return }
        let current = generation
        let ids = offeredIDs.filter { renderedIDs?.contains($0) ?? true }
        guard !ids.isEmpty else { return }
        do {
            let data = try await api.request(
                "clients/\(clientID)/acknowledgments",
                body: .object(["message_ids": .array(ids.map { .integer(Int64($0)) })]), key: nil
            )
            let acknowledgment = try Wire.decoder().decode(ClientAcknowledgment.self, from: data)
            guard generation == current else { return }
            offeredIDs.removeAll { acknowledgment.acknowledged.contains($0) }
            guard ids.allSatisfy(acknowledgment.acknowledged.contains) else { throw ClientError.unacknowledged }
        } catch {
            if generation == current, let message = error.presentableMessage { pollingError = message }
        }
    }

    /// Polls at the server cadence; recoverable connection failures rediscover the same installation.
    private func runPolling(instance: String, generation current: UUID) async {
        var failures = 0
        while !Task.isCancelled && generation == current {
            do {
                guard let api else { throw ClientError.unavailable }
                if clientID == nil {
                    let stored = defaults.string(forKey: "assistant.client.\(instance)")
                    let identifier = stored ?? UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
                    defaults.set(identifier, forKey: "assistant.client.\(instance)")
                    let registration = try await perform(.object([
                        "operation": .string("client.register"), "name": .string(profile.name),
                        "client_type": .string("desktop"), "client_id": .string(identifier),
                        "confirmed": .bool(true)
                    ]))
                    guard registration["client"]?["id"]?.string == identifier else {
                        throw ClientError.malformedResponse
                    }
                    clientID = identifier
                    try await loadHistory()
                }
                guard let clientID else { throw ClientError.malformedResponse }
                let result = try await api.read("clients/\(clientID)/messages", as: ClientPoll.self)
                guard generation == current else { return }
                guard result.pollIntervalSeconds > 0, result.availabilityTimeoutSeconds > 0 else {
                    throw ClientError.malformedResponse
                }
                let known = Set(messages.map(\.id))
                for message in result.messages where !known.contains(message.id) {
                    await addUpdate(id: "delivery:\(message.id)", title: String(localized: "Assistant has an update"),
                                    taskID: message.taskID, category: "replies")
                }
                merge(result.messages)
                offeredIDs = result.messages.map(\.id)
                lastPoll = Date()
                pollingError = nil
                status = String(localized: "Connected")
                failures = 0
                if !liveUpdates, lastApprovalRefresh.map({ Date().timeIntervalSince($0) >= 30 }) ?? true {
                    requestApprovalRefresh(generation: current)
                }
                try await Task.sleep(for: .seconds(result.pollIntervalSeconds))
            } catch {
                guard generation == current, !Task.isCancelled else { return }
                failures += 1
                let busy = (error as? ClientError)?.httpStatus == 503
                // A busy executor is expected under load; only persistent trouble is worth showing.
                if !busy || failures > 3 { pollingError = error.presentableMessage }
                let authenticationExpired = (error as? ClientError)?.httpStatus == 401
                let reconnect = ((error as? URLError).map { $0.code != .cancelled } ?? false) || authenticationExpired
                if reconnect {
                    status = String(localized: "Reconnecting")
                    do {
                        let (replacement, verified) = try await connection.connect(profile)
                        guard generation == current else { return }
                        try verified.validate(expectedInstance: instance)
                        api = replacement
                        startEvents(generation: current)
                    } catch {
                        pollingError = error.presentableMessage
                    }
                }
                let delay = min(30, pow(2, Double(min(failures, 5)))) + Double.random(in: 0...1)
                do { try await Task.sleep(for: .seconds(delay)) }
                catch { return }
            }
        }
    }

    /// A disconnected event stream leaves lease polling active and reconnects with its last cursor.
    private func startEvents(generation current: UUID) {
        eventTask?.cancel()
        guard health?.capabilities.contains("events.stream") == true else { return }
        eventTask = Task { [weak self] in
            guard let self else { return }
            var cursor = eventCursor
            var failures = 0
            while !Task.isCancelled && generation == current {
                let revisionBefore = liveRevision
                do {
                    guard let api else { return }
                    try await api.events(after: cursor) { [weak self] event in
                        await self?.receiveEvent(event, generation: current)
                    }
                } catch {
                    guard !Task.isCancelled, generation == current else { return }
                    liveUpdates = false
                    liveUpdateError = String(localized: "Live updates paused. Checking periodically.")
                    if liveRevision != revisionBefore { failures = 0 }
                    if error.presentableMessage != nil, failures == 0 {
                        await addUpdate(id: "events:\(current.uuidString)",
                                        title: String(localized: "Live updates paused. Checking periodically."),
                                        taskID: nil, category: "errors")
                    }
                    failures += 1
                }
                cursor = eventCursor
                if liveUpdates { failures = 0 }
                do { try await Task.sleep(for: .seconds(min(30, pow(2, Double(min(failures, 5)))))) }
                catch { return }
            }
        }
    }

    private var eventCursor: String?

    /// Event data is only an invalidation; ordinary reads remain authoritative.
    private func receiveEvent(_ event: ManagementEvent, generation current: UUID) {
        guard !Task.isCancelled, generation == current else { return }
        eventCursor = event.id
        liveUpdates = event.kind != "server.unavailable"
        liveUpdateError = liveUpdates ? nil : String(localized: "Server updates are temporarily unavailable.")
        if event.kind == "resync" || event.kind == "approvals.changed" {
            requestApprovalRefresh(generation: current)
        }
        if liveUpdates && event.kind != "approvals.changed" { liveRevision += 1 }
    }

    /// Approval reads can create review references, so they stay on the isolated API executor.
    private func requestApprovalRefresh(generation current: UUID) {
        guard health?.capabilities.contains("approvals.read") == true else { return }
        if approvalTask != nil { approvalRefreshPending = true; return }
        approvalTask = Task { [weak self] in
            guard let self else { return }
            defer { if generation == current { approvalTask = nil } }
            repeat {
                approvalRefreshPending = false
                do {
                    let result = try await read("approvals")
                    guard generation == current, !Task.isCancelled else { return }
                    guard let rows = result["approvals"]?.array else { throw ClientError.malformedResponse }
                    let pending = rows.filter { $0["actionable"] == .bool(true) }
                    pendingApprovals = pending.count
                    lastApprovalRefresh = Date()
                    for approval in pending {
                        guard let id = approval["approval_id"]?.string,
                              let version = approval["version"]?.string else { throw ClientError.malformedResponse }
                        await addUpdate(id: "approval:\(id):\(version)", title: String(localized: "Approval requested"),
                                        taskID: nil, category: "approvals")
                    }
                } catch {
                    if generation == current, let message = error.presentableMessage { self.error = message }
                    return
                }
            } while approvalRefreshPending && generation == current && !Task.isCancelled
        }
    }

    /// Records useful updates even when native notifications are disabled or the app is in front.
    func addUpdate(id: String, title: String, taskID: Int?, category: String) async {
        guard let instance = health?.instanceID else { return }
        let identifier = "\(instance):\(id)"
        guard notificationIDs.insert(identifier).inserted else { return }
        notificationOrder.append(identifier)
        if notificationOrder.count > 1000 {
            let expired = notificationOrder.removeFirst()
            notificationIDs.remove(expired)
        }
        activityUpdates.insert(ActivityUpdate(id: identifier, instanceID: instance, title: title,
                                             taskID: taskID, createdAt: Date(), category: category), at: 0)
        activityUpdates = Array(activityUpdates.prefix(100))
        defaults.set(notificationOrder, forKey: "assistant.notified")
        do {
            defaults.set(try JSONEncoder().encode(activityUpdates), forKey: "assistant.activity")
            guard defaults.bool(forKey: "assistant.notifications"),
                  defaults.object(forKey: "assistant.notifications.\(category)") as? Bool ?? true,
                  !NSApp.isActive else { return }
            let content = UNMutableNotificationContent()
            content.title = String(localized: "Assistant")
            content.body = category == "errors" ? String(localized: "Something needs your attention.") : title
            content.userInfo = ["instance": instance, "category": category]
            if let taskID { content.userInfo["task"] = taskID }
            try await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
        } catch { self.error = String(localized: "Notification could not be saved or delivered: \(error.localizedDescription)") }
    }

    /// Asks only when the person explicitly enables notifications in App settings.
    func enableNotifications() async {
        do {
            let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge])
            defaults.set(allowed, forKey: "assistant.notifications")
            if !allowed { error = String(localized: "Notifications are not enabled. In-app updates remain available.") }
        } catch { self.error = error.presentableMessage }
    }

    /// Replaces repeated deliveries without persisting private conversation content.
    private func merge(_ incoming: [ClientMessage]) {
        var indexed = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
        for message in incoming { indexed[message.id] = message }
        messages = indexed.values.sorted { $0.id < $1.id }
    }

    /// Retained in-app feedback stores no message bodies or transport credentials.
    struct ActivityUpdate: Codable, Identifiable {
        let id: String
        let instanceID: String
        let title: String
        let taskID: Int?
        let createdAt: Date
        let category: String?
    }

    /// Updates an operation without duplicating the same server ID.
    private func updateOperation(_ operation: ManagementOperation) {
        operations.removeAll { $0.id == operation.id }
        operations.insert(operation, at: 0)
    }

    /// Journals metadata only; JSON request bodies deliberately stay in memory.
    private func saveReferences() throws {
        defaults.set(try JSONEncoder().encode(references), forKey: "assistant.operations")
    }
}
