import Foundation

/// Injectable API boundary; native UI never invokes server domain operations locally.
protocol ManagementAPI: Sendable {
    /// Sends a bounded authenticated request to a relative v2 resource.
    func request(_ resource: String, body: JSONValue?, key: String?) async throws -> Data
}

/// Prevents a redirect from forwarding an administrative credential elsewhere.
final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    /// Refuses all redirects on the loopback-only management connection.
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// HTTP transport retains tokens only in native session memory.
final class HTTPManagementAPI: ManagementAPI {
    private let baseURL: URL
    private let token: String
    private let session: URLSession
    static let responseLimit = 2 * 1024 * 1024

    /// Creates an ephemeral, proxy-free connection to a local API or owned SSH tunnel.
    init(port: Int, token: String, session: URLSession? = nil) throws {
        guard (1...65535).contains(port), let url = URL(string: "http://127.0.0.1:\(port)/v2/") else {
            throw ClientError.invalidDiscovery
        }
        baseURL = url
        self.token = token
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            // Server reads may wait for a Docker helper for up to three minutes.
            configuration.timeoutIntervalForRequest = 200
            configuration.timeoutIntervalForResource = 240
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.connectionProxyDictionary = [:]
            self.session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        }
    }

    /// Validates and creates a request without allowing arbitrary origins or paths.
    func makeRequest(_ resource: String, body: JSONValue?, key: String?) throws -> URLRequest {
        let path = String(resource.split(separator: "?", maxSplits: 1).first ?? "")
        guard !resource.isEmpty, !resource.hasPrefix("/"), !resource.contains("://"),
              !(path.removingPercentEncoding ?? path).split(separator: "/").contains(".."),
              !resource.contains("\\"),
              let url = URL(string: resource, relativeTo: baseURL)?.absoluteURL,
              url.host == baseURL.host, url.port == baseURL.port, url.scheme == "http",
              url.path.hasPrefix("/v2/"), url.fragment == nil else { throw ClientError.invalidResource }
        var request = URLRequest(url: url)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        if let key { request.setValue(key, forHTTPHeaderField: "Idempotency-Key") }
        return request
    }

    /// Reads retry briefly when the server is busy or the connection blips; writes never retry here.
    func request(_ resource: String, body: JSONValue? = nil, key: String? = nil) async throws -> Data {
        let request = try makeRequest(resource, body: body, key: key)
        var attempt = 0
        while true {
            do {
                return try await send(request)
            } catch {
                attempt += 1
                guard body == nil, attempt < Self.readAttempts, Self.retryable(error) else { throw error }
                try await Task.sleep(for: .milliseconds(500 * (1 << attempt)))
            }
        }
    }

    static let readAttempts = 3

    /// Busy executors and dropped connections are transient; everything else is reported immediately.
    static func retryable(_ error: Error) -> Bool {
        if let error = error as? ClientError { return error.httpStatus == 503 }
        guard let error = error as? URLError else { return false }
        return error.code == .networkConnectionLost
    }

    /// Streams response bytes with a hard limit, including responses without Content-Length.
    private func send(_ request: URLRequest) async throws -> Data {
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw ClientError.malformedResponse }
        guard response.expectedContentLength <= Self.responseLimit else { throw ClientError.oversizedResponse }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < Self.responseLimit else { throw ClientError.oversizedResponse }
            data.append(byte)
        }
        guard (200...299).contains(response.statusCode) else {
            throw Self.failure(status: response.statusCode, body: data)
        }
        return data
    }

    /// Uses the server's curated `{"error": {"message"}}` explanation when one is provided.
    static func failure(status: Int, body: Data) -> ClientError {
        struct Envelope: Decodable {
            struct Detail: Decodable { let message: String? }
            let error: Detail?
        }
        guard let message = (try? JSONDecoder().decode(Envelope.self, from: body))?.error?.message?
            .trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty else {
            return .http(status)
        }
        return .server(status, message)
    }
}

extension ManagementAPI {
    /// Reads a typed resource through the same bounded transport.
    func read<T: Decodable & Sendable>(_ resource: String, as type: T.Type) async throws -> T {
        try Wire.decoder().decode(type, from: await request(resource, body: nil, key: nil))
    }

    /// Submits a typed operation with one key for the complete submission intent.
    func submit(_ payload: JSONValue, key: String) async throws -> ManagementOperation {
        try Wire.decoder().decode(
            ManagementOperation.self,
            from: await request("operations", body: payload, key: key)
        )
    }
}
