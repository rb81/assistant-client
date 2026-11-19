import AppKit

/// Writes complete message source using the native pasteboard object contract.
enum MessageClipboard {
    @MainActor
    static func copy(_ text: String, to pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.clearContents()
        return pasteboard.writeObjects([text as NSString])
    }
}
