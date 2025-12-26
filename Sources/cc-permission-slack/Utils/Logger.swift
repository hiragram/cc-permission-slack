import Foundation

/// ログをファイルとstderrに出力するロガー
/// テスト用編集: Permission hookのテスト (Socket Mode再起動後)
enum Logger {
    private static let logFilePath = "/tmp/cc-permission-slack.log"

    static func info(_ message: String) {
        log(level: "INFO", message: message)
    }

    static func error(_ message: String) {
        log(level: "ERROR", message: message)
    }

    static func debug(_ message: String) {
        log(level: "DEBUG", message: message)
    }

    static func warning(_ message: String) {
        log(level: "WARN", message: message)
    }

    private static func log(level: String, message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let logLine = "[\(timestamp)] [\(level)] \(message)\n"

        // stderr に出力
        fputs(logLine, stderr)

        // ファイルにも出力
        if let data = logLine.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logFilePath) {
                if let handle = FileHandle(forWritingAtPath: logFilePath) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                FileManager.default.createFile(atPath: logFilePath, contents: data)
            }
        }
    }
}
