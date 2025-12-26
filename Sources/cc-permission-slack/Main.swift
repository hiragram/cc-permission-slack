import Foundation

@main
struct CCPermissionSlack {
    static func main() async {
        do {
            // 1. 設定を読み込み
            Logger.info("Loading configuration...")
            let config = try Configuration.fromEnvironment()

            // 2. stdin から PermissionRequest を読み取り
            Logger.info("Reading permission request from stdin...")
            let request = try readPermissionRequest()
            Logger.info("Received permission request for tool: \(request.toolName), session_id: \(request.sessionId ?? "unknown")")
            Logger.debug("Full request: toolName=\(request.toolName), sessionId=\(request.sessionId ?? "nil"), toolInput=\(request.toolInput.formattedString(maxLength: 200))")

            // 3. Socket Mode 接続
            let socketConnection = SocketModeConnection(appToken: config.slackAppToken)
            try await socketConnection.connect()

            defer {
                Task {
                    await socketConnection.disconnect()
                }
            }

            let slackClient = SlackClient(botToken: config.slackBotToken)

            // 4. ツールに応じた処理を実行
            let response: PermissionResponse
            if request.isAskUserQuestion, let questions = request.extractQuestions() {
                response = try await handleAskUserQuestion(
                    request: request,
                    questions: questions,
                    config: config,
                    slackClient: slackClient,
                    socketConnection: socketConnection
                )
            } else {
                response = try await handlePermissionRequest(
                    request: request,
                    config: config,
                    slackClient: slackClient,
                    socketConnection: socketConnection
                )
            }

            try outputResponse(response)

        } catch {
            Logger.error("Fatal error: \(error)")

            // エラー時は deny で応答
            let response = PermissionResponse.deny(message: "Internal error: \(error.localizedDescription)")
            do {
                try outputResponse(response)
            } catch {
                // 出力すら失敗した場合は stderr にエラーを出力して終了
                Logger.error("Failed to output error response: \(error)")
            }

            exit(1)
        }
    }

    // MARK: - Permission Request 処理

    private static func handlePermissionRequest(
        request: PermissionRequest,
        config: Configuration,
        slackClient: SlackClient,
        socketConnection: SocketModeConnection
    ) async throws -> PermissionResponse {
        // Slack にボタン付きメッセージを送信
        let blocks = MessageBuilder.buildPermissionBlocks(request: request)
        let fallbackText = MessageBuilder.buildFallbackText(request: request)

        let messageTs = try await slackClient.postMessage(
            channel: config.slackChannelId,
            blocks: blocks,
            text: fallbackText
        )

        // ボタン押下を待機
        let expectedActions: Set<String> = [
            MessageBuilder.approveActionId,
            MessageBuilder.denyActionId
        ]

        let (action, userId, _) = try await socketConnection.waitForBlockAction(
            expectedActionIds: expectedActions,
            expectedMessageTs: messageTs
        )

        // 決定を判定
        let approved = action.actionId == MessageBuilder.approveActionId

        // メッセージを更新（ボタン削除 + 結果表示）
        let resultBlocks = MessageBuilder.buildResultBlocks(
            request: request,
            approved: approved,
            userId: userId
        )
        let resultText = MessageBuilder.buildResultFallbackText(request: request, approved: approved)

        try await slackClient.updateMessage(
            channel: config.slackChannelId,
            ts: messageTs,
            blocks: resultBlocks,
            text: resultText
        )

        if approved {
            Logger.info("Permission approved by user: \(userId)")
            return .allow()
        } else {
            Logger.info("Permission denied by user: \(userId)")
            return .deny(message: "Denied by user via Slack")
        }
    }

    // MARK: - AskUserQuestion 処理

