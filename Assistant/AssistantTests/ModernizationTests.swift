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
    func testPendingActivationActionsUseServerAuditNames() throws {
        let model = ClientModel(defaults: try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)),
                                health: health)
        func operation(_ action: String, _ state: String) -> ManagementOperation {
            ManagementOperation(id: "operation", action: action, state: state,
                                progress: "", error: nil, result: nil)
        }
        for action in ["configuration.save.AGENT_LLM_MODEL", "service.apply.application",
                       "service.restart.management", "configuration.save", "service.lifecycle"] {
            model.operations = [operation(action, "running")]
            XCTAssertTrue(model.pendingActivationAction, action)
            model.operations = [operation(action, "succeeded")]
            XCTAssertFalse(model.pendingActivationAction, action)
        }
        model.operations = [operation("record.delete.1", "running")]
        XCTAssertFalse(model.pendingActivationAction)
    }

    func testWebAccessSettingsUseServerNavigationChoicesAndSecretMetadata() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let configuration = try decoder.decode(FullConfiguration.self, from: Data("""
        {"revision":"r1","setup_complete":true,"instructions":"","setup_notice":"",
         "groups":[
          {"id":"catalog:search","title":"Web search providers","basic":true,"destination":"models"},
          {"id":"catalog:web_fetch","title":"Web page reader","basic":true,"destination":"models",
           "advanced_title":"External reader & limits"}],
         "settings":[
          {"group":"catalog:search","key":"AGENT_SEARCH_PRIMARY_PROVIDER","label":"Preferred search provider",
           "value":"exa","secret":false,"boolean":false,"editable":true,
           "metadata":{"level":"basic","section":"Search providers","choices":["openrouter","exa"],
                       "choice_labels":{"openrouter":"OpenRouter","exa":"Exa (direct)"}}},
          {"group":"catalog:search","key":"AGENT_SEARCH_EXA_API_KEY","label":"Exa API key (optional)",
           "value":"","secret":true,"boolean":false,"editable":true,
           "metadata":{"level":"basic","section":"Search providers"}},
          {"group":"catalog:web_fetch","key":"AGENT_WEB_FETCH_ENABLED","label":"Web page reader",
           "value":"false","secret":false,"boolean":true,"editable":true,"metadata":{"level":"basic"}},
          {"group":"catalog:web_fetch","key":"AGENT_WEB_FETCH_API_TOKEN","label":"External Crawl4AI API token",
           "value":"","secret":true,"boolean":false,"editable":true,"metadata":{"level":"advanced"}}]}
        """.utf8))
        let navigation = SettingsNavigation(configuration)
        XCTAssertEqual(navigation.pages(in: .models).map(\.id), ["catalog:search", "catalog:web_fetch"])
        let providers = try XCTUnwrap(navigation.sections(in: "catalog:search").first)
        XCTAssertEqual(providers.title, "Search providers")
        let preferred = try XCTUnwrap(providers.fields.first)
        XCTAssertEqual(preferred.choices, ["openrouter", "exa"])
        XCTAssertEqual(preferred.choiceLabel(preferred.value), "Exa (direct)")
        XCTAssertTrue(try XCTUnwrap(providers.fields.last).secret)
        let reader = try XCTUnwrap(navigation.group("catalog:web_fetch"))
        let readerFields = navigation.fields(in: reader.id)
        let toggle = try XCTUnwrap(readerFields.first)
        let token = try XCTUnwrap(readerFields.last)
        XCTAssertTrue(toggle.boolean)
        XCTAssertEqual(navigation.category(for: reader, field: toggle), .models)
        XCTAssertTrue(token.secret)
        XCTAssertEqual(navigation.category(for: reader, field: token), .advanced)
        XCTAssertEqual(navigation.title(reader, in: .advanced), "External reader & limits")
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
        XCTAssertEqual(resources.filter { $0 == "query" }.count, 1)
        model.invalidateResources(includingSkills: true)
        _ = try await model.cachedSkillQuery(query)
        resources = await api.resources
        XCTAssertEqual(resources.filter { $0 == "query" }.count, 2)
        do {
            _ = try await model.cachedSkillQuery(.object(["action": .string("skills.delete")]))
            XCTFail("Mutation must never enter the read cache")
        } catch { XCTAssertTrue(error is ClientError) }
    }

    @MainActor
    func testApplyingSavedSettingsRefreshesCachedConfigurationAndMountedSettings() async throws {
        let api = ChatAPI()
        let model = ClientModel(defaults: try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)),
                                api: api, health: health)
        let previousVisit = model.configurationVisit
        await api.setSettingsCatalog(.object(["revision": .string("before")]))
        await api.setAssistantName("Before")
        let oldCatalog = try await model.cachedRead("configuration/catalog")
        XCTAssertEqual(oldCatalog["revision"], .string("before"))
        let before = try await model.cachedRead("configuration/settings?group=identity")
        XCTAssertEqual(before["settings"]?.array?.first?["value"], .string("Before"))
        await api.setSettingsCatalog(.object(["revision": .string("after")]))
        await api.setAssistantName("After")

        _ = try await model.perform(.object([
            "operation": .string("service.lifecycle"), "action": .string("apply"), "confirmed": .bool(true)
        ]))
        let after = try await model.cachedRead("configuration/settings?group=identity")
        XCTAssertEqual(after["settings"]?.array?.first?["value"], .string("After"))
        let newCatalog = try await model.cachedRead("configuration/catalog")
        XCTAssertEqual(newCatalog["revision"], .string("after"))
        XCTAssertNotEqual(model.configurationVisit, previousVisit)
        let resources = await api.resources
        XCTAssertEqual(resources.filter { $0 == "configuration/settings?group=identity" }.count, 2)
        XCTAssertEqual(resources.filter { $0 == "configuration/catalog" }.count, 2)
    }

    @MainActor
    func testCopyPreservesWholeMessageSourceOnNativePasteboard() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let text = "# A reply\n\nFirst **paragraph**.\nSecond line: مرحباً 👋\n\n```swift\nlet ready = true\n```\n\n- Last item"
        XCTAssertTrue(MessageClipboard.copy(text, to: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), text)
        XCTAssertTrue(MessageClipboard.copy("A user message\nwith two lines", to: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), "A user message\nwith two lines")
    }

    @MainActor
    func testNativeCopyButtonHitTargetAndActionCopyTheCompleteCurrentMessage() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        for appearance in [ColorScheme.light, .dark] {
            for compact in [true, false] {
                let source = "# A message\n\nFirst paragraph.\nSecond line.\n\n```swift\nlet ready = true\n```"
                func content(_ text: String) -> some View {
                    VStack(alignment: .leading) {
                        HStack {
                            Text("Assistant").textSelection(.enabled)
                            Spacer()
                            CopyTextButton(text: text, compact: compact, pasteboard: pasteboard)
                        }
                        Text(text).textSelection(.enabled)
                    }.padding().environment(\.colorScheme, appearance)
                }
                let host = NSHostingView(rootView: content(source))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                                      styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host
                defer { window.close() }
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
                let button = try XCTUnwrap(descendant(NativeCopyControl.CopyButton.self, in: host))
                XCTAssertGreaterThanOrEqual(button.bounds.width, 28)
                XCTAssertGreaterThanOrEqual(button.bounds.height, 28)
                XCTAssertTrue(button.acceptsFirstMouse(for: nil))
                for point in [NSPoint(x: button.bounds.midX, y: button.bounds.midY), NSPoint(x: 3, y: 3)] {
                    let hit = host.hitTest(button.convert(point, to: host.superview))
                    XCTAssertTrue(hit === button || hit?.isDescendant(of: button) == true,
                                  "compact=\(compact), appearance=\(appearance), point=\(point), hit=\(String(describing: hit)), bounds=\(button.bounds), visible=\(button.visibleRect)")
                }
                button.performClick(nil)
                XCTAssertEqual(pasteboard.string(forType: .string), source)
                let updated = "A different user message\nwith its entire second line."
                host.rootView = content(updated)
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(50))
                try XCTUnwrap(descendant(NativeCopyControl.CopyButton.self, in: host)).performClick(nil)
                XCTAssertEqual(pasteboard.string(forType: .string), updated, "Reused controls must copy the current message")
            }
        }
    }

    /// Textual's copy proxy keeps fenced source intact and does not include its toolbar.
    @MainActor
    func testMarkdownCodeCopyPreservesSource() async throws {
        for source in ["let ready = true", "  ┌────┐\n  │ A  │\n  └────┘"] {
            let host = NSHostingView(rootView: MarkdownContent(text: "```\n\(source)\n```"))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.close() }
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            try XCTUnwrap(descendant(NativeCopyControl.CopyButton.self, in: host)).performClick(nil)
            XCTAssertEqual(NSPasteboard.general.string(forType: .string), source)
        }
    }

    @MainActor
    func testSettingsMenuPrefetchIsAtomicCoalescedPersistentAndContainsNoSavedValues() async throws {
        let api = ChatAPI()
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = ClientModel(defaults: defaults, api: api, health: health)
        let catalog = try JSONDecoder().decode(JSONValue.self, from: Data("""
        {"revision":"r1","setup_complete":true,"setup_notice":"private-notice","instructions":"private-instructions",
         "agent_yaml":"private-source","credential_names":["private-key-name"],
         "groups":[{"id":"email","title":"Email","basic":true,"destination":"connections"}],
         "settings":[{"group":"email","key":"EMAIL_ACCOUNT","label":"Account","value":"private-saved-value",
          "secret":true,"boolean":false,"editable":true,"default":"private-default",
          "metadata":{"level":"basic","description":"private-description","default":"private-metadata-default"}}]}
        """.utf8))
        await api.setSettingsCatalog(catalog)
        await api.pauseNextRead("configuration/catalog")
        let first = Task { try await model.configurationCatalog() }
        for _ in 0..<100 {
            if await api.readIsPaused("configuration/catalog") { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let paused = await api.readIsPaused("configuration/catalog")
        XCTAssertTrue(paused)
        let second = Task { try await model.configurationCatalog() }
        await Task.yield()
        XCTAssertNil(model.settingsMenu, "No partial static menu should become ready during the catalog read")
        await api.resumeRead("configuration/catalog")
        _ = try await (first.value, second.value)
        let resources = await api.resources
        XCTAssertEqual(resources.filter { $0 == "configuration/catalog" }.count, 1)
        let menu = try XCTUnwrap(model.settingsMenu)
        XCTAssertEqual(SettingsNavigation(menu).pages(in: .connections).map(\.id), ["email"])
        let stored = try XCTUnwrap(defaults.data(forKey: "assistant.settingsMenu.\(health.instanceID)"))
        XCTAssertFalse(String(decoding: stored, as: UTF8.self).contains("private-"))
        let restored = ClientModel(defaults: defaults, api: api, health: health)
        XCTAssertEqual(restored.settingsMenu?.groups?.map(\.id), ["email"])
        XCTAssertEqual(restored.settingsMenu?.settings.first?.value, "")
        XCTAssertNil(restored.settingsMenu?.settings.first?.defaultValue)
        let otherHealth = InstanceHealth(apiVersion: 2, instanceID: "different", name: "Other", capabilities: [], readOnly: false)
        XCTAssertNil(ClientModel(defaults: defaults, api: api, health: otherHealth).settingsMenu)
        model.configurationDirty = true
        model.invalidateResources()
        XCTAssertNotNil(model.settingsMenu)
        var updated = try XCTUnwrap(catalog["groups"]?.array)
        updated.append(.object(["id": .string("models"), "title": .string("Models"), "basic": .bool(true)]))
        guard case .object(var object) = catalog else { return XCTFail("Expected object") }
        object["groups"] = .array(updated)
        object["settings"] = .array((catalog["settings"]?.array ?? []) + [.object([
            "group": .string("models"), "key": .string("MODEL"), "label": .string("Model"), "value": .string(""),
            "secret": .bool(false), "boolean": .bool(false), "editable": .bool(true)
        ])])
        await api.setSettingsCatalog(.object(object))
        _ = try await model.configurationCatalog()
        XCTAssertEqual(model.settingsMenu?.groups?.map(\.id), ["email", "models"])
        XCTAssertEqual(SettingsNavigation(try XCTUnwrap(model.settingsMenu)).pages(in: .models).map(\.id), ["models"])
        XCTAssertTrue(model.configurationDirty, "Menu refresh must not discard an active draft")
        model.configurationDirty = false
        await model.disconnect()
        XCTAssertNil(model.settingsMenu)
    }

    @MainActor
    func testNativeSplitViewRemembersAdjustedWidthAcrossRecreation() async throws {
        let name = "AssistantTests.Split.\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: "NSSplitView Subview Frames \(name)") }
        func makeWindow() -> (NSWindow, NSHostingView<some View>) {
            let host = NSHostingView(rootView: HSplitView {
                Color.clear.frame(minWidth: 220, idealWidth: 270, maxWidth: 380)
                    .background(SplitViewAutosave(name: name, defaultLeadingWidth: 270))
                Color.clear.frame(minWidth: 340)
            })
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 400),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            return (window, host)
        }
        let (firstWindow, firstHost) = makeWindow()
        defer { firstWindow.close() }
        try await Task.sleep(for: .milliseconds(150))
        let first = try XCTUnwrap(descendant(NSSplitView.self, in: firstHost))
        XCTAssertEqual(first.autosaveName, name)
        XCTAssertEqual(try XCTUnwrap(first.arrangedSubviews.first).frame.width, 270, accuracy: 2)
        first.setPosition(330, ofDividerAt: 0)
        try await Task.sleep(for: .milliseconds(150))
        let width = try XCTUnwrap(first.arrangedSubviews.first).frame.width
        XCTAssertEqual(width, 330, accuracy: 2)
        firstWindow.close()
        let (secondWindow, secondHost) = makeWindow()
        defer { secondWindow.close() }
        try await Task.sleep(for: .milliseconds(150))
        let second = try XCTUnwrap(descendant(NSSplitView.self, in: secondHost))
        XCTAssertEqual(second.autosaveName, name)
        XCTAssertEqual(try XCTUnwrap(second.arrangedSubviews.first).frame.width, width, accuracy: 2)
    }

    func testToolDetailPreparationPreservesFullJSONAndReportsFormattingErrors() throws {
        let value = JSONValue.object(["result": .array([.string("Line one\nLine two"), .bool(true)])])
        let source = try XCTUnwrap(ChatJSON.Document.value(value).formatted())
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: Data(source.utf8)), value)
        XCTAssertThrowsError(try ChatJSON.Document.value(.number(.infinity)).formatted())
    }

    func testMenuRefreshKeepsLoadedValuesButNotObsoleteFieldPresentation() throws {
        let data = Data("""
        {"revision":"r1","setup_complete":true,"setup_notice":"","instructions":"",
         "settings":[{"group":"email","key":"EMAIL_ACCOUNT","label":"Account","value":"",
          "secret":false,"boolean":false,"editable":true,"metadata":{"level":"basic"}}]}
        """.utf8)
        var old = try Wire.decoder().decode(FullConfiguration.self, from: data)
        old.settings[0].value = "saved@example.invalid"
        var current = old
        current.settings[0].value = ""
        current.settings[0].metadata = .object(["level": .string("advanced"), "help": .string("Updated explanation")])
        current.mergeLoadedValues(["EMAIL_ACCOUNT": old.settings[0]])
        XCTAssertEqual(current.settings[0].value, "saved@example.invalid")
        XCTAssertEqual(current.settings[0].metadata?["level"], .string("advanced"))
        XCTAssertEqual(current.settings[0].help, "Updated explanation")
    }

    @MainActor
    func testJSONDetailsShowLoadingAndUseABoundedSelectableViewport() async throws {
        let value = JSONValue.array((0..<10_000).map { .object(["row": .integer(Int64($0))]) })
        let host = NSHostingView(rootView: ChatJSON(value: value))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 420),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        XCTAssertNotNil(descendant(NSProgressIndicator.self, in: host))
        for _ in 0..<100 {
            if descendant(NSTextView.self, in: host) != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let text = try XCTUnwrap(descendant(NSTextView.self, in: host))
        XCTAssertFalse(text.isEditable)
        XCTAssertTrue(text.isSelectable)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: Data(text.string.utf8)), value)
        XCTAssertLessThanOrEqual(try XCTUnwrap(text.enclosingScrollView).bounds.height, 360)
        let current = JSONValue.object(["current": .bool(true)])
        host.rootView = ChatJSON(value: current)
        host.layoutSubtreeIfNeeded()
        for _ in 0..<100 {
            if let text = descendant(NSTextView.self, in: host),
               (try? JSONDecoder().decode(JSONValue.self, from: Data(text.string.utf8))) == current { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: Data(try XCTUnwrap(descendant(NSTextView.self, in: host)).string.utf8)), current)
    }

    @MainActor
    func testReminderReadStateSurvivesRelaunchWithoutOverwritingChatCache() async throws {
        let api = ChatAPI()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let model = ClientModel(defaults: defaults, api: api, health: health)
        let reminder = Conversation(threadID: "reminder:daily:7", channel: "reminder", messageCount: 2,
                                    openingMessage: "Daily briefing", lastActivityAt: "2026-11-19T10:00:00Z",
                                    latestTaskID: 7, latestTaskStatus: "completed", latestTaskSummary: "Briefing",
                                    workstreamTitle: nil)
        await api.setConversations([reminder])
        try await model.reminderRuns.loadConversations(model)
        model.reminderRuns.setRead(true, conversation: reminder)
        await api.setConversations([])
        try await model.chats.loadConversations(model)
        let restored = ClientModel(defaults: defaults, api: api, health: health)
        XCTAssertEqual(restored.reminderRuns.conversations, [reminder])
        XCTAssertFalse(restored.reminderRuns.isUnread(reminder))
        XCTAssertTrue(restored.chats.conversations.isEmpty)
        restored.reminderRuns.setRead(false, conversation: reminder)
        let unread = ClientModel(defaults: defaults, api: api, health: health)
        XCTAssertTrue(unread.reminderRuns.isUnread(reminder))
        let anotherHealth = InstanceHealth(apiVersion: 2, instanceID: "another", name: "Assistant",
                                           capabilities: [], readOnly: false)
        let another = ClientModel(defaults: defaults, api: api, health: anotherHealth)
        XCTAssertTrue(another.reminderRuns.conversations.isEmpty)
        XCTAssertTrue(another.reminderRuns.isUnread(reminder))
    }

    @MainActor
    func testSkillsPrefetchSharesBrowserCacheAndRetainsNavigationState() async throws {
        let api = ChatAPI()
        let health = InstanceHealth(apiVersion: 2, instanceID: "skills", name: "Assistant",
                                    capabilities: ["skills.manage", "skills.preferences"], readOnly: false)
        let model = ClientModel(defaults: try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)),
                                api: api, health: health)
        await model.prefetchSkills()
        XCTAssertEqual(model.skillsBrowser.entries.map(\.id), ["CALENDAR"])
        model.skillsBrowser.selected = model.skillsBrowser.entries.first
        _ = SkillsSettingsView(model: model)
        model.invalidateResources()
        _ = try await model.cachedSkillQuery(SkillPage.query(search: "", offset: 0, preferences: true))
        var queries = await api.queryPayloads
        XCTAssertEqual(queries.count, 1)
        XCTAssertEqual(queries.first?["arguments"]?["limit"], .integer(20))
        XCTAssertEqual(model.skillsBrowser.selected?.id, "CALENDAR")
        model.invalidateResources(includingSkills: true)
        await model.prefetchSkills()
        queries = await api.queryPayloads
        XCTAssertEqual(queries.count, 2)
        await model.disconnect()
        XCTAssertTrue(model.skillsBrowser.entries.isEmpty)
        XCTAssertNil(model.skillsBrowser.selected)
    }

    @MainActor
    func testConnectionInventoryRetriesTransientReadsAndRetainsLastGoodSnapshot() async throws {
        let api = ChatAPI()
        let model = ClientModel(defaults: try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)),
                                api: api, health: health)
        await api.failServices([.http(503), .http(502)])
        await model.refreshServices()
        var resources = await api.resources
        XCTAssertEqual(resources.count, 3)
        XCTAssertNil(model.servicesError)
        let lastGood = model.services
        XCTAssertFalse(lastGood.isEmpty)
        await api.failServices([.http(503), .http(503), .http(503)])
        await model.refreshServices()
        resources = await api.resources
        XCTAssertEqual(resources.count, 6)
        XCTAssertNotNil(model.servicesError)
        XCTAssertEqual(model.services, lastGood)
        await api.failServices([.http(401)])
        await model.refreshServices()
        resources = await api.resources
        XCTAssertEqual(resources.count, 7, "Authentication failures must not be retried")
    }

    /// Retaining hidden panes must not turn navigation into background reads or mark a chat read.
    @MainActor
    func testRetainedInactivePanesDoNotPollOrMarkRead() async throws {
        let api = ChatAPI()
        let model = ClientModel(defaults: try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)),
                                api: api, health: health)
        try await model.chats.loadConversations(model)
        let conversation = try XCTUnwrap(model.chats.conversations.first)
        model.chats.select(conversation)
        try await model.chats.refresh(model)
        let reads = await api.resources
        XCTAssertTrue(model.chats.isUnread(conversation))
        let host = NSHostingView(rootView: ZStack {
            InboxView(model: model, chat: model.chats, isVisible: false)
            ServicesView(model: model, isVisible: false)
        }.environment(\.scenePhase, .active))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        let afterMount = await api.resources
        XCTAssertEqual(afterMount, reads)
        XCTAssertTrue(model.chats.isUnread(conversation))
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

    /// Box-drawing and arrow glyphs must occupy the same cells as text and spaces.
    func testDiagramFontKeepsBoxDrawingAligned() throws {
        let font = try XCTUnwrap(NSFont(name: "Menlo", size: 13))
        let cellWidth = NSAttributedString(string: "M", attributes: [.font: font]).size().width
        for glyph in " ┌─┐│└┘├┤┬┴┼→▼▶" {
            XCTAssertEqual(NSAttributedString(string: String(glyph), attributes: [.font: font]).size().width,
                           cellWidth, accuracy: 0.01, "Diagram glyph \(glyph) must retain its cell width")
        }
    }

    /// Tables and diagrams remain bounded in narrow transcripts and both appearances.
    @MainActor
    func testMarkdownTableAndDiagramLayoutInBothAppearances() async throws {
        let source = """
        ## Outcome metrics

        | Metric | What it measures | How to compute |
        |:---|:---:|---:|
        | **Task completion** | Did the agent achieve the task's success criteria? | Binary or partial-credit per task, averaged over the suite |
        | Pass@k | Capability ceiling | At least 1 of k independent runs succeeds |

        ---

        ```
        ┌──────────────────────────────────────────────────────────────┐
        │                         TEST RUNNER                          │
        │ ┌─────────────┐    ┌───────────────┐    ┌───────────────────┐ │
        │ │ Test suite  │───▶│ Environment   │───▶│ Injection         │ │
        │ └─────────────┘    └───────────────┘    └───────────────────┘ │
        └──────────────────────────────────────────────────────────────┘
        ```
        """
        for appearance in [ColorScheme.light, .dark] {
            let host = NSHostingView(rootView: MarkdownContent(text: source)
                .padding(16).environment(\.colorScheme, appearance))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.close() }
            for width in [800.0, 420.0] {
                window.setContentSize(NSSize(width: width, height: 500))
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(150))
                XCTAssertLessThan(host.fittingSize.height, 500, "Horizontal scrollers must not add empty height")
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])),
                                               uniformTypeIdentifier: "public.png")
                attachment.name = "Markdown table and diagram \(appearance) \(width)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    @MainActor
    private func descendant<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        return view.subviews.lazy.compactMap { self.descendant(type, in: $0) }.first
    }

    /// The reported diagram retains its exact spaces and line breaks without narrow-window wrapping.
    @MainActor
    func testReportedDiagramPreservesSourceAndScrollsHorizontally() async throws {
        let diagram = """
        ┌─────────────────────────────────────────────────────┐
        │                   TEST RUNNER                        │
        │  (Python script, orchestrates the whole suite)       │
        │                                                      │
        │  ┌───────────┐    ┌──────────────┐   ┌───────────┐ │
        │  │ Test Case  │───▶│ Environment  │──▶│ Injection │ │
        │  │ Suite      │    │ Setup       │   │           │ │
        │  │ (YAML/JSON)│    │ (fresh       │   │ Send test │ │
        │  │            │    │  container) │   │ email via │ │
        │  └───────────┘    └──────────────┘   │ SMTP/IMAP │ │
        │                                       └─────┬─────┘ │
        │                                             │       │
        │                                             ▼       │
        │              ┌──────────────────────────────────┐   │
        │              │   rb81/assistant (Docker)         │   │
        │              │   ┌─────────────────────────┐     │   │
        │              │   │ LLM (OpenRouter)        │     │   │
        │              │   │ Tools (email, cal,      │     │   │
        │              │   │ files, web, scripts...) │     │   │
        │              │   │ Memory, approval gates  │     │   │
        │              │   └─────────────────────────┘     │   │
        │              └──────────────┬───────────────────┘   │
        │                             │                        │
        │                             ▼                        │
        │              ┌──────────────────────────────────┐   │
        │              │   Response Capture               │   │
        │              │   - Poll IMAP for reply email    │   │
        │              │   - OR intercept via dashboard   │   │
        │              │     API (no email needed)        │   │
        │              │   - Capture OTLP traces          │   │
        │              └──────────────┬───────────────────┘   │
        │                             │                        │
        │                             ▼                        │
        │              ┌──────────────────────────────────┐   │
        │              │   Grading Layer                   │   │
        │              │   ┌────────────┐ ┌────────────┐  │   │
        │              │   │Deterministic│ │ LLM Judge  │  │   │
        │              │   │ Validators  │ │ (rubric-    │  │   │
        │              │   │ (check side │ │  based,     │  │   │
        │              │   │  effects,   │ │  calibrated)│  │   │
        │              │   │  files, cal)│ │             │  │   │
        │              │   └────────────┘ └────────────┘  │   │
        │              └──────────────┬───────────────────┘   │
        │                             │                        │
        │                             ▼                        │
        │              ┌──────────────────────────────────┐   │
        │              │   Results Store                   │   │
        │              │   - JSON per run: task, config,   │   │
        │              │     outcome, metrics, trace       │   │
        │              │   - Time-series for regression    │   │
        │              │     tracking                      │   │
        │              └──────────────────────────────────┘   │
        └─────────────────────────────────────────────────────┘
        """
        let source = "```\n\(diagram)\n```"
        let parsed = try ClientMarkdownParser().attributedString(for: source)
        XCTAssertEqual(String(parsed.characters), diagram + "\n")
        for appearance in [ColorScheme.light, .dark] {
            let host = NSHostingView(rootView: VStack(alignment: .leading, spacing: 0) {
                MarkdownContent(text: source)
                Spacer(minLength: 0)
            }.padding(16).environment(\.colorScheme, appearance))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 1100),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.close() }
            var wideHeight: CGFloat?
            for width in [800.0, 420.0] {
                window.setContentSize(NSSize(width: width, height: 1100))
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(250))
                let scroll = try XCTUnwrap(descendant(NSScrollView.self, in: host))
                let document = try XCTUnwrap(scroll.documentView)
                if let wideHeight {
                    XCTAssertEqual(document.bounds.height, wideHeight, accuracy: 2,
                                   "Narrowing a diagram must not wrap lines or change its height")
                    XCTAssertGreaterThan(document.bounds.width, scroll.contentView.bounds.width,
                                         "The complete unwrapped diagram must remain horizontally scrollable")
                } else {
                    wideHeight = document.bounds.height
                }

                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])),
                                               uniformTypeIdentifier: "public.png")
                attachment.name = "Reported diagram \(appearance) \(width)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    /// Rasterized table borders include the bottom edge, with real trailing padding even at document end.
    @MainActor
    func testMarkdownTableHasBottomBorderAndPaddingInBothAppearances() async throws {
        let source = """
        | Metric | What it measures | How to compute |
        |---|---|---|
        | Task completion | Did the agent achieve the task's success criteria? | Binary or partial credit averaged over the suite |
        | Pass@k | Capability ceiling for repeated independent attempts | At least one of k independent runs succeeds |
        """
        for appearance in [ColorScheme.light, .dark] {
            var renderedSize = CGSize.zero
            let host = NSHostingView(rootView: VStack(alignment: .leading, spacing: 0) {
                MarkdownContent(text: source)
                    .onGeometryChange(for: CGSize.self, of: \.size) { renderedSize = $0 }
                Spacer(minLength: 0)
            }.padding(16).background(appearance == .light ? Color.white : Color.black)
                .environment(\.colorScheme, appearance))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 500),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.close() }
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(250))
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let scale = CGFloat(bitmap.pixelsHigh) / host.bounds.height
            let topColor = try XCTUnwrap(
                bitmap.colorAt(x: bitmap.pixelsWide / 2, y: Int(16 * scale))?.usingColorSpace(.sRGB)
            )
            let border = [topColor.redComponent, topColor.greenComponent, topColor.blueComponent]
            var strokeRows: [Int] = []
            for y in 0..<bitmap.pixelsHigh {
                var matching = 0
                for x in stride(from: 0, to: bitmap.pixelsWide, by: 4) {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    if zip([color.redComponent, color.greenComponent, color.blueComponent], border)
                        .allSatisfy({ abs($0 - $1) < 0.025 }) {
                        matching += 1
                    }
                }
                if matching > bitmap.pixelsWide / 8 { strokeRows.append(y) }
            }
            let edges = strokeRows.enumerated().filter { index, y in
                index == 0 || y > strokeRows[index - 1] + 1
            }
            XCTAssertEqual(edges.count, 4,
                           "Header and two rows need four complete borders in \(appearance); rows \(strokeRows)")
            let bottom = CGFloat(try XCTUnwrap(strokeRows.last)) * host.bounds.height / CGFloat(bitmap.pixelsHigh) - 16
            XCTAssertGreaterThanOrEqual(renderedSize.height - bottom, 15,
                                        "Final table padding in \(appearance): size \(renderedSize), bottom \(bottom), rows \(strokeRows)")
            let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])),
                                           uniformTypeIdentifier: "public.png")
            attachment.name = "Complete table borders \(appearance)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    /// Thematic breaks must paint a visible rule, not merely survive parsing as an intent.
    @MainActor
    func testMarkdownHorizontalRuleRendersInBothAppearances() async throws {
        for appearance in [ColorScheme.light, .dark] {
            let host = NSHostingView(rootView: VStack(alignment: .leading, spacing: 0) {
                MarkdownContent(text: "Before the rule.\n\n---\n\nAfter the rule.")
                Spacer(minLength: 0)
            }.padding(16).background(appearance == .light ? Color.white : Color.black)
                .environment(\.colorScheme, appearance))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 250),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.close() }
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(250))
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let background = try XCTUnwrap(bitmap.colorAt(x: 0, y: 0)?.usingColorSpace(.sRGB))
            let backgroundComponents = [background.redComponent, background.greenComponent, background.blueComponent]
            let hasRule = (0..<bitmap.pixelsHigh).contains { y in
                var matching = 0
                for x in stride(from: 0, to: bitmap.pixelsWide, by: 4) {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    if zip([color.redComponent, color.greenComponent, color.blueComponent], backgroundComponents)
                        .contains(where: { abs($0 - $1) > 0.025 }) {
                        matching += 1
                    }
                }
                return matching > bitmap.pixelsWide * 3 / 16
            }
            XCTAssertTrue(hasRule, "A horizontal rule must span most of the Markdown viewport in \(appearance)")
            let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])),
                                           uniformTypeIdentifier: "public.png")
            attachment.name = "Markdown horizontal rule \(appearance)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
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
    func testProviderCatalogCachesFullAndZDRListsSeparately() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let loader = CatalogFixture()
        let catalog = OpenRouterCatalog(defaults: defaults, loader: loader)
        await catalog.refreshProviders(zdr: false)
        await catalog.refreshProviders(zdr: true)
        XCTAssertEqual(catalog.providers(zdr: false).map(\.id), ["example", "other"])
        XCTAssertEqual(catalog.providers(zdr: true).map(\.id), ["example"])
        let restored = OpenRouterCatalog(defaults: defaults, loader: loader)
        XCTAssertEqual(restored.providers(zdr: true).map(\.id), ["example"])
        XCTAssertEqual(restored.providers(zdr: false).map(\.id), ["example", "other"])
        await loader.fail()
        await restored.refreshProviders(zdr: true, force: true)
        XCTAssertNotNil(restored.providerErrors[true])
        XCTAssertEqual(restored.providers(zdr: true).map(\.id), ["example"])
    }

    func testProviderEndpointsDecodeAndDeduplicateRoutingSlugs() throws {
        let endpoints = """
        [{"provider_name":"DeepInfra","tag":"deepinfra/fp4"},
         {"provider_name":"DeepInfra","tag":"deepinfra/turbo"},
         {"provider_name":"Azure","tag":"azure"}]
        """
        let full = try PublicOpenRouterCatalog.decodeProviderEndpoints(
            Data("{\"data\":{\"endpoints\":\(endpoints)}}".utf8), zdr: false)
        let zdr = try PublicOpenRouterCatalog.decodeProviderEndpoints(
            Data("{\"data\":\(endpoints)}".utf8), zdr: true)
        XCTAssertEqual(try PublicOpenRouterCatalog.providerChoices(full).map(\.id), ["azure", "deepinfra"])
        XCTAssertEqual(try PublicOpenRouterCatalog.providerChoices(zdr).map(\.id), ["azure", "deepinfra"])
        XCTAssertThrowsError(try PublicOpenRouterCatalog.decodeProviderEndpoints(Data("{}".utf8), zdr: true))
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

    /// Overview discovery rejects older servers without substituting an empty successful page.
    @MainActor
    func testModelOverviewRequiresCapabilityAndValidatesRevision() async throws {
        let api = PreviewManagementAPI()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let oldHealth = InstanceHealth(apiVersion: 2, instanceID: "overview", name: "Assistant",
                                      capabilities: [], readOnly: false)
        let unsupported = ClientModel(defaults: defaults, api: api, health: oldHealth)
        do {
            _ = try await unsupported.modelSettingsOverview(revision: "r")
            XCTFail("An unsupported server must explain the missing feature")
        } catch {
            XCTAssertEqual(error as? ClientError, .serverOutdated("model settings overview"))
        }
        let health = InstanceHealth(apiVersion: 2, instanceID: "overview", name: "Assistant",
                                    capabilities: ["configuration.model-settings"], readOnly: false)
        let model = ClientModel(defaults: defaults, api: api, health: health)
        let revision = String(repeating: "0", count: 64)
        let overview = try await model.modelSettingsOverview(revision: revision)
        XCTAssertEqual(overview.sections.map(\.id), ["task", "research", "speech"])
        XCTAssertFalse(try XCTUnwrap(overview.sections.last?.enabled))
        XCTAssertEqual(overview.matchingSections("speech").map(\.id), ["speech"])
        XCTAssertTrue(overview.matchingSections("temperature").isEmpty)
        XCTAssertEqual(overview.matchingSections("").first?.selections.map(\.id), ["AGENT_LLM_MODEL"])
        XCTAssertEqual(overview.sections.first?.relatedSettings?.map(\.group), ["models", "catalog:llm"])
        XCTAssertEqual(overview.sections[1].summary.first?.valueSource, .inherited)
        let secret = try XCTUnwrap(overview.sections[0].settings.first { $0.field.secret })
        XCTAssertEqual(secret.field.value, "")
        XCTAssertEqual(secret.displayValue, "Configured")
        do {
            _ = try await model.modelSettingsOverview(revision: "stale")
            XCTFail("A stale overview must not merge with an editing draft")
        } catch {
            guard case .operationFailed = error as? ClientError else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    /// Provider catalogs validate their route identity and never accept duplicate model IDs.
    func testProviderModelCatalogValidatesProviderAndUniqueIdentifiers() throws {
        let valid = ProviderModelCatalog(
            provider: "anthropic",
            models: [ProviderModel(id: "claude-sonnet-4-6", name: "Claude Sonnet")],
            zdrOnly: true,
            warning: "Verify account eligibility."
        )
        XCTAssertNoThrow(try valid.validate())
        let duplicate = ProviderModelCatalog(
            provider: "openai",
            models: [
                ProviderModel(id: "gpt-4.1", name: "GPT-4.1"),
                ProviderModel(id: "gpt-4.1", name: "Duplicate"),
            ],
            zdrOnly: false,
            warning: nil
        )
        XCTAssertThrowsError(try duplicate.validate())
    }

    /// Discovery requires the advertised server capability and decodes only provider model metadata.
    @MainActor
    func testProviderModelDiscoveryRequiresCapabilityAndDecodesCatalog() async throws {
        let api = PreviewManagementAPI()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let unsupported = ClientModel(
            defaults: defaults, api: api,
            health: InstanceHealth(apiVersion: 2, instanceID: "catalog", name: "Assistant",
                                   capabilities: [], readOnly: false)
        )
        do {
            _ = try await unsupported.providerModelCatalog()
            XCTFail("An unsupported server must explain the missing feature")
        } catch {
            XCTAssertEqual(error as? ClientError, .serverOutdated("provider model discovery"))
        }
        let model = ClientModel(
            defaults: defaults, api: api,
            health: InstanceHealth(apiVersion: 2, instanceID: "catalog", name: "Assistant",
                                   capabilities: ["configuration.model-catalog"], readOnly: false)
        )
        let catalog = try await model.providerModelCatalog()
        XCTAssertEqual(catalog.provider, "openai")
        XCTAssertEqual(catalog.models.map(\.id), ["gpt-4.1"])
        XCTAssertTrue(catalog.zdrOnly)
    }

    /// Back and forward preserve subpage/search state, and a new visit abandons the forward branch.
    func testNavigationHistoryRestoresSettingsVisitsAndBranches() {
        let initial = SettingsLocation()
        let models = SettingsLocation(category: .models, page: .modelOverview, search: "speech")
        let tuning = SettingsLocation(category: .advanced, page: .group("catalog:llm"))
        var history = NavigationHistory(initial)
        history.visit(models)
        history.visit(models)
        history.visit(tuning)
        history.back()
        XCTAssertEqual(history.current, models)
        history.back()
        XCTAssertEqual(history.current, initial)
        XCTAssertFalse(history.canGoBack)
        history.forward()
        XCTAssertEqual(history.current, models)
        history.update(SettingsLocation(category: .models, page: .modelOverview, search: "research"))
        history.visit(tuning)
        XCTAssertFalse(history.canGoForward)
        history.back()
        XCTAssertEqual(history.current.search, "research")
    }

    /// Shared offset storage separates the same group in different categories and searches.
    @MainActor
    func testScrollMemoryPreservesExactOffsetsForEachSettingsLocation() {
        let memory = ScrollMemory()
        let models = SettingsLocation(category: .models, page: .group("models"))
        let advanced = SettingsLocation(category: .advanced, page: .group("models"))
        let filtered = SettingsLocation(category: .models, page: .group("models"), search: "fallback")
        memory.remember(CGPoint(x: 0, y: 437.5), for: models)
        memory.remember(CGPoint(x: 0, y: 918.25), for: advanced)
        XCTAssertEqual(memory.offset(for: models).y, 437.5)
        XCTAssertEqual(memory.offset(for: advanced).y, 918.25)
        XCTAssertEqual(memory.offset(for: filtered), .zero)
    }

    /// Recreating a native scroll view restores its viewport after visiting a different page.
    @MainActor
    func testRememberedScrollRestoresNativeViewport() async throws {
        let memory = ScrollMemory()
        func page(_ key: String) -> some View {
            ScrollView {
                VStack { Color.clear.frame(height: 1800) }
            }
            .rememberingScroll(key, in: memory)
            .id(key)
        }
        let host = NSHostingView(rootView: page("models"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        func scrollView(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
        }
        try await Task.sleep(for: .milliseconds(150))
        let original = try XCTUnwrap(scrollView(in: host))
        original.contentView.scroll(to: CGPoint(x: 0, y: 437.5))
        original.reflectScrolledClipView(original.contentView)
        try await Task.sleep(for: .milliseconds(150))
        let expected = original.contentView.bounds.origin.y
        XCTAssertGreaterThan(expected, 400)
        host.rootView = page("safety")
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(memory.offset(for: "models").y, expected, accuracy: 1)
        host.rootView = page("models")
        try await Task.sleep(for: .milliseconds(150))
        let restored = try XCTUnwrap(scrollView(in: host))
        XCTAssertEqual(restored.contentView.bounds.origin.y, expected, accuracy: 1)
    }

    /// Credential read-back and malformed field identity must never render as a valid overview.
    func testModelOverviewRejectsSecretsAndDuplicateFields() throws {
        let field = """
        {"group":"models","key":"AGENT_LLM_OPENROUTER_API_KEY","label":"OpenRouter API key",
         "value":"accidental-secret","secret":true,"boolean":false,"editable":true,
         "display_value":"Configured","value_source":"credential_status","pending_activation":false}
        """
        XCTAssertThrowsError(try Wire.decoder().decode(ModelOverviewField.self, from: Data(field.utf8)))
        let ordinary = """
        {"group":"models","key":"MODEL","label":"Model","value":"example/model","secret":false,
         "boolean":false,"editable":true,"display_value":"example/model",
         "value_source":"configured","pending_activation":false}
        """
        let duplicated = """
        {"api_version":2,"revision":"r","value_state":"saved","read_only":true,
         "activation_tracked":false,"pending_activation":false,"sections":[
          {"id":"task","title":"Task","provider":"example","summary_keys":["MODEL"],
           "settings":[\(ordinary),\(ordinary)]}]}
        """
        let overview = try Wire.decoder().decode(ModelSettingsOverview.self, from: Data(duplicated.utf8))
        XCTAssertThrowsError(try overview.validate(revision: "r"))
    }

    /// Settings destinations added with provider routing remain valid overview links.
    func testModelOverviewAcceptsAllCurrentSettingsDestinations() throws {
        for destination in ["providers", "knowledge", "operations"] {
            let json = """
            {"api_version":2,"revision":"r","value_state":"saved","read_only":true,
             "activation_tracked":false,"pending_activation":false,"sections":[
              {"id":"task","title":"Task responses","provider":"openrouter","summary_keys":["MODEL"],
               "selection_keys":[],"related_settings":[
                {"group":"providers","title":"Provider settings","destination":"\(destination)","field_key":"MODEL"}],
               "settings":[{"group":"providers","key":"MODEL","label":"Model","value":"example/model",
                "secret":false,"boolean":false,"editable":true,"display_value":"example/model",
                "value_source":"configured","pending_activation":false}]}]}
            """
            let overview = try Wire.decoder().decode(ModelSettingsOverview.self, from: Data(json.utf8))
            XCTAssertNoThrow(try overview.validate(revision: "r"))
        }
    }

    /// Privacy and fallback choices are discovered by the server, not typed as comma-separated IDs.
    @MainActor
    func testProviderSettingChoicesRequireCapabilityAndDecodeLabels() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let api = PreviewManagementAPI()
        let unsupported = ClientModel(defaults: defaults, api: api,
                                      health: InstanceHealth(apiVersion: 2, instanceID: "choices",
                                                             name: "Assistant", capabilities: [], readOnly: false))
        do {
            _ = try await unsupported.settingChoices(key: "AGENT_LLM_ZDR_VERIFIED_MODELS")
            XCTFail("An older server must explain that choices are unavailable")
        } catch {
            XCTAssertEqual(error as? ClientError, .serverOutdated("provider setting choices"))
        }
        let model = ClientModel(defaults: defaults, api: api,
                                health: InstanceHealth(apiVersion: 2, instanceID: "choices", name: "Assistant",
                                                       capabilities: ["configuration.choices"], readOnly: false))
        let choices = try await model.settingChoices(key: "AGENT_LLM_ZDR_VERIFIED_MODELS")
        XCTAssertEqual(choices.choices, ["openai:gpt-4.1"])
        XCTAssertEqual(choices.choiceLabels["openai:gpt-4.1"], "OpenAI / GPT-4.1")
    }

    /// Image URLs are removed before Textual can schedule any attachment loading.
    @MainActor
    func testMarkdownImagesRemainAltTextWithoutAttachmentURLs() throws {
        let text = """
        ![A remote image](https://example.invalid/image.png)

        Inline ![a local image](file:///tmp/image.png) stays readable.

        ```
        ![literal code](https://example.invalid/code.png)
        ```
        """
        let content = try ClientMarkdownParser().attributedString(for: text)
        XCTAssertTrue(content.runs.allSatisfy { $0.imageURL == nil })
        let rendered = String(content.characters)
        XCTAssertTrue(rendered.contains("A remote image"))
        XCTAssertTrue(rendered.contains("a local image"))
        XCTAssertTrue(rendered.contains("![literal code](https://example.invalid/code.png)"))
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
    func providers(zdr: Bool) async throws -> [OpenRouterProvider] {
        if failing { throw URLError(.notConnectedToInternet) }
        return [OpenRouterProvider(id: "example", name: "Example")] +
            (zdr ? [] : [OpenRouterProvider(id: "other", name: "Other")])
    }
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
