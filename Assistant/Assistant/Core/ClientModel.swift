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
    var activationSummary: ConfigurationActivation?
    var activationReviewPresented = false
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
    private(set) var receiptLookups: [UUID: String] = [:]
    var busy = false
    var configurationDirty = false
    var chats: ConversationModel
    let reminderRuns: ConversationModel
    var skillsBrowser = SkillBrowserState()
    private(set) var settingsMenu: FullConfiguration?
    private var settingsMenuSource: JSONValue?
    let modelCatalog: OpenRouterCatalog
    private(set) var assistantName = String(localized: "Assistant")
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
    var activityPresented = false
    var activitySection = ActivitySection.attention
    var configurationVisit = UUID()
    private var resourceCache: [String: (Date, JSONValue)] = [:]
    private var resourceReads: [String: Task<JSONValue, Error>] = [:]
    private var cacheGeneration = UUID()
    private var skillGeneration = UUID()
    private(set) var services: [JSONValue] = []
    private(set) var servicesUpdatedAt: Date?
    private(set) var servicesLoading = false
    private(set) var servicesError: String?
    private(set) var api: (any ManagementAPI)?
    private let connection = SSHConnection()
    private let defaults: UserDefaults
    private let receiptStore: any DeliveryReceiptStoring
    private let notificationDelivery: any ClientNotificationDelivering
    private(set) var requestDurations: [String: TimeInterval] = [:]
    var preferences: UserDefaults { defaults }
    var unconfirmedReferences: [OperationReference] {
        references.filter { reference in
            reference.instanceID == health?.instanceID &&
                !operations.contains(where: { $0.id == reference.operationID })
        }
    }
    /// An absent receipt is not evidence that a service action did not run.
    var unconfirmedActivationAction: Bool {
        unconfirmedReferences.contains { ["service.lifecycle", "configuration.save"].contains($0.action) }
    }
    /// Applying must wait for known configuration writes and service actions to finish.
    var pendingActivationAction: Bool {
        operations.contains {
            $0.pending && ($0.action == "configuration.save" || $0.action.hasPrefix("configuration.save.") ||
                           $0.action == "service.lifecycle" || $0.action.hasPrefix("service."))
        }
    }
    private var pollTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var approvalTask: Task<Void, Never>?
    private var approvalRefreshPending = false
    private var lastApprovalRefresh: Date?
    private var notificationIDs: Set<String> = []
    private var notificationOrder: [String] = []
    private var generation = UUID()
    private var activationVersion = UUID()

    /// Loads only non-secret metadata and reports malformed local state explicitly.
    init(defaults: UserDefaults = .standard, api: (any ManagementAPI)? = nil, health: InstanceHealth? = nil,
         modelCatalogLoader: any OpenRouterCatalogLoading = PublicOpenRouterCatalog(),
         notificationDelivery: (any ClientNotificationDelivering)? = nil,
         receiptStore: any DeliveryReceiptStoring = DeliveryReceiptStore()) {
        self.defaults = defaults
        self.receiptStore = receiptStore
        self.notificationDelivery = notificationDelivery ?? SystemNotificationDelivery()
        self.chats = ConversationModel(defaults: defaults)
        self.reminderRuns = ConversationModel(defaults: defaults, reminderHistory: true)
        self.modelCatalog = OpenRouterCatalog(defaults: defaults, loader: modelCatalogLoader)
        self.api = api
        self.health = health
        assistantName = health?.name ?? String(localized: "Assistant")
        do {
            if let data = defaults.data(forKey: "assistant.profiles") {
                profiles = try JSONDecoder().decode([ConnectionProfile].self, from: data)
            }
            if let data = defaults.data(forKey: "assistant.operations") {
                references = try JSONDecoder().decode([OperationReference].self, from: data)
            }
            if let first = profiles.first { profile = first }
            if let health { try chats.restoreCache(instance: health.instanceID) }
            if let health { try reminderRuns.restoreCache(instance: health.instanceID) }
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
        if let health {
            do { try restoreSettingsMenu(instance: health.instanceID) }
            catch { self.error = String(localized: "Saved settings menu could not be read: \(error.localizedDescription)") }
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
            assistantName = health.name
            activationState = ActivationState(rawValue: defaults.string(forKey: "assistant.activation.\(health.instanceID)") ?? "") ?? .active
            updatesSeenAt = Date(timeIntervalSince1970: defaults.double(forKey: "assistant.updatesSeen.\(health.instanceID)"))
            profile.instanceID = health.instanceID
            try saveProfile()
            do { try chats.restoreCache(instance: health.instanceID) }
            catch { chats.error = String(localized: "Saved conversations could not be read: \(error.localizedDescription)") }
            do { try reminderRuns.restoreCache(instance: health.instanceID) }
            catch { reminderRuns.error = String(localized: "Saved reminder history could not be read: \(error.localizedDescription)") }
            do { try restoreServices(instance: health.instanceID) }
            catch { servicesError = String(localized: "Saved service statuses could not be read: \(error.localizedDescription)") }
            do { try restoreSettingsMenu(instance: health.instanceID) }
            catch { self.error = String(localized: "Saved settings menu could not be read: \(error.localizedDescription)") }
            status = String(localized: "Connected")
            if health.capabilities.contains("configuration.structured") {
                do {
                    let catalog = try await configurationCatalog()
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
                assistantName = String(localized: "Assistant")
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
        invalidateResources(includingSkills: true)
        skillsBrowser = SkillBrowserState()
        settingsMenu = nil
        settingsMenuSource = nil
        health = nil
        clientID = nil
        messages = []
        chats.clear()
        reminderRuns.clear()
        offeredIDs = []
        historyCursor = nil
        pollingError = nil
        operations = []
        receiptLookups = [:]
        lastPoll = nil
        services = []; servicesUpdatedAt = nil; servicesError = nil; servicesLoading = false
        requestDurations = [:]
        activationState = .active
        activationSummary = nil
        activationReviewPresented = false
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
        let startedAt = Date()
        let result = try await api.read(resource, as: JSONValue.self)
        guard generation == current else { throw CancellationError() }
        let path = String(resource.split(separator: "?", maxSplits: 1).first ?? "")
        if requestDurations[path] == nil, requestDurations.count >= 50, let oldest = requestDurations.keys.first {
            requestDurations.removeValue(forKey: oldest)
        }
        requestDurations[path] = Date().timeIntervalSince(startedAt)
        return result
    }

    /// Session-only read caching coalesces navigation requests without storing credentials on disk.
    func cachedRead(_ resource: String, maxAge: TimeInterval = 60) async throws -> JSONValue {
        try await cachedResource(resource, maxAge: maxAge) { try await self.read(resource) }
    }

    /// Menus restore immediately; only live, revision-bound responses may initialize an editable form.
    func configurationCatalog() async throws -> JSONValue {
        guard let instance = health?.instanceID else { throw ClientError.unavailable }
        let current = generation
        let catalog = try await cachedRead("configuration/catalog")
        guard current == generation, health?.instanceID == instance else { throw CancellationError() }
        let snapshot = try SettingsMenuCache.snapshot(catalog)
        if snapshot != settingsMenuSource {
            let menu = try Wire.decoder().decode(FullConfiguration.self, from: JSONEncoder().encode(snapshot))
            try SettingsMenuCache.save(snapshot, instance: instance, defaults: defaults)
            settingsMenuSource = snapshot
            settingsMenu = menu
        }
        return catalog
    }

    /// All model roles load together; older servers must explain their missing capability.
    func modelSettingsOverview(revision: String) async throws -> ModelSettingsOverview {
        guard health?.capabilities.contains("configuration.model-settings") == true else {
            throw ClientError.serverOutdated(String(localized: "model settings overview"))
        }
        let result = try await cachedRead("configuration/model-settings")
        let overview = try Wire.decoder().decode(ModelSettingsOverview.self, from: JSONEncoder().encode(result))
        try overview.validate(revision: revision)
        return overview
    }

    /// Provider credentials remain on the server while the authenticated client requests model IDs.
    func providerModelCatalog(providerID: String? = nil) async throws -> ProviderModelCatalog {
        guard health?.capabilities.contains("configuration.model-catalog") == true else {
            throw ClientError.serverOutdated(String(localized: "provider model discovery"))
        }
        let resource = providerID.map { "configuration/models?provider=\($0)" } ?? "configuration/models"
        let result = try await cachedRead(resource, maxAge: 5 * 60)
        let catalog = try Wire.decoder().decode(ProviderModelCatalog.self, from: JSONEncoder().encode(result))
        if let providerID, catalog.provider != providerID {
            throw ClientError.serverOutdated(String(localized: "provider model catalog"))
        }
        try catalog.validate()
        return catalog
    }

    func prefetchSettingsMenu() async {
        guard health?.capabilities.contains("configuration.structured") == true else { return }
        do { _ = try await configurationCatalog() }
        catch { if let message = error.presentableMessage { self.error = message } }
    }

    private func restoreSettingsMenu(instance: String) throws {
        settingsMenuSource = try SettingsMenuCache.read(instance: instance, defaults: defaults)
        if let settingsMenuSource {
            settingsMenu = try Wire.decoder().decode(FullConfiguration.self, from: JSONEncoder().encode(settingsMenuSource))
        } else { settingsMenu = nil }
    }

    /// Only side-effect-free skill discovery enters the session query cache.
    func cachedSkillQuery(_ payload: JSONValue) async throws -> JSONValue {
        guard ["skills.list", "skills.read"].contains(payload["action"]?.string ?? "") else {
            throw ClientError.invalidResource
        }
        let key = "query:" + (try payload.formatted())
        return try await cachedResource(key, maxAge: 15 * 60) { try await self.query("query", payload: payload) }
    }

    /// Fetch the first page before Settings opens; details and later pages still load on demand.
    func prefetchSkills() async {
        guard health?.capabilities.contains("skills.manage") == true else { return }
        let browser = skillsBrowser
        do {
            let value = try await cachedSkillQuery(SkillPage.query(
                search: "", offset: 0, preferences: health?.capabilities.contains("skills.preferences") == true))
            let page = try Wire.decoder().decode(SkillPage.self, from: JSONEncoder().encode(value))
            guard browser === skillsBrowser else { return }
            if skillsBrowser.search.isEmpty && skillsBrowser.offset == 0 {
                skillsBrowser.entries = page.skills
                skillsBrowser.total = page.total
                skillsBrowser.error = nil
            }
        } catch {
            if browser === skillsBrowser, let message = error.presentableMessage { browser.error = message }
        }
    }

    private func cacheVersion(_ key: String) -> UUID {
        key.hasPrefix("query:") ? skillGeneration : cacheGeneration
    }

    private func cachedResource(_ key: String, maxAge: TimeInterval,
                                load: @escaping @MainActor () async throws -> JSONValue) async throws -> JSONValue {
        let current = cacheVersion(key)
        if let (date, value) = resourceCache[key], Date().timeIntervalSince(date) < maxAge { return value }
        if let task = resourceReads[key] {
            let value = try await task.value
            guard current == cacheVersion(key) else { throw CancellationError() }
            return value
        }
        let task = Task { try await load() }
        resourceReads[key] = task
        defer { if current == cacheVersion(key) { resourceReads[key] = nil } }
        let value = try await task.value
        guard current == cacheVersion(key) else { throw CancellationError() }
        if resourceCache.count >= 128, let oldest = resourceCache.min(by: { $0.value.0 < $1.value.0 })?.key {
            resourceCache.removeValue(forKey: oldest)
        }
        resourceCache[key] = (Date(), value)
        return value
    }

    /// Identity values are read from their owning settings page, never the static API product name.
    func refreshAssistantName() async {
        guard health?.capabilities.contains("configuration.structured") == true else { return }
        do {
            let settings = try await cachedRead("configuration/settings?group=identity")
            guard let name = settings["settings"]?.array?.first(where: {
                $0["key"] == .string("AGENT_IDENTITY_NAME")
            })?["value"]?.string else { throw ClientError.malformedResponse }
            let configured = name.trimmingCharacters(in: .whitespacesAndNewlines)
            assistantName = configured.isEmpty ? (health?.name ?? String(localized: "Assistant")) : configured
        } catch {
            if let message = error.presentableMessage { self.error = message }
        }
    }

    /// Explicit reloads and mutations invalidate all dependent settings and inventory snapshots.
    func invalidateResources(includingSkills: Bool = false) {
        cacheGeneration = UUID()
        if includingSkills { skillGeneration = UUID() }
        for (key, task) in resourceReads where includingSkills || !key.hasPrefix("query:") { task.cancel() }
        resourceReads = resourceReads.filter { !includingSkills && $0.key.hasPrefix("query:") }
        resourceCache = resourceCache.filter { !includingSkills && $0.key.hasPrefix("query:") }
    }

    /// Keeps the last successful inventory visible while checking current health.
    func refreshServices() async {
        guard !servicesLoading, let instance = health?.instanceID else { return }
        let current = generation
        servicesLoading = true
        defer { if current == generation { servicesLoading = false } }
        do {
            let result = try await readWithRetry("services?details=true")
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
        activationVersion = UUID()
        activationState = state
        defaults.set(state.rawValue, forKey: "assistant.activation.\(instance)")
    }

    /// Old servers retain the local warning but cannot fabricate a reviewed change list.
    func refreshActivation() async throws {
        guard health?.capabilities.contains("configuration.activation") == true else {
            throw ClientError.serverOutdated(String(localized: "saved-settings activation review"))
        }
        let version = activationVersion
        let response = try await read("configuration/activation")
        guard version == activationVersion else { throw CancellationError() }
        let summary = try Wire.decoder().decode(ConfigurationActivation.self, from: JSONEncoder().encode(response))
        activationSummary = summary
        if summary.tracked,
           activationState != .unknown || (!unconfirmedActivationAction && !pendingActivationAction) {
            recordActivation(summary.pending ? .pending : .active)
        }
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
        defer {
            if action == "service.lifecycle", current == generation {
                invalidateResources()
                if payload["service"] == nil, ["start", "apply"].contains(payload["action"]?.string ?? "") {
                    configurationVisit = UUID()
                }
            }
        }
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
        if action.hasPrefix("configuration.") || action.hasPrefix("credential") || action == "domain.mutate" {
            invalidateResources(includingSkills: payload["action"]?.string?.hasPrefix("skills.") == true)
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
        var statuses = try await api.read("operations", as: [ManagementOperation].self)
        guard current == generation else { throw CancellationError() }
        if health?.capabilities.contains("operations.lookup") == true {
            for reference in references where reference.instanceID == health?.instanceID &&
                !statuses.contains(where: { $0.id == reference.operationID }) {
                var query = URLComponents()
                query.queryItems = [URLQueryItem(name: "key", value: reference.key)]
                let result = try await read("operations/lookup?\(query.percentEncodedQuery ?? "")")
                guard current == generation else { throw CancellationError() }
                guard let status = result["status"]?.string,
                      ["found", "not_found", "expired"].contains(status) else { throw ClientError.malformedResponse }
                receiptLookups[reference.id] = status
                if status == "found" {
                    guard let value = result["operation"] else { throw ClientError.malformedResponse }
                    let operation = try Wire.decoder().decode(ManagementOperation.self, from: JSONEncoder().encode(value))
                    if !statuses.contains(where: { $0.id == operation.id }) { statuses.append(operation) }
                    if let index = references.firstIndex(where: { $0.id == reference.id }) {
                        references[index].operationID = operation.id
                    }
                }
            }
        }
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

    /// Persist first, then acknowledge transport receipt without changing human unread state.
    func receiveDeliveries(_ incoming: [ClientMessage]) async throws {
        guard let api, let clientID, let instance = health?.instanceID else { throw ClientError.unavailable }
        let current = generation
        if !incoming.isEmpty { try await receiptStore.save(incoming, instance: instance, client: clientID) }
        guard generation == current else { throw CancellationError() }
        merge(incoming)
        let ids = incoming.map(\.id)
        if offeredIDs != ids { offeredIDs = ids }
        guard !ids.isEmpty else {
            try await receiptStore.remove(instance: instance, client: clientID)
            return
        }
        let acknowledgment = try await api.acknowledge(client: clientID, ids: ids)
        guard generation == current else { throw CancellationError() }
        offeredIDs.removeAll { acknowledgment.acknowledged.contains($0) }
        guard ids.allSatisfy(acknowledgment.acknowledged.contains) else { throw ClientError.unacknowledged }
        try await receiptStore.remove(instance: instance, client: clientID)
    }

    /// Clear transcript and pending-receipt caches without touching server history or human delivery state.
    func clearConversationCache() async {
        chats.clearSavedCache()
        reminderRuns.clearSavedCache()
        do { try await receiptStore.clear() }
        catch { self.error = error.presentableMessage }
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
                    let buffered = try await receiptStore.load(instance: instance, client: identifier)
                    guard generation == current else { return }
                    merge(buffered)
                    try await loadHistory()
                }
                guard let clientID else { throw ClientError.malformedResponse }
                let result = try await api.read("clients/\(clientID)/messages", as: ClientPoll.self)
                guard generation == current else { return }
                guard result.pollIntervalSeconds > 0, result.availabilityTimeoutSeconds > 0 else {
                    throw ClientError.malformedResponse
                }
                let known = Set(messages.map(\.id))
                try await receiveDeliveries(result.messages)
                guard generation == current else { return }
                for message in result.messages where !known.contains(message.id) {
                    await addUpdate(id: "delivery:\(message.id)", title: message.taskID == nil ?
                                    String(localized: "New installation notice") : String(localized: "New reply from \(assistantName)"),
                                    taskID: message.taskID, category: "replies")
                }
                lastPoll = Date()
                pollingError = nil
                let connected = String(localized: "Connected")
                if status != connected { status = connected }
                failures = 0
                if !liveUpdates, lastApprovalRefresh.map({ Date().timeIntervalSince($0) >= 30 }) ?? true {
                    requestApprovalRefresh(generation: current)
                }
                try await Task.sleep(for: .seconds(result.pollIntervalSeconds))
            } catch {
                guard generation == current, !Task.isCancelled else { return }
                failures += 1
                if !ReadRetryPolicy.isTransient(error) || failures >= 3 { pollingError = error.presentableMessage }
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
                        if failures >= 3 { pollingError = error.presentableMessage }
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
                  !notificationDelivery.applicationIsActive else { return }
            let content = UNMutableNotificationContent()
            content.title = assistantName
            content.body = category == "errors" ? String(localized: "Something needs your attention.") : title
            content.userInfo = ["instance": instance, "category": category]
            if let taskID { content.userInfo["task"] = taskID }
            try await notificationDelivery.deliver(
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
        let updated = indexed.values.sorted { $0.id < $1.id }
        if messages != updated { messages = updated }
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
