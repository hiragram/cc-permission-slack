import Foundation

/// Claude Code PermissionRequest hook から stdin で受け取る入力
struct PermissionRequest: Codable, Sendable {
    let sessionId: String?
    let transcriptPath: String?
    let cwd: String?
    let permissionMode: String?
    let hookEventName: String?
    let toolName: String
    let toolInput: JSONValue
    let toolUseId: String

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case transcriptPath = "transcript_path"
        case cwd
        case permissionMode = "permission_mode"
        case hookEventName = "hook_event_name"
        case toolName = "tool_name"
        case toolInput = "tool_input"
        case toolUseId = "tool_use_id"
    }
}

/// 任意のJSON値を扱うための型
enum JSONValue: Codable, Sendable, CustomStringConvertible {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
            return
        }

        if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
            return
        }

        if let int = try? container.decode(Int.self) {
            self = .int(int)
            return
        }

        if let double = try? container.decode(Double.self) {
            self = .double(double)
            return
        }

        if let string = try? container.decode(String.self) {
            self = .string(string)
            return
        }

        if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
            return
        }

        if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
            return
        }

        throw DecodingError.typeMismatch(
            JSONValue.self,
            DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unknown JSON type")
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    var description: String {
        switch self {
        case .string(let value):
            return "\"\(value)\""
        case .int(let value):
            return "\(value)"
        case .double(let value):
            return "\(value)"
        case .bool(let value):
            return "\(value)"
        case .object(let value):
            let pairs = value.map { "\"\($0.key)\": \($0.value)" }
            return "{\(pairs.joined(separator: ", "))}"
        case .array(let value):
            return "[\(value.map { $0.description }.joined(separator: ", "))]"
        case .null:
            return "null"
        }
    }

    /// 特定のキーの文字列値を取得
    func getString(forKey key: String) -> String? {
        if case .object(let dict) = self,
           case .string(let value) = dict[key] {
            return value
        }
        return nil
    }

    /// 表示用のフォーマット済み文字列を取得（長い場合は切り詰め）
    func formattedString(maxLength: Int = 1000) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        guard let data = try? encoder.encode(self),
              var string = String(data: data, encoding: .utf8) else {
            return description
        }

        if string.count > maxLength {
            string = String(string.prefix(maxLength)) + "\n... (truncated)"
        }

        return string
    }
}
