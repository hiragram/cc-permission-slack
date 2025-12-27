import Foundation

// MARK: - Socket Mode

/// apps.connections.open のレスポンス
struct ConnectionOpenResponse: Codable, Sendable {
    let ok: Bool
    let url: String?
    let error: String?
}

/// Socket Mode で受信するエンベロープ
struct SocketModeEnvelope: Codable, Sendable {
    let envelopeId: String?  // hello メッセージには含まれない
    let type: String  // "hello", "events_api", "interactive", "disconnect"
    let payload: SocketPayload?
    let connectionInfo: ConnectionInfo?
    let numConnections: Int?
    let debugInfo: DebugInfo?

    enum CodingKeys: String, CodingKey {
        case envelopeId = "envelope_id"
        case type
        case payload
        case connectionInfo = "connection_info"
        case numConnections = "num_connections"
        case debugInfo = "debug_info"
    }
}

struct DebugInfo: Codable, Sendable {
    let host: String?
    let buildNumber: Int?
    let approximateConnectionTime: Int?

    enum CodingKeys: String, CodingKey {
        case host
        case buildNumber = "build_number"
        case approximateConnectionTime = "approximate_connection_time"
    }
}

struct ConnectionInfo: Codable, Sendable {
    let appId: String?

    enum CodingKeys: String, CodingKey {
        case appId = "app_id"
    }
}

struct SocketPayload: Codable, Sendable {
    let type: String?  // "block_actions", "event_callback"
    let actions: [SlackAction]?
    let user: SlackUser?
    let message: SlackMessage?
    let channel: SlackChannel?
    let responseUrl: String?
    let event: SlackEvent?  // events_api用

    enum CodingKeys: String, CodingKey {
        case type, actions, user, message, channel, event
        case responseUrl = "response_url"
    }
}

/// Slack Events API のイベント
struct SlackEvent: Codable, Sendable {
    let type: String  // "message"
    let channel: String?
    let user: String?
    let text: String?
    let ts: String?
    let threadTs: String?  // スレッドの親メッセージのts

    enum CodingKeys: String, CodingKey {
        case type, channel, user, text, ts
        case threadTs = "thread_ts"
    }
}

struct SlackAction: Codable, Sendable {
    let actionId: String
    let blockId: String?
    let value: String?
    let type: String?

    enum CodingKeys: String, CodingKey {
        case actionId = "action_id"
        case blockId = "block_id"
        case value, type
    }
}

struct SlackUser: Codable, Sendable {
    let id: String
    let username: String?
    let name: String?
}

struct SlackMessage: Codable, Sendable {
    let ts: String?
    let text: String?
}

struct SlackChannel: Codable, Sendable {
    let id: String
    let name: String?
}

/// Socket Mode acknowledge レスポンス
struct SocketModeAck: Codable, Sendable {
    let envelopeId: String

    enum CodingKeys: String, CodingKey {
        case envelopeId = "envelope_id"
    }
}

// MARK: - Slack Web API

/// chat.postMessage のレスポンス
struct PostMessageResponse: Codable, Sendable {
    let ok: Bool
    let ts: String?
    let channel: String?
    let error: String?
}

/// chat.update のレスポンス
struct UpdateMessageResponse: Codable, Sendable {
    let ok: Bool
    let ts: String?
    let channel: String?
    let error: String?
}

// MARK: - Block Kit

/// Block Kit の Block
enum Block: Codable, Sendable {
    case section(SectionBlock)
    case actions(ActionsBlock)
    case divider(DividerBlock)
    case context(ContextBlock)

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: TypeCodingKey.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "section":
            self = .section(try SectionBlock(from: decoder))
        case "actions":
            self = .actions(try ActionsBlock(from: decoder))
        case "divider":
            self = .divider(try DividerBlock(from: decoder))
        case "context":
            self = .context(try ContextBlock(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown block type: \(type)")
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .section(let block):
            try block.encode(to: encoder)
        case .actions(let block):
            try block.encode(to: encoder)
        case .divider(let block):
            try block.encode(to: encoder)
        case .context(let block):
            try block.encode(to: encoder)
        }
    }

    private enum TypeCodingKey: String, CodingKey {
        case type
    }
}

struct SectionBlock: Codable, Sendable {
    let type: String
    let text: TextObject?
    let blockId: String?
    let fields: [TextObject]?

    enum CodingKeys: String, CodingKey {
        case type, text, fields
        case blockId = "block_id"
    }

    init(text: TextObject, blockId: String? = nil, fields: [TextObject]? = nil) {
        self.type = "section"
        self.text = text
        self.blockId = blockId
        self.fields = fields
    }
}

struct ActionsBlock: Codable, Sendable {
    let type: String
    let blockId: String?
    let elements: [ButtonElement]

    enum CodingKeys: String, CodingKey {
        case type, elements
        case blockId = "block_id"
    }

    init(blockId: String? = nil, elements: [ButtonElement]) {
        self.type = "actions"
        self.blockId = blockId
        self.elements = elements
    }
}

struct DividerBlock: Codable, Sendable {
    let type: String

    init() {
        self.type = "divider"
    }
}

struct ContextBlock: Codable, Sendable {
    let type: String
    let elements: [TextObject]

    init(elements: [TextObject]) {
        self.type = "context"
        self.elements = elements
    }
}

struct TextObject: Codable, Sendable {
    let type: String  // "plain_text" or "mrkdwn"
    let text: String
    let emoji: Bool?

    static func plainText(_ text: String, emoji: Bool = true) -> TextObject {
        TextObject(type: "plain_text", text: text, emoji: emoji)
    }

    static func mrkdwn(_ text: String) -> TextObject {
        TextObject(type: "mrkdwn", text: text, emoji: nil)
    }
}

struct ButtonElement: Codable, Sendable {
    let type: String
    let text: TextObject
    let actionId: String
    let value: String?
    let style: String?  // "primary", "danger"

    enum CodingKeys: String, CodingKey {
        case type, text, value, style
        case actionId = "action_id"
    }

    init(text: String, actionId: String, value: String? = nil, style: String? = nil) {
        self.type = "button"
        self.text = .plainText(text)
        self.actionId = actionId
        self.value = value
        self.style = style
    }

    static func primary(text: String, actionId: String, value: String? = nil) -> ButtonElement {
        ButtonElement(text: text, actionId: actionId, value: value, style: "primary")
    }

    static func danger(text: String, actionId: String, value: String? = nil) -> ButtonElement {
        ButtonElement(text: text, actionId: actionId, value: value, style: "danger")
    }
}
