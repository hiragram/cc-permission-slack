import Foundation

/// Slack Block Kit メッセージビルダー
enum MessageBuilder {
    /// 承認ボタンの action_id
    static let approveActionId = "approve_permission"

    /// 却下ボタンの action_id
    static let denyActionId = "deny_permission"

    /// 許可リクエストメッセージを構築
    static func buildPermissionBlocks(request: PermissionRequest) -> [Block] {
        var blocks: [Block] = []

        // ヘッダー
        blocks.append(.section(SectionBlock(
            text: .mrkdwn("*Permission Request*\n\nClaude Code is requesting permission to use a tool.")
        )))

        blocks.append(.divider(DividerBlock()))

        // ツール情報
        let toolInfo = buildToolInfoText(request: request)
        blocks.append(.section(SectionBlock(
            text: .mrkdwn(toolInfo)
        )))

        // ツール入力の詳細
        let inputDetail = buildInputDetailText(request: request)
        if !inputDetail.isEmpty {
            blocks.append(.section(SectionBlock(
                text: .mrkdwn(inputDetail)
            )))
        }

        blocks.append(.divider(DividerBlock()))

        // 承認/却下ボタン
        blocks.append(.actions(ActionsBlock(
            blockId: "permission_actions_\(request.toolUseId)",
            elements: [
                .primary(text: "Approve", actionId: approveActionId, value: request.toolUseId),
                .danger(text: "Deny", actionId: denyActionId, value: request.toolUseId)
            ]
        )))

        return blocks
    }

    /// 結果表示メッセージを構築
    static func buildResultBlocks(request: PermissionRequest, approved: Bool, userId: String) -> [Block] {
        var blocks: [Block] = []

        let statusEmoji = approved ? ":white_check_mark:" : ":x:"
        let statusText = approved ? "Approved" : "Denied"

        // ヘッダー（結果付き）
        blocks.append(.section(SectionBlock(
            text: .mrkdwn("*Permission Request* - \(statusEmoji) *\(statusText)*")
        )))

        blocks.append(.divider(DividerBlock()))

        // ツール情報
        let toolInfo = buildToolInfoText(request: request)
        blocks.append(.section(SectionBlock(
            text: .mrkdwn(toolInfo)
        )))

        // 処理者情報
        blocks.append(.context(ContextBlock(
            elements: [
                .mrkdwn("\(statusText) by <@\(userId)>")
            ]
        )))

        return blocks
    }

    /// ツール情報テキストを構築
    private static func buildToolInfoText(request: PermissionRequest) -> String {
        var text = "*Tool:* `\(request.toolName)`"

        // ファイルパスがあれば表示
        if let filePath = request.toolInput.getString(forKey: "file_path") {
            text += "\n*File:* `\(filePath)`"
        }

        // コマンドがあれば表示
        if let command = request.toolInput.getString(forKey: "command") {
            let truncated = truncateString(command, maxLength: 200)
            text += "\n*Command:* `\(truncated)`"
        }

        return text
    }

    /// ツール入力の詳細テキストを構築
    private static func buildInputDetailText(request: PermissionRequest) -> String {
        // content や他の詳細情報を表示
        var details: [String] = []

        if let content = request.toolInput.getString(forKey: "content") {
            let preview = truncateString(content, maxLength: 800)
            details.append("*Content Preview:*\n```\n\(preview)\n```")
        }

        // その他の入力パラメータを表示
        if case .object(let dict) = request.toolInput {
            let excludeKeys: Set<String> = ["file_path", "command", "content"]
            let otherParams = dict.filter { !excludeKeys.contains($0.key) }

            if !otherParams.isEmpty {
                var paramText = "*Other Parameters:*\n"
                for (key, value) in otherParams.sorted(by: { $0.key < $1.key }) {
                    let valueStr = truncateString(value.description, maxLength: 200)
                    paramText += "• `\(key)`: \(valueStr)\n"
                }
                details.append(paramText)
            }
        }

        return details.joined(separator: "\n")
    }

    /// 文字列を切り詰め
    private static func truncateString(_ string: String, maxLength: Int) -> String {
        if string.count <= maxLength {
            return string
        }
        return String(string.prefix(maxLength)) + "..."
    }

    /// フォールバックテキストを生成
    static func buildFallbackText(request: PermissionRequest) -> String {
        "Permission request: \(request.toolName)"
    }

    /// 結果のフォールバックテキストを生成
    static func buildResultFallbackText(request: PermissionRequest, approved: Bool) -> String {
        let status = approved ? "Approved" : "Denied"
        return "Permission \(status): \(request.toolName)"
    }
}
