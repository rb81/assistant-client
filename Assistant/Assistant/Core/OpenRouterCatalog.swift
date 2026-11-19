import Foundation
import Observation

/// Public catalog metadata is separate from credentials and server configuration.
struct OpenRouterModel: Codable, Identifiable, Sendable {
    let id: String
    let name: String
    let architecture: Architecture?
    let supportedParameters: [String]?
    let endpoints: [String]?

    /// Dedicated speech and decision models must not appear in ordinary chat fields.
    struct Architecture: Codable, Sendable {
        let inputModalities: [String]?
        let outputModalities: [String]?
    }

    func supports(_ purpose: ModelPurpose) -> Bool {
        let outputs = architecture?.outputModalities ?? []
        switch purpose {
        case .chat: return outputs.contains("text") &&
            (endpoints == nil || endpoints?.contains("/api/v1/chat/completions") == true)
        case .tools: return supports(.chat) && supportedParameters?.contains("tools") == true
        case .speech: return outputs.contains("speech")
        case .decisions: return outputs.contains("decisions")
        }
    }
}

/// A model field's actual execution path determines eligible choices.
enum ModelPurpose: Sendable {
    case chat, tools, speech, decisions

    static func forSetting(_ key: String) -> ModelPurpose? {
        if key == "AGENT_TTS_MODEL" { return .speech }
        if key == "AGENT_SECURITY_DECISION_MODEL_MODEL" { return .decisions }
        if ["AGENT_LLM_MODEL", "AGENT_LLM_FALLBACK_MODEL", "AGENT_SECURITY_DEVELOPMENT_MODEL",
            "AGENT_DEEP_RESEARCH_MODEL"].contains(key) { return .tools }
        if key.hasSuffix("_MODEL") || key == "AGENT_FUSION_ANALYSIS_MODELS" {
            if key.hasPrefix("AGENT_EMBEDDINGS_") || key.hasPrefix("AGENT_TRANSCRIPTION_") { return nil }
            return .chat
        }
        return nil
    }
}

/// Injectable catalog discovery never receives an installation token or a provider API key.
protocol OpenRouterCatalogLoading: Sendable {
    func models(zdr: Bool) async throws -> [OpenRouterModel]
}

/// Fixed-origin HTTPS discovery with bounded responses, pagination, and no credential forwarding.
struct PublicOpenRouterCatalog: OpenRouterCatalogLoading {
    func models(zdr: Bool) async throws -> [OpenRouterModel] {
        struct Envelope: Decodable { let data: [OpenRouterModel] }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var models: [OpenRouterModel] = []
        let pageSize = 1000
        for page in 0..<10 {
            var components = URLComponents(string: "https://openrouter.ai/api/v1/models")
            components?.queryItems = [
                URLQueryItem(name: "output_modalities", value: "all"),
                URLQueryItem(name: "limit", value: String(pageSize)),
                URLQueryItem(name: "offset", value: String(page * pageSize))
            ] + (zdr ? [URLQueryItem(name: "zdr", value: "true")] : [])
            guard let url = components?.url else { throw ClientError.invalidResource }
            let (bytes, response) = try await session.bytes(from: url)
            guard let response = response as? HTTPURLResponse else { throw ClientError.malformedResponse }
            guard response.statusCode == 200 else { throw ClientError.http(response.statusCode) }
            let limit = 16 * 1024 * 1024
            guard response.expectedContentLength <= limit else { throw ClientError.oversizedResponse }
            var data = Data()
            for try await byte in bytes {
                guard data.count < limit else { throw ClientError.oversizedResponse }
                data.append(byte)
            }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let rows = try decoder.decode(Envelope.self, from: data).data
            guard rows.allSatisfy({ !$0.id.isEmpty && !$0.name.isEmpty }) else { throw ClientError.malformedResponse }
            models += rows
            if rows.count < pageSize {
                guard Set(models.map(\.id)).count == models.count else { throw ClientError.malformedResponse }
                return models.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            }
        }
        throw ClientError.oversizedResponse
    }
}

/// Full and ZDR lists are independently cached on this Mac; refresh scheduling is never a server setting.
@MainActor @Observable
final class OpenRouterCatalog {
    private struct Snapshot: Codable {
        let fetchedAt: Date
        let models: [OpenRouterModel]
    }
    static let refreshInterval: TimeInterval = 7 * 24 * 60 * 60
    private let defaults: UserDefaults
    private let loader: any OpenRouterCatalogLoading
    private var snapshots: [Bool: Snapshot] = [:]
    private var requests: [Bool: Task<Void, Never>] = [:]
    private(set) var loading: Set<Bool> = []
    private(set) var errors: [Bool: String] = [:]
    var automaticallyRefresh: Bool {
        didSet { defaults.set(automaticallyRefresh, forKey: "assistant.models.autoRefresh") }
    }

    init(defaults: UserDefaults, loader: any OpenRouterCatalogLoading = PublicOpenRouterCatalog()) {
        self.defaults = defaults
        self.loader = loader
        automaticallyRefresh = defaults.object(forKey: "assistant.models.autoRefresh") as? Bool ?? true
        for zdr in [false, true] {
            guard let data = defaults.data(forKey: Self.key(zdr)) else { continue }
            do { snapshots[zdr] = try JSONDecoder().decode(Snapshot.self, from: data) }
            catch { errors[zdr] = String(localized: "The saved model list could not be read. Refresh it to try again.") }
        }
    }

    private static func key(_ zdr: Bool) -> String { "assistant.models.\(zdr ? "zdr" : "full")" }

    func models(zdr: Bool, purpose: ModelPurpose) -> [OpenRouterModel] {
        (snapshots[zdr]?.models ?? []).filter { $0.supports(purpose) }
    }

    func fetchedAt(zdr: Bool) -> Date? { snapshots[zdr]?.fetchedAt }

    /// Explicit refresh bypasses age and the automatic preference, but still joins an in-flight read.
    func refresh(zdr: Bool, force: Bool = false, now: Date = Date()) async {
        if let request = requests[zdr] { await request.value; return }
        let due = snapshots[zdr].map { now.timeIntervalSince($0.fetchedAt) >= Self.refreshInterval } ?? true
        guard force || (automaticallyRefresh && due) else { return }
        let request = Task {
            loading.insert(zdr)
            defer { loading.remove(zdr); requests[zdr] = nil }
            do {
                let models = try await loader.models(zdr: zdr)
                try Task.checkCancellation()
                let snapshot = Snapshot(fetchedAt: now, models: models)
                defaults.set(try JSONEncoder().encode(snapshot), forKey: Self.key(zdr))
                snapshots[zdr] = snapshot
                errors[zdr] = nil
            } catch {
                if let message = error.presentableMessage { errors[zdr] = message }
            }

        }
        requests[zdr] = request
        await request.value
    }

    /// A running client checks weekly eligibility without repeatedly fetching the catalog.
    func refreshKnownLists(force: Bool = false) async {
        let policies = snapshots.isEmpty && force ? [false] : Array(snapshots.keys)
        for zdr in policies { await refresh(zdr: zdr, force: force) }
    }
}

#if DEBUG
/// Deterministic UI discovery never makes external requests.
struct PreviewCatalogLoader: OpenRouterCatalogLoading {
    func models(zdr: Bool) async throws -> [OpenRouterModel] {
        [OpenRouterModel(id: "example/model", name: "Example model",
                         architecture: .init(inputModalities: ["text"], outputModalities: ["text"]),
                         supportedParameters: ["tools"], endpoints: ["/api/v1/chat/completions"])]
    }
}
#endif
