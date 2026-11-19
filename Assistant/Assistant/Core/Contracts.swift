import Foundation

/// Lossless JSON used for the API's extensible domain argument and result schemas.
enum JSONValue: Codable, Sendable, Equatable {
    case object([String: JSONValue]), array([JSONValue]), string(String)
    case integer(Int64), number(Double), bool(Bool), null

    /// Decodes JSON without unsafe untyped casts.
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode(Int64.self) { self = .integer(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    /// Encodes a value for an authenticated request.
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    /// Returns a named member when this value is an object.
    subscript(_ key: String) -> JSONValue? {
        guard case .object(let values) = self else { return nil }
        return values[key]
    }

    /// Extracts a string without coercing incompatible server data.
    var string: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    /// Extracts an array without inventing an empty successful result.
    var array: [JSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    /// Reads exact integer identifiers without floating-point coercion.
    var integer: Int64? {
        guard case .integer(let value) = self else { return nil }
        return value
    }

    /// Formats structured server data for a text-only inspector.
    func formatted() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    /// Parses user-authored domain arguments using the same JSON representation.
    static func parse(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(Self.self, from: Data(text.utf8))
    }
}

/// Non-secret connection metadata; SSH and API credentials are never encoded here.
struct ConnectionProfile: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name = "Assistant"
    var host = ""
    var sshPort = 22
    var local = false
    var instanceID: String?

    /// Validates destinations before passing them as individual OpenSSH arguments.
    func validate() throws {
        guard (1...65535).contains(sshPort), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.count <= 120 else { throw ClientError.invalidProfile }
        guard local || (
            !host.isEmpty && host.utf8.count <= 255 &&
            host.utf8.first.map { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) } == true &&
            host.utf8.allSatisfy { byte in
                (48...57).contains(byte) || (65...90).contains(byte) ||
                (97...122).contains(byte) || Array("_.@:-".utf8).contains(byte)
            }
        ) else { throw ClientError.invalidProfile }
    }
}

/// Fixed installed-launcher credential handoff, deliberately separate from API v2.
struct ConnectionDiscovery: Decodable, Sendable {
    let apiVersion: Int
    let host: String
    let port: Int
    let token: String

    /// Rejects non-loopback handoffs and malformed administrative credentials.
    func validate() throws {
        guard apiVersion == 1, host == "127.0.0.1", (1...65535).contains(port),
              (43...128).contains(token.utf8.count),
              token.utf8.allSatisfy({ byte in
                  (48...57).contains(byte) || (65...90).contains(byte) ||
                  (97...122).contains(byte) || byte == 45 || byte == 95
              }) else { throw ClientError.invalidDiscovery }
    }
}

/// Negotiated protocol and immutable installation identity.
struct InstanceHealth: Decodable, Sendable {
    let apiVersion: Int
    let instanceID: String
    let name: String
    let capabilities: [String]
    let readOnly: Bool

    private enum CodingKeys: String, CodingKey {
        case apiVersion, name, capabilities, readOnly
        case instanceID = "instanceId"
    }

    /// Requires the writable management protocol, not merely a responsive port.
    func validate(expectedInstance: String?) throws {
        guard apiVersion == 2, !readOnly, !instanceID.isEmpty,
              capabilities.contains("configuration.read") else { throw ClientError.incompatibleAPI }
        if let expectedInstance, expectedInstance != instanceID { throw ClientError.instanceMismatch }
    }
}

/// Typed server-managed asynchronous mutation status.
struct ManagementOperation: Decodable, Identifiable, Sendable {
    let id: String
    let action: String
    let state: String
    let progress: String
    let error: String?
    let result: JSONValue?

    /// Distinguishes accepted/running mutations from terminal outcomes.
    var pending: Bool { state == "queued" || state == "running" }
}

/// Inbox deliveries are deduplicated by server ID, not message content.
struct ClientMessage: Decodable, Identifiable, Sendable {
    let id: Int
    let taskID: Int?
    let purpose: String
    let body: String
    let createdAt: String
    let attachments: [JSONValue]?
    let status: String?
    let fallbackChannel: String?
    let error: String?

    private enum CodingKeys: String, CodingKey {
        case id, purpose, body, createdAt, attachments, status, fallbackChannel, error
        case taskID = "taskId"
    }
}

/// Server timing controls both availability and delivery fallback.
struct ClientPoll: Decodable, Sendable {
    let messages: [ClientMessage]
    let pollIntervalSeconds: Int
    let availabilityTimeoutSeconds: Int
}

/// Retained delivery history uses its own backward pagination cursor.
struct ClientHistory: Decodable, Sendable {
    let messages: [ClientMessage]
    let nextBeforeID: Int?

