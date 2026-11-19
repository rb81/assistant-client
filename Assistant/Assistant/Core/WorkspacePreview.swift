import AVFoundation
import Foundation
import Observation
import OSLog
import PDFKit

/// Native previewers only receive supported contained files, never playlists or remote URLs.
enum WorkspacePreviewKind: Equatable {
    case markdown, pdf, office, media

    init?(path: String) {
        switch (path as NSString).pathExtension.lowercased() {
        case "md", "markdown", "mdown": self = .markdown
        case "pdf": self = .pdf
        case "doc", "docx", "xls", "xlsx", "ppt", "pptx", "odt", "ods", "odp", "pages", "numbers", "key", "rtf":
            self = .office
        case "mp3", "m4a", "aac", "wav", "aiff", "aif", "flac", "mp4", "m4v", "mov", "webm", "ogg", "opus":
            self = .media
        default: return nil
        }
    }

    var maximumBytes: Int64 {
        switch self {
        case .markdown: 2 * 1024 * 1024
        case .pdf, .office: 16 * 1024 * 1024
        case .media: 64 * 1024 * 1024
        }
    }
}

/// One private temporary directory is removed on dismissal or after an unused result is released.
final class PreviewFile: Sendable {
    let url: URL
    private let directory: URL

    init(data: Data, name: String) throws {
        let leaf = (name as NSString).lastPathComponent
        guard !["", ".", "..", "/"].contains(leaf), !leaf.contains("\0") else { throw ClientError.invalidResource }
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("AssistantPreview-\(UUID().uuidString)",
                                                                                 isDirectory: true)
        url = directory.appendingPathComponent(leaf, isDirectory: false)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        do {
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            Self.remove(directory)
            throw error
        }
    }

    deinit { Self.remove(directory) }

    /// Explicit shutdown must not depend on SwiftUI releasing a native viewer before process exit.
    func remove() { Self.remove(directory) }

    private static func remove(_ directory: URL) {
        do { try FileManager.default.removeItem(at: directory) }
        catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {}
        catch {
            Logger(subsystem: "Assistant", category: "Previews")
                .error("Temporary preview cleanup failed: \(error.localizedDescription, privacy: .private)")
        }
    }
}

/// Selection changes cancel stale results and stop playback without opening another application.
@MainActor @Observable
final class WorkspacePreview {
    enum Content {
        case markdown(String)
        case pdf(PDFDocument)
        case office(PreviewFile)
        case media(PreviewFile, AVPlayer)
    }
    private(set) var content: Content?
    private(set) var loading = false
    private(set) var error: String?
    private var version = UUID()

    func clear() {
        version = UUID()
        if case .media(let file, let player) = content {
            player.pause()
            player.replaceCurrentItem(with: nil)
            file.remove()
        } else if case .office(let file) = content {
            file.remove()
        }
        content = nil
        error = nil
        loading = false
    }

    func load(_ path: String, model: ClientModel) async {
        clear()
        let current = version
        guard let kind = WorkspacePreviewKind(path: path) else {
            error = String(localized: "Preview is not available for this file type. Download it to open it in another app.")
            return
        }
        loading = true
        defer { if current == version { loading = false } }
        do {
            let data = try await model.downloadFile(.workspace(path), maximumBytes: kind.maximumBytes)
            try Task.checkCancellation()
            guard current == version else { return }
            switch kind {
            case .markdown:
                guard let text = String(data: data, encoding: .utf8) else {
                    throw ClientError.operationFailed(String(localized: "This Markdown file is not valid UTF-8 text."))
                }
                content = .markdown(text)
            case .pdf:
                guard let document = PDFDocument(data: data), document.pageCount > 0 else {
                    throw ClientError.operationFailed(String(localized: "This PDF could not be opened. It may be damaged or encrypted."))
                }
                content = .pdf(document)
            case .office, .media:
                let file = try await Task.detached(priority: .userInitiated) { try PreviewFile(data: data, name: path) }.value
                try Task.checkCancellation()
                guard current == version else { return }
                if kind == .office {
                    content = .office(file)
                } else {
                    let asset = AVURLAsset(url: file.url, options: [
                        AVURLAssetReferenceRestrictionsKey: NSNumber(value: AVAssetReferenceRestrictions.forbidAll.rawValue)
                    ])
                    guard try await asset.load(.isPlayable) else {
                        throw ClientError.operationFailed(String(localized: "macOS cannot play this media format or codec. Download it to use another player."))
                    }
                    try Task.checkCancellation()
                    guard current == version else { return }
                    let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
                    player.allowsExternalPlayback = false
                    content = .media(file, player)
                }
            }
        } catch {
            if current == version { self.error = error.presentableMessage }
        }
    }
}
