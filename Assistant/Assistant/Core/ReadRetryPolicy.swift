import Foundation

/// Retries apply only to idempotent reads, never submissions or validation failures.
enum ReadRetryPolicy {
    static func isTransient(_ error: Error) -> Bool {
        if let status = (error as? ClientError)?.httpStatus {
            return [408, 429, 500, 502, 503, 504].contains(status)
        }
        guard let error = error as? URLError else { return false }
        return [.timedOut, .networkConnectionLost, .cannotConnectToHost, .notConnectedToInternet,
                .dnsLookupFailed, .cannotFindHost].contains(error.code)
    }
}

extension ClientModel {
    /// Three attempts keep transient inventory failures quiet while retaining the last good snapshot.
    func readWithRetry(_ resource: String) async throws -> JSONValue {
        for attempt in 0..<3 {
            do { return try await read(resource) }
            catch {
                guard attempt < 2, ReadRetryPolicy.isTransient(error) else { throw error }
                try await Task.sleep(for: .milliseconds(250 * (attempt + 1)))
            }
        }
        throw ClientError.unavailable
    }
}
