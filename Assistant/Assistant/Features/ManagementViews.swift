import SwiftUI

/// Service health distinguishes a healthy container, an unverified process, and a stopped worker.
enum ServiceAppearance {
    /// Probe jargon stays in technical details rather than the primary service description.
    static func summary(state: String, health: String) -> String {
        if health.contains("unhealthy") || health.contains("failed") { return String(localized: "Needs attention. View logs for details.") }
        if state.contains("restarting") || health.contains("starting") { return String(localized: "Starting up…") }
        if health.contains("completed successfully") { return String(localized: "Setup completed successfully.") }
        if state == "profile inactive" { return String(localized: "Optional service is turned off.") }
        if state == "not created" { return String(localized: "Not installed yet.") }
        if state != "running" { return String(localized: "Not running.") }
        return health.hasPrefix("healthy") ? String(localized: "Running and responding to health checks.") :
            String(localized: "Running. Health has not been verified.")
    }

    /// State and probe results must both support a green status.
    static func tone(state: String, health: String) -> Color {
        if state.contains("restarting") || health.contains("starting") { return .orange }
        if state.contains("dead") || state.contains("exited") || health.contains("unhealthy") ||
            health.contains("failed") { return health.contains("completed successfully") ? .gray : .red }
        return state == "running" && health.hasPrefix("healthy") ? .green :
            state == "running" ? .orange : .gray
    }
}