    private enum CodingKeys: String, CodingKey {
        case messages
        case nextBeforeID = "nextBeforeId"
    }
}

/// Credential status contains metadata only; saved values never reach the UI.
struct CredentialInventory: Decodable, Sendable {
    let credentials: [SavedCredential]
}

/// Activation state is reported by the server, not inferred from a masked text field.
struct SavedCredential: Decodable, Sendable {
    let name: String
    let status: String

    var active: Bool { status == "configured" }
    var title: String {
        switch status {
        case "configured": return String(localized: "Saved and active")
        case "activation pending": return String(localized: "Saved · Apply to activate")
        case "removal pending": return String(localized: "Removal pending")
        default: return String(localized: "Status unknown")
        }
    }
}

/// Catalog field metadata is supplied by the server, not duplicated in the UI.
struct SettingField: Decodable, Identifiable, Sendable {
    let group: String
    let key: String
    let label: String
    var value: String
    let secret: Bool
    let boolean: Bool
    let editable: Bool
    let editRestriction: String?
    var metadata: JSONValue?
    var defaultValue: JSONValue?
    var id: String { key }

    private enum CodingKeys: String, CodingKey {
        case group, key, label, value, secret, boolean, editable, editRestriction, metadata
        case defaultValue = "default"
    }

    /// Plain-language explanation; older servers only supplied schema descriptions.
    var help: String? { metadata?["help"]?.string ?? metadata?["description"]?.string }
    /// Sub-heading within the group's page, such as a calendar provider.
    var section: String? { metadata?["section"]?.string }
    /// Allowed values when the server restricts a field to a fixed list.
    var choices: [String]? { (metadata?["choices"]?.array ?? metadata?["enum"]?.array)?.compactMap(\.string) }
    /// Friendly display names never change the wire value sent back to the server.
    func choiceLabel(_ value: String) -> String { metadata?["choice_labels"]?[value]?.string ?? value }
    /// Caution shown beside the field, or why it cannot be edited here.
    var warning: String? { metadata?["warning"]?.string ?? editRestriction }
    /// Readable default for the help popover; empty defaults are omitted.
    var defaultText: String? {
        switch defaultValue ?? .null {
        case .string(let text): return text.isEmpty ? nil : text
        case .integer(let number): return String(number)
        case .number(let number): return String(number)
        case .bool(let flag): return flag ? "true" : "false"
        case .null: return nil
        case let value: return try? value.formatted()
        }
    }
}

/// Server-defined navigation for settings: top-level pages, nested sections, and their introductions.
struct SettingGroup: Decodable, Identifiable, Sendable, Hashable {
    let id: String
    let title: String
    let help: String?
    let parent: String?
    var section: String?
    let basic: Bool
    var destination: String? = nil
    var advancedTitle: String? = nil
}

/// Revision-bound settings and instructions used for preview/confirmed saves.
struct FullConfiguration: Decodable, Sendable {
    let revision: String
    let setupComplete: Bool
    var settings: [SettingField]
    var instructions: String
    let setupNotice: String
    var groups: [SettingGroup]?
    var agentYaml: String?
    var agentYamlBackups: [String]?
    var instructionsConfigured: Bool?
    var credentialNames: [String]?

    /// Keep effective values without replacing refreshed navigation and field presentation metadata.
    mutating func mergeLoadedValues(_ loaded: [String: SettingField]) {
        settings = settings.map { descriptor in
            var field = descriptor
            if let effective = loaded[field.key] { field.value = effective.value }
            return field
        }
    }
}

/// A redacted saved value; credentials and instruction bodies never enter this review.
struct SavedSettingChange: Decodable, Identifiable, Sendable {
    let key: String
    let label: String
    let context: String?
    let value: String
    var id: String { key }
}

/// Server-persisted activation tracking works across client restarts and multiple Macs.
struct ConfigurationActivation: Decodable, Sendable {
    let revision: String
    let tracked: Bool
    let pending: Bool
    let requiresRebuild: Bool
    let changes: [SavedSettingChange]
}

/// Acknowledgments confirm delivery, not whether a human read the message.
struct ClientAcknowledgment: Decodable, Sendable {
    let acknowledged: [Int]
}

/// Persisted mutation metadata excludes request bodies, secret values, and file bytes.
struct OperationReference: Codable, Identifiable, Sendable {
    let id: UUID
    let instanceID: String
    let key: String
    let action: String
    var operationID: String?
    let submittedAt: Date
}

/// Explicit errors distinguish trust, protocol, connectivity, and ambiguous writes.
enum ClientError: LocalizedError, Equatable {
    case invalidProfile, invalidDiscovery, incompatibleAPI, instanceMismatch
    case sshFailed, sshTimedOut, oversizedResponse, invalidResource
    case http(Int), server(Int, String), malformedResponse, operationFailed(String), unavailable, unacknowledged
    case serverOutdated(String)
    case sshAuthentication, sshTrust, sshHostChanged, sshResolution, sshUnreachable, sshNoRoute
    case launcherMissing, launcherPermission, dockerMissing, dockerUnavailable, managementNotRunning
    case discoveryFailed(Int32)

