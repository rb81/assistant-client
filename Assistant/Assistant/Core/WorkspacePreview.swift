import AVFoundation
import Foundation
import ImageIO
import Observation
import OSLog
import PDFKit
import UniformTypeIdentifiers

/// Native previewers only receive supported contained files, never playlists or remote URLs.
enum WorkspacePreviewKind: Equatable {
    case markdown, pdf, quickLook, media, image, text

    init?(path: String) {
        switch (path as NSString).pathExtension.lowercased() {
        case "md", "markdown", "mdown": self = .markdown
        case "pdf": self = .pdf
        case "doc", "docx", "xls", "xlsx", "ppt", "pptx", "odt", "ods", "odp", "pages", "numbers", "key", "rtf":
            self = .quickLook
        case "ttf", "otf": self = .quickLook
        case "mp3", "m4a", "aac", "wav", "aiff", "aif", "flac", "mp4", "m4v", "mov", "webm", "ogg", "opus":
            self = .media
        case "m3u", "m3u8", "pls", "asx", "xspf", "webloc", "url", "inetloc": return nil
        case "svg", "html", "htm", "log", "yaml", "yml", "toml", "ini", "conf", "jsonl", "ndjson", "sql", "env":
            self = .text
        case "swift", "py", "rb", "js", "ts", "tsx", "jsx", "mjs", "cjs", "go", "rs", "java", "kt", "kts",
             "c", "h", "m", "mm", "cc", "cpp", "hpp", "cs", "sh", "bash", "zsh", "fish", "css", "scss", "lua":
            self = .text
        default:
            if let type = UTType(filenameExtension: (path as NSString).pathExtension) {
                if type.conforms(to: .image) { self = .image; return }
                if type.conforms(to: .audio) || type.conforms(to: .movie) { self = .media; return }
                if type.conforms(to: .text) || type.conforms(to: .sourceCode) || type.conforms(to: .json) ||
                    type.conforms(to: .xml) || type.conforms(to: .propertyList) {
                    self = .text; return
                }
            }
            guard ["readme", "license", "notice", "dockerfile", "makefile", ".gitignore", ".env"]
                .contains((path as NSString).lastPathComponent.lowercased()) else { return nil }
            self = .text
        }
    }

    var maximumBytes: Int64 {
        switch self {
        case .markdown, .text: 2 * 1024 * 1024
        case .pdf, .quickLook, .image: 16 * 1024 * 1024
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
        case quickLook(PreviewFile)
        case media(PreviewFile, AVPlayer)
        case image(CGImage)
        case text(String)
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
        } else if case .quickLook(let file) = content {
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
            case .text:
                let encoding: String.Encoding = data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) ? .utf16 : .utf8
                guard let text = String(data: data, encoding: encoding), !text.contains("\0") else {
                    throw ClientError.operationFailed(String(localized: "This file is not supported UTF-8 or UTF-16 text. Download it to use another app."))
                }
                content = .text(text)
            case .image:
                let image = try await Task.detached(priority: .userInitiated) { try Self.decodeImage(data) }.value
                try Task.checkCancellation()
                guard current == version else { return }
                content = .image(image)
            case .pdf:
                guard let document = PDFDocument(data: data), document.pageCount > 0 else {
                    throw ClientError.operationFailed(String(localized: "This PDF could not be opened. It may be damaged or encrypted."))
                }
                content = .pdf(document)
            case .quickLook, .media:
                let file = try await Task.detached(priority: .userInitiated) { try PreviewFile(data: data, name: path) }.value
                try Task.checkCancellation()
                guard current == version else { return }
                if kind == .quickLook {
                    content = .quickLook(file)
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

    /// Decode a bounded, orientation-correct first frame instead of allocating an unbounded full-size bitmap.
    nonisolated private static func decodeImage(_ data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            throw ClientError.operationFailed(String(localized: "macOS could not decode this image. It may be damaged or unsupported."))
        }
        guard width.doubleValue > 0, height.doubleValue > 0, width.doubleValue * height.doubleValue <= 80_000_000 else {
            throw ClientError.operationFailed(String(localized: "This image is too large to preview safely. Download it to open it in another app."))
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 4096,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ClientError.operationFailed(String(localized: "macOS could not decode this image. It may be damaged or unsupported."))
        }
        return image
    }
}
