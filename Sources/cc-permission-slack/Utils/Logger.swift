import Foundation

/// stderr にログを出力するロガー
/// stdout は Claude Code との通信に使用するため、ログは全て stderr に出力
enum Logger {
    static func info(_ message: String) {
        log(level: "INFO", message: message)
    }

    static func error(_ message: String) {
        log(level: "ERROR", message: message)
    }

    static func debug(_ message: String) {
        #if DEBUG
        log(level: "DEBUG", message: message)
        #endif
    }

    static func warning(_ message: String) {
        log(level: "WARN", message: message)
    }

    private static func log(level: String, message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let logLine = "[\(timestamp)] [\(level)] \(message)\n"
        fputs(logLine, stderr)
    }
}