    /// User-facing errors intentionally exclude credentials and raw helper output.
    var errorDescription: String? {
        switch self {
        case .invalidProfile: return String(localized: "Enter a valid SSH alias or user@host and port.")
        case .invalidDiscovery: return String(localized: "The installed launcher returned an invalid connection handoff.")
        case .incompatibleAPI: return String(localized: "This server does not support writable Management API v2.")
        case .instanceMismatch: return String(localized: "This profile reached a different installation. Verify the server before creating a new profile.")
        case .sshFailed: return String(localized: "SSH discovery failed. Verify the host key and key/agent authentication in Terminal, then check the installed launcher and Docker access.")
        case .sshAuthentication: return String(localized: "SSH key/agent authentication failed. Terminal may be using a password or prompting to unlock a key; this client cannot answer those prompts. Configure key authentication and load the key into your SSH agent.")
        case .sshTrust: return String(localized: "SSH does not trust this host yet. Verify its fingerprint and establish host trust in Terminal before reconnecting.")
        case .sshHostChanged: return String(localized: "The server's SSH host key has changed. Verify the server's identity in Terminal; this client will not bypass host-key checking.")
        case .sshResolution: return String(localized: "SSH could not resolve this host. Check the destination or SSH configuration alias.")
        case .sshUnreachable: return String(localized: "SSH could not reach this host and port. Check the server, network, and SSH port.")
        case .sshNoRoute: return String(localized: "SSH has no route to this server. For a local-network server, allow Assistant in System Settings > Privacy & Security > Local Network, then reconnect. Also check the server address and network route.")
        case .launcherMissing: return String(localized: "SSH connected, but ~/.local/bin/assistant is missing on the server. Install the Assistant server launcher for this SSH account.")
        case .launcherPermission: return String(localized: "SSH connected, but this account cannot execute ~/.local/bin/assistant. Check the installed launcher's permissions.")
        case .dockerMissing: return String(localized: "The installed launcher cannot find Docker. Ensure Docker with Compose is available in the server's noninteractive SSH environment.")
        case .dockerUnavailable: return String(localized: "The installed launcher cannot access Docker. Start Docker and grant the SSH account access to the selected local Docker daemon.")
        case .managementNotRunning: return String(localized: "SSH and the launcher work, but the management service is stopped. Start the server with assistant server start.")
        case .discoveryFailed(let status): return String(localized: "The connection launcher exited with status \(status). Run ~/.local/bin/assistant connect on the server to inspect its error; do not share the credential handoff.")
        case .sshTimedOut: return String(localized: "SSH did not become ready in time. Check server reachability and authentication.")
        case .oversizedResponse: return String(localized: "The response exceeded the client display limit.")
        case .invalidResource: return String(localized: "The client selected an invalid API resource.")
        case .http(401): return String(localized: "The server rejected this session's credentials. Reconnect to continue.")
        case .http(503): return String(localized: "The server is busy with another management task. Try again in a moment.")
        case .http(let status): return String(localized: "Management request failed with HTTP \(status). Check authentication, saved configuration, and server health.")
        case .server(_, let message): return message
        case .serverOutdated(let feature): return String(localized: "The server is older than this app and does not support \(feature). Update the server, then reconnect: run `./run.sh server start` (or `assistant server start`) on the server.")
        case .malformedResponse: return String(localized: "The server returned an incompatible response.")
        case .operationFailed(let message): return message
        case .unavailable: return String(localized: "Connect to an instance first.")
        case .unacknowledged: return String(localized: "Some deliveries were not acknowledged. They will be offered again.")
        }
    }
}

extension ClientError {
    /// HTTP status for transport and server failures, so callers can branch without parsing text.
    var httpStatus: Int? {
        switch self {
        case .http(let status), .server(let status, _): return status
        default: return nil
        }
    }
}

extension Error {
    /// True when work stopped because the view or connection moved on, which is never a user-facing failure.
    var isCancellation: Bool {
        if self is CancellationError { return true }
        if let error = self as? URLError, error.code == .cancelled { return true }
        return (self as NSError).domain == NSURLErrorDomain && (self as NSError).code == NSURLErrorCancelled
    }

    /// Message to show the user, or nil when the error is a cancellation that should stay silent.
    var presentableMessage: String? {
        guard !isCancellation else { return nil }
        if let error = self as? URLError {
            switch error.code {
            case .timedOut:
                return String(localized: "The server took too long to respond. It may be busy; try again shortly.")
            case .networkConnectionLost, .cannotConnectToHost, .notConnectedToInternet:
                return String(localized: "The connection to the server was interrupted. Reconnecting may help.")
            default: break
            }
        }
        return localizedDescription
    }
}

/// Shared API decoding keeps wire naming independent of Swift property names.
enum Wire {
    /// Creates a decoder for the server's snake_case contracts.
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}
