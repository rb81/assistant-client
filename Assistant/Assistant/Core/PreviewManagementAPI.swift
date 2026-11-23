#if DEBUG
import Foundation
import CryptoKit

/// Explicit opt-in local UI-test data never connects to SSH, Docker, or a real installation.
actor PreviewManagementAPI: ManagementAPI {
    private var deleted = false
    private var sent = false
    private var assistantName = "Assistant"
    private var assistantInstructions = "Be thoughtful, clear, and useful."
    private var pendingSettings: [String: JSONValue] = [:]
    private var configurationRevision = 0
    private let chatDetails: Bool
    private let offline: Bool
    private let liveChat: Bool
    private let slowReads: Bool
    private var activityReads = 0
    private var sentBody = ""

    /// Detail fixtures exercise attachments and external-delivery metadata without any network.
    init(chatDetails: Bool = false, offline: Bool = false, liveChat: Bool = false, slowReads: Bool = false) {
        self.chatDetails = chatDetails
        self.offline = offline
        self.liveChat = liveChat
        self.slowReads = slowReads
    }

    /// A short silent WAV is safe to prepare for playback during UI tests.
    private var audio: Data {
        get throws {
            guard let data = Data(base64Encoded: "UklGRnQAAABXQVZFZm10IBAAAAABAAEAQB8AAEAfAAABAAgAZGF0YVAAAACAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgA==") else {
                throw ClientError.malformedResponse
            }
            return data
        }
    }

    /// Two small brand-color panels exercise native image preview and zoom without external assets.
    private var image: Data {
        get throws {
            guard let data = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAHgAAABQCAIAAABd+SbeAAAAz0lEQVR4nO3QQQ3DQAAEsRAtiiApm/7LKq/AmD3JkhH4+nx/x3n+93GufE30rnxN9C7RokXn8jXRu0SLFp3L10TvEi1adC5fE71LtGjRuXxN9C7RokXn8jXRu0SLFp3L10TvEi1adC5fE71LtGjRuXxN9C7RokXn8jXRu0SLFp3L10TvEi1adC5fE71LtGjRuXxN9C7RokXn8jXRu0SLFp3L10TvEi1adC5fE71LtGjRuXxN9C7RokXn8jXRu0SLFp3L10TvEi1adC5fE73rBaHp8Kr0ztHNAAAAAElFTkSuQmCC") else {
                throw ClientError.malformedResponse
            }
            return data
        }
    }

    /// Fixture responses mirror the wire contract and reject any unmodeled operation.
    func request(_ resource: String, body: JSONValue?, key: String?) async throws -> Data {
        if offline { throw URLError(.notConnectedToInternet) }
        if slowReads && (resource.hasSuffix("/logs") || body?["action"] == .string("workspace.list")
                         || resource.hasPrefix("configuration/settings") || resource == "configuration/instructions"
                         || resource == "configuration/model-settings") {
            try await Task.sleep(for: .seconds(2))
        }
        let value: JSONValue
        let audio = try self.audio
        let task: JSONValue = .object([
            "id": .integer(7), "thread_id": .string("fixture-thread"),
            "task_summary": .string(deleted ? "[Deleted task]" : "Plan a thoughtful launch"),
            "status": .string(deleted ? "deleted" : liveChat ? "running" : "completed"),
            "updated_at": .string("2026-11-16T10:00:00Z"), "last_error": .null
        ])
        if resource.hasPrefix("conversations?"), resource.contains("channel=reminder") {
            value = .object(["total": .integer(1), "rows": .array([.object([
                "thread_id": .string("reminder:3"), "channel": .string("reminder"),
                "message_count": .integer(1), "opening_message": .string("Check tomorrow’s calendar."),
                "last_activity_at": .string("2026-11-16T10:00:01Z"), "latest_task_id": .integer(8),
                "latest_task_status": .string("completed"), "latest_task_summary": .string("Calendar digest"),
            ])])])
        } else if resource.hasPrefix("tasks/8/messages") {
            value = .object(["total": .integer(2), "rows": .array([
                .object(["id": .integer(3), "kind": .string("request"), "channel": .string("reminder"),
                         "body": .string("Check tomorrow’s calendar."), "created_at": .string("2026-11-16T10:00:00Z")]),
                .object(["id": .integer(4), "kind": .string("reply"), "channel": .string("telegram"),
                         "body": .string("There are no events tomorrow."), "created_at": .string("2026-11-16T10:00:01Z")])
            ])])
        } else if resource.hasPrefix("tasks/8/activity") {
            value = .object(["total": .integer(0), "truncated": .bool(false), "rows": .array([])])
        } else if resource == "records/tasks/8" {
            value = .object(["total": .integer(1), "rows": .array([.object([
                "id": .integer(8), "thread_id": .string("reminder:3"), "task_summary": .string("Calendar digest"),
                "status": .string("completed"), "updated_at": .string("2026-11-16T10:00:01Z"),
                "source_channel": .string("reminder")
            ])])])
        } else if resource.hasPrefix("records/reminders?") {
            value = .object(["total": .integer(1), "rows": .array([.object([
                "id": .integer(3), "title": .string("Calendar digest"), "status": .string("scheduled"),
                "run_at": .string("2026-11-17T10:00:00Z"),
                "metadata": .object(["delivery": .object(["primary": .object(["channel": .string("telegram")])])])
            ])])])
        } else if resource.hasPrefix("conversations?") {
            value = .object(["total": .integer(1), "rows": .array([.object([
                "thread_id": .string("fixture-thread"), "channel": .string("client"),
                "message_count": .integer(sent ? 4 : 2), "opening_message": .string("Help me plan the launch."),
                "last_activity_at": .string(sent ? "2026-11-16T10:00:03Z" : "2026-11-16T10:00:01Z"), "latest_task_id": .integer(7),
                "latest_task_status": .string(deleted ? "deleted" : liveChat ? "running" : "completed"),
                "latest_task_summary": .string(deleted ? "[Deleted task]" : "Plan a thoughtful launch"),
                "workstream_title": .string("Product launch")
            ])])])
        } else if resource.hasPrefix("records/tasks/7/children") {
            value = .object(["total": .integer(1), "rows": .array([.object([
                "sequence": .integer(1), "event_type": .string("tool_result"),
                "tool_name": .string("workspace.search"), "tool_action": .string("Find project notes"),
                "output_data": .object(["files_found": .integer(3)])
            ])])])
        } else if resource.hasPrefix("tasks/7/activity") {
            var calls: [JSONValue] = [.object([
                "id": .string("7:2"), "task_id": .integer(7), "created_at": .string("2026-11-16T10:00:00.500000+00:00"),
                "tool_name": .string("workspace_search"), "tool_action": .string("Find project notes"),
                "status": .string("succeeded"), "input": .object(["query": .string("launch")]),
                "output": .object(["files_found": .integer(3)]), "duration_ms": .integer(420)
            ])]
            if chatDetails {
                let result: JSONValue = .object(["response": .string("Invitation sent."),
                                                 "summary": .string("Launch invitation delivered.")])
                calls += [
                    .object(["id": .string("7:3"), "task_id": .integer(7),
                             "created_at": .string("2026-11-16T10:00:00.600000+00:00"),
                             "tool_name": .string("task_complete"), "status": .string("succeeded"),
                             "input": result, "output": result]),
                    .object(["id": .string("7:4"), "task_id": .integer(7),
                             "created_at": .string("2026-11-16T10:00:00.700000+00:00"),
                             "tool_name": .string("calendar_lookup"), "status": .string("failed"),
                             "output": .object(["error": .string("Calendar unavailable")])])
                ]
            } else if liveChat {
                activityReads += 1
                calls = (1...min(activityReads, 3)).map { index in
                    .object(["id": .string("7:\(index)"), "task_id": .integer(7),
                             "created_at": .string("2026-11-16T10:01:0\(index)Z"),
                             "tool_name": .string("live_tool_\(index)"), "status": .string("succeeded")])
                }
            }
            value = .object(["total": .integer(Int64(calls.count)), "truncated": .bool(false), "rows": .array(calls)])
        } else if resource.hasPrefix("records/tasks") {
            value = .object(["total": .integer(1), "rows": .array([task])])
        } else if resource.hasPrefix("tasks/7/messages") {
            var rows: [JSONValue] = [
                .object(["id": .integer(1), "kind": .string("request"), "channel": .string("client"),
                         "body": .string("Help me plan the launch."), "created_at": .string("2026-11-16T10:00:00Z")]),
                .object(["id": .integer(2), "kind": .string("reply"), "channel": .string("client"),
                         "body": .string("# A thoughtful launch\nStart small, then learn.\n\n```swift\nlet ready = true\n```\n\n- Validate the essentials\n- Keep the feedback loop short"),
                         "created_at": .string("2026-11-16T10:00:01Z")])
            ]
            if chatDetails {
                rows = [.object([
                    "id": .integer(3), "kind": .string("message"), "channel": .string("email"),
                    "body": .string("{\"delivery_status\":\"Sent\",\"summary\":\"Invitation delivered\"}"),
                    "created_at": .string("2026-11-16T10:00:01Z"), "external": .bool(true),
                    "recipients": .array([.string("guest@example.com")]), "subject": .string("Launch invitation"),
                    "attachments": .array([.object([
                        "filename": .string("voice-note.wav"), "content_type": .string("audio/wav"),
                        "voice_note": .bool(true), "size_bytes": .integer(Int64(audio.count)),
                        "available": .bool(true), "project_id": .integer(4), "file_id": .integer(8)
                    ])])
                ])]
            } else if liveChat {
                rows = (1...12).map { index in
                    .object(["id": .integer(Int64(index)), "kind": .string("reply"), "channel": .string("client"),
                             "body": .string("Update \(index)\n\n" + String(repeating: "A detailed progress update. ", count: 15)),
                             "created_at": .string("2026-11-16T10:00:\(String(format: "%02d", index))Z")])
                }
            }
            if sent {
                rows.append(.object([
                    "id": .integer(100), "kind": .string("request"), "channel": .string("client"),
                    "body": .string(sentBody), "created_at": .string("2026-11-16T10:00:02Z")
                ]))
                rows.append(.object([
                    "id": .integer(101), "kind": .string("reply"), "channel": .string("client"),
                    "body": .string("Your follow-up was received."), "created_at": .string("2026-11-16T10:00:03Z")
                ]))
            }
            value = .object(["total": .integer(Int64(rows.count)), "rows": .array(rows)])
        } else if resource.hasPrefix("projects/4/files/8/content?") {
            value = .object([
                "content_base64": .string(audio.base64EncodedString()),
                "size_bytes": .integer(Int64(audio.count)), "next_offset": .integer(Int64(audio.count)),
                "sha256": .string(SHA256.hash(data: audio).map { String(format: "%02x", $0) }.joined())
            ])
        } else if resource == "tasks/7/deletion-preview" {
            value = .object(["task_id": .integer(7), "deletable": .bool(true),
                             "preview_digest": .string(String(repeating: "a", count: 64))])
        } else if resource.hasSuffix("/logs") {
            value = .object(["content": .string("task-agent | 2026-11-16T10:00:00Z {\"level\":\"info\",\"message\":\"Ready for tasks\"}"),
                             "truncated": .bool(false)])
        } else if resource.hasPrefix("services") {
            value = .object(["services": .array([.object([
                "id": .string("task-agent"), "title": .string("Task worker"),
                "state": .string("running"), "health": .string("healthy"), "uptime": .string("2 hours")
            ])])])
        } else if resource.hasPrefix("approvals") {
            value = .object(["approvals": .array([])])
        } else if resource == "query", body?["action"] == .string("skills.list") {
            value = .object(["total": .integer(2), "skills": .array([
                skill(email: false, includeBody: false), skill(email: true, includeBody: false)
            ])])
        } else if resource == "query", body?["action"] == .string("skills.read"),
                  let id = body?["arguments"]?["id"]?.string, ["EMAIL", "CALENDAR"].contains(id) {
            value = skill(email: id == "EMAIL", includeBody: true)
        } else if resource == "query", body?["action"] == .string("workspace.list") {
            value = .object(["entries": .array([
                .object(["path": .string("notes"), "is_dir": .bool(true), "size_bytes": .integer(0)]),
                .object(["path": .string("README.md"), "is_dir": .bool(false), "size_bytes": .integer(48)]),
                .object(["path": .string("palette.png"), "is_dir": .bool(false), "size_bytes": .integer(264)]),
                .object(["path": .string("source.html"), "is_dir": .bool(false), "size_bytes": .integer(59)])
            ]), "total": .integer(4)])
        } else if resource == "query", body?["action"] == .string("workspace.read"),
                  let path = body?["arguments"]?["path"]?.string,
                  ["README.md", "palette.png", "source.html"].contains(path) {
            let content: Data
            switch path {
            case "palette.png": content = try image
            case "source.html": content = Data("<h1>Inert source preview</h1>\n<script>Not executed</script>".utf8)
            default: content = Data("# Workspace preview fixture\n\nA verified document.".utf8)
            }
            value = .object([
                "content_base64": .string(content.base64EncodedString()),
                "size_bytes": .integer(Int64(content.count)), "next_offset": .integer(Int64(content.count)),
                "sha256": .string(SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined())
            ])
        } else if resource == "credentials" {
            value = .object(["credentials": .array([
                .object(["name": .string("AGENT_LLM_OPENROUTER_API_KEY"), "status": .string("configured")])
            ])])
        } else if resource == "configuration/activation" {
            value = .object([
                "revision": .string(String(format: "%064d", configurationRevision)), "tracked": .bool(true),
                "pending": .bool(!pendingSettings.isEmpty), "requires_rebuild": .bool(false),
                "changes": .array(pendingSettings.keys.sorted().compactMap { pendingSettings[$0] })
            ])
        } else if resource == "configuration/instructions" {
            value = .object(["revision": .string(String(format: "%064d", configurationRevision)),
                             "instructions": .string(assistantInstructions)])
        } else if resource == "configuration/model-settings" {
            value = .object([
                "api_version": .integer(2), "revision": .string(String(format: "%064d", configurationRevision)),
                "value_state": .string("saved"), "read_only": .bool(true),
                "activation_tracked": .bool(true), "pending_activation": .bool(!pendingSettings.isEmpty),
                "sections": .array([
                    .object([
                        "id": .string("task"), "title": .string("Task models & provider"),
                        "provider": .string("https://openrouter.ai/api/v1"), "enabled": .null,
                        "summary_keys": .array([.string("AGENT_LLM_MODEL")]),
                        "selection_keys": .array([.string("AGENT_LLM_MODEL")]),
                        "related_settings": .array([
                            .object(["group": .string("models"), "title": .string("Models"),
                                     "destination": .string("models"),
                                     "field_key": .string("AGENT_LLM_OPENROUTER_API_KEY")]),
                            .object(["group": .string("catalog:llm"), "title": .string("Generation & sampling"),
                                     "destination": .string("advanced"),
                                     "field_key": .string("AGENT_LLM_TEMPERATURE")])
                        ]),
                        "settings": .array([
                            overviewSetting("models", "AGENT_LLM_MODEL", "Primary model", "example/model"),
                            overviewSetting("models", "AGENT_LLM_OPENROUTER_API_KEY", "OpenRouter API key", "",
                                            display: "Configured", source: "credential_status", secret: true),
                            overviewSetting("catalog:llm", "AGENT_LLM_TEMPERATURE", "Model temperature", "0.2")
                        ])
                    ]),
                    .object([
                        "id": .string("research"), "title": .string("Deep research"),
                        "provider": .string("https://openrouter.ai/api/v1"), "enabled": .bool(true),
                        "summary_keys": .array([.string("AGENT_DEEP_RESEARCH_MODEL")]),
                        "selection_keys": .array([.string("AGENT_DEEP_RESEARCH_MODEL")]),
                        "related_settings": .array([]),
                        "settings": .array([
                            overviewSetting("catalog:deep_research", "AGENT_DEEP_RESEARCH_MODEL", "Deep research model", "",
                                            display: "example/model", source: "inherited", inherited: "AGENT_LLM_MODEL")
                        ])
                    ]),
                    .object([
                        "id": .string("speech"), "title": .string("Speech generation"),
                        "provider": .string("https://openrouter.ai/api/v1"), "enabled": .bool(false),
                        "summary_keys": .array([.string("AGENT_TTS_MODEL")]),
                        "selection_keys": .array([.string("AGENT_TTS_MODEL")]),
                        "related_settings": .array([]),
                        "settings": .array([
                            overviewSetting("advanced:Model preset tool", "AGENT_TTS_MODEL", "Speech model", "example/speech")
                        ])
                    ])
                ])
            ])
        } else if resource.hasPrefix("configuration/models") {
            value = .object([
                "provider": .string("openai"),
                "models": .array([.object([
                    "id": .string("gpt-4.1"), "name": .string("GPT-4.1")
                ])]),
                "zdr_only": .bool(true),
                "warning": .string("Verify account eligibility."),
            ])
        } else if resource == "configuration" || resource == "configuration/catalog" || resource.hasPrefix("configuration/settings") {
            value = .object([
                "revision": .string(String(format: "%064d", configurationRevision)), "setup_complete": .bool(true),
                "instructions": .string(assistantInstructions), "setup_notice": .string(""),
                "agent_yaml": .string("agent:\n  identity:\n    name: Assistant\n"),
                "agent_yaml_backups": .array([]),
                "settings": .array([
                    setting("identity", "AGENT_IDENTITY_NAME", "Assistant name", assistantName,
                            help: "The name the assistant uses when introducing itself."),
                    setting("identity", "AGENT_APP_TIMEZONE", "Timezone", "UTC",
                            help: "Timezone used by your assistant."),
                    setting("approvals", "AGENT_ADMIN_EMAIL", "Approval email", "admin@example.test",
                            help: "The address used for administrative decisions."),
                    setting("approvals", "AGENT_APPROVALS_CHANNEL", "Approval delivery", "email",
                            help: "Where approval requests are delivered.", choices: ["email", "telegram", "both", "client"]),
                    setting("models", "AGENT_LLM_MODEL", "Primary model", "example/model",
                            help: "Model used for ordinary tasks."),
                    setting("models", "AGENT_LLM_BASE_URL", "Provider API URL", "https://openrouter.ai/api/v1",
                            help: "The HTTPS endpoint used by task models."),
                    setting("models", "AGENT_LLM_ZDR_ONLY", "Require Zero Data Retention on OpenRouter", "false",
                            boolean: true, help: "Restrict OpenRouter requests to Zero Data Retention endpoints."),
                    setting("models", "AGENT_LLM_ALLOWED_PROVIDERS", "Allowed OpenRouter providers", "",
                            help: "Leave empty for no preference."),
                    setting("catalog:llm", "AGENT_LLM_TEMPERATURE", "Model temperature", "0.2",
                            help: "Sampling temperature sent to the task model."),
                    setting("catalog:deep_research", "AGENT_DEEP_RESEARCH_MODEL", "Deep research model", "",
                            help: "Blank reuses the primary model."),
                    setting("advanced:Model preset tool", "AGENT_TTS_MODEL", "Speech model", "example/speech",
                            help: "Model used to generate speech."),
                    .object(["group": .string("models"), "key": .string("AGENT_LLM_OPENROUTER_API_KEY"),
                             "label": .string("OpenRouter API key"), "value": .string(""),
                             "secret": .bool(true), "boolean": .bool(false), "editable": .bool(true)]),
                    setting("email", "AGENT_EMAIL_IMAP_HOST", "IMAP server", "imap.example.test",
                            help: "Incoming mail server for the assistant's mailbox."),
                    setting("calendar", "AGENT_CALENDAR_DEFAULT_PROVIDER", "Default provider", "google",
                            help: "Provider used when a request does not name one.", section: "General",
                            choices: ["google", "outlook", "zoho"]),
                    setting("calendar", "AGENT_CALENDAR_GOOGLE_CALENDAR_ID", "Calendar ID", "primary",
                            help: "Calendar identifier within the account.", section: "Google"),
                    setting("calendar", "AGENT_CALENDAR_ZOHO_CALENDAR_ID", "Calendar ID", "",
                            help: "Calendar identifier within the account.", section: "Zoho"),
                    setting("calendar:google_2", "AGENT_CALENDAR_GOOGLE_2_CALENDAR_ID", "Calendar ID", "",
                            help: "Calendar identifier within the account."),
                    setting("zoom", "AGENT_ZOOM_ENABLED", "Enable Zoom", "false", boolean: true,
                            help: "Allow the assistant to manage Zoom meetings."),
                    setting("advanced:Task limits", "AGENT_LIMITS_MAX_ITERATIONS_PER_TASK", "Maximum iterations", "50",
                            help: "Upper bound on model steps for one task.")
                ]),
                "groups": .array([
                    group("identity", "Assistant & people", help: "Name your assistant and set its timezone.", basic: true),
                    group("models", "Models & access", help: "Choose the models used for tasks.", basic: true),
                    group("catalog:llm", "Generation & sampling", help: "Tune task-model sampling.", destination: "models"),
                    group("catalog:deep_research", "Deep research", help: "Choose research models.", destination: "models"),
                    group("advanced:Model preset tool", "Model tools & speech", help: "Choose speech models.", destination: "models"),
                    group("email", "Email", help: "Connect a dedicated assistant mailbox.", basic: true),
                    group("calendar", "Calendar", help: "Connect Google, Outlook or Zoho calendars.", basic: true),
                    group("calendar:google_2", "Google calendar 2", help: "An additional Google calendar account.",
                          parent: "calendar", section: "Google"),
                    group("zoom", "Zoom", help: "Connect Zoom so the assistant can manage meetings.", basic: true),
                    group("approvals", "Approvals", help: "Choose where to receive approval requests.",
                          basic: true, destination: "safety"),
                    group("advanced:Task limits", "Task limits", help: "Bound model iterations and output.")
                ])
            ])
        } else if resource == "configuration/preview" {
            value = .object(["valid": .bool(true), "preview_id": .string(String(repeating: "b", count: 64)),
                             "problems": .array([]), "changes": .array([.object([
                                "key": .string("AGENT_IDENTITY_NAME"), "before": .string(assistantName),
                                "after": body?["values"]?["AGENT_IDENTITY_NAME"] ?? .string(assistantName)
                             ])])])
        } else if resource == "operations", let action = body?["operation"]?.string {
            guard ["task.start", "task.reply", "task.delete", "configuration.save", "service.lifecycle"].contains(action) else {
                throw ClientError.invalidResource
            }
            if action == "task.delete" { deleted = true }
            if action == "task.start" || action == "task.reply" {
                sent = true
                sentBody = body?["body"]?.string ?? ""
            }
            if action == "configuration.save", let name = body?["values"]?["AGENT_IDENTITY_NAME"]?.string {
                assistantName = name
                pendingSettings["AGENT_IDENTITY_NAME"] = .object([
                    "key": .string("AGENT_IDENTITY_NAME"), "label": .string("Assistant name"), "value": .string(name)
                ])
            }
            if action == "configuration.save", let instructions = body?["instructions"]?.string {
                assistantInstructions = instructions
                pendingSettings["instructions"] = .object([
                    "key": .string("instructions"), "label": .string("Assistant instructions"), "value": .string("Updated")
                ])
            }
            if body?["apply"] == .bool(true) || action == "service.lifecycle" && body?["action"] == .string("apply") {
                pendingSettings = [:]
            }
            if action == "configuration.save" ||
                (action == "service.lifecycle" && ["apply", "start"].contains(body?["action"]?.string ?? "")) {
                configurationRevision += 1
            }
            value = .object([
                "id": .string("fixture-operation"), "action": .string(action), "state": .string("succeeded"),
                "progress": .string("Completed"), "result": .object(["task_id": .integer(7), "request_id": .integer(100)])
            ])
        } else if resource == "operations" {
            value = .array([])
        } else { throw ClientError.invalidResource }
        if resource == "configuration/catalog" || resource.hasPrefix("configuration/settings"),
           case .object(var configuration) = value {
            configuration.removeValue(forKey: "agent_yaml")
            configuration.removeValue(forKey: "agent_yaml_backups")
            configuration["instructions"] = .string("")
            configuration["instructions_configured"] = .bool(true)
            let group = URLComponents(string: "http://localhost/\(resource)")?.queryItems?
                .first(where: { $0.name == "group" })?.value
            configuration["settings"] = .array((configuration["settings"]?.array ?? []).compactMap { field in
                guard case .object(var definition) = field else { return nil }
                if resource == "configuration/catalog" { definition["value"] = .string("") }
                if let group, let fieldGroup = definition["group"]?.string,
                   fieldGroup != group && !(group == "calendar" && fieldGroup.hasPrefix("calendar:")) { return nil }
                return .object(definition)
            })
            return try JSONEncoder().encode(JSONValue.object(configuration))
        }
        return try JSONEncoder().encode(value)
    }

    /// Pinned overview fixture preserves flattened settings, provenance, redaction and activation fields.
    private func overviewSetting(_ group: String, _ key: String, _ label: String, _ value: String,
                                 display: String? = nil, source: String = "configured",
                                 inherited: String? = nil, secret: Bool = false) -> JSONValue {
        .object([
            "group": .string(group), "key": .string(key), "label": .string(label), "value": .string(value),
            "default": .string(""), "secret": .bool(secret), "boolean": .bool(false), "editable": .bool(true),
            "metadata": .object(["help": .string("Saved model setting.")]),
            "display_value": .string(display ?? value), "value_source": .string(source),
            "inherited_from": inherited.map(JSONValue.string) ?? .null, "pending_activation": .bool(false)
        ])
    }

    private func skill(email: Bool, includeBody: Bool) -> JSONValue {
        var fields: [String: JSONValue] = [
            "id": .string(email ? "EMAIL" : "CALENDAR"), "title": .string(email ? "Email" : "Calendar"),
            "description": .string(email ? "Draft and reply to email." : "Manage calendar events."),
            "revision": .string("fixture-rev"), "locked": .bool(true), "overlay_for": .null
        ]
        if includeBody {
            fields["body"] = .string(email ? "Verify the recipient before composing the message." : "Check availability first.")
            fields["preferences"] = email ? .object([
                "id": .string("EMAIL.LEGACY"), "title": .string("Signature"), "description": .string("Signoff"),
                "revision": .string("3"), "body": .string("Use this signoff for outgoing email.")
            ]) : .null
        }
        return .object(fields)
    }

    private func setting(_ group: String, _ key: String, _ label: String, _ value: String, boolean: Bool = false,
                         help: String, section: String? = nil, choices: [String]? = nil) -> JSONValue {
        var metadata: [String: JSONValue] = ["help": .string(help), "level": .string("basic")]
        if let section { metadata["section"] = .string(section) }
        if let choices { metadata["choices"] = .array(choices.map(JSONValue.string)) }
        return .object(["group": .string(group), "key": .string(key), "label": .string(label), "value": .string(value),
                        "default": .string(""), "secret": .bool(false), "boolean": .bool(boolean),
                        "editable": .bool(true), "metadata": .object(metadata)])
    }

    private func group(_ id: String, _ title: String, help: String, parent: String? = nil,
                       section: String? = nil, basic: Bool = false, destination: String? = nil) -> JSONValue {
        .object(["id": .string(id), "title": .string(title), "help": .string(help),
                 "parent": parent.map(JSONValue.string) ?? .null, "section": section.map(JSONValue.string) ?? .null,
                 "basic": .bool(basic), "destination": destination.map(JSONValue.string) ?? .null])
    }
}
#endif
