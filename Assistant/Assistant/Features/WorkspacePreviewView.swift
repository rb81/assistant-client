import AVKit
import PDFKit
import QuickLookUI
import SwiftUI

/// A persistent native preview pane shares the workspace selection, not an external app.
struct WorkspacePreviewView: View {
    let preview: WorkspacePreview
    let path: String?
    var retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(path.map { ($0 as NSString).lastPathComponent } ?? String(localized: "File preview"),
                  systemImage: "doc.text.magnifyingglass").font(.headline).lineLimit(1)
            Divider()
            if preview.loading {
                ProgressView("Loading verified preview…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = preview.error {
                VStack(alignment: .leading, spacing: 12) {
                    ErrorBanner(message: error)
                    Button("Retry preview", action: retry)
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if let content = preview.content {
                switch content {
                case .markdown(let text):
                    ScrollView { MarkdownContent(text: text).padding(12).frame(maxWidth: .infinity, alignment: .leading) }
                case .pdf(let document):
                    PDFPreview(document: document)
                case .office(let file):
                    OfficePreview(file: file)
                    Text("Office previews use macOS Quick Look. Availability depends on installed preview support.")
                        .font(.caption).foregroundStyle(Theme.secondary)
                case .media(_, let player):
                    VideoPlayer(player: player).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ContentUnavailableView("Select a file", systemImage: "doc.text.magnifyingglass",
                                       description: Text("Preview Markdown, PDF and Office documents, or play audio and video."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace-preview")
    }
}

/// PDFKit provides page navigation, selectable text, zoom, and native accessibility.
private struct PDFPreview: NSViewRepresentable {
    let document: PDFDocument
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        return view
    }
    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== document { view.document = document }
    }
    static func dismantleNSView(_ view: PDFView, coordinator: ()) { view.document = nil }
}

/// Quick Look displays Office files without launching a separate editor.
private struct OfficePreview: NSViewRepresentable {
    let file: PreviewFile
    func makeNSView(context: Context) -> NSView {
        guard let view = QLPreviewView(frame: .zero, style: .normal) else {
            return NSTextField(labelWithString: String(localized: "Quick Look is unavailable. Download this document to open it."))
        }
        view.shouldCloseWithWindow = false
        view.autostarts = false
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {
        guard let view = view as? QLPreviewView, view.previewItem?.previewItemURL != file.url else { return }
        view.previewItem = file.url as NSURL
    }
    static func dismantleNSView(_ view: NSView, coordinator: ()) { (view as? QLPreviewView)?.close() }
}