/// A clear service inventory and deliberate lifecycle controls replace the technical status dump.
struct ServicesView: View {
    let model: ClientModel
    @State private var pending: ReviewedMutation?
    @State private var error: String?
    @State private var busy = false
    @State private var logService: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeading(title: "Connections", subtitle: "Your server connection, service health, and diagnostics.")
                HStack {
                    StatusBadge(title: model.status, tone: model.pollingError == nil ? .green : .orange)
                    Text(model.profile.name).font(.headline)
                    StableProgress(active: model.servicesLoading)
                    Spacer()
                    Button(model.servicesError == nil ? "Refresh" : "Retry", systemImage: "arrow.clockwise") { Task { await load() } }
                        .disabled(busy || model.servicesLoading)
                }
                if let error { ErrorBanner(message: error) }
                if let error = model.servicesError {
                    Label(model.services.isEmpty ? "Can’t check Assistant’s services right now." :
                          "Can’t refresh service status. The results below are from the last successful check.",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text("Check that Docker is running on the computer that hosts Assistant, then retry.")
                        .foregroundStyle(Theme.secondary)
                    DisclosureGroup("Technical details") { ErrorBanner(message: error) }
                }
                if model.activationState != .active {
                    Label(model.activationState == .pending ?
                          String(localized: "Saved settings need applying. Review and apply when you are ready.") :
                          String(localized: "Activation outcome needs checking. Inspect operation history before retrying."),
                          systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                }
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Services").font(Theme.sectionTitle).accessibilityAddTraits(.isHeader)
                        if let refreshed = model.servicesUpdatedAt {
                            Text("Last checked \(refreshed.formatted(date: .omitted, time: .standard))")
                                .font(.caption.monospacedDigit()).foregroundStyle(Theme.secondary)
                        }
                    }
                    Spacer()
                    if model.activationState == .pending {
                        Button("Apply saved settings") { lifecycle("apply") }
                            .disabled(model.servicesError != nil)
                    }
                    Menu("Service actions") {
                        Button("Start Assistant") { lifecycle("start") }
                        Button("Restart Assistant") { lifecycle("restart") }
                        Button("Stop Assistant", role: .destructive) { lifecycle("stop") }
                    }.disabled(model.servicesError != nil)
                }
                ForEach(Array(model.services.enumerated()), id: \.offset) { _, service in
                    serviceCard(service)
                }
                if model.services.isEmpty && !model.servicesLoading && model.servicesError == nil {
                    Text("No service statuses were returned.").foregroundStyle(Theme.secondary)
                }
                DisclosureGroup("Request performance") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Most recent successful network reads, including tunnel and server time. Cached navigation does not make another request.")
                            .font(.callout).foregroundStyle(Theme.secondary)
                        ForEach(model.requestDurations.keys.sorted(), id: \.self) { resource in
                            HStack {
                                Text(resource).font(.caption.monospaced())
                                Spacer()
                                Text((model.requestDurations[resource] ?? 0).formatted(.number.precision(.fractionLength(2))) + " s")
                                    .font(.caption.monospacedDigit()).foregroundStyle(Theme.secondary)
                            }
                        }
                    }.padding(.top, 12)
                }
            }
            .frame(maxWidth: 1050).padding(28).frame(maxWidth: .infinity)
        }
        .disabled(busy).task {
            while !Task.isCancelled {
                await load()
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
            }
        }
        .sheet(item: $pending) { mutation in
            MutationReview(mutation: mutation) {
                busy = true
                do { _ = try await model.perform(mutation.payload); await load() }
                catch { self.error = error.presentableMessage ?? self.error }
                busy = false
            }
        }
        .sheet(isPresented: Binding(get: { logService != nil }, set: { if !$0 { logService = nil } })) {
            if let logService {
                VStack {
                    HStack {
                        Text("Logs · \(logService)").font(.title2.weight(.semibold))
                        Spacer()
                        Button("Done") { self.logService = nil }
                    }.padding()
                    ResourceInspector(model: model, resource: "services/\(logService)/logs")
                }.frame(width: 800, height: 600)
            }
        }
    }

    /// Missing uptime is reported honestly; the client never infers it from its connection age.
    private func serviceCard(_ service: JSONValue) -> some View {
        let id = service["id"]?.string ?? ""
        let state = service["state"]?.string ?? String(localized: "Unknown")
        let health = service["health"]?.string ?? String(localized: "Not checked")
        return ManagementPanel {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    Image(systemName: "server.rack").font(.title2).foregroundStyle(Theme.accent).frame(width: 34)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(service["title"]?.string ?? id).font(.headline)
                        Text(ServiceAppearance.summary(state: state, health: health))
                            .font(.callout).foregroundStyle(Theme.secondary)
                        Text(service["uptime"]?.string ?? String(localized: "Uptime not reported by this server"))
                            .font(.caption).foregroundStyle(Theme.secondary)
                    }
                    Spacer()
                    StatusBadge(title: state.capitalized, tone: ServiceAppearance.tone(state: state, health: health))
                }
                HStack {
                    Button("View logs", systemImage: "text.alignleft") { logService = id }
                    Spacer()
                    HStack {
                        Button("Start") { lifecycle("start", service: id) }.disabled(state == "running")
                        Button("Restart") { lifecycle("restart", service: id) }
                        Button("Stop", role: .destructive) { lifecycle("stop", service: id) }
                            .disabled(["management", "management-docker"].contains(id))
                    }.disabled(model.servicesError != nil)
                }.font(.callout)
                DisclosureGroup("Technical details") {
                    Text(health).font(.caption.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.font(.caption).foregroundStyle(Theme.secondary)
            }
        }
    }

    /// The immutable payload captures the selected service, not a mutable picker state.
    private func lifecycle(_ action: String, service: String? = nil) {
        var payload: [String: JSONValue] = [
            "operation": .string("service.lifecycle"), "action": .string(action), "confirmed": .bool(true)
        ]
        if let service { payload["service"] = .string(service) }
        let title = action == "apply" ? String(localized: "Apply saved settings") :
            "\(action.capitalized) · \(service ?? String(localized: "Application services"))"
        pending = ReviewedMutation(title: title, payload: .object(payload))
    }

    /// Errors never masquerade as an empty healthy installation.
    private func load() async {
        await model.refreshServices()
    }
}

/// Bounded technical details are deliberately secondary to task-oriented screens.
struct ResourceInspector: View {
    let model: ClientModel
    let resource: String
    @State private var output = ""
    @State private var error: String?
    @State private var loading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let error { ErrorBanner(message: error) }
            ScrollView { TerminalOutput(text: output) }
                .accessibilityIdentifier("inspector-output")
                .overlay(alignment: .topTrailing) { StableProgress(active: loading).padding(8) }
        }.padding().task(id: resource) {
            loading = true
            defer { loading = false }
            do {
                let result = try await model.read(resource)
                output = try result["content"]?.string.map(ServiceLogFormatting.prettyPrinted) ?? result.formatted()
                error = nil
            }
            catch { self.error = error.presentableMessage ?? self.error }
        }
    }
}

