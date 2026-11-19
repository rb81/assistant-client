import SwiftUI

/// Asynchronously prepared JSON in a bounded native selectable viewport.
struct ChatJSON: View {
    private let document: Document
    @State private var source: String?
    @State private var loading = true
    @State private var error: String?
    @State private var height: CGFloat = 120
    @State private var displayedDocument: Document?

    init(value: JSONValue) { document = .value(value) }
    init(call: ToolCall) { document = .call(call) }

    /// Derivation and formatting happen off the UI actor, including duplicate-input elimination.
    enum Document: Equatable, Sendable {
        case value(JSONValue), call(ToolCall)
        func formatted() throws -> String? {
            switch self {
            case .value(let value): try value.formatted()
            case .call(let call): try call.details?.formatted()
            }
        }
    }

    var body: some View {
        Group {
            if loading || displayedDocument != document {
                ProgressView("Loading details…").controlSize(.small).frame(maxWidth: .infinity, alignment: .leading)
            } else if let error { ErrorBanner(message: error) }
            else if let source { SourceTextView(text: source).frame(height: height) }
            else { Text("No details were recorded.").font(.caption).foregroundStyle(Theme.secondary) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
        .task(id: document) {
            loading = true
            error = nil
            do {
                let document = document
                let worker = Task.detached(priority: .userInitiated) {
                    try Task.checkCancellation()
                    let text = try document.formatted()
                    try Task.checkCancellation()
                    let lines = text?.reduce(1) { $1 == "\n" ? $0 + 1 : $0 } ?? 1
                    return (text, min(360, max(64, lines * 16 + 24)))
                }
                let result = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                source = result.0
                height = CGFloat(result.1)
                displayedDocument = document
                loading = false
            } catch {
                guard !Task.isCancelled else { return }
                if let message = error.presentableMessage {
                    self.error = message
                    displayedDocument = document
                    loading = false
                }
            }
        }
    }
}
