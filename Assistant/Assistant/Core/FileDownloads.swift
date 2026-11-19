import CryptoKit
import Foundation

/// Downloads use only contained workspace paths or project-bound file identities.
enum FileDownloadSource {
    case workspace(String)
    case project(Int, Int)
}

extension ClientModel {
    /// Reads bounded chunks and verifies the server digest before exposing any downloaded content.
    func downloadFile(_ source: FileDownloadSource, maximumBytes: Int64 = 64 * 1024 * 1024) async throws -> Data {
        var data = Data()
        var digest: String?
        var expectedSize: Int64?
        var position: Int64 = 0
        while true {
            try Task.checkCancellation()
            let result: JSONValue
            switch source {
            case .workspace(let path):
                result = try await query("query", payload: .object([
                    "action": .string("workspace.read"),
                    "arguments": .object(["path": .string(path), "offset": .integer(position),
                                          "limit": .integer(1_048_576)])
                ]))
            case .project(let project, let file):
                result = try await read("projects/\(project)/files/\(file)/content?offset=\(position)&limit=1048576")
            }
            guard let encoded = result["content_base64"]?.string, let chunk = Data(base64Encoded: encoded),
                  let size = result["size_bytes"]?.integer, let next = result["next_offset"]?.integer,
                  let hash = result["sha256"]?.string, next == position + Int64(chunk.count),
                  size >= 0, next <= size, digest == nil || digest == hash,
                  expectedSize == nil || expectedSize == size else { throw ClientError.malformedResponse }
            guard size <= maximumBytes else {
                let limit = ByteCountFormatter.string(fromByteCount: maximumBytes, countStyle: .binary)
                throw ClientError.operationFailed(String(localized: "This file exceeds the \(limit) limit for this view."))
            }
            digest = hash
            expectedSize = size
            data.append(chunk)
            position = next
            if position == size { break }
            guard !chunk.isEmpty else { throw ClientError.malformedResponse }
        }
        let actualDigest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actualDigest == digest else {
            throw ClientError.operationFailed(String(localized: "The downloaded content did not match its server digest. No file was saved."))
        }
        return data
    }
}
