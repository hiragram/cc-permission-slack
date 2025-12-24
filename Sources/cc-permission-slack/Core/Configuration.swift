import Foundation

/// アプリケーション設定
struct Configuration: Sendable {
    /// Slack App-Level Token (xapp-...)
    let slackAppToken: String

    /// Slack Bot Token (xoxb-...)
    let slackBotToken: String

    /// 通知先チャンネルID
    let slackChannelId: String

    /// 環境変数から設定を読み込み
    static func fromEnvironment() throws -> Configuration {
        guard let appToken = ProcessInfo.processInfo.environment["SLACK_APP_TOKEN"],
              !appToken.isEmpty else {
            throw CCPermissionError.missingEnvironmentVariable("SLACK_APP_TOKEN")
        }

        guard let botToken = ProcessInfo.processInfo.environment["SLACK_BOT_TOKEN"],
              !botToken.isEmpty else {
            throw CCPermissionError.missingEnvironmentVariable("SLACK_BOT_TOKEN")
        }

        guard let channelId = ProcessInfo.processInfo.environment["SLACK_CHANNEL_ID"],
              !channelId.isEmpty else {
            throw CCPermissionError.missingEnvironmentVariable("SLACK_CHANNEL_ID")
        }

        // トークン形式の簡易検証
        guard appToken.hasPrefix("xapp-") else {
            throw CCPermissionError.invalidConfiguration("SLACK_APP_TOKEN should start with 'xapp-'")
        }

        guard botToken.hasPrefix("xoxb-") else {
            throw CCPermissionError.invalidConfiguration("SLACK_BOT_TOKEN should start with 'xoxb-'")
        }

        return Configuration(
            slackAppToken: appToken,
            slackBotToken: botToken,
            slackChannelId: channelId
        )
    }
}
