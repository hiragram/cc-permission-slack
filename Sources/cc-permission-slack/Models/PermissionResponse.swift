import Foundation

/// Claude Code PermissionRequest hook への stdout 出力
struct PermissionResponse: Codable, Sendable {
    let hookSpecificOutput: HookSpecificOutput
}

struct HookSpecificOutput: Codable, Sendable {
    let hookEventName: String
    let decision: Decision

    init(decision: Decision) {
        self.hookEventName = "PermissionRequest"
        self.decision = decision
    }
}

struct Decision: Codable, Sendable {
    let behavior: Behavior
    let message: String?

    enum Behavior: String, Codable, Sendable {
        case allow
        case deny
    }

    static func allow() -> Decision {
        Decision(behavior: .allow, message: nil)
    }

    static func deny(message: String? = nil) -> Decision {
        Decision(behavior: .deny, message: message)
    }
}

extension PermissionResponse {
    static func allow() -> PermissionResponse {
        PermissionResponse(hookSpecificOutput: HookSpecificOutput(decision: .allow()))
    }

    static func deny(message: String? = nil) -> PermissionResponse {
        PermissionResponse(hookSpecificOutput: HookSpecificOutput(decision: .deny(message: message)))
    }

    func toJSON() throws -> String {
        let encoder = JSONEncoder()
        let data = try encoder.encode(self)
        guard let json = String(data: data, encoding: .utf8) else {
            throw CCPermissionError.encodingFailed
        }
        return json
    }
}

/// アプリケーション全体で使用するエラー型
enum CCPermissionError: Error, LocalizedError {
    // 設定エラー
    case missingEnvironmentVariable(String)
    case invalidConfiguration(String)

    // 入出力エラー
    case stdinReadFailed
    case jsonDecodingFailed(Error)
    case encodingFailed

    // Slack接続エラー
    case connectionOpenFailed(String)
    case webSocketConnectionFailed(Error)
    case webSocketDisconnected
    case webSocketTimeout

    // Slack APIエラー
    case slackAPIError(method: String, error: String)
    case messagePostFailed(Error)
    case messageUpdateFailed(Error)

    var errorDescription: String? {
        switch self {
        case .missingEnvironmentVariable(let name):
            return "Missing environment variable: \(name)"
        case .invalidConfiguration(let message):
            return "Invalid configuration: \(message)"
        case .stdinReadFailed:
            return "Failed to read from stdin"
        case .jsonDecodingFailed(let error):
            return "JSON decoding failed: \(error.localizedDescription)"
        case .encodingFailed:
            return "Failed to encode response"
        case .connectionOpenFailed(let error):
            return "Failed to open Socket Mode connection: \(error)"
        case .webSocketConnectionFailed(let error):
            return "WebSocket connection failed: \(error.localizedDescription)"
        case .webSocketDisconnected:
            return "WebSocket disconnected unexpectedly"
        case .webSocketTimeout:
            return "WebSocket connection timed out"
        case .slackAPIError(let method, let error):
            return "Slack API error (\(method)): \(error)"
        case .messagePostFailed(let error):
            return "Failed to post message: \(error.localizedDescription)"
        case .messageUpdateFailed(let error):
            return "Failed to update message: \(error.localizedDescription)"
        }
    }
}
