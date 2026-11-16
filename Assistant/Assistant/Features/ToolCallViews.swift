import SwiftUI

/// The tool calls made between two messages, shown in place so the transcript reads as what happened.
struct ToolRunView: View {
    let calls: [ToolCall]
    /// Longer runs start collapsed to a one-line summary so they don't push the conversation apart.
    private static let expandedLimit = 3
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if calls.count <= Self.expandedLimit {
                rows
            } else {
                DisclosureGroup(isExpanded: $expanded) { rows } label: { summary }
            }
        }
        .padding(14)
        .background(Theme.panel.opacity(0.65), in: RoundedRectangle(cornerRadius: Theme.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.secondary.opacity(0.15)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tool calls")
    }

    private var rows: some View {
        ForEach(calls) { call in ToolCallRow(call: call) }
    }

    /// Distinct tool names in call order, so a collapsed run still says what the assistant did.
    private var summary: some View {
        var seen = Set<String>()
        let names = calls.map(\.toolName).filter { seen.insert($0).inserted }
        let failures = calls.filter(\.failed).count
        return HStack(spacing: 8) {
            Image(systemName: "wrench.and.screwdriver").foregroundStyle(Theme.accent)
            Text("\(calls.count) tool calls").font(.callout.weight(.medium))
            Text(names.prefix(4).joined(separator: ", ") + (names.count > 4 ? "…" : ""))
                .font(.caption.monospaced()).foregroundStyle(Theme.secondary).lineLimit(1)
            if failures > 0 {
                Text("\(failures) failed").font(.caption).foregroundStyle(.red)
            }
        }
    }
}

/// One tool call: its name and outcome at a glance, with input and result on demand.
struct ToolCallRow: View {
    let call: ToolCall
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                if let details = call.details {
                    ChatJSON(value: details)
                } else {
                    Text("No details were recorded.").font(.caption).foregroundStyle(Theme.secondary)
                }
                if call.status == "interrupted" {
                    Text("This call stopped without a recorded result.").font(.caption).foregroundStyle(Theme.secondary)
                }
            }.padding(.vertical, 4)
        } label: {
            HStack(spacing: 8) {
                statusIcon
                Text(verbatim: call.toolName).font(.callout.monospaced())
                if let action = call.toolAction, !action.isEmpty {
                    Text(verbatim: action).font(.callout).foregroundStyle(Theme.secondary).lineLimit(1)
                }
                Spacer()
                if let duration = call.durationMS {
                    Text(Duration.milliseconds(duration).formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow, maximumUnitCount: 1)))
                        .font(.caption).foregroundStyle(Theme.secondary)
                }
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .onTapGesture { expanded.toggle() }
        }
    }

    @ViewBuilder private var statusIcon: some View {
        if call.running {
            ProgressView().controlSize(.mini).accessibilityLabel("Running")
        } else if call.failed {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red).accessibilityLabel("Failed")
        } else if call.status == "interrupted" {
            Image(systemName: "pause.circle").foregroundStyle(Theme.secondary).accessibilityLabel("Interrupted")
        } else {
            Image(systemName: "checkmark.circle").foregroundStyle(Theme.accent).accessibilityLabel("Succeeded")
        }
    }
}