    private static func handleAskUserQuestion(
        request: PermissionRequest,
        questions: [AskUserQuestionQuestion],
        config: Configuration,
        slackClient: SlackClient,
        socketConnection: SocketModeConnection
    ) async throws -> PermissionResponse {
        Logger.info("Handling AskUserQuestion with \(questions.count) question(s) using thread format")

        let requestId = request.sessionId ?? UUID().uuidString
        var answers: [Int: String] = [:]  // 確定した回答
        var multiSelectSelections: [Int: Set<Int>] = [:]  // multiSelect用の選択状態
        var lastUserId: String = "unknown"

        // 1. 親メッセージ（ヘッダー）を投稿
        let headerBlocks = MessageBuilder.buildAskUserQuestionHeaderBlocks(questionCount: questions.count)
        let headerFallbackText = MessageBuilder.buildAskUserQuestionFallbackText(questions: questions)

        let parentTs = try await slackClient.postMessage(
            channel: config.slackChannelId,
            blocks: headerBlocks,
            text: headerFallbackText
        )
        Logger.debug("Posted parent message: ts=\(parentTs)")

        // 2. 各質問をスレッドに投稿（全質問を一度に投稿）
        var questionMessageTs: [Int: String] = [:]
        for (index, question) in questions.enumerated() {
            // multiSelectの場合は選択状態を初期化
            if question.multiSelect {
                multiSelectSelections[index] = []
            }

            let questionBlocks = MessageBuilder.buildAskUserQuestionQuestionBlocks(
                question: question,
                questionIndex: index,
                requestId: requestId,
                selectedIndices: question.multiSelect ? [] : nil
            )
            let questionFallbackText = MessageBuilder.buildAskUserQuestionQuestionFallbackText(
                question: question,
                questionIndex: index
            )

            let ts = try await slackClient.postMessage(
                channel: config.slackChannelId,
                blocks: questionBlocks,
                text: questionFallbackText,
                threadTs: parentTs,
                replyBroadcast: true
            )
            questionMessageTs[index] = ts
            Logger.debug("Posted question \(index) in thread: ts=\(ts)")
        }

        // 3. すべての質問に回答が揃うまでボタン押下を待機
        while answers.count < questions.count {
            Logger.debug("Waiting for answers (\(answers.count)/\(questions.count) completed)")

            // 未回答の質問に対応するactionIdを収集
            var pendingActions: Set<String> = []
            for (questionIndex, question) in questions.enumerated() {
                guard answers[questionIndex] == nil else { continue }

                // オプションボタン
                for optionIndex in 0..<question.options.count {
                    let actionId = MessageBuilder.questionOptionActionId(
                        questionIndex: questionIndex,
                        optionIndex: optionIndex
                    )
                    pendingActions.insert(actionId)
                }

                // multiSelectの場合は確定ボタンも追加
                if question.multiSelect {
                    let submitActionId = MessageBuilder.questionSubmitActionId(questionIndex: questionIndex)
                    pendingActions.insert(submitActionId)
                }
            }

            // ボタン押下を待機
            let (action, userId, _) = try await socketConnection.waitForBlockAction(
                expectedActionIds: pendingActions,
                expectedMessageTs: nil
            )

            lastUserId = userId

            // 確定ボタンかどうかを確認
            if let questionIndex = MessageBuilder.parseQuestionSubmitActionId(action.actionId) {
                // multiSelectの確定ボタンが押された
                let question = questions[questionIndex]
                let selectedIndices = multiSelectSelections[questionIndex] ?? []

                // 選択されたラベルを結合
                let selectedLabels = selectedIndices.sorted().compactMap { index -> String? in
                    guard index < question.options.count else { return nil }
                    return question.options[index].label
                }
                let answerText = selectedLabels.isEmpty ? "(未選択)" : selectedLabels.joined(separator: ", ")

                answers[questionIndex] = answerText
                Logger.info("Question \(questionIndex) (multiSelect) confirmed: \(answerText) by user: \(userId)")

                // メッセージを更新（確定表示）
                if let questionTs = questionMessageTs[questionIndex] {
                    let updatedBlocks = MessageBuilder.buildAskUserQuestionQuestionBlocks(
                        question: question,
                        questionIndex: questionIndex,
                        requestId: requestId,
                        answer: answerText
                    )
                    let questionFallbackText = MessageBuilder.buildAskUserQuestionQuestionFallbackText(
                        question: question,
                        questionIndex: questionIndex
                    )

                    try await slackClient.updateMessage(
                        channel: config.slackChannelId,
                        ts: questionTs,
                        blocks: updatedBlocks,
                        text: questionFallbackText
                    )
                }
                continue
            }

            // オプションボタンが押された
            guard let (questionIndex, optionIndex) = MessageBuilder.parseQuestionOptionActionId(action.actionId) else {
                Logger.warning("Could not parse actionId: \(action.actionId)")
                continue
            }

            let question = questions[questionIndex]

            if question.multiSelect {
                // multiSelect: 選択をトグル
                var selected = multiSelectSelections[questionIndex] ?? []
                if selected.contains(optionIndex) {
                    selected.remove(optionIndex)
                    Logger.debug("Question \(questionIndex): deselected option \(optionIndex)")
                } else {
                    selected.insert(optionIndex)
                    Logger.debug("Question \(questionIndex): selected option \(optionIndex)")
                }
                multiSelectSelections[questionIndex] = selected

                // メッセージを更新（選択状態を反映）
                if let questionTs = questionMessageTs[questionIndex] {
                    let updatedBlocks = MessageBuilder.buildAskUserQuestionQuestionBlocks(
                        question: question,
                        questionIndex: questionIndex,
                        requestId: requestId,
                        selectedIndices: selected
                    )
                    let questionFallbackText = MessageBuilder.buildAskUserQuestionQuestionFallbackText(
                        question: question,
                        questionIndex: questionIndex
                    )

                    try await slackClient.updateMessage(
                        channel: config.slackChannelId,
                        ts: questionTs,
                        blocks: updatedBlocks,
                        text: questionFallbackText
                    )
                }
            } else {
                // 単一選択: 即座に回答確定
                let selectedLabel = action.value ?? "unknown"
                answers[questionIndex] = selectedLabel
                Logger.info("Question \(questionIndex) answered: \(selectedLabel) by user: \(userId)")

                // メッセージを更新（確定表示）
                if let questionTs = questionMessageTs[questionIndex] {
                    let updatedBlocks = MessageBuilder.buildAskUserQuestionQuestionBlocks(
                        question: question,
                        questionIndex: questionIndex,
                        requestId: requestId,
                        answer: selectedLabel
                    )
                    let questionFallbackText = MessageBuilder.buildAskUserQuestionQuestionFallbackText(
                        question: question,
                        questionIndex: questionIndex
                    )

                    try await slackClient.updateMessage(
                        channel: config.slackChannelId,
                        ts: questionTs,
                        blocks: updatedBlocks,
                        text: questionFallbackText
                    )
                }
            }
        }

        // 4. 全回答完了 - 親メッセージを更新
        let completedHeaderBlocks = MessageBuilder.buildAskUserQuestionHeaderCompletedBlocks(
            questionCount: questions.count,
            userId: lastUserId
        )

        try await slackClient.updateMessage(
            channel: config.slackChannelId,
            ts: parentTs,
            blocks: completedHeaderBlocks,
            text: "AskUserQuestion: Answered"
        )

        // answersをClaude Code用の形式に変換
        var answersDict: [String: JSONValue] = [:]
        for (index, question) in questions.enumerated() {
            if let answer = answers[index] {
                answersDict[question.question] = .string(answer)
            }
        }

        let updatedInput: JSONValue = .object(["answers": .object(answersDict)])

        Logger.info("AskUserQuestion completed with \(answers.count) answer(s)")
        return .allowWithUpdatedInput(updatedInput)
    }

    /// stdin から PermissionRequest を読み取り
    private static func readPermissionRequest() throws -> PermissionRequest {
        var inputData = Data()

        // stdin から全データを読み取り
        while let line = readLine(strippingNewline: false) {
            guard let lineData = line.data(using: .utf8) else {
                continue
            }
            inputData.append(lineData)
        }

        guard !inputData.isEmpty else {
            throw CCPermissionError.stdinReadFailed
        }

        Logger.debug("Read \(inputData.count) bytes from stdin")

        // 受け取ったJSONをそのままログ出力
        if let rawJson = String(data: inputData, encoding: .utf8) {
            Logger.debug("Raw JSON: \(rawJson)")
        }

        do {
            let decoder = JSONDecoder()
            return try decoder.decode(PermissionRequest.self, from: inputData)
        } catch {
            Logger.error("JSON decoding failed: \(error)")
            throw CCPermissionError.jsonDecodingFailed(error)
        }
    }

    /// stdout に PermissionResponse を出力
    private static func outputResponse(_ response: PermissionResponse) throws {
        let json = try response.toJSON()
        print(json)
        fflush(stdout)
        Logger.debug("Output response: \(json)")
    }
}
