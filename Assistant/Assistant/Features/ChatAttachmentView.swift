import AppKit
import AVFoundation
import SwiftUI

/// Attachments are fetched on demand through the authenticated API, never from paths embedded in chat text.
struct ChatAttachmentView: View {
    let model: ClientModel
    let attachment: ChatAttachment
    @State private var data: Data?
    @State private var player: AVAudioPlayer?
    @State private var image: NSImage?
    @State private var loading = false
    @State private var error: String?

    private var name: String { (attachment.filename as NSString?)?.lastPathComponent ?? String(localized: "Attachment") }
    private var source: FileDownloadSource? {
        guard attachment.available else { return nil }
        if let project = attachment.projectID, let file = attachment.fileID { return .project(project, file) }
        if let path = attachment.workspacePath { return .workspace(path) }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: attachment.audio ? "waveform" : "doc.fill").foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(name).font(.callout.weight(.medium))
                    if let size = attachment.sizeBytes {
                        Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                            .font(.caption).foregroundStyle(Theme.secondary)
                    }
                }
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                if attachment.audio && player == nil {
                    Button("Load audio", systemImage: "play.circle") { Task { await loadAudio() } }
                        .disabled(source == nil || loading)
                }
                if attachment.contentType?.hasPrefix("image/") == true && image == nil {
                    Button("View image", systemImage: "photo") { Task { await loadImage() } }
                        .disabled(source == nil || loading)
                }
                Button("Download", systemImage: "arrow.down.circle") { Task { await save() } }
                    .disabled(source == nil || loading)
            }
            if let image {
                Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 320)
                    .accessibilityLabel(name)
            }
            if let player {
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    HStack(spacing: 12) {
                        Button(player.isPlaying ? "Pause" : "Play",
                               systemImage: player.isPlaying ? "pause.fill" : "play.fill") {
                            if player.isPlaying { player.pause() }
                            else {
                                if player.currentTime >= player.duration { player.currentTime = 0 }
                                if !player.play() { error = String(localized: "Audio playback could not start. Download the file to open it in another player.") }
                            }
                        }
                        Slider(value: Binding(get: { player.currentTime }, set: { player.currentTime = $0 }),
                               in: 0...max(player.duration, 0.01)).accessibilityLabel("Playback position")
                        Text(Duration.seconds(player.currentTime).formatted(.time(pattern: .minuteSecond)))
                            .font(.caption.monospacedDigit())
                    }
                }
            }
            if source == nil {
                Text("This attachment is no longer available for download.")
                    .font(.caption).foregroundStyle(Theme.secondary)
            }
            if let error { ErrorBanner(message: error) }
        }
        .padding(12)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
        .onDisappear { player?.stop() }
    }

    private func content() async throws -> Data {
        if let data { return data }
        guard let source else { throw ClientError.unavailable }
        let downloaded = try await model.downloadFile(source)
        data = downloaded
        return downloaded
    }

    private func loadAudio() async {
        loading = true
        defer { loading = false }
        do {
            let audio = try AVAudioPlayer(data: await content())
            guard audio.prepareToPlay() else { throw ClientError.operationFailed(String(localized: "This audio format cannot be played. Download the file to open it in another player.")) }
            player = audio
            error = nil
        } catch { self.error = error.presentableMessage ?? error.localizedDescription }
    }

    private func loadImage() async {
        loading = true
        defer { loading = false }
        do {
            guard let decoded = NSImage(data: try await content()) else {
                throw ClientError.operationFailed(String(localized: "This image format cannot be displayed. Download the file to open it in another app."))
            }
            image = decoded
            error = nil
        } catch { self.error = error.presentableMessage ?? error.localizedDescription }
    }

    private func save() async {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loading = true
        defer { loading = false }
        do {
            try await content().write(to: url, options: .atomic)
            error = nil
        } catch { self.error = error.presentableMessage ?? error.localizedDescription }
    }
}
