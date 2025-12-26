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
        Logger.info("Handling AskUserQuestion with \(questions.count) question(s)")

        var answers: [Int: String] = [:]
        var lastUserId: String = "unknown"

        // 最初のメッセージを送信（質問0から開始）
        let initialBlocks = MessageBuilder.buildAskUserQuestionBlocks(
            request: request,
            questions: questions,
            currentQuestionIndex: 0,
            answers: answers
        )
        let fallbackText = MessageBuilder.buildAskUserQuestionFallbackText(questions: questions)

        let messageTs = try await slackClient.postMessage(
            channel: config.slackChannelId,
            blocks: initialBlocks,
            text: fallbackText
        )

        // 各質問に対して回答を収集
        for questionIndex in 0..<questions.count {
            let question = questions[questionIndex]

            // 現在の質問の選択肢に対応するactionIdを生成
            var expectedActions: Set<String> = []
            for optionIndex in 0..<question.options.count {
                let actionId = MessageBuilder.questionOptionActionId(
                    questionIndex: questionIndex,
                    optionIndex: optionIndex
                )
                expectedActions.insert(actionId)
            }

            Logger.debug("Waiting for answer to question \(questionIndex): expecting actions \(expectedActions)")

            // ボタン押下を待機
            let (action, userId, _) = try await socketConnection.waitForBlockAction(
                expectedActionIds: expectedActions,
                expectedMessageTs: messageTs
            )

            lastUserId = userId

            // 回答を記録（valueにはlabelが入っている）
            let selectedLabel = action.value ?? "unknown"
            answers[questionIndex] = selectedLabel
            Logger.info("Question \(questionIndex) answered: \(selectedLabel) by user: \(userId)")

            // メッセージを更新して次の質問のボタンを表示
            let nextQuestionIndex = questionIndex + 1
            if nextQuestionIndex < questions.count {
                let updatedBlocks = MessageBuilder.buildAskUserQuestionBlocks(
                    request: request,
                    questions: questions,
                    currentQuestionIndex: nextQuestionIndex,
                    answers: answers
                )

                try await slackClient.updateMessage(
                    channel: config.slackChannelId,
                    ts: messageTs,
                    blocks: updatedBlocks,
                    text: fallbackText
                )
            }
        }

        // 全回答完了 - 結果メッセージを表示
        let resultBlocks = MessageBuilder.buildAskUserQuestionResultBlocks(
            request: request,
            questions: questions,
            answers: answers,
            userId: lastUserId
        )

        try await slackClient.updateMessage(
            channel: config.slackChannelId,
            ts: messageTs,
            blocks: resultBlocks,
            text: "AskUserQuestion: Answered"
        )

        // answersをClaude Code用の形式に変換
        // { "質問文": "選択したラベル" } の形式
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
