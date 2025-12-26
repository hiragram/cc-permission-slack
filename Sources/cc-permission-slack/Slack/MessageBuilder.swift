import Foundation

/// Slack Block Kit メッセージビルダー
enum MessageBuilder {
    /// 承認ボタンの action_id
    static let approveActionId = "approve_permission"

    /// 却下ボタンの action_id
    static let denyActionId = "deny_permission"

    /// AskUserQuestion選択肢ボタンの action_id プレフィックス
    static let questionOptionActionIdPrefix = "question_option_"

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
        let requestId = request.sessionId ?? UUID().uuidString
        blocks.append(.actions(ActionsBlock(
            blockId: "permission_actions_\(requestId)",
            elements: [
                .primary(text: "Approve", actionId: approveActionId, value: requestId),
                .danger(text: "Deny", actionId: denyActionId, value: requestId)
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

    // MARK: - AskUserQuestion サポート

    /// AskUserQuestion用のactionIdを生成
    static func questionOptionActionId(questionIndex: Int, optionIndex: Int) -> String {
        "\(questionOptionActionIdPrefix)\(questionIndex)_\(optionIndex)"
    }

    /// actionIdから質問インデックスと選択肢インデックスを抽出
    static func parseQuestionOptionActionId(_ actionId: String) -> (questionIndex: Int, optionIndex: Int)? {
        guard actionId.hasPrefix(questionOptionActionIdPrefix) else { return nil }
        let suffix = String(actionId.dropFirst(questionOptionActionIdPrefix.count))
        let parts = suffix.split(separator: "_")
        guard parts.count == 2,
              let qIndex = Int(parts[0]),
              let oIndex = Int(parts[1]) else {
            return nil
        }
        return (qIndex, oIndex)
    }

    /// AskUserQuestionメッセージを構築
    /// - Parameters:
    ///   - request: PermissionRequest
    ///   - questions: 抽出された質問リスト
    ///   - currentQuestionIndex: 現在回答中の質問インデックス
    ///   - answers: これまでの回答（質問インデックス → 選択したラベル）
    static func buildAskUserQuestionBlocks(
        request: PermissionRequest,
        questions: [AskUserQuestionQuestion],
        currentQuestionIndex: Int,
        answers: [Int: String]
    ) -> [Block] {
        var blocks: [Block] = []

        // ヘッダー
        blocks.append(.section(SectionBlock(
            text: .mrkdwn("*:question: AskUserQuestion*\n\nClaude Code is asking you a question.")
        )))

        blocks.append(.divider(DividerBlock()))

        // 各質問を表示
        for (index, question) in questions.enumerated() {
            let questionNumber = index + 1

            if let answer = answers[index] {
                // 回答済み
                blocks.append(.section(SectionBlock(
                    text: .mrkdwn("*Q\(questionNumber). \(question.header)*\n\(question.question)\n:white_check_mark: 回答: *\(answer)*")
                )))
            } else if index == currentQuestionIndex {
                // 現在回答中
                blocks.append(.section(SectionBlock(
                    text: .mrkdwn("*Q\(questionNumber). \(question.header)* :point_left:\n\(question.question)")
                )))

                // 選択肢ボタン
                let requestId = request.sessionId ?? UUID().uuidString
                var elements: [ButtonElement] = []
                for (optionIndex, option) in question.options.enumerated() {
                    let actionId = questionOptionActionId(questionIndex: index, optionIndex: optionIndex)
                    // valueにはlabelを入れる
                    elements.append(ButtonElement(
                        text: option.label,
                        actionId: actionId,
                        value: option.label
                    ))
                }

                blocks.append(.actions(ActionsBlock(
                    blockId: "question_actions_\(requestId)_\(index)",
                    elements: elements
                )))
            } else {
                // 未回答（まだ順番が来ていない）
                blocks.append(.section(SectionBlock(
                    text: .mrkdwn("*Q\(questionNumber). \(question.header)*\n\(question.question)\n_（未回答）_")
                )))
            }

            // 質問間の区切り
            if index < questions.count - 1 {
                blocks.append(.divider(DividerBlock()))
            }
        }

        return blocks
    }

    /// AskUserQuestion回答完了メッセージを構築
    static func buildAskUserQuestionResultBlocks(
        request: PermissionRequest,
        questions: [AskUserQuestionQuestion],
        answers: [Int: String],
        userId: String
    ) -> [Block] {
        var blocks: [Block] = []

        // ヘッダー（完了）
        blocks.append(.section(SectionBlock(
            text: .mrkdwn("*:question: AskUserQuestion* - :white_check_mark: *Answered*")
        )))

        blocks.append(.divider(DividerBlock()))

        // 各質問と回答を表示
        for (index, question) in questions.enumerated() {
            let questionNumber = index + 1
            let answer = answers[index] ?? "（回答なし）"

            blocks.append(.section(SectionBlock(
                text: .mrkdwn("*Q\(questionNumber). \(question.header)*\n\(question.question)\n:white_check_mark: 回答: *\(answer)*")
            )))

            if index < questions.count - 1 {
                blocks.append(.divider(DividerBlock()))
            }
        }

        // 処理者情報
        blocks.append(.context(ContextBlock(
            elements: [
                .mrkdwn("Answered by <@\(userId)>")
            ]
        )))

        return blocks
    }

    /// AskUserQuestionのフォールバックテキストを生成
    static func buildAskUserQuestionFallbackText(questions: [AskUserQuestionQuestion]) -> String {
        "AskUserQuestion: \(questions.count) question(s)"
    }
}
