import AppKit
import SwiftUI
import Textual

/// Textual owns Markdown parsing; image references remain readable alt text without loading URLs.
struct ClientMarkdownParser: MarkupParser {
    func attributedString(for input: String) throws -> AttributedString {
        var content = try AttributedStringMarkdownParser.markdown().attributedString(for: input)
        let imageRanges = content.runs.filter { $0.imageURL != nil }.map(\.range)
        for range in imageRanges { content[range].imageURL = nil }
        return content
    }
}

/// Full Markdown documents use Textual's native block layout and coordinated text selection.
struct MarkdownContent: View {
    let text: String

    var body: some View {
        // Closest environment modifiers win, so block overrides precede the bundled preset.
        StructuredText(text, parser: ClientMarkdownParser())
            .textual.codeBlockStyle(ClientCodeBlockStyle(identity: text))
            .textual.tableStyle(ClientTableStyle())
            .textual.structuredTextStyle(.gitHub)
            .textual.textSelection(.enabled)
            .font(.body)
            .foregroundStyle(Theme.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Library-rendered tables retain all borders and margins inside a selection-aware overflow region.
private struct ClientTableStyle: StructuredText.TableStyle {
    func makeBody(configuration: Configuration) -> some View {
        Overflow { state in
            StructuredText.GitHubTableStyle().makeBody(configuration: configuration)
                .frame(maxWidth: state.containerWidth.map { $0 * 1.5 }, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 16)
        }
        .textual.blockSpacing(.init(top: 0, bottom: 0))
    }
}

/// Textual lays out unwrapped code; no added line spacing breaks box-drawing connections.
private struct ClientCodeBlockStyle: StructuredText.CodeBlockStyle {
    let identity: String

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(configuration.languageHint ?? String(localized: "Code"))
                    .font(.caption.weight(.medium))
                Spacer()
                CopyActionButton(identity: identity, label: String(localized: "Copy code")) {
                    let pasteboard = NSPasteboard.general
                    let previousChange = pasteboard.changeCount
                    configuration.codeBlock.copyToPasteboard()
                    return pasteboard.changeCount > previousChange && pasteboard.string(forType: .string) != nil
                }
            }.padding(10).background(Theme.secondary.opacity(0.07))
            Overflow {
                configuration.label
                    .font(.custom("Menlo", size: 13, relativeTo: .callout))
                    .textual.lineSpacing(.fontScaled(0))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(14)
            }
        }
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.outline).allowsHitTesting(false))
        .textual.blockSpacing(.init(top: 0, bottom: 16))
    }
}

/// Non-Markdown technical output, such as configuration diffs, retains literal source copying.
struct CodeBlock: View {
    let language: String
    let source: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? String(localized: "Code") : language).font(.caption.weight(.medium))
                Spacer()
                CopyTextButton(text: source, label: String(localized: "Copy code"))
            }.padding(10).background(Theme.secondary.opacity(0.07))
            ScrollView(.horizontal) {
                Text(verbatim: source).font(.system(.callout, design: .monospaced))
                    .fixedSize(horizontal: true, vertical: true)
                    .textSelection(.enabled).padding(14)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.outline).allowsHitTesting(false))
    }
}

/// Copies complete original messages or technical source, independent of text selection.
struct CopyTextButton: View {
    let text: String
    var label = String(localized: "Copy message")
    var compact = false
    var pasteboard: NSPasteboard = .general

    var body: some View {
        CopyActionButton(identity: text, label: label, compact: compact) {
            MessageClipboard.copy(text, to: pasteboard)
        }
    }
}

/// Native copy hit targets and explicit failure feedback are shared with Textual's code actions.
private struct CopyActionButton: View {
    let identity: String
    let label: String
    var compact = false
    let copy: () -> Bool
    @State private var copied = false
    @State private var copyFailed = false

    var body: some View {
        NativeCopyControl(label: copied ? String(localized: "Copied") : label, compact: compact, copied: copied) {
            copied = copy()
            copyFailed = !copied
        }
        .fixedSize()
        .onChange(of: identity) { copied = false }
        .alert("Couldn’t copy text", isPresented: $copyFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The clipboard could not be updated. Try copying again.")
        }
    }
}
