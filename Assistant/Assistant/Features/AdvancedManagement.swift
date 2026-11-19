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

/// Flattened labeled fields keep complete approval details selectable and easy to scan.
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

/// Approval decisions preserve opaque references/versions and never manufacture a default approval.
struct ApprovalsView: View {
    let model: ClientModel
    @State private var approvals: [JSONValue] = []
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
            approvals = values; error = nil
        } catch { self.error = error.presentableMessage ?? self.error }
    }
}
