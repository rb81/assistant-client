import Foundation
@testable import Assistant

/// Read/write chat fixtures capture request intent without real credentials or process launches.
actor ChatAPI: ManagementAPI {
    var payloads: [JSONValue] = []
    var resources: [String] = []
    private var lost = false
    private var pauseSubmission = false
    private var pauseReceipt = false
    private var submissionWaiter: CheckedContinuation<Void, Never>?
    private var requests: [(Int, String)] = []
    private var pausedReads = Set<String>()
    private var readWaiters: [String: CheckedContinuation<Void, Never>] = [:]
    private var conversationRows: [Conversation]?
    private var assistantName = ""
    private var activationPending = false

    func setAssistantName(_ name: String) { assistantName = name }
    func setActivationPending(_ pending: Bool) { activationPending = pending }

    /// List updates model remote activity and unsorted merged pages.
    func setConversations(_ rows: [Conversation]) { conversationRows = rows }

    /// Named read gates make overlapping refreshes deterministic without network timing assumptions.
    func pauseNextRead(_ prefix: String) { pausedReads.insert(prefix) }
    func readIsPaused(_ prefix: String) -> Bool { readWaiters[prefix] != nil }
    func resumeRead(_ prefix: String) { readWaiters.removeValue(forKey: prefix)?.resume() }

    /// Controlled latency lets tests inspect the optimistic transcript before the server accepts a send.
    func pauseNextSubmission() { pauseSubmission = true }
    func pauseNextReceipt() { pauseReceipt = true }
    var submissionPaused: Bool { submissionWaiter != nil }
    func resumeSubmission() { submissionWaiter?.resume(); submissionWaiter = nil }

    /// The next write models a response lost after submission.
    func loseNextSubmission() { lost = true }

    /// Unknown fixture routes fail explicitly instead of fabricating successful empty data.
    func request(_ resource: String, body: JSONValue?, key: String?) async throws -> Data {
        resources.append(resource)
        if let prefix = pausedReads.first(where: { resource.hasPrefix($0) }) {
            pausedReads.remove(prefix)
            await withCheckedContinuation { readWaiters[prefix] = $0 }
            try Task.checkCancellation()
        }
        if resource == "operations", let body {
            payloads.append(body)
            if pauseSubmission {
                pauseSubmission = false
                await withCheckedContinuation { submissionWaiter = $0 }
            }
            let id = requests.count + 100
            requests.append((id, body["body"]?.string ?? body["question"]?.string ?? ""))
            if lost { lost = false; throw URLError(.networkConnectionLost) }
            if pauseReceipt {
                pauseReceipt = false
                await withCheckedContinuation { submissionWaiter = $0 }
            }
            return Data("""
            {"id":"chat-operation","action":"chat","state":"succeeded","progress":"done","result":{"task_id":7,"request_id":\(id)}}
            """.utf8)
        }
        if resource.hasPrefix("conversations?") {
            if let conversationRows {
                return try JSONEncoder().encode(JSONValue.object([
                    "rows": try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(conversationRows)),
                    "total": .integer(Int64(conversationRows.count))
                ]))
            }
            return Data("""
            {"rows":[{"thread_id":"chat-thread","channel":"client","message_count":2,"opening_message":"Chat",
            "last_activity_at":"2026-11-16T10:00:00Z","latest_task_id":7,"latest_task_status":"completed",
            "latest_task_summary":"Chat","workstream_title":null}],"total":1}
            """.utf8)
        }
        if resource == "services?details=true" {
            return Data(#"{"services":[{"id":"task-agent","title":"Task worker","state":"running","health":"healthy"}]}"#.utf8)
        }
        if resource == "query", body?["action"] == .string("skills.list") {
            return Data(#"{"skills":[],"total":0}"#.utf8)
        }
        if resource == "configuration/settings?group=identity" {
            return try JSONEncoder().encode(JSONValue.object(["settings": .array([
                .object(["key": .string("AGENT_IDENTITY_NAME"), "value": .string(assistantName)])
            ])]))
        }
        if resource == "configuration/activation" {
            return try JSONEncoder().encode(JSONValue.object([
                "revision": .string(String(repeating: "a", count: 64)), "tracked": .bool(true),
                "pending": .bool(activationPending), "requires_rebuild": .bool(false),
                "changes": .array(activationPending ? [.object([
                    "key": .string("AGENT_IDENTITY_NAME"), "label": .string("Assistant name"), "value": .string("Juniper")
                ])] : [])
            ]))
        }
        if resource == "tasks/7/snapshot" {
            return Data("""
            {"page":1,"messages":{"rows":[{"id":2,"kind":"reply","channel":"client","body":"Newest snapshot",
              "created_at":"2026-11-16T10:01:00Z"}],"total":51},
             "activity":{"rows":[{"id":"7:1","task_id":7,"created_at":"2026-11-16T10:00:00Z",
               "tool_name":"web_search","status":"succeeded","input":{"search_query":"places"}}],"truncated":false},
             "task":{"id":7,"thread_id":"chat-thread","task_summary":"Chat","status":"completed","updated_at":"2026-11-16"}}
            """.utf8)
        }
        if resource.hasPrefix("tasks/7/activity") {
            return Data(#"{"rows":[],"total":0,"truncated":false}"#.utf8)
        }
        if resource.hasPrefix("records/tasks") {
            return Data("""
            {"rows":[{"id":7,"thread_id":"chat-thread","task_summary":"Chat","status":"completed","updated_at":"2026-11-16"}],"total":1}
            """.utf8)
        }
        if resource.hasPrefix("tasks/7/messages") {
            let text = resource.hasSuffix("page=1") ? "Newest page" : "Oldest page"
            let rows: [JSONValue] = [.object([
                "id": .integer(1), "kind": .string("reply"), "channel": .string("client"),
                "body": .string(text), "created_at": .string("2026-11-16")
            ])] + requests.map { id, body in .object([
                "id": .integer(Int64(id)), "kind": .string("request"), "channel": .string("client"),
                "body": .string(body), "created_at": .string("2026-11-16T10:01:00Z")
            ]) }
            return try JSONEncoder().encode(JSONValue.object(["rows": .array(rows), "total": .integer(51)]))
        }
        if resource.hasSuffix("/acknowledgments") { return Data(#"{"acknowledged":[2]}"#.utf8) }
        throw ClientError.invalidResource
    }
}
