import Foundation

/// Persist navigation descriptors only; saved values, credentials, defaults and source bodies are excluded.
enum SettingsMenuCache {
    static func snapshot(_ catalog: JSONValue) throws -> JSONValue {
        guard case .object(let object) = catalog, let fields = catalog["settings"]?.array else {
            throw ClientError.malformedResponse
        }
        let allowed = Set(["revision", "setup_complete"])
        var result = object.filter { allowed.contains($0.key) }
        result["instructions"] = .string("")
        result["setup_notice"] = .string("")
        if let groups = catalog["groups"]?.array {
            result["groups"] = .array(try groups.map { group in
                guard case .object(let object) = group else { throw ClientError.malformedResponse }
                let keys = Set(["id", "title", "parent", "section", "basic", "destination", "advanced_title"])
                return .object(object.filter { keys.contains($0.key) })
            })
        }
        result["settings"] = .array(try fields.map { field in
            guard case .object(let object) = field else { throw ClientError.malformedResponse }
            let allowed = Set(["group", "key", "label", "secret", "boolean", "editable"])
            var descriptor = object.filter { allowed.contains($0.key) }
            descriptor["value"] = .string("")
            if let level = field["metadata"]?["level"] { descriptor["metadata"] = .object(["level": level]) }
            return .object(descriptor)
        })
        let value = JSONValue.object(result)
        _ = try Wire.decoder().decode(FullConfiguration.self, from: JSONEncoder().encode(value))
        return value
    }

    static func read(instance: String, defaults: UserDefaults) throws -> JSONValue? {
        guard let data = defaults.data(forKey: "assistant.settingsMenu.\(instance)") else { return nil }
        return try snapshot(JSONDecoder().decode(JSONValue.self, from: data))
    }

    static func save(_ snapshot: JSONValue, instance: String, defaults: UserDefaults) throws {
        defaults.set(try JSONEncoder().encode(snapshot), forKey: "assistant.settingsMenu.\(instance)")
    }
}
