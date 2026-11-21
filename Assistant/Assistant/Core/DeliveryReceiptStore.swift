import CryptoKit
import Foundation

/// Buffers received deliveries before acknowledging transport receipt, independently of reading them.
protocol DeliveryReceiptStoring: Sendable {
    func save(_ messages: [ClientMessage], instance: String, client: String) async throws
    func load(instance: String, client: String) async throws -> [ClientMessage]
    func remove(instance: String, client: String) async throws
    func clear() async throws
}

/// Atomic private journals cover a crash or lost acknowledgment; confirmed receipts remain in server history.
actor DeliveryReceiptStore: DeliveryReceiptStoring {
    private let directory: URL
    private static let journalLimit = 4 * 1024 * 1024

    /// Tests inject an isolated directory; ordinary launches use this app's private support folder.
    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Assistant/DeliveryReceipts", isDirectory: true)
    }

    /// Content is durably buffered before an acknowledgment can leave this client.
    func save(_ messages: [ClientMessage], instance: String, client: String) throws {
        let data = try JSONEncoder().encode(messages)
        guard data.count <= Self.journalLimit else { throw ClientError.oversizedResponse }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let url = file(instance: instance, client: client)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let handle = try FileHandle(forWritingTo: url)
        try handle.synchronize()
        try handle.close()
    }

    /// Only the verified installation and registered client can restore a pending receipt.
    func load(instance: String, client: String) throws -> [ClientMessage] {
        let url = file(instance: instance, client: client)
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let size = attributes[.size] as? NSNumber, size.intValue <= Self.journalLimit else {
                throw ClientError.oversizedResponse
            }
            return try JSONDecoder().decode([ClientMessage].self, from: Data(contentsOf: url))
        } catch let error as CocoaError where Self.isMissing(error) {
            return []
        }
    }

    /// Delete a journal only after the server confirms every receipt in it.
    func remove(instance: String, client: String) throws {
        let url = file(instance: instance, client: client)
        do { try FileManager.default.removeItem(at: url) }
        catch let error as CocoaError where Self.isMissing(error) { return }
    }

    /// Clearing local caches removes only this store's individually identified journal files.
    func clear() throws {
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
        } catch let error as CocoaError where Self.isMissing(error) {
            return
        }
        for url in files {
            let key = url.deletingPathExtension().lastPathComponent
            guard url.pathExtension == "json", key.count == 64,
                  key.allSatisfy({ "0123456789abcdef".contains($0) }),
                  try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            try FileManager.default.removeItem(at: url)
        }
    }

    private func file(instance: String, client: String) -> URL {
        let key = SHA256.hash(data: Data("\(instance)\u{0}\(client)".utf8))
            .map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(key + ".json")
    }

    private static func isMissing(_ error: CocoaError) -> Bool {
        error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile
    }
}
