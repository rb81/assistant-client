import SwiftUI

/// One selectable, wrapping JSON inset without nested headings, table rules, or repeated labels.
struct ChatJSON: View {
    let value: JSONValue

    var body: some View {
        Group {
            if let source = try? value.formatted() {
                TerminalOutput(text: source)
            } else {
                ErrorBanner(message: String(localized: "This response could not be formatted."))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
    }
}