/// Formats JSON log lines individually while preserving timestamps and non-JSON diagnostics.
enum ServiceLogFormatting {
    static func prettyPrinted(_ content: String) throws -> String {
        try content.components(separatedBy: .newlines).map { line in
            guard let start = line.firstIndex(of: "{"),
                  let data = String(line[start...]).data(using: .utf8),
                  let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { return line }
            return String(line[..<start]) + "\n" + (try value.formatted())
        }.joined(separator: "\n")
    }
}

/// A saved receipt describes what was attempted without exposing the original request.
private struct OperationReceiptRow: View {
    let reference: OperationReference

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(operationTitle(reference.action)).font(.callout.weight(.semibold))
            Text(reference.operationID == nil ? "No receipt from the server" : "Accepted; final result not confirmed")
                .font(.caption).foregroundStyle(Theme.secondary)
            Text(reference.submittedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption.monospacedDigit()).foregroundStyle(Theme.secondary)
        }
    }
}

private func operationTitle(_ action: String) -> String {
    switch action {
    case "configuration.save": return String(localized: "Save settings")
    case "service.lifecycle": return String(localized: "Change Assistant service state")
    case "task.start": return String(localized: "Start a chat")
    case "task.reply": return String(localized: "Send a chat reply")
    case "task.delete": return String(localized: "Delete chat task data")
    case "research.start": return String(localized: "Start deep research")
    case "approval.decide": return String(localized: "Submit an approval decision")
    case "database.reset": return String(localized: "Reset Assistant data")
    case "domain.mutate": return String(localized: "Change a workspace item")
    default: return action.replacingOccurrences(of: ".", with: " ").capitalized
    }
}

/// Durable mutation outcomes remain inspectable when a write response is uncertain.
struct OperationsView: View {
    let model: ClientModel
    @State private var error: String?
    @State private var loading = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeading(title: "Operation history", subtitle: "Accepted is not completed. Check uncertain outcomes before submitting again.")
                HStack {
                    Button("Refresh") { Task { await refresh() } }.disabled(loading)
                    StableProgress(active: loading)
                }
                Text("An unconfirmed submission is not an approval request. Assistant never automatically repeats an action whose outcome is unknown.")
                    .font(.callout).foregroundStyle(Theme.secondary)
                if let error { ErrorBanner(message: error) }
                if model.operations.isEmpty && model.unconfirmedReferences.isEmpty && error == nil && !loading {
                    ContentUnavailableView("No operations yet", systemImage: "clock.arrow.circlepath",
                                           description: Text("Server receipts for actions you take will appear here."))
                }
                ForEach(model.unconfirmedReferences) { reference in
                    ManagementPanel {
                        VStack(alignment: .leading, spacing: 8) {
                            OperationReceiptRow(reference: reference)
                            if let status = model.receiptLookups[reference.id], status != "found" {
                                Text(status == "expired" ?
                                     "The server’s receipt has expired. Check the affected item before taking any further action." :
                                        "No retained receipt matches this submission. This does not prove that the action failed; check the affected item before retrying.")
                                    .font(.callout).foregroundStyle(.orange)
                            }
                            DisclosureGroup("Submission details") {
                                if let operationID = reference.operationID {
                                    Text(operationID).font(.caption.monospaced()).textSelection(.enabled)
                                }
                                Text(reference.key).font(.caption.monospaced()).textSelection(.enabled)
                                Text(reference.id.uuidString).font(.caption.monospaced()).textSelection(.enabled)
                            }
                        }
                    }
                }
                ForEach(model.operations) { operation in
                    ManagementPanel {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(operationTitle(operation.action)).font(.headline)
                                Spacer()
                                StatusBadge(title: operation.state, tone: operation.state == "succeeded" ? .green : .orange)
                            }
                            Text(operation.progress).foregroundStyle(Theme.secondary)
                            if let error = operation.error { ErrorBanner(message: error) }
                        }
                    }
                }
            }.padding(24)
        }.task { await refresh() }
    }

    private func refresh() async {
        loading = true
        defer { loading = false }
        do { try await model.refreshOperations(); error = nil }
        catch { self.error = error.presentableMessage ?? self.error }
    }
}
