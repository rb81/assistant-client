import AppKit
import SwiftUI

/// Bounded Markdown blocks retain fenced source exactly, including incomplete streaming fences.
enum MarkdownBlock: Equatable {
    case prose(String)
    case code(language: String, source: String)

    /// Splits fences without executing HTML or fetching remote images.
    static func parse(_ text: String) -> [MarkdownBlock] {
        var result: [MarkdownBlock] = []
        var lines: [String] = []
        var fence: String?
        var language = ""
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let delimiter = fence {
                if trimmed.hasPrefix(delimiter) && trimmed.dropFirst(delimiter.count).allSatisfy({ $0 == delimiter.first }) {
                    result.append(.code(language: language, source: lines.joined(separator: "\n")))
                    lines = []; fence = nil
                } else { lines.append(line) }
            } else if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                if !lines.isEmpty { result.append(.prose(lines.joined(separator: "\n"))); lines = [] }
                let marker = trimmed.first ?? "`"
                let count = trimmed.prefix(while: { $0 == marker }).count
                fence = String(repeating: String(marker), count: count)
                language = String(trimmed.dropFirst(count)).trimmingCharacters(in: .whitespaces)
            } else { lines.append(line) }
        }
        if let _ = fence { result.append(.code(language: language, source: lines.joined(separator: "\n"))) }
        else if !lines.isEmpty { result.append(.prose(lines.joined(separator: "\n"))) }
        return result
    }

    /// Groups prose into paragraphs split at blank lines. Consecutive plain lines share one paragraph,
    /// while headings, list items, and quotes keep their own rows.
    static func paragraphs(_ text: String) -> [[String]] {
        var result: [[String]] = []
        var current: [String] = []
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !current.isEmpty { result.append(current); current = [] }
            } else if let last = current.last, !isStructural(line), !isStructural(last) {
                current[current.count - 1] = last + "\n" + line
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// Lines rendered with their own marker or font rather than flowing into a paragraph.
    static func isStructural(_ line: String) -> Bool {
        let heading = line.prefix(while: { $0 == "#" }).count
        if (1...6).contains(heading) && line.dropFirst(heading).hasPrefix(" ") { return true }
        if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("> ") { return true }
        let number = line.prefix(while: \.isNumber)
        return !number.isEmpty && (line.dropFirst(number.count).hasPrefix(". ") || line.dropFirst(number.count).hasPrefix(") "))
    }
}

/// Rich native text and copyable code share the application palette in both appearances.
struct MarkdownContent: View {
    let text: String
    /// Space between paragraphs and code blocks, and between list rows inside one paragraph.
    private static let paragraphSpacing: CGFloat = 12

    var body: some View {
        VStack(alignment: .leading, spacing: Self.paragraphSpacing) {
            ForEach(Array(MarkdownBlock.parse(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .prose(let text):
                    Text(Self.prose(text)).lineSpacing(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .code(let language, let source):
                    CodeBlock(language: language, source: source)
                }
            }
        }.textSelection(.enabled)
    }

    /// Headings and lists remain native selectable text; inline Markdown handles links and emphasis.
    static func prose(_ text: String) -> AttributedString {
        var result = AttributedString()
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            if index > 0 { result.append(AttributedString("\n")) }
            let heading = line.prefix(while: { $0 == "#" }).count
            let isHeading = (1...6).contains(heading) && line.dropFirst(heading).hasPrefix(" ")
            let bullet = line.hasPrefix("- ") || line.hasPrefix("* ")
            let content = isHeading ? String(line.dropFirst(heading + 1)) :
                bullet ? "• " + String(line.dropFirst(2)) : line
            var attributed = (try? AttributedString(
                markdown: content, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )) ?? AttributedString(content)
            attributed.font = isHeading ? .system(size: heading == 1 ? 25 : heading == 2 ? 21 : 17, weight: .semibold) : .body
            result.append(attributed)
        }
        return result
    }
}

/// Copy operates on original source rather than rendered Markdown or a selected text fragment.
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
                    .textSelection(.enabled).padding(14)
            }

        }
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.secondary.opacity(0.15)).allowsHitTesting(false))
    }
}

/// Copies the complete original text, including paragraphs, lists, and fenced code.
struct CopyTextButton: View {
    let text: String
    var label = String(localized: "Copy message")
    var compact = false
    @State private var copied = false
    @State private var copyFailed = false

    var body: some View {
        Button {
            copied = MessageClipboard.copy(text)
            copyFailed = !copied
        } label: {
            if compact {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .frame(width: 28, height: 28).contentShape(Rectangle())
            } else {
                Label(copied ? String(localized: "Copied") : label, systemImage: copied ? "checkmark" : "doc.on.doc")
            }
        }
        .buttonStyle(.plain).font(.caption).textSelection(.disabled)
        .accessibilityLabel(copied ? String(localized: "Copied") : label)
        .help(label)
        .onChange(of: text) { copied = false }
        .alert("Couldn’t copy text", isPresented: $copyFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The clipboard could not be updated. Try copying again.")
        }
    }
}
