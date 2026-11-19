import CryptoKit
import CoreGraphics
import Foundation
import XCTest
@testable import Assistant

/// Isolated transport and mutation tests never contact a real server or Docker installation.
final class AssistantTests: XCTestCase {
    /// Delete operations carry the reviewed revision and cannot be built for locked skills.
    func testSkillDeletionUsesReviewedRevision() throws {
        let editable = Data("""
        {"id":"CUSTOM","title":"Custom","description":"An example","revision":"7","locked":false,"overlay_for":"EMAIL"}
        """.utf8)
        let skill = try Wire.decoder().decode(SkillEntry.self, from: editable)
        XCTAssertEqual(skill.overlayFor, "EMAIL")
        XCTAssertNil(skill.body)
        XCTAssertEqual(skill.deletion()?["arguments"]?["revision"], .string("7"))
        XCTAssertEqual(skill.deletion()?["confirmed"], .bool(true))

        let locked = Data("""
        {"id":"EMAIL","title":"Email","description":"Compose email","revision":"shipped","locked":true,"body":"Instructions"}
        """.utf8)
        XCTAssertNil(try Wire.decoder().decode(SkillEntry.self, from: locked).deletion())
    }

    /// Only known bounded invalidations are accepted; incomplete and oversized frames cannot grow state.
    func testEventParserBoundsAndSeparatesFrames() throws {
        var parser = ManagementEventParser()
        XCTAssertNil(try parser.consume(": keepalive"))
        XCTAssertNil(try parser.consume("id: epoch:1"))
        XCTAssertNil(try parser.consume("event: approvals.changed"))
        XCTAssertEqual(try parser.consume(""), ManagementEvent(id: "epoch:1", kind: "approvals.changed"))
        XCTAssertNil(try parser.consume(""))
        XCTAssertNil(try parser.consume("event: unknown"))
        XCTAssertNil(try parser.consume("id: epoch:2"))
        XCTAssertNil(try parser.consume(""))
        XCTAssertThrowsError(try parser.consume("id: " + String(repeating: "x", count: 129)))
        XCTAssertThrowsError(try parser.consume("id: bad\u{0}cursor"))
        XCTAssertThrowsError(try parser.consume(String(repeating: "x", count: 4097)))
    }

