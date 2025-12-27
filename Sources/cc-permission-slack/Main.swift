import Foundation

/// タイムアウト時間（30分）
private let timeoutDuration: UInt64 = 30 * 60 * 1_000_000_000  // nanoseconds

/// タイムアウトエラー
enum TimeoutError: Error {
    case timedOut
}

/// タイムアウト結果
enum TimeoutResult<T: Sendable>: Sendable {
    case success(T)
    case timeout
}

/// タイムアウト付きで非同期処理を実行（結果をenumで返す）
/// - Parameters:
///   - nanoseconds: タイムアウト時間（ナノ秒）
///   - onTimeout: タイムアウト発火時に呼ばれるコールバック（操作タスクを強制終了するために使用）
///   - operation: 実行する非同期処理
func withTimeoutResult<T: Sendable>(
    nanoseconds: UInt64,
    onTimeout: (@Sendable () async -> Void)? = nil,
    operation: @escaping @Sendable () async throws -> T
) async throws -> TimeoutResult<T> {
    try await withThrowingTaskGroup(of: TimeoutResult<T>.self) { group in
        group.addTask {
            let result = try await operation()
            return .success(result)
        }

        group.addTask {
            try await Task.sleep(nanoseconds: nanoseconds)
            // タイムアウト時にコールバックを呼んで、操作タスクを強制終了
            if let onTimeout = onTimeout {
                await onTimeout()
            }
            return .timeout
        }

        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

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
            do {
                try await socketConnection.connect()
            } catch {
                // Socket Mode接続に失敗した場合は、hookを透過的に終了
                // ターミナル側で回答可能
                Logger.warning("Socket Mode connection failed: \(error). Exiting gracefully.")
                exit(0)
            }

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
            } else if request.isExitPlanMode {
                response = try await handleExitPlanMode(
                    request: request,
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

        let result = try await withTimeoutResult(
            nanoseconds: timeoutDuration,
            onTimeout: {
                // タイムアウト時にWebSocket接続を切断して、受信タスクを強制終了
                await socketConnection.disconnect()
            }
        ) {
            try await socketConnection.waitForBlockAction(
                expectedActionIds: expectedActions,
                expectedMessageTs: messageTs
            )
        }

        switch result {
        case .success(let (action, userId, _)):
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

        case .timeout:
            // タイムアウト時：Slackメッセージを更新してボタンを削除
            // (WebSocket接続はonTimeoutコールバックで既に切断済み)
            Logger.warning("Permission request timed out - updating Slack message")

            let timeoutBlocks = MessageBuilder.buildTimeoutBlocks(request: request)
            let timeoutText = MessageBuilder.buildTimeoutFallbackText(request: request)

            try await slackClient.updateMessage(
                channel: config.slackChannelId,
                ts: messageTs,
                blocks: timeoutBlocks,
                text: timeoutText
            )

            // Slackはタイムアウトしたので、hookプロセスは終了
            // ターミナル側で引き続き回答可能
            Logger.info("Slack timed out, exiting hook process")
            exit(0)
        }
    }

    // MARK: - ExitPlanMode 処理

    private static func handleExitPlanMode(
        request: PermissionRequest,
        config: Configuration,
        slackClient: SlackClient,
        socketConnection: SocketModeConnection
    ) async throws -> PermissionResponse {
        Logger.info("Handling ExitPlanMode")

        let requestId = request.sessionId ?? UUID().uuidString
        let planContent = request.extractPlanContent() ?? "(Plan content not available)"

        // Slack にプランレビューメッセージを送信
        let blocks = MessageBuilder.buildExitPlanModeBlocks(
            planContent: planContent,
            requestId: requestId
        )
        let fallbackText = MessageBuilder.buildExitPlanModeFallbackText()

        let messageTs = try await slackClient.postMessage(
            channel: config.slackChannelId,
            blocks: blocks,
            text: fallbackText
        )

        // ボタン押下またはスレッド返信を待機
        let expectedActions: Set<String> = [
            MessageBuilder.approvePlanActionId,
            MessageBuilder.requestRevisionActionId
        ]

        let result = try await withTimeoutResult(
            nanoseconds: timeoutDuration,
            onTimeout: {
                await socketConnection.disconnect()
            }
        ) {
            try await socketConnection.waitForBlockActionOrThreadReply(
                expectedActionIds: expectedActions,
                expectedMessageTs: messageTs
            )
        }

        switch result {
        case .success(let interaction):
            switch interaction {
            case .buttonAction(let action, let userId, _):
                let approved = action.actionId == MessageBuilder.approvePlanActionId

                // メッセージを更新
                let resultBlocks = MessageBuilder.buildExitPlanModeResultBlocks(
                    planContent: planContent,
                    approved: approved,
                    userId: userId
                )
                let resultText = MessageBuilder.buildExitPlanModeResultFallbackText(approved: approved)

                try await slackClient.updateMessage(
                    channel: config.slackChannelId,
                    ts: messageTs,
                    blocks: resultBlocks,
                    text: resultText
                )

                if approved {
                    Logger.info("Plan approved by user: \(userId)")
                    return .allow()
                } else {
                    Logger.info("Revision requested by user: \(userId)")
                    return .deny(message: "User requested revision of the plan via Slack")
                }

            case .threadReply(let text, let userId, _):
                // スレッド返信は修正指示として扱う
                Logger.info("Revision requested via thread reply by user: \(userId)")

                // メッセージを更新
                let resultBlocks = MessageBuilder.buildExitPlanModeResultBlocks(
                    planContent: planContent,
                    approved: false,
                    userId: userId
                )
                let resultText = MessageBuilder.buildExitPlanModeResultFallbackText(approved: false)

                try await slackClient.updateMessage(
                    channel: config.slackChannelId,
                    ts: messageTs,
                    blocks: resultBlocks,
                    text: resultText
                )

                return .deny(message: "User requested revision via Slack thread: \(text)")
            }

        case .timeout:
            Logger.warning("ExitPlanMode request timed out - updating Slack message")

            let timeoutBlocks = MessageBuilder.buildExitPlanModeTimeoutBlocks(planContent: planContent)
            let timeoutText = MessageBuilder.buildExitPlanModeTimeoutFallbackText()

            try await slackClient.updateMessage(
                channel: config.slackChannelId,
                ts: messageTs,
                blocks: timeoutBlocks,
                text: timeoutText
            )

            Logger.info("Slack timed out, exiting hook process")
            exit(0)
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
        Logger.info("Handling AskUserQuestion with \(questions.count) question(s) - one by one format")

        let requestId = request.sessionId ?? UUID().uuidString
        let totalQuestions = questions.count

        // 1. 親メッセージ（ヘッダー）を投稿
        let headerBlocks = MessageBuilder.buildAskUserQuestionHeaderBlocks(questionCount: totalQuestions)
        let headerFallbackText = MessageBuilder.buildAskUserQuestionFallbackText(questions: questions)

        let parentTs = try await slackClient.postMessage(
            channel: config.slackChannelId,
            blocks: headerBlocks,
            text: headerFallbackText
        )
        Logger.debug("Posted parent message: ts=\(parentTs)")

        // タイムアウト付きで回答を収集（一問一答形式）
        let result = try await withTimeoutResult(
            nanoseconds: timeoutDuration,
            onTimeout: {
                // タイムアウト時にWebSocket接続を切断して、受信タスクを強制終了
                await socketConnection.disconnect()
            }
        ) {
            try await collectAnswersOneByOne(
                questions: questions,
                parentTs: parentTs,
                requestId: requestId,
                config: config,
                slackClient: slackClient,
                socketConnection: socketConnection
            )
        }

        switch result {
        case .success(let (answers, lastUserId)):
            // 全回答完了 - 親メッセージを更新
            let completedHeaderBlocks = MessageBuilder.buildAskUserQuestionHeaderCompletedBlocks(
                questionCount: totalQuestions,
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

        case .timeout:
            // タイムアウト時：Slackメッセージを更新
            // (WebSocket接続はonTimeoutコールバックで既に切断済み)
            Logger.warning("AskUserQuestion timed out - updating Slack messages")

            // 親メッセージを更新
            let timeoutHeaderBlocks = MessageBuilder.buildAskUserQuestionHeaderTimeoutBlocks(questionCount: totalQuestions)
            try await slackClient.updateMessage(
                channel: config.slackChannelId,
                ts: parentTs,
                blocks: timeoutHeaderBlocks,
                text: "AskUserQuestion: Timed Out"
            )

            // Slackはタイムアウトしたので、hookプロセスは終了
            // ターミナル側で引き続き回答可能
            Logger.info("Slack timed out, exiting hook process")
            exit(0)
        }
    }

    /// 一問一答形式で回答を収集するヘルパー関数
    private static func collectAnswersOneByOne(
        questions: [AskUserQuestionQuestion],
        parentTs: String,
        requestId: String,
        config: Configuration,
        slackClient: SlackClient,
        socketConnection: SocketModeConnection
    ) async throws -> (answers: [Int: String], lastUserId: String) {
        var answers: [Int: String] = [:]
        var lastUserId: String = "unknown"
        let totalQuestions = questions.count

        for (questionIndex, question) in questions.enumerated() {
            Logger.debug("Posting question \(questionIndex + 1)/\(totalQuestions)")

            // 質問をスレッドに投稿
            let questionBlocks = MessageBuilder.buildAskUserQuestionQuestionBlocks(
                question: question,
                questionIndex: questionIndex,
                totalQuestions: totalQuestions,
                requestId: requestId,
                selectedIndices: question.multiSelect ? [] : nil
            )
            let questionFallbackText = MessageBuilder.buildAskUserQuestionQuestionFallbackText(
                question: question,
                questionIndex: questionIndex,
                totalQuestions: totalQuestions
            )

            let questionTs = try await slackClient.postMessage(
                channel: config.slackChannelId,
                blocks: questionBlocks,
                text: questionFallbackText,
                threadTs: parentTs
            )
            Logger.debug("Posted question \(questionIndex) in thread: ts=\(questionTs)")

            // この質問への回答を待機
            let answer = try await waitForSingleAnswer(
                question: question,
                questionIndex: questionIndex,
                totalQuestions: totalQuestions,
                questionTs: questionTs,
                parentTs: parentTs,
                requestId: requestId,
                config: config,
                slackClient: slackClient,
                socketConnection: socketConnection
            )

            answers[questionIndex] = answer.text
            lastUserId = answer.userId
            Logger.info("Question \(questionIndex) answered: \(answer.text) by user: \(answer.userId)")
        }

        return (answers, lastUserId)
    }

    /// 単一の質問への回答を待機
    private static func waitForSingleAnswer(
        question: AskUserQuestionQuestion,
        questionIndex: Int,
        totalQuestions: Int,
        questionTs: String,
        parentTs: String,
        requestId: String,
        config: Configuration,
        slackClient: SlackClient,
        socketConnection: SocketModeConnection
    ) async throws -> (text: String, userId: String) {
        var multiSelectSelections: Set<Int> = []

        // このの質問に対応するactionIdを収集
        var pendingActions: Set<String> = []
        for optionIndex in 0..<question.options.count {
            let actionId = MessageBuilder.questionOptionActionId(
                questionIndex: questionIndex,
                optionIndex: optionIndex
            )
            pendingActions.insert(actionId)
        }

        if question.multiSelect {
            let submitActionId = MessageBuilder.questionSubmitActionId(questionIndex: questionIndex)
            pendingActions.insert(submitActionId)
        }

        while true {
            Logger.debug("Waiting for answer to question \(questionIndex)")

            // ボタン押下またはスレッド返信を待機
            // ボタンはquestionTsのメッセージに紐づく、スレッド返信はparentTsのスレッドに投稿される
            // replyAfterTs: 質問投稿後の返信のみを受け付ける（前の質問への回答を除外）
            let interaction = try await socketConnection.waitForBlockActionOrThreadReply(
                expectedActionIds: pendingActions,
                expectedMessageTs: questionTs,
                expectedThreadTs: parentTs,
                replyAfterTs: questionTs
            )

            switch interaction {
            case .buttonAction(let action, let userId, _):
                // 確定ボタンかどうかを確認
                if let _ = MessageBuilder.parseQuestionSubmitActionId(action.actionId) {
                    let selectedLabels = multiSelectSelections.sorted().compactMap { index -> String? in
                        guard index < question.options.count else { return nil }
                        return question.options[index].label
                    }
                    let answerText = selectedLabels.isEmpty ? "(未選択)" : selectedLabels.joined(separator: ", ")

                    // メッセージを更新（回答済み状態に）
                    let updatedBlocks = MessageBuilder.buildAskUserQuestionQuestionBlocks(
                        question: question,
                        questionIndex: questionIndex,
                        totalQuestions: totalQuestions,
                        requestId: requestId,
                        answer: answerText
                    )
                    try await slackClient.updateMessage(
                        channel: config.slackChannelId,
                        ts: questionTs,
                        blocks: updatedBlocks,
                        text: MessageBuilder.buildAskUserQuestionQuestionFallbackText(
                            question: question,
                            questionIndex: questionIndex,
                            totalQuestions: totalQuestions
                        )
                    )

                    return (answerText, userId)
                }

                // オプション選択の処理
                guard let (_, optionIndex) = MessageBuilder.parseQuestionOptionActionId(action.actionId) else {
                    Logger.warning("Could not parse actionId: \(action.actionId)")
                    continue
                }

                if question.multiSelect {
                    // multiSelect: トグル選択
                    if multiSelectSelections.contains(optionIndex) {
                        multiSelectSelections.remove(optionIndex)
                    } else {
                        multiSelectSelections.insert(optionIndex)
                    }

                    // 選択状態を反映したメッセージに更新
                    let updatedBlocks = MessageBuilder.buildAskUserQuestionQuestionBlocks(
                        question: question,
                        questionIndex: questionIndex,
                        totalQuestions: totalQuestions,
                        requestId: requestId,
                        selectedIndices: multiSelectSelections
                    )
                    try await slackClient.updateMessage(
                        channel: config.slackChannelId,
                        ts: questionTs,
                        blocks: updatedBlocks,
                        text: MessageBuilder.buildAskUserQuestionQuestionFallbackText(
                            question: question,
                            questionIndex: questionIndex,
                            totalQuestions: totalQuestions
                        )
                    )
                } else {
                    // 単一選択: 即座に回答確定
                    let selectedLabel = action.value ?? "unknown"

                    // メッセージを更新（回答済み状態に）
                    let updatedBlocks = MessageBuilder.buildAskUserQuestionQuestionBlocks(
                        question: question,
                        questionIndex: questionIndex,
                        totalQuestions: totalQuestions,
                        requestId: requestId,
                        answer: selectedLabel
                    )
                    try await slackClient.updateMessage(
                        channel: config.slackChannelId,
                        ts: questionTs,
                        blocks: updatedBlocks,
                        text: MessageBuilder.buildAskUserQuestionQuestionFallbackText(
                            question: question,
                            questionIndex: questionIndex,
                            totalQuestions: totalQuestions
                        )
                    )

                    return (selectedLabel, userId)
                }

            case .threadReply(let text, let userId, _):
                // スレッド返信は自由記述の回答として扱う
                Logger.info("Received thread reply as answer: \(text.prefix(100))")

                // メッセージを更新（回答済み状態に）
                let updatedBlocks = MessageBuilder.buildAskUserQuestionQuestionBlocks(
                    question: question,
                    questionIndex: questionIndex,
                    totalQuestions: totalQuestions,
                    requestId: requestId,
                    answer: text
                )
                try await slackClient.updateMessage(
                    channel: config.slackChannelId,
                    ts: questionTs,
                    blocks: updatedBlocks,
                    text: MessageBuilder.buildAskUserQuestionQuestionFallbackText(
                        question: question,
                        questionIndex: questionIndex,
                        totalQuestions: totalQuestions
                    )
                )

                return (text, userId)
            }
        }
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
