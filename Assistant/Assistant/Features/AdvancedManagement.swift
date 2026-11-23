import SwiftUI

/// Exact server decisions get clear labels without inventing approval options.
enum ApprovalDecision: String, CaseIterable, Identifiable {
    case approve, deny, approveOnce = "approve_once", approveAlways = "approve_always"
    case blockOnce = "block_once", blockAlways = "block_always", cancelJob = "cancel_job"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .approve: return String(localized: "Approve")
        case .deny: return String(localized: "Deny")
        case .approveOnce: return String(localized: "Allow once")
        case .approveAlways: return String(localized: "Allow this script version")
        case .blockOnce: return String(localized: "Block once")
        case .blockAlways: return String(localized: "Block always")
        case .cancelJob: return String(localized: "Cancel task")
        }
    }
}

/// An immutable in-memory request binds confirmation to exactly what was reviewed.
struct ReviewedMutation: Identifiable {
    let id = UUID()
    let title: String
    let payload: JSONValue
    var context: JSONValue?

    /// Redaction affects presentation only, never the submitted request.
    var displayPayload: JSONValue {
        let request = redact(payload, credential: payload["operation"]?.string == "credential.replace")
        if let context { return .object(["request": request, "reviewed_action": redact(context)]) }
        return request
    }

    private func redact(_ value: JSONValue, credential: Bool = false) -> JSONValue {
        switch value {
        case .object(let fields):
            return .object(fields.mapValues { redact($0) }.merging(
                fields.filter { key, _ in
                    let name = key.lowercased()
                    return ["password", "secret", "token", "api_key", "private_key"].contains(where: name.contains) ||
                        (credential && name == "value") || name == "content_base64"
                }.mapValues { _ in .string("[redacted]") },
                uniquingKeysWith: { _, replacement in replacement }
            ))
        case .array(let items): return .array(items.map { redact($0) })
        default: return value
        }
    }
}

/// Reviewed operations show readable intent first, without hiding exact technical details.
struct MutationReview: View {
    let mutation: ReviewedMutation
    let submit: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var sending = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing) {
            Text(mutation.title).font(.title2.weight(.semibold))
            Text("This changes server data or may interrupt active work. An interrupted operation can have partial effects. Inspect its outcome before trying again.")
                .foregroundStyle(Theme.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let context = mutation.context { ReviewDetails(value: context["action"] ?? context) }
                    DisclosureGroup("Technical request details") { PreviewText(value: mutation.displayPayload) }
                }
            }
            HStack {
                StableProgress(active: sending)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Confirm") {
                    sending = true
                    Task { await submit(); dismiss() }
                }.buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(24).frame(width: 680, height: 520).disabled(sending)
        .interactiveDismissDisabled(sending)
    }
}

/// Email reviews default to a short summary; other actions retain their exact details.
struct ReviewDetails: View {
    let value: JSONValue

    private func rows(_ value: JSONValue, path: String = "") -> [(String, String)] {
        switch value {
        case .object(let fields):
            return fields.keys.sorted().flatMap { key in
                rows(fields[key] ?? .null, path: path.isEmpty ? key : path + " / " + key)
            }
        case .array(let items):
            return items.enumerated().flatMap { rows($0.element, path: path + " \($0.offset + 1)") }
        case .string(let text): return [(path, text)]
        case .integer(let number): return [(path, String(number))]
        case .number(let number): return [(path, String(number))]
        case .bool(let value): return [(path, value ? String(localized: "Yes") : String(localized: "No"))]
        case .null: return []
        }
    }

    var body: some View {
        if ["email_ingestion", "screened_email_release"].contains(value["type"]?.string ?? "") {
            EmailApprovalDetails(action: value)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(rows(value).enumerated()), id: \.offset) { _, row in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.0.replacingOccurrences(of: "_", with: " ").capitalized)
                            .font(.caption.weight(.semibold)).foregroundStyle(Theme.secondary)
                        Text(verbatim: row.1).textSelection(.enabled)
                    }
                }
            }
        }
    }
}