    /// Deduplication survives relaunch and evicts the oldest ID rather than the lexicographically smallest.
    @MainActor
    func testNotificationDeduplicationRetainsRecentIDs() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        defaults.set(["fixture:z-old"] + (0..<999).map { "fixture:m-\($0)" }, forKey: "assistant.notified")
        let model = ClientModel(defaults: defaults, health: health)
        await model.addUpdate(id: "a-new", title: "Task completed", taskID: 7, category: "replies")
        XCTAssertEqual(defaults.stringArray(forKey: "assistant.notified")?.count, 1000)
        XCTAssertEqual(defaults.stringArray(forKey: "assistant.notified")?.last, "fixture:a-new")
        XCTAssertFalse(defaults.stringArray(forKey: "assistant.notified")?.contains("fixture:z-old") ?? true)
        let restored = ClientModel(defaults: defaults, health: health)
        await restored.addUpdate(id: "a-new", title: "Duplicate", taskID: 7, category: "replies")
        XCTAssertEqual(restored.activityUpdates.count, 1)
        XCTAssertEqual(restored.activityUpdates.first?.title, "Task completed")
        XCTAssertEqual(restored.unreadUpdates, 1)
        restored.markUpdatesSeen()
        XCTAssertEqual(ClientModel(defaults: defaults, health: health).unreadUpdates, 0)
    }

    /// Saving without applying remains visible across navigation and relaunch.
    @MainActor
    func testPendingActivationIsPersistedPerInstallation() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let model = ClientModel(defaults: defaults, health: health)
        model.recordActivation(.pending)
        XCTAssertEqual(ClientModel(defaults: defaults, health: health).activationState, .pending)
        model.recordActivation(.unknown)
        XCTAssertEqual(ClientModel(defaults: defaults, health: health).activationState, .unknown)
        let other = InstanceHealth(apiVersion: 2, instanceID: "other", name: "Other", capabilities: [], readOnly: false)
        XCTAssertEqual(ClientModel(defaults: defaults, health: other).activationState, .active)
    }

    /// Scope is a per-installation preference, not evidence that a thread belongs to this Mac.
    @MainActor
    func testChannelScopeSurvivesDisconnectAndIsIsolated() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let model = ClientModel(defaults: defaults, health: health)
        model.chats.channel = "telegram"
        await model.disconnect()
        let restored = ClientModel(defaults: defaults, health: health)
        XCTAssertEqual(restored.chats.channel, "telegram")
        try restored.chats.restoreCache(instance: "another-installation")
        XCTAssertEqual(restored.chats.channel, "")
    }

    /// A snapshot replaces sequential transcript reads without transforming tool argument keys.
    @MainActor
    func testConversationUsesSnapshotAndPreservesToolKeys() async throws {
        let api = ChatAPI()
        let snapshotHealth = InstanceHealth(apiVersion: 2, instanceID: "snapshot", name: "Assistant",
                                           capabilities: ["tasks.snapshot"], readOnly: false)
        let model = ClientModel(defaults: try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)),
                                api: api, health: snapshotHealth)
        try await model.chats.loadConversations(model)
        model.chats.select(try XCTUnwrap(model.chats.conversations.first))
        try await model.chats.refresh(model)
        XCTAssertEqual(model.chats.messages.first?.body, "Newest snapshot")
        XCTAssertEqual(model.chats.totalMessages, 51)
        XCTAssertEqual(model.chats.toolCalls.first?.input?["search_query"], .string("places"))
        let resources = await api.resources
        XCTAssertTrue(resources.contains("tasks/7/snapshot"))
        XCTAssertFalse(resources.contains(where: { $0.hasPrefix("tasks/7/messages") || $0.hasPrefix("tasks/7/activity") }))
    }

    /// Unread state survives relaunch, ignores clicks, and never marks newer list metadata as rendered.
    @MainActor
    func testUnreadConversationsPersistOnlyRenderedVersionsAndSortByInstant() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let api = ChatAPI()
        let model = ClientModel(defaults: defaults, api: api, health: health)
        try await model.chats.loadConversations(model)
        let original = try XCTUnwrap(model.chats.conversations.first)
        XCTAssertTrue(model.chats.isUnread(original))
        model.chats.select(original)
        model.chats.markRendered()
        XCTAssertTrue(model.chats.isUnread(original), "Selection alone is not reading")
        try await model.chats.refresh(model)
        model.chats.markRendered()
        XCTAssertFalse(model.chats.isUnread(original))

        var changed = original
        changed.latestTaskID += 1
        let newer = Conversation(threadID: "new", channel: "email", messageCount: 1, openingMessage: "New",
                                 lastActivityAt: "2026-11-16T12:00:00+01:00", latestTaskID: 9,
                                 latestTaskStatus: "completed", latestTaskSummary: nil, workstreamTitle: nil)
        await api.setConversations([changed, newer])
        try await model.chats.loadConversations(model)
        XCTAssertEqual(model.chats.conversations.map(\.threadID), ["new", original.threadID])
        model.chats.markRendered()
        XCTAssertTrue(model.chats.isUnread(changed), "An older transcript cannot clear a new task's unread state")
        let restored = ClientModel(defaults: defaults, api: api, health: health)
        XCTAssertFalse(restored.chats.isUnread(original))
        XCTAssertTrue(restored.chats.isUnread(changed))
        try restored.chats.restoreCache(instance: "other")
        XCTAssertTrue(restored.chats.conversations.isEmpty)
    }

    /// Reopened health pages retain an installation-scoped snapshot while their next read is in flight.
    @MainActor
    func testServiceSnapshotRendersWhileRefreshingAndDoesNotCrossInstances() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let api = ChatAPI()
        let first = ClientModel(defaults: defaults, api: api, health: health)
        await first.refreshServices()
        XCTAssertEqual(first.services.count, 1)
        let restored = ClientModel(defaults: defaults, api: api, health: health)
        XCTAssertEqual(restored.services.count, 1)
        await api.pauseNextRead("services")
        let refresh = Task { await restored.refreshServices() }
        try await waitForRead("services", api: api)
        XCTAssertTrue(restored.servicesLoading)
        XCTAssertEqual(restored.services.count, 1)
        await api.resumeRead("services")
        await refresh.value
        XCTAssertFalse(restored.servicesLoading)
        let otherHealth = InstanceHealth(apiVersion: 2, instanceID: "other", name: "Other", capabilities: [], readOnly: false)
        XCTAssertTrue(ClientModel(defaults: defaults, api: api, health: otherHealth).services.isEmpty)
    }

    /// Nested log content is rendered as JSON, not an escaped string inside another JSON document.
    func testServiceLogsAndCredentialActivationPresentation() throws {
        let text = try ServiceLogFormatting.prettyPrinted("worker | 2026-11-16 {\"level\":\"info\",\"message\":\"Ready\"}\nplain diagnostic")
        XCTAssertTrue(text.contains("\"level\" : \"info\""))
        XCTAssertTrue(text.hasSuffix("plain diagnostic"))
        XCTAssertFalse(text.contains("\\\"message\\\""))
        XCTAssertTrue(SavedCredential(name: "KEY", status: "configured").active)
        XCTAssertFalse(SavedCredential(name: "KEY", status: "activation pending").active)
        XCTAssertNotEqual(SavedCredential(name: "KEY", status: "configured").title,
                          SavedCredential(name: "KEY", status: "activation pending").title)
        XCTAssertFalse(ServiceAppearance.summary(state: "running", health: "healthy (daemon ping)").contains("daemon"))
    }

    /// Incomplete fences are common during generation; code must remain copyable without losing whitespace.
    func testMarkdownFencesPreserveSource() {
        XCTAssertEqual(MarkdownBlock.parse("Hello\n```swift\n  let x = 1\n```"), [
            .prose("Hello"), .code(language: "swift", source: "  let x = 1")
        ])
        XCTAssertEqual(MarkdownBlock.parse("~~~python\nprint('hi')\n"), [
            .code(language: "python", source: "print('hi')\n")
        ])
        XCTAssertEqual(MarkdownBlock.parse("````text\n```\n````"), [
            .code(language: "text", source: "```")
        ])
    }

    /// Blank lines separate paragraphs instead of rendering as empty rows; list items keep their own rows.
    func testMarkdownParagraphsJoinSoftBreaksAndKeepListRows() {
        XCTAssertEqual(MarkdownBlock.paragraphs("One\ntwo\n\n\nThree\n- a\n- b\n1. c"), [
            ["One\ntwo"], ["Three", "- a", "- b", "1. c"]
        ])
    }

    /// Tool calls appear between the messages they happened between, whatever the timestamp format.
    func testTimelinePlacesToolCallsBetweenMessages() throws {
        let messages = try Wire.decoder().decode([ChatMessage].self, from: Data("""
        [{"id":1,"kind":"request","channel":"email","body":"Find a venue","created_at":"2026-11-16T10:00:00Z"},
         {"id":2,"kind":"reply","channel":"email","body":"Found one","created_at":"2026-11-16T10:05:00.250Z"}]
        """.utf8))
        let calls = try JSONDecoder().decode([ToolCall].self, from: Data("""
        [{"id":"7:1","task_id":7,"created_at":"2026-11-16T10:01:00.123456+00:00","tool_name":"web_search",
          "status":"succeeded","input":{"search_query":"venues"}},
         {"id":"7:3","task_id":7,"created_at":"2026-11-16 10:06:00+00:00","tool_name":"calendar","status":"failed"}]
        """.utf8))
        XCTAssertEqual(calls[0].input?["search_query"], .string("venues"))
        XCTAssertEqual(TranscriptItem.timeline(messages: messages, calls: calls).map(\.id), [
            messages[0].id, "tools:7:1", messages[1].id, "tools:7:3"
        ])
    }

    /// Conversation rows title themselves from the opening request and reflect their latest execution.
    func testConversationTitleAndState() throws {
        let rows = try Wire.decoder().decode([Conversation].self, from: Data("""
        [
          {"thread_id":"a","channel":"telegram","message_count":3,"opening_message":"Book flights\\nfor May",
           "last_activity_at":"2026-11-16T10:00:00Z","latest_task_id":3,"latest_task_status":"deleted",
           "latest_task_summary":"[Deleted task]","workstream_title":"Travel"},
          {"thread_id":"b","channel":"email","message_count":1,"opening_message":"  ",
           "last_activity_at":"2026-11-15T10:00:00Z","latest_task_id":2,"latest_task_status":"running",
           "latest_task_summary":"Summarize inbox","workstream_title":null}
        ]
        """.utf8))
        XCTAssertEqual(rows.map(\.title), ["Book flights", "Summarize inbox"])
        XCTAssertTrue(rows[0].deleted)
        XCTAssertTrue(rows[1].active)
        XCTAssertEqual(Conversation.channelTitle("telegram"), "Telegram")
        XCTAssertEqual(Conversation.channelTitle("client"), "Assistant client")
    }

    /// Completion results commonly echo arguments; only genuinely different input is shown.
    func testToolDetailsSuppressEchoedFields() throws {
        let call = try JSONDecoder().decode(ToolCall.self, from: Data("""
        {"id":"7:1","task_id":7,"created_at":"2026-11-16T10:00:00Z","tool_name":"task_complete",
         "status":"succeeded","input":{"summary":"Done","response":"Answer","already_delivered":true},
         "output":{"summary":"Done","response":"Answer"}}
        """.utf8))
        XCTAssertEqual(call.distinctInput, .object(["already_delivered": .bool(true)]))
        let identical = try JSONDecoder().decode(ToolCall.self, from: Data("""
        {"id":"7:2","task_id":7,"created_at":"2026-11-16T10:00:00Z","tool_name":"task_complete",
         "status":"succeeded","input":{"response":"Answer"},"output":{"response":"Answer"}}
        """.utf8))
        XCTAssertNil(identical.distinctInput)
        XCTAssertEqual(identical.details, identical.output)
    }

    /// An obsolete read must not dismiss the current loader, and activity latency must not hide messages.
    @MainActor
    func testTranscriptLoadingIsOwnedByCurrentRefreshAndMessagesRenderBeforeActivity() async throws {
        let api = ChatAPI()
        let model = ClientModel(defaults: try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)),
                                api: api, health: health)
        try await model.chats.loadConversations(model)
        model.chats.select(try XCTUnwrap(model.chats.conversations.first))
        XCTAssertTrue(model.chats.loadingTranscript, "A cold selection must never start as a blank screen")
        await api.pauseNextRead("tasks/7/messages?page=0")
        let obsolete = Task { try await model.chats.refresh(model) }
        try await waitForRead("tasks/7/messages?page=0", api: api)
        await api.pauseNextRead("tasks/7/messages?page=1")
        await api.pauseNextRead("tasks/7/activity")
        let current = Task { try await model.chats.refresh(model) }
        try await waitForRead("tasks/7/messages?page=1", api: api)
        obsolete.cancel()
        await api.resumeRead("tasks/7/messages?page=0")
        do { try await obsolete.value; XCTFail("The obsolete read should be cancelled") }
        catch is CancellationError {}
        XCTAssertTrue(model.chats.loadingTranscript)
        await api.resumeRead("tasks/7/messages?page=1")
        try await waitForRead("tasks/7/activity", api: api)
        XCTAssertEqual(model.chats.messages.first?.body, "Newest page")
        XCTAssertFalse(model.chats.loadingTranscript)
        model.chats.newChat()
        model.chats.select(try XCTUnwrap(model.chats.conversations.first))
        XCTAssertEqual(model.chats.messages.first?.body, "Newest page")
        XCTAssertFalse(model.chats.loadingTranscript, "Messages stay cached even while activity is still loading")
        await api.resumeRead("tasks/7/activity")
        try await current.value
    }

    /// Scrolling up pauses following; new tool rows do not masquerade as deliberate user scrolling.
    func testTranscriptScrollFollowsGrowthButRespectsHistoryBrowsing() {
        var state = TranscriptScrollState()
        func frame(_ y: CGFloat, _ height: CGFloat) -> CGRect { CGRect(x: 0, y: y, width: 800, height: height) }
        state.update(frame: frame(0, 1000), viewportHeight: 400)
        state.update(frame: frame(-600, 1000), viewportHeight: 400)
        XCTAssertTrue(state.followsLatest)
        state.update(frame: frame(-600, 1200), viewportHeight: 400)
        XCTAssertTrue(state.followsLatest, "Growing tool rows must not disable live following")
        state.update(frame: frame(-400, 1200), viewportHeight: 400)
        XCTAssertFalse(state.followsLatest)
        state.update(frame: frame(-400, 1400), viewportHeight: 400)
        XCTAssertFalse(state.followsLatest, "New activity must not pull a reader out of history")
        state.update(frame: frame(-1000, 1400), viewportHeight: 400)
        XCTAssertTrue(state.followsLatest)
    }

    @MainActor
    private func waitForRead(_ prefix: String, api: ChatAPI) async throws {
        for _ in 0..<100 {
            if await api.readIsPaused(prefix) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Read did not reach its controlled pause: \(prefix)")
        throw ClientError.unavailable
    }

    /// Transcript metadata identifies external emails and decodes contained audio references.
    func testChatAttachmentAndExternalEmailMetadata() throws {
        let message = try Wire.decoder().decode(ChatMessage.self, from: Data("""
        {"id":3,"kind":"message","channel":"email","body":"Sent","created_at":"2026-11-16",
         "external":true,"recipients":["guest@example.com"],"subject":"Invitation",
         "attachments":[{"filename":"note.mp3","content_type":"audio/mpeg","size_bytes":12,
                         "available":true,"project_id":4,"file_id":8,"voice_note":true}]}
        """.utf8))
        XCTAssertEqual(message.external, true)
        XCTAssertEqual(message.recipients, ["guest@example.com"])
        let attachment = try XCTUnwrap(message.attachments?.first)
        XCTAssertTrue(attachment.audio)
        XCTAssertEqual(attachment.projectID, 4)
        XCTAssertEqual(attachment.fileID, 8)
    }

    /// Recreating the model and disconnecting preserve local snapshots, but identities never share history.
    @MainActor
    func testConversationCachePersistsAndClearsAcrossInstances() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let first = ClientModel(defaults: defaults, api: ChatAPI(), health: health)
        try await first.chats.loadConversations(first)
        first.chats.select(try XCTUnwrap(first.chats.conversations.first))
        try await first.chats.refresh(first)
        await first.disconnect()
        let restored = ClientModel(defaults: defaults, api: ChatAPI(), health: health)
        restored.chats.select(try XCTUnwrap(restored.chats.conversations.first))
        XCTAssertEqual(restored.chats.messages.first?.body, "Newest page")
        try restored.chats.restoreCache(instance: "another-installation")
        XCTAssertTrue(restored.chats.conversations.isEmpty)
        try restored.chats.restoreCache(instance: health.instanceID)
        XCTAssertEqual(restored.chats.conversations.count, 1)
        restored.chats.draft = "Keep this unsent draft"
        restored.chats.clearSavedCache()
        XCTAssertEqual(restored.chats.draft, "Keep this unsent draft")
        let cleared = ClientModel(defaults: defaults, api: ChatAPI(), health: health)
        XCTAssertTrue(cleared.chats.conversations.isEmpty)
    }

    /// Sending renders immediately and reconciliation uses request identity, never matching duplicate text.
    @MainActor
    func testOptimisticMessageAppearsBeforeSubmissionCompletes() async throws {
        let api = ChatAPI()
        let model = ClientModel(defaults: try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)),
                                api: api, health: health)
        model.clientID = String(repeating: "a", count: 32)
        model.chats.draft = "Immediate message"
        await api.pauseNextSubmission()
        let send = Task { await model.chats.send(model) }
        for _ in 0..<100 {
            if await api.submissionPaused { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(model.chats.sending)
        XCTAssertEqual(model.chats.pendingMessage?.body, "Immediate message")
        XCTAssertEqual(model.chats.timeline.count, 1)
        await api.resumeSubmission()
        await send.value
        XCTAssertNil(model.chats.pendingMessage)
        XCTAssertEqual(model.chats.messages.filter { $0.body == "Immediate message" }.count, 1)
    }

    /// Downloads reject corrupt/changing chunks and oversized files before exposing bytes to playback or save.
    @MainActor
    func testAttachmentDownloadsVerifyDigestAndBounds() async throws {
        for mode in [DownloadAPI.Mode.valid, .badDigest, .changingSize, .oversized] {
            let api = DownloadAPI(mode: mode)
            let model = ClientModel(defaults: try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)),
                                    api: api, health: health)
            do {
                let data = try await model.downloadFile(.project(4, 8))
                XCTAssertEqual(mode, .valid)
                XCTAssertEqual(data, Data("file".utf8))
            } catch {
                XCTAssertNotEqual(mode, .valid)
            }
        }
    }

    /// Cancelled view tasks are routine and must never surface as an error banner.
    func testCancellationIsNotPresentedAndServerMessagesAre() {
        XCTAssertNil(CancellationError().presentableMessage)
        XCTAssertNil(URLError(.cancelled).presentableMessage)
        let failure = HTTPManagementAPI.failure(status: 409, body: Data(#"{"error":{"message":"Docker is not running."}}"#.utf8))
        XCTAssertEqual(failure.httpStatus, 409)
        XCTAssertEqual(failure.presentableMessage, "Docker is not running.")
        XCTAssertEqual(HTTPManagementAPI.failure(status: 409, body: Data("oops".utf8)).httpStatus, 409)
    }

    /// Settings pages nest extra accounts under their provider and hide advanced groups until requested.
    func testSettingsNavigationNestsAccountsAndAdvancedGroups() throws {
        let configuration = try Wire.decoder().decode(FullConfiguration.self, from: Data("""
        {"revision":"r","setup_complete":true,"instructions":"","setup_notice":"",
         "settings":[
          {"group":"calendar","key":"AGENT_CALENDAR_ENABLED","label":"Enable calendar","value":"true","secret":false,
           "boolean":true,"editable":true,"metadata":{"section":"General","help":"Allow calendar tools."}},
          {"group":"calendar","key":"AGENT_CALENDAR_ZOHO_CLIENT_ID","label":"Client ID","value":"","secret":false,
           "boolean":false,"editable":true,"metadata":{"section":"Zoho"}},
          {"group":"calendar:zoho_2","key":"AGENT_CALENDAR_ZOHO_2_CLIENT_ID","label":"Client ID","value":"id",
           "secret":false,"boolean":false,"editable":true},
          {"group":"catalog:calendar","key":"AGENT_CALENDAR_TIMEZONE","label":"Timezone","value":"UTC","secret":false,
           "boolean":false,"editable":true,"default":"UTC"},
          {"group":"catalog:memory","key":"AGENT_MEMORY_TTL","label":"Memory lifetime","value":"7","secret":false,
           "boolean":false,"editable":true}
         ],
         "groups":[
          {"id":"calendar","title":"Calendar","parent":null,"basic":true},
          {"id":"calendar:zoho_2","title":"Zoho calendar 2","parent":"calendar","section":"Zoho","basic":false},
          {"id":"catalog:calendar","title":"Calendar defaults","parent":"calendar","basic":false},
          {"id":"catalog:memory","title":"Memory","parent":null,"basic":false}
         ]}
        """.utf8))
        let navigation = SettingsNavigation(configuration)
        XCTAssertEqual(navigation.essentials.map(\.id), ["calendar"])
        XCTAssertEqual(navigation.advanced.map(\.id), ["catalog:memory"])
        let sections = navigation.sections(in: "calendar")
        XCTAssertEqual(sections.map(\.title), ["General", "Zoho"])
        XCTAssertEqual(sections[1].accounts.map(\.id), ["calendar:zoho_2"])
        XCTAssertTrue(navigation.configured(sections[1].accounts[0]))
        XCTAssertTrue(navigation.subgroups(of: "calendar", includeAdvanced: false).isEmpty)
        XCTAssertEqual(navigation.subgroups(of: "calendar", includeAdvanced: true).map(\.id), ["catalog:calendar"])
        XCTAssertEqual(navigation.search("calendar tools").map(\.group.id), ["calendar"])
        XCTAssertEqual(navigation.path(sections[1].accounts[0]), "Calendar › Zoho calendar 2")
        XCTAssertEqual(navigation.fields(in: "catalog:calendar").first?.defaultText, "UTC")
    }

    /// Drafts cannot silently follow the user into a different thread, and deleted tasks reject sends.
    @MainActor
    func testDraftIsolationAndDeletedTaskCannotSend() async throws {
        let api = ChatAPI()
        let model = ClientModel(defaults: try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)),
                                api: api, health: health)
        model.clientID = String(repeating: "a", count: 32)
        let task = Conversation(threadID: "deleted-thread", channel: "client", messageCount: 1,
                                openingMessage: "Old", lastActivityAt: "2026-11-16", latestTaskID: 1,
                                latestTaskStatus: "deleted", latestTaskSummary: "[Deleted task]", workstreamTitle: nil)
        model.chats.conversations = [task]
        model.chats.draft = "New chat draft"
        model.chats.select(task)
        XCTAssertTrue(model.chats.draft.isEmpty)
        model.chats.draft = "Cannot reply"
        await model.chats.send(model)
        let submissions = await api.payloads
        XCTAssertTrue(submissions.isEmpty)
        model.chats.newChat()
        XCTAssertEqual(model.chats.draft, "New chat draft")
        model.chats.select(task)
        XCTAssertEqual(model.chats.draft, "Cannot reply")
    }

    /// Synthetic requests and replies use server routing; no manual workstream appears in the payload.
    @MainActor
    func testChatStartReplyAndUncertainSubmission() async throws {
        let api = ChatAPI()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let model = ClientModel(defaults: defaults, api: api, health: health)
        model.clientID = String(repeating: "a", count: 32)
        model.chats.draft = "A new conversation"
        await model.chats.send(model)
        let first = await api.payloads.first
        XCTAssertEqual(first?["operation"], .string("task.start"))
        XCTAssertNil(first?["workstream_id"])
        XCTAssertEqual(model.chats.selectedThread, "chat-thread")
        XCTAssertTrue(model.chats.draft.isEmpty)
        model.chats.draft = "A follow-up"
        await model.chats.send(model)
        let last = await api.payloads.last
        XCTAssertEqual(last?["operation"], .string("task.reply"))
        XCTAssertEqual(last?["task_id"], .integer(7))
        await api.loseNextSubmission()
        model.chats.draft = "Do not silently replay this"
        await model.chats.send(model)
        XCTAssertEqual(model.chats.draft, "Do not silently replay this")
        XCTAssertTrue(model.chats.error?.contains("unresolved") == true)
        XCTAssertEqual(model.references.count, 1)
    }

    /// The newest transcript page loads first; older messages are explicitly requested.
    @MainActor
    func testTranscriptLoadsLatestPageAndAcknowledgesOnlyRenderedDelivery() async throws {
        let api = ChatAPI()
        let model = ClientModel(defaults: try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)),
                                api: api, health: health)
        model.clientID = String(repeating: "a", count: 32)
        try await model.chats.loadConversations(model)
        model.chats.select(try XCTUnwrap(model.chats.conversations.first))
        try await model.chats.refresh(model)
        XCTAssertEqual(model.chats.messages.first?.body, "Newest page")
        try await model.chats.refresh(model, moreMessages: true)
        XCTAssertEqual(model.chats.messages.first?.body, "Oldest page")
        // Reopening a conversation shows its cached transcript before any read.
        model.chats.newChat()
        XCTAssertTrue(model.chats.messages.isEmpty)
        model.chats.select(try XCTUnwrap(model.chats.conversations.first))
        XCTAssertEqual(model.chats.messages.first?.body, "Oldest page")
        model.offeredIDs = [1, 2]
        await model.acknowledgeRendered(ids: [2])
        XCTAssertEqual(model.offeredIDs, [1])
    }

    /// Host validation rejects option injection and shell metacharacters but supports numeric hosts.
    func testSSHProfileValidation() throws {
        for host in ["-oProxyCommand=bad", "user@host;command", "host\nother", "host path"] {
            var profile = ConnectionProfile()
            profile.host = host
            XCTAssertThrowsError(try profile.validate())
        }
    }

    /// Valid aliases, user-qualified destinations, and numeric addresses remain supported.
    func testValidSSHProfiles() throws {
        for host in ["user@host", "my-alias", "192.0.2.1"] {
            var profile = ConnectionProfile()
            profile.host = host
            XCTAssertNoThrow(try profile.validate())
        }
    }

    /// Discovery version and API version are distinct; installation identity survives token rotation.
    func testWireContractsAndIdentityValidation() throws {
        let health = try Wire.decoder().decode(InstanceHealth.self, from: Data("""
        {"api_version":2,"instance_id":"instance-a","name":"Assistant","capabilities":["configuration.read"],"read_only":false}
        """.utf8))
        XCTAssertEqual(health.instanceID, "instance-a")
        XCTAssertNoThrow(try health.validate(expectedInstance: "instance-a"))
        XCTAssertThrowsError(try health.validate(expectedInstance: "instance-b"))
        let history = try Wire.decoder().decode(ClientHistory.self, from: Data("""
        {"messages":[{"id":1,"task_id":7,"purpose":"reply","body":"hello","created_at":"2026-11-15","status":"pending"}],"next_before_id":1}
        """.utf8))
        XCTAssertEqual(history.messages.first?.taskID, 7)
        XCTAssertEqual(history.nextBeforeID, 1)
    }

    /// Loopback credentials are rejected when helpers claim public hosts or malformed tokens.
    func testDiscoveryValidation() throws {
        let token = String(repeating: "a", count: 64)
        for (host, port) in [("public.example", 8765), ("127.0.0.1", 0)] {
            let discovery = ConnectionDiscovery(apiVersion: 1, host: host, port: port, token: token)
            XCTAssertThrowsError(try discovery.validate())
        }
        XCTAssertNoThrow(try ConnectionDiscovery(apiVersion: 1, host: "127.0.0.1", port: 8765, token: token).validate())
    }

    /// Request builders keep credentials on loopback and preserve encoded query parameters.
    func testAuthenticatedRequestAndPathContainment() throws {
        let api = try HTTPManagementAPI(port: 8765, token: "test-token")
        let payload = try JSONValue.parse("{\"operation\":\"search.maintenance\",\"action\":\"status\"}")
        let request = try api.makeRequest("operations", body: payload, key: "retry-key")
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:8765/v2/operations")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), "retry-key")
        XCTAssertEqual(request.httpMethod, "POST")
        for resource in ["https://public.example/v2/health", "//public.example", "../health", "%2e%2e/health", "/v2/health"] {
            XCTAssertThrowsError(try api.makeRequest(resource, body: nil, key: nil))
        }
        XCTAssertNoThrow(try api.makeRequest("records/tasks?query=hello..", body: nil, key: nil))
    }

    /// Dynamic domain keys retain their wire spelling through typed JSON round trips.
    func testDynamicArgumentsAndCredentialReviewRedaction() throws {
        let source = #"{"operation":"credential.replace","name":"API_KEY","value":"private-value","nested":{"api_key":"private-key","enabled":true}}"#
        let payload = try JSONValue.parse(source)
        let mutation = ReviewedMutation(title: "credential.replace", payload: payload)
        let preview = try mutation.displayPayload.formatted()
        XCTAssertFalse(preview.contains("private-value"))
        XCTAssertFalse(preview.contains("private-key"))
        XCTAssertEqual(payload["value"]?.string, "private-value")
        XCTAssertEqual(try JSONValue.parse(payload.formatted()), payload)
        let record = try JSONValue.parse("{\"task_id\":9007199254740993}")
        XCTAssertEqual(record["task_id"], .integer(9007199254740993))
        XCTAssertTrue(try record.formatted().contains("9007199254740993"))
    }

    /// Helper capture bounds output without printing raw diagnostics.
    func testBoundedHelperCapture() async throws {
        let output = try await ConnectionHelper.capture(
            executable: URL(fileURLWithPath: "/bin/echo"), arguments: ["{\"api_version\":1}"]
        )
        XCTAssertEqual(try JSONValue.parse(String(decoding: output, as: UTF8.self))["api_version"], .integer(1))
        do {
            _ = try await ConnectionHelper.capture(
                executable: URL(fileURLWithPath: "/bin/echo"), arguments: [String(repeating: "x", count: 5000)]
            )
            XCTFail("Oversized helper output must fail")
        } catch {
            XCTAssertTrue(error is ClientError)
        }
    }

    /// Failed helpers expose recognized causes without exposing arbitrary diagnostic content.
    func testDiscoveryFailureDiagnostics() async throws {
        let fixtures: [(String, ClientError)] = [
            ("host: Permission denied (publickey,password).", .sshAuthentication),
            ("Host key verification failed.", .sshTrust),
            ("WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!", .sshHostChanged),
            ("ssh: connect to host 192.0.2.1 port 22: No route to host", .sshNoRoute),
            ("sh: /home/user/.local/bin/assistant: No such file or directory", .launcherMissing),
            ("Install and start Docker with Compose, then run this command again.", .dockerMissing),
            ("Docker is not accessible. Start it and grant this account Docker access.", .dockerUnavailable),
            ("service \"management\" is not running", .managementNotRunning),
            ("token=never-show-secret", .discoveryFailed(7))
        ]
        for (diagnostic, expected) in fixtures {
            do {
                _ = try await ConnectionHelper.capture(
                    executable: URL(fileURLWithPath: "/bin/sh"),
                    arguments: ["-c", "printf '%s\\n' \"$1\" >&2; exit 7", "diagnostic", diagnostic]
                )
                XCTFail("A failed helper cannot return a successful handoff")
            } catch {
                XCTAssertEqual(error as? ClientError, expected)
                XCTAssertFalse(error.localizedDescription.contains("never-show-secret"))
            }
        }
    }

    /// Draining stderr concurrently prevents pipe-buffer deadlocks while retaining only bounded diagnostics.
    func testHelperDrainsLargeDiagnostics() async throws {
        let output = try await ConnectionHelper.capture(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c", "printf '%s' \"$1\" >&2; printf '%s' '{\"api_version\":1}'",
                "diagnostic", String(repeating: "x", count: 70000)
            ]
        )
        XCTAssertEqual(try JSONValue.parse(String(decoding: output, as: UTF8.self))["api_version"], .integer(1))
    }

    /// A lost submission response is recorded as unresolved and is not automatically replayed.
    @MainActor
    func testUnknownSubmissionPersistsMetadataWithoutBody() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let api = FakeAPI(mode: .lostSubmission)
        let model = ClientModel(defaults: defaults, api: api, health: health)
        let payload = try JSONValue.parse("""
        {"operation":"credential.replace","name":"API_KEY","value":"private-body","confirmed":true}
        """)
        do {
            _ = try await model.perform(payload)
            XCTFail("An unknown submission cannot report success")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("unresolved"))
        }
        let data = try XCTUnwrap(defaults.data(forKey: "assistant.operations"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("private-body"))
        XCTAssertEqual(model.references.count, 1)
        let count = await api.submissions
        XCTAssertEqual(count, 1)
    }

    /// Accepted operation IDs remain recoverable if polling loses the connection.
    @MainActor
    func testAcceptedOperationSurvivesPollingFailure() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let model = ClientModel(defaults: defaults, api: FakeAPI(mode: .lostPolling), health: health)
        do {
            _ = try await model.perform(try JSONValue.parse("""
            {"operation":"search.maintenance","action":"reindex","confirmed":true}
            """))
            XCTFail("Polling failure must remain visible")
        } catch {
            XCTAssertEqual(model.references.first?.operationID, "operation-a")
        }
        let restored = ClientModel(defaults: defaults)
        XCTAssertEqual(restored.references.first?.operationID, "operation-a")
    }

    /// Terminal failure and success are distinct, and both retain their server status.
    @MainActor
    func testOperationTerminalOutcomes() async throws {
        let payload = try JSONValue.parse("{\"operation\":\"search.maintenance\",\"action\":\"status\"}")
        for mode in [FakeAPI.Mode.succeeded, .interrupted] {
            let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
            let model = ClientModel(defaults: defaults, api: FakeAPI(mode: mode), health: health)
            do {
                _ = try await model.perform(payload)
                XCTAssertEqual(mode, .succeeded)
            } catch {
                XCTAssertEqual(mode, .interrupted)
            }
            XCTAssertTrue(model.references.isEmpty)
            XCTAssertEqual(model.operations.first?.state, mode == .succeeded ? "succeeded" : "interrupted")
        }
    }

    /// Fixture identity has no relationship to a live installation.
    private var health: InstanceHealth {
        InstanceHealth(apiVersion: 2, instanceID: "fixture", name: "Assistant", capabilities: ["configuration.read"], readOnly: false)
    }
}

