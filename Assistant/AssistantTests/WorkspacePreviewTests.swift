import AppKit
import AVFoundation
import PDFKit
import XCTest
@testable import Assistant

/// Verified file reads, selection races, and the lifetime of private native-preview files.
@MainActor
final class WorkspacePreviewTests: XCTestCase {
    private func client(_ api: ChatAPI) throws -> ClientModel {
        ClientModel(defaults: try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)), api: api,
                    health: InstanceHealth(apiVersion: 2, instanceID: "preview", name: "Assistant",
                                           capabilities: [], readOnly: false))
    }

    func testMarkdownAndPDFUseVerifiedWorkspaceContent() async throws {
        let api = ChatAPI()
        let model = try client(api)
        let preview = WorkspacePreview()
        let markdown = "# Notes\n\nFirst paragraph.\n\n- A useful list\n"
        await api.setWorkspaceFile("notes.md", data: Data(markdown.utf8))
        await preview.load("notes.md", model: model)
        guard case .markdown(let text) = preview.content else { return XCTFail("Expected Markdown preview") }
        XCTAssertEqual(text, markdown)
        let document = PDFDocument()
        let image = NSImage(size: NSSize(width: 100, height: 100), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            return true
        }
        document.insert(try XCTUnwrap(PDFPage(image: image)), at: 0)
        await api.setWorkspaceFile("notes.pdf", data: try XCTUnwrap(document.dataRepresentation()))
        await preview.load("notes.pdf", model: model)
        guard case .pdf(let pdf) = preview.content else { return XCTFail("Expected PDF preview: \(preview.error ?? "")") }
        XCTAssertEqual(pdf.pageCount, 1)
        XCTAssertNil(preview.error)
        XCTAssertFalse(preview.loading)
        preview.clear()
        XCTAssertNil(preview.content)
    }

    func testInvalidAndOversizedDocumentsHaveExplicitErrors() async throws {
        let api = ChatAPI()
        let model = try client(api)
        let preview = WorkspacePreview()
        await api.setWorkspaceFile("broken.pdf", data: Data("not a PDF".utf8))
        await preview.load("broken.pdf", model: model)
        XCTAssertNil(preview.content)
        XCTAssertNotNil(preview.error)
        await api.setWorkspaceFile("large.md", data: Data(repeating: 65, count: 2 * 1024 * 1024 + 1))
        await preview.load("large.md", model: model)
        XCTAssertNil(preview.content)
        XCTAssertNotNil(preview.error)
        let before = await api.resources.count
        await preview.load("playlist.m3u8", model: model)
        let after = await api.resources.count
        XCTAssertEqual(before, after, "Playlists must not load remote media")
        XCTAssertNil(preview.content)
        XCTAssertNotNil(preview.error)
    }

    func testLatePreviewCannotReplaceANewerSelection() async throws {
        let api = ChatAPI()
        let model = try client(api)
        let preview = WorkspacePreview()
        await api.setWorkspaceFile("old.md", data: Data("Old".utf8))
        await api.setWorkspaceFile("new.md", data: Data("New".utf8))
        await api.pauseNextRead("query")
        let old = Task { await preview.load("old.md", model: model) }
        for _ in 0..<100 {
            if await api.readIsPaused("query") { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let paused = await api.readIsPaused("query")
        XCTAssertTrue(paused)
        await preview.load("new.md", model: model)
        await api.resumeRead("query")
        await old.value
        guard case .markdown(let text) = preview.content else { return XCTFail("Expected current preview") }
        XCTAssertEqual(text, "New")
        XCTAssertFalse(preview.loading)
    }

    func testPreviewFileIsPrivateContainedAndRemovedAfterRelease() throws {
        let url = try autoreleasepool {
            let file = try PreviewFile(data: Data("fixture".utf8), name: "../notes/document.docx")
            XCTAssertEqual(file.url.lastPathComponent, "document.docx")
            let attributes = try FileManager.default.attributesOfItem(atPath: file.url.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            let parent = try FileManager.default.attributesOfItem(atPath: file.url.deletingLastPathComponent().path)
            XCTAssertEqual((parent[.posixPermissions] as? NSNumber)?.intValue, 0o700)
            XCTAssertEqual(try Data(contentsOf: file.url), Data("fixture".utf8))
            return file.url
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
        XCTAssertThrowsError(try PreviewFile(data: Data(), name: ".."))
    }

    func testAudioDoesNotAutoplayAndClearingReleasesPlayerItem() async throws {
        let api = ChatAPI()
        let model = try client(api)
        var wave = Data()
        func text(_ value: String) { wave.append(Data(value.utf8)) }
        func number<T: FixedWidthInteger>(_ value: T) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { wave.append(contentsOf: $0) }
        }
        text("RIFF"); number(UInt32(1_636)); text("WAVEfmt "); number(UInt32(16))
        number(UInt16(1)); number(UInt16(1)); number(UInt32(8_000)); number(UInt32(16_000))
        number(UInt16(2)); number(UInt16(16)); text("data"); number(UInt32(1_600))
        wave.append(Data(repeating: 0, count: 1_600))
        await api.setWorkspaceFile("audio/briefing.wav", data: wave)
        let preview = WorkspacePreview()
        await preview.load("audio/briefing.wav", model: model)
        guard case .media(let file, let player) = preview.content else {
            return XCTFail("Expected native audio preview: \(preview.error ?? "")")
        }
        XCTAssertEqual(file.url.lastPathComponent, "briefing.wav")
        XCTAssertEqual(player.rate, 0)
        XCTAssertNotNil(player.currentItem)
        preview.clear()
        XCTAssertEqual(player.rate, 0)
        XCTAssertNil(player.currentItem)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.url.path))
    }

    func testOfficePreviewReleasesItsPrivateFileOnDismissal() async throws {
        let api = ChatAPI()
        let model = try client(api)
        let data = Data(#"{\rtf1\ansi A small document}"#.utf8)
        await api.setWorkspaceFile("note.rtf", data: data)
        let preview = WorkspacePreview()
        await preview.load("note.rtf", model: model)
        guard case .office(let file) = preview.content else { return XCTFail("Expected an Office preview") }
        XCTAssertEqual(try Data(contentsOf: file.url), data)
        preview.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.url.deletingLastPathComponent().path))
    }
}
