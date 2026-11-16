import Foundation
import Observation

/// Shared native state; views never retain tokens or construct SSH commands.
@MainActor @Observable
final class ClientModel {
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
    var newChatRequest = UUID()
    var configurationApplying = false
    private(set) var api: (any ManagementAPI)?
    private let connection = SSHConnection()
    private let defaults: UserDefaults
    private var pollTask: Task<Void, Never>?
    private var generation = UUID()

    /// Loads only non-secret metadata and reports malformed local state explicitly.
    init(defaults: UserDefaults = .standard, api: (any ManagementAPI)? = nil, health: InstanceHealth? = nil) {
        self.defaults = defaults
        self.chats = ConversationModel(defaults: defaults)
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
            profile.instanceID = health.instanceID
            try saveProfile()
            do { try chats.restoreCache(instance: health.instanceID) }
            catch { chats.error = String(localized: "Saved conversations could not be read: \(error.localizedDescription)") }
            status = String(localized: "Connected")
            let instance = health.instanceID
            pollTask = Task { [weak self] in
                await self?.runPolling(instance: instance, generation: current)
            }
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
        api = nil
        health = nil
        clientID = nil
        messages = []
        chats.clear()
        offeredIDs = []
        historyCursor = nil
        pollingError = nil
        operations = []
        lastPoll = nil
        status = String(localized: "Disconnected")
        await connection.disconnect()
    }

    /// Called synchronously when macOS terminates the application.
    func terminate() {
        pollTask?.cancel()
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
                merge(result.messages)
                offeredIDs = result.messages.map(\.id)
                lastPoll = Date()
                pollingError = nil
                status = String(localized: "Connected")
                failures = 0
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

    /// Replaces repeated deliveries without persisting private conversation content.
    private func merge(_ incoming: [ClientMessage]) {
        var indexed = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
        for message in incoming { indexed[message.id] = message }
        messages = indexed.values.sorted { $0.id < $1.id }
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