/// Deterministic API fixture for accepted, ambiguous, and interrupted operations.
actor FakeAPI: ManagementAPI {
    enum Mode { case succeeded, interrupted, lostSubmission, lostPolling }
    let mode: Mode
    var submissions = 0

    /// Selects one narrowly scoped operation outcome.
    init(mode: Mode) { self.mode = mode }

    /// Simulates protocol responses without launching an SSH process or contacting the network.
    func request(_ resource: String, body: JSONValue?, key: String?) async throws -> Data {
        if resource == "operations" && body != nil {
            submissions += 1
            if mode == .lostSubmission { throw URLError(.networkConnectionLost) }
        } else if mode == .lostPolling {
            throw URLError(.cannotConnectToHost)
        }

        let state = mode == .lostPolling ? "running" : mode == .interrupted ? "interrupted" : "succeeded"
        return Data("""
        {"id":"operation-a","action":"search.status","state":"\(state)","progress":"fixture","error":null,"result":{}}
        """.utf8)
    }
}

/// Two-chunk download fixtures exercise both integrity and range invariants.
actor DownloadAPI: ManagementAPI {
    enum Mode { case valid, badDigest, changingSize, oversized }
    let mode: Mode
    private var reads = 0

    init(mode: Mode) { self.mode = mode }

    func request(_ resource: String, body: JSONValue?, key: String?) async throws -> Data {
        guard resource.hasPrefix("projects/4/files/8/content?") else { throw ClientError.invalidResource }
        reads += 1
        let chunk = Data((reads == 1 ? "fi" : "le").utf8)
        let digest = SHA256.hash(data: Data("file".utf8)).map { String(format: "%02x", $0) }.joined()
        return try JSONEncoder().encode(JSONValue.object([
            "content_base64": .string(chunk.base64EncodedString()),
            "sha256": .string(mode == .badDigest ? "bad-digest" : digest),
            "size_bytes": .integer(mode == .oversized ? 64 * 1024 * 1024 + 1 : mode == .changingSize && reads > 1 ? 5 : 4),
            "next_offset": .integer(Int64(reads * 2))
        ]))
    }
}
