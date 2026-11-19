import Foundation
import AppKit
import SwiftUI
import UserNotifications
import XCTest
@testable import Assistant

/// Regression coverage for cached navigation, catalog policy, and chat presentation races.
final class ModernizationTests: XCTestCase {
    private var health: InstanceHealth {
        InstanceHealth(apiVersion: 2, instanceID: "modernization", name: "Nova",
                       capabilities: ["configuration.read"], readOnly: false)
    }

    @MainActor
    func testReadCacheCoalescesRequestsAndInvalidatesExplicitly() async throws {
        let api = ChatAPI()
        let model = ClientModel(defaults: try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)),
                                api: api, health: health)
        await api.pauseNextRead("services")
        let first = Task { try await model.cachedRead("services?details=true") }
        try await waitForPause(api, submission: false)
        let second = Task { try await model.cachedRead("services?details=true") }
        await Task.yield()
        await api.resumeRead("services")
        let results = try await (first.value, second.value)
        XCTAssertEqual(results.0, results.1)
        _ = try await model.cachedRead("services?details=true")
        var resources = await api.resources
        XCTAssertEqual(resources.filter { $0 == "services?details=true" }.count, 1)
        model.invalidateResources()
        _ = try await model.cachedRead("services?details=true")
        resources = await api.resources
        XCTAssertEqual(resources.filter { $0 == "services?details=true" }.count, 2)

        let query = JSONValue.object(["action": .string("skills.list"), "arguments": .object(["limit": .integer(20)])])
        _ = try await model.cachedSkillQuery(query)
        _ = try await model.cachedSkillQuery(query)
        resources = await api.resources
        XCTAssertEqual(resources.filter { $0 == "query" }.count, 1)
        model.invalidateResources()
        _ = try await model.cachedSkillQuery(query)
        resources = await api.resources
        XCTAssertEqual(resources.filter { $0 == "query" }.count, 2)
        do {
            _ = try await model.cachedSkillQuery(.object(["action": .string("skills.delete")]))
            XCTFail("Mutation must never enter the read cache")
        } catch { XCTAssertTrue(error is ClientError) }
    }

    @MainActor
    func testServerEchoBeforeReceiptDoesNotDuplicateOptimisticMessage() async throws {
        let api = ChatAPI()
        let model = ClientModel(defaults: try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)),
                                api: api, health: health)
        model.clientID = "fixture-client"
        try await model.chats.loadConversations(model)
        model.chats.select(try XCTUnwrap(model.chats.conversations.first))
        try await model.chats.refresh(model)
        model.chats.draft = "Repeated text is allowed"
        await model.chats.send(model)
        model.chats.draft = "Repeated text is allowed"
        await api.pauseNextReceipt()
        let sending = Task { await model.chats.send(model) }
        try await waitForPause(api, submission: true)
        try await model.chats.refresh(model)
        let messages = model.chats.timeline.compactMap { item -> ChatMessage? in
            if case .message(let message) = item { return message }
            return nil
        }
        XCTAssertEqual(messages.filter { $0.body == "Repeated text is allowed" }.count, 2)
        await api.resumeSubmission()
        await sending.value
        XCTAssertNil(model.chats.pendingMessage)
        XCTAssertEqual(model.chats.messages.filter { $0.body == "Repeated text is allowed" }.count, 2)
    }

    @MainActor
    func testExplicitUnreadSurvivesRenderingAndRelaunch() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let model = ClientModel(defaults: defaults, api: ChatAPI(), health: health)
        try await model.chats.loadConversations(model)
        let conversation = try XCTUnwrap(model.chats.conversations.first)
        model.chats.select(conversation)
        try await model.chats.refresh(model)
        model.chats.setRead(true, conversation: conversation)
        XCTAssertFalse(model.chats.isUnread(conversation))
        model.chats.setRead(false, conversation: conversation)
        model.chats.markRendered()
        XCTAssertTrue(model.chats.isUnread(conversation))
        let restored = ClientModel(defaults: defaults, health: health)
        XCTAssertTrue(restored.chats.isUnread(conversation))
    }

    @MainActor
    func testLostReceiptShowsAuthoritativeMessageOnlyAndPreservesDraft() async throws {
        let api = ChatAPI()
        let model = ClientModel(defaults: try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)),
                                api: api, health: health)
        model.clientID = "fixture-client"
        try await model.chats.loadConversations(model)
        model.chats.select(try XCTUnwrap(model.chats.conversations.first))
        await api.loseNextSubmission()
        model.chats.draft = "Do not duplicate this"
        await model.chats.send(model)
        try await model.chats.refresh(model)
        XCTAssertTrue(model.chats.pendingUnconfirmed)
        XCTAssertEqual(model.chats.draft, "Do not duplicate this")
        let matching = model.chats.timeline.filter {
            if case .message(let message) = $0 { return message.body == "Do not duplicate this" }
            return false
        }
        XCTAssertEqual(matching.count, 1)
        XCTAssertTrue(model.chats.unconfirmedSend)
        let writes = await api.payloads
        XCTAssertEqual(writes.count, 1)
    }

    @MainActor
    func testMarkdownViewportTracksWindowNotDocumentLengthInBothAppearances() async throws {
        for appearance in [ColorScheme.light, .dark] {
            var source = String(repeating: "# Heading\n\nA **Markdown** paragraph with `code`.\n", count: 100)
            let text = Binding(get: { source }, set: { source = $0 })
            let host = NSHostingView(rootView: MarkdownEditor(text: text).environment(\.colorScheme, appearance))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 300),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.close() }
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(150))
            let scroll = try XCTUnwrap(descendant(NSScrollView.self, in: host))
            let editor = try XCTUnwrap(scroll.documentView as? NSTextView)
            let viewport = scroll.bounds.height
            XCTAssertTrue(scroll.hasVerticalScroller)
            XCTAssertEqual(editor.string, source)
            XCTAssertGreaterThan(editor.bounds.height, scroll.contentView.bounds.height)
            let range = (editor.string as NSString).range(of: "**Markdown**")
            XCTAssertTrue(editor.shouldChangeText(in: range, replacementString: "**edited**"))
            editor.textStorage?.replaceCharacters(in: range, with: "**edited**")
            editor.didChangeText()
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertTrue(source.contains("**edited**"))
            editor.undoManager?.undo()
            XCTAssertTrue(source.contains("**Markdown**"))

            source = "# Short"
            host.rootView = MarkdownEditor(text: .constant(source)).environment(\.colorScheme, appearance)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertTrue(editor.string == source, "External document updates must reach the native editor")
            XCTAssertEqual(scroll.bounds.height, viewport, accuracy: 1)
            XCTAssertLessThanOrEqual(editor.bounds.height, scroll.contentView.bounds.height + 1)
            window.setContentSize(NSSize(width: 680, height: 420))
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertGreaterThan(scroll.bounds.height, viewport)
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])),
                                           uniformTypeIdentifier: "public.png")
            attachment.name = "Markdown editor \(appearance)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    @MainActor
    private func descendant<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        return view.subviews.lazy.compactMap { self.descendant(type, in: $0) }.first
    }

    @MainActor
    func testCatalogWeeklyManualDisabledRefreshAndSeparatePolicies() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let loader = CatalogFixture()
        let catalog = OpenRouterCatalog(defaults: defaults, loader: loader)
        let now = Date()
        await catalog.refresh(zdr: false, now: now)
        await catalog.refresh(zdr: false, now: now.addingTimeInterval(6 * 24 * 60 * 60))
        var policies = await loader.policies
        XCTAssertEqual(policies, [false])
        await catalog.refresh(zdr: false, now: now.addingTimeInterval(OpenRouterCatalog.refreshInterval))
        await catalog.refresh(zdr: true, now: now)
        XCTAssertEqual(catalog.models(zdr: true, purpose: .speech).map(\.id), ["speech"])
        XCTAssertEqual(catalog.models(zdr: false, purpose: .tools).map(\.id), ["tools"])
        XCTAssertEqual(catalog.models(zdr: false, purpose: .decisions).map(\.id), ["decisions"])
        catalog.automaticallyRefresh = false
        let later = now.addingTimeInterval(3 * OpenRouterCatalog.refreshInterval)
        await catalog.refresh(zdr: true, now: later)
        policies = await loader.policies
        XCTAssertEqual(policies, [false, false, true])
        await catalog.refresh(zdr: true, force: true, now: later)
        policies = await loader.policies
        XCTAssertEqual(policies, [false, false, true, true])
        let restored = OpenRouterCatalog(defaults: defaults, loader: loader)
        XCTAssertFalse(restored.automaticallyRefresh)
        XCTAssertEqual(restored.models(zdr: true, purpose: .chat).map(\.id), ["tools"])
        XCTAssertEqual(restored.models(zdr: true, purpose: .speech).first?.supportedVoices, ["jane", "dan"])
        await loader.fail()
        await restored.refresh(zdr: true, force: true)
        XCTAssertNotNil(restored.errors[true])
        XCTAssertEqual(restored.models(zdr: true, purpose: .chat).map(\.id), ["tools"])
    }

    @MainActor
    func testConfiguredAssistantNameRefreshesAndClearingItRestoresInstallationName() async throws {
        let api = ChatAPI()
        let health = InstanceHealth(apiVersion: 2, instanceID: "names", name: "Assistant",
                                    capabilities: ["configuration.structured"], readOnly: false)
        let model = ClientModel(defaults: try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)),
                                api: api, health: health)
        await api.setAssistantName(" Juniper ")
        await model.refreshAssistantName()
        XCTAssertEqual(model.assistantName, "Juniper")
        await api.setAssistantName("")
        model.invalidateResources()
        await model.refreshAssistantName()
        XCTAssertEqual(model.assistantName, "Assistant")
    }

    func testCalendarDefaultsDoNotCountAsConfiguredAccounts() throws {
        let configuration = try Wire.decoder().decode(FullConfiguration.self, from: Data("""
        {"revision":"r","setup_complete":true,"instructions":"","setup_notice":"","settings":[
          {"group":"calendar:google_2","key":"CLIENT_ID","label":"Client ID","value":"","secret":true,"boolean":false,"editable":true},
          {"group":"calendar:google_2","key":"CLIENT_SECRET","label":"Client secret","value":"","secret":true,"boolean":false,"editable":true},
          {"group":"calendar:google_2","key":"REFRESH_TOKEN","label":"Refresh token","value":"","secret":true,"boolean":false,"editable":true},
          {"group":"calendar:google_2","key":"CALENDAR_ID","label":"Calendar ID","value":"primary","default":"primary",
           "secret":false,"boolean":false,"editable":true}
        ],"groups":[{"id":"calendar:google_2","title":"Google calendar 2","parent":"calendar","basic":true}]}
        """.utf8))
        let navigation = SettingsNavigation(configuration)
        let account = try XCTUnwrap(navigation.group("calendar:google_2"))
        XCTAssertFalse(navigation.configured(account))
        XCTAssertFalse(navigation.configured(account, credentials: ["CLIENT_ID", "CLIENT_SECRET"]))
        XCTAssertTrue(navigation.configured(account, credentials: ["CLIENT_ID", "CLIENT_SECRET", "REFRESH_TOKEN"]))
    }

    @MainActor
    func testActivationReviewUsesServerStateAcrossRelaunch() async throws {
        let api = ChatAPI()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let health = InstanceHealth(apiVersion: 2, instanceID: "activation", name: "Assistant",
                                    capabilities: ["configuration.activation"], readOnly: false)
        let model = ClientModel(defaults: defaults, api: api, health: health)
        await api.setActivationPending(true)
        try await model.refreshActivation()
        XCTAssertEqual(model.activationState, .pending)
        XCTAssertEqual(model.activationSummary?.changes.first?.label, "Assistant name")
        model.references = [OperationReference(id: UUID(), instanceID: health.instanceID, key: UUID().uuidString,
                                               action: "service.lifecycle", operationID: nil, submittedAt: Date())]
        model.recordActivation(.unknown)
        try await model.refreshActivation()
        XCTAssertEqual(model.activationState, .unknown, "A settings read cannot resolve a missing operation receipt")
        model.references = []
        try await model.refreshActivation()
        let restored = ClientModel(defaults: defaults, api: api, health: health)
        XCTAssertEqual(restored.activationState, .pending)
        await api.setActivationPending(false)
        try await restored.refreshActivation()
        XCTAssertEqual(restored.activationState, .active)
        XCTAssertTrue(restored.activationSummary?.changes.isEmpty == true)
        await api.setActivationPending(true)
        await api.pauseNextRead("configuration/activation")
        let staleRead = Task { try await restored.refreshActivation() }
        while await !api.readIsPaused("configuration/activation") { await Task.yield() }
        restored.recordActivation(.active)
        await api.resumeRead("configuration/activation")
        do {
            try await staleRead.value
            XCTFail("An older read must not overwrite a newer activation outcome")
        } catch is CancellationError {}
        XCTAssertEqual(restored.activationState, .active)
        await restored.disconnect()
        XCTAssertNil(restored.activationSummary)
    }

    func testRenderedProseKeepsParagraphsAndListsInOneSelectableText() {
        let text = "# Heading\nFirst line.\nSecond **line**.\n\n- First item\n- Second item\n\nFinal paragraph."
        let rendered = String(MarkdownContent.prose(text).characters)
        XCTAssertEqual(rendered, "Heading\nFirst line.\nSecond line.\n\n• First item\n• Second item\n\nFinal paragraph.")
    }

    @MainActor
    func testInactiveNotificationsDeliverOnceWithoutMessageBodies() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        defaults.set(true, forKey: "assistant.notifications")
        let delivery = NotificationFixture()
        let model = ClientModel(defaults: defaults, health: health, notificationDelivery: delivery)
        await model.addUpdate(id: "reply:1", title: "New reply from Nova", taskID: 9, category: "replies")
        await model.addUpdate(id: "reply:1", title: "Duplicate", taskID: 9, category: "replies")
        XCTAssertEqual(delivery.requests.count, 1)
        XCTAssertEqual(delivery.requests.first?.content.title, "Nova")
        XCTAssertEqual(delivery.requests.first?.content.userInfo["task"] as? Int, 9)
        XCTAssertEqual(delivery.requests.first?.content.userInfo["instance"] as? String, health.instanceID)
        delivery.applicationIsActive = true
        await model.addUpdate(id: "reply:2", title: "New reply", taskID: 10, category: "replies")
        delivery.applicationIsActive = false
        defaults.set(false, forKey: "assistant.notifications.replies")
        await model.addUpdate(id: "reply:3", title: "New reply", taskID: 11, category: "replies")
        XCTAssertEqual(delivery.requests.count, 1)
        XCTAssertEqual(model.activityUpdates.count, 3)
    }

    private func waitForPause(_ api: ChatAPI, submission: Bool) async throws {
        for _ in 0..<100 {
            let paused = submission ? await api.submissionPaused : await api.readIsPaused("services")
            if paused { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Fixture request did not reach its deterministic gate")
    }
}

/// Capability fixtures exercise discovery without contacting OpenRouter.
private actor CatalogFixture: OpenRouterCatalogLoading {
    var policies: [Bool] = []
    private var failing = false
    func fail() { failing = true }
    func models(zdr: Bool) async throws -> [OpenRouterModel] {
        policies.append(zdr)
        if failing { throw URLError(.notConnectedToInternet) }
        return [
            OpenRouterModel(id: "tools", name: "Tools", architecture: .init(inputModalities: ["text"], outputModalities: ["text"]),
                            supportedParameters: ["tools"], endpoints: nil),
            try Wire.decoder().decode(OpenRouterModel.self, from: Data("""
            {"id":"speech","name":"Speech","architecture":{"input_modalities":["text"],"output_modalities":["speech"]},
             "supported_voices":["jane","dan"]}
            """.utf8)),
            OpenRouterModel(id: "decisions", name: "Decisions", architecture: .init(inputModalities: ["text"], outputModalities: ["decisions"]),
                            supportedParameters: nil, endpoints: nil)
        ]
    }
}

/// Records native delivery intent while keeping the system notification center untouched.
@MainActor private final class NotificationFixture: ClientNotificationDelivering {
    var applicationIsActive = false
    var requests: [UNNotificationRequest] = []
    func deliver(_ request: UNNotificationRequest) async throws { requests.append(request) }
}
