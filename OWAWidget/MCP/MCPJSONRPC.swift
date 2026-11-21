import Foundation

/// A JSON value with lossless integers (JSON-RPC ids must round-trip exactly).
enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    /// Integers, and doubles that hold a whole number (some clients send `30.0`).
    var intValue: Int? {
        switch self {
        case .int(let value): return Int(exactly: value)
        case .double(let value): return value.rounded() == value ? Int(exactly: value) : nil
        default: return nil
        }
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(integerLiteral value: Int) { self = .int(Int64(value)) }
    init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
    init(nilLiteral: ()) { self = .null }
}

extension JSONValue {
    static func optional(_ value: String?) -> JSONValue {
        value.map(JSONValue.string) ?? .null
    }
}

enum JSONLine {
    static func decode(_ line: Data) -> JSONValue? {
        try? JSONDecoder().decode(JSONValue.self, from: line)
    }

    /// One line of the stdio framing: compact, no embedded newlines (JSONEncoder escapes them).
    static func encode(_ value: JSONValue) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)) ?? Data("{}".utf8)
    }

    static func encodeString(_ value: JSONValue) -> String {
        String(data: encode(value), encoding: .utf8) ?? "{}"
    }
}

/// JSON-RPC error codes the server uses.
enum JSONRPCErrorCode {
    static let parseError = -32700
    static let invalidRequest = -32600
    static let methodNotFound = -32601
    static let invalidParams = -32602
    static let internalError = -32603
    /// Resource not found, before 2026-07-28 (which uses `invalidParams`).
    static let resourceNotFound = -32002
    /// MCP 2026-07-28 `UnsupportedProtocolVersionError`.
    static let unsupportedProtocolVersion = -32022
}

enum JSONRPC {
    static func result(id: JSONValue, _ result: JSONValue) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    static func error(id: JSONValue, code: Int, message: String, data: JSONValue? = nil) -> JSONValue {
        var error: [String: JSONValue] = ["code": .int(Int64(code)), "message": .string(message)]
        if let data { error["data"] = data }
        return ["jsonrpc": "2.0", "id": id, "error": .object(error)]
    }
}