/// Extracts original message text and legacy headers without exposing attachment bytes.
struct EmailApprovalPresentation {
    let action: JSONValue

    var review: JSONValue { action["review"] ?? .null }
    func header(_ name: String) -> String {
        (action["headers"]?.array ?? []).first {
            $0["name"]?.string?.lowercased() == name.lowercased()
        }?["value"]?.string ?? String(localized: "Not provided")
    }
    var attachments: [String] {
        review["attachments"]?.array?.compactMap(\.string)
            ?? (action["parts"]?.array ?? []).compactMap { $0["filename"]?.string }
    }
    var original: [String] {
        let parts = action["parts"]?.array ?? []
        let plain = parts.filter {
            $0["filename"] == .null && $0["content_type"]?.string == "text/plain"
                && !($0["content"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let textParts = plain.isEmpty ? parts.filter {
            $0["filename"] == .null && $0["content_type"]?.string == "text/html"
        } : plain
        return textParts.compactMap { $0["content"]?.string }
    }
}

/// Displays source headers and a generated summary without hiding the original message.
struct EmailApprovalDetails: View {
    let action: JSONValue
    private var presentation: EmailApprovalPresentation { EmailApprovalPresentation(action: action) }
    private var review: JSONValue { presentation.review }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if action["type"]?.string == "screened_email_release" {
                Text("Security-held email: review before release.").foregroundStyle(Theme.secondary)
            }
            field(review["summary_source"]?.string == "ai" ? "AI-generated summary" : "Summary",
                  review["summary"]?.string ?? String(localized: "Summary unavailable; review the original message before deciding."))
            field("From (email header)", review["sender"]?.string ?? presentation.header("From"))
            field("Subject", review["subject"]?.string ?? presentation.header("Subject"))
            field("Date (email header)", review["date"]?.string ?? presentation.header("Date"))
            field("Message ID", review["message_id"]?.string ?? presentation.header("Message-ID"))
            if let screening = review["screening"]?.string, !screening.isEmpty {
                field("Screening", screening)
            }
            if !presentation.attachments.isEmpty {
                field("Attachments", presentation.attachments.joined(separator: ", "))
            }
            DisclosureGroup("Original message") {
                if presentation.original.isEmpty {
                    Text("No text content is available.").foregroundStyle(Theme.secondary)
                } else {
                    ForEach(Array(presentation.original.enumerated()), id: \.offset) { _, content in
                        Text(verbatim: content).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private func field(_ label: LocalizedStringKey, _ content: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(Theme.secondary)
            Text(verbatim: content).textSelection(.enabled)
        }
    }
}

/// Approval decisions preserve opaque references/versions and never manufacture a default approval.
struct ApprovalsView: View {
    let model: ClientModel
    @State private var approvals: [JSONValue] = []
    @State private var executions: [JSONValue] = []
    @State private var error: String?
    @State private var pending: ReviewedMutation?
    @State private var offset = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacing) {
                PageHeading(title: "Permission requests", subtitle: "Assistant is asking permission to take these specific actions. Review each action before allowing it.")
                HStack {
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await load() } }
                    Spacer()
                    Button("Previous") { offset -= 50; Task { await load() } }.disabled(offset == 0)
                    Button("Next") { offset += 50; Task { await load() } }.disabled(approvals.count < 50)
                }

                if let error { ErrorBanner(message: error) }
                if approvals.isEmpty && error == nil { Text("Nothing needs your approval on this page.").foregroundStyle(Theme.secondary) }
                ForEach(Array(approvals.enumerated()), id: \.offset) { _, approval in
                    ManagementPanel {
                        VStack(alignment: .leading, spacing: 14) {
                            Text((approval["kind"]?.string ?? String(localized: "Review")).capitalized)
                                .font(.title3.weight(.semibold))
                            ReviewDetails(value: approval["action"] ?? .null)
                            if let reason = approval["reason"]?.string { Text(reason).foregroundStyle(Theme.secondary) }
                            if (approval["action"]?["decision_options"]?.array ?? []).contains(where: {
                                guard let name = $0.string else { return true }
                                return ApprovalDecision(rawValue: name) == nil
                            }) {
                                ErrorBanner(message: String(localized: "This review includes decisions that require a newer client."))
                            }
                            if approval["actionable"] == .bool(true),
                               let id = approval["approval_id"]?.string, let version = approval["version"]?.string {
                                HStack {
                                    ForEach((approval["action"]?["decision_options"]?.array ?? [])
                                        .compactMap { $0.string.flatMap(ApprovalDecision.init(rawValue:)) }) { decision in
                                        Button(decision.title) { decide(id, version, decision, approval) }
                                            .buttonStyle(.bordered)
                                    }
                                }
                            }
                        }
                    }
                }
                if !executions.isEmpty {
                    Text("Recent approved email processing").font(.title3.weight(.semibold))
                    ForEach(Array(executions.enumerated()), id: \.offset) { _, execution in
                        ManagementPanel {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(verbatim: execution["review"]?["subject"]?.string ?? String(localized: "Email"))
                                    .font(.headline)
                                Text(executionStatus(execution["status"]?.string))
                                    .foregroundStyle(Theme.secondary)
                                if let messageID = execution["review"]?["message_id"]?.string {
                                    Text(verbatim: messageID).font(.caption).textSelection(.enabled)
                                }
                                if let updated = execution["updated_at"]?.string {
                                    Text(verbatim: updated).font(.caption).foregroundStyle(Theme.secondary)
                                }
                                if execution["status"]?.string == "uncertain" {
                                    Text("The outcome may be partial. Check the email and task before taking further action.")
                                        .foregroundStyle(Theme.secondary)
                                }
                            }
                        }
                    }
                }
            }.padding(24)
        }.task { await load() }
        .sheet(item: $pending) { mutation in
            MutationReview(mutation: mutation) {
                do { _ = try await model.perform(mutation.payload); await load() }
                catch { self.error = error.presentableMessage ?? self.error }
            }
        }
    }

    private func decide(_ id: String, _ version: String, _ decision: ApprovalDecision, _ approval: JSONValue) {
        pending = ReviewedMutation(title: decision.title,
                                   payload: .object([
                                    "operation": .string("approval.decide"), "approval_id": .string(id),
                                    "version": .string(version), "decision": .string(decision.rawValue), "confirmed": .bool(true)
                                   ]), context: approval)
    }

    private func load() async {
        do {
            guard model.health?.capabilities.contains("approvals.read") == true else {
                throw ClientError.serverOutdated(String(localized: "permission requests"))
            }
            let result = try await model.read("approvals?limit=50&offset=\(offset)")
            guard let values = result["approvals"]?.array else { throw ClientError.malformedResponse }
            approvals = values
            executions = result["executions"]?.array ?? []
            error = nil
        } catch { self.error = error.presentableMessage ?? self.error }
    }

    private func executionStatus(_ status: String?) -> LocalizedStringKey {
        switch status {
        case "pending": return "Queued"
        case "running": return "Processing"
        case "succeeded": return "Processed"
        case "failed": return "Stopped before processing"
        case "uncertain": return "Outcome uncertain"
        default: return "Unknown status"
        }
    }
}

private let emailApprovalPreview: JSONValue = .object([
        "type": .string("email_ingestion"),
        "review": .object([
            "summary": .string("Prepare a report for the meeting."),
            "summary_source": .string("ai"),
            "sender": .string("admin@example.com"),
            "subject": .string("Meeting report"),
            "date": .string("Mon, 23 Nov 2026 10:00:00 +0000"),
            "attachments": .array([.string("report.pdf")]),
        ]),
        "parts": .array([.object([
            "content_type": .string("text/plain"), "filename": .null,
            "content": .string("Please prepare a report for the meeting."),
        ])]),
])

#Preview("Email approval light") {
    EmailApprovalDetails(action: emailApprovalPreview).padding(24).frame(width: 520).preferredColorScheme(.light)
}

#Preview("Email approval dark") {
    EmailApprovalDetails(action: emailApprovalPreview).padding(24).frame(width: 520).preferredColorScheme(.dark)
}
