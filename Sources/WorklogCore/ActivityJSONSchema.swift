import Foundation

/// Encodes Ollama's JSON Schema format without untyped dictionaries.
indirect enum ActivityJSONSchema: Encodable {
    case object([String: ActivityJSONSchema])
    case array(ActivityJSONSchema, Int, minimum: Int = 0)
    case string([String]?)
    case number(Double, Double)
    case nullable(ActivityJSONSchema)
    private enum Keys: String, CodingKey { case type, properties, required, additionalProperties, items, maxItems, minItems, minimum, maximum, anyOf, `enum` }
    func encode(to encoder: Encoder) throws {
        var box = encoder.container(keyedBy: Keys.self)
        switch self {
        case .object(let properties):
            try box.encode("object", forKey: .type); try box.encode(properties, forKey: .properties)
            try box.encode(properties.keys.sorted(), forKey: .required); try box.encode(false, forKey: .additionalProperties)
        case .array(let item, let maximum, let minimum):
            try box.encode("array", forKey: .type); try box.encode(item, forKey: .items); try box.encode(maximum, forKey: .maxItems); try box.encode(minimum, forKey: .minItems)
        case .string(let values):
            try box.encode("string", forKey: .type); try box.encodeIfPresent(values, forKey: .enum)
        case .number(let minimum, let maximum):
            try box.encode("number", forKey: .type); try box.encode(minimum, forKey: .minimum); try box.encode(maximum, forKey: .maximum)
        case .nullable(let schema):
            try box.encode([NullableBranch.schema(schema), .null], forKey: .anyOf)
        }
    }
    static func response(duration: Double, evidenceIDs: [String]) -> ActivityJSONSchema {
        let confidence = Self.number(0, 1)
        let ids = Self.array(.string(evidenceIDs), 24, minimum: 1)
        let fact = Self.object([
            "kind": .string(["outcome", "problem", "decision"]), "text": .string(nil), "evidenceIDs": ids,
            "confidence": confidence, "status": .nullable(.string(["OPEN", "RESOLVED", "UNKNOWN"])),
            "provenance": .string(["INFERRED"])
        ])
        let entity = Self.object(["kind": .string(["application", "repository", "file", "website", "domain", "technology", "language", "framework", "person", "document", "topic"]), "name": .string(nil)])
        let activity = Self.object([
            "startOffset": .number(0, duration), "endOffset": .number(0, duration), "title": .string(nil), "summary": .string(nil),
            "category": .string(ActivityCategory.allCases.map(\.rawValue)), "intent": .string(ActivityIntent.allCases.map(\.rawValue)),
            "project": .nullable(.string(nil)), "confidence": confidence, "classificationConfidence": confidence,
            "backgroundContext": .string(nil), "entities": .array(entity, 32), "evidenceIDs": ids, "facts": .array(fact, 24)
        ])
        return .object(["activities": .array(activity, 48, minimum: 1)])
    }
    private enum NullableBranch: Encodable {
        case schema(ActivityJSONSchema), null
        func encode(to encoder: Encoder) throws {
            switch self {
            case .schema(let schema): try schema.encode(to: encoder)
            case .null:
                var box = encoder.container(keyedBy: Keys.self); try box.encode("null", forKey: .type)
            }
        }
    }
}
enum OllamaFormat: Encodable {
    case json, schema(ActivityJSONSchema)
    func encode(to encoder: Encoder) throws {
        switch self {
        case .json: var box = encoder.singleValueContainer(); try box.encode("json")
        case .schema(let schema): try schema.encode(to: encoder)
        }
    }
}
