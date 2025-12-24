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
            Logger.info("Received permission request for tool: \(request.toolName)")

            // 3. Socket Mode 接続
            let socketConnection = SocketModeConnection(appToken: config.slackAppToken)
            try await socketConnection.connect()

            defer {
                Task {
                    await socketConnection.disconnect()
                }
            }

            // 4. Slack にボタン付きメッセージを送信
            let slackClient = SlackClient(botToken: config.slackBotToken)
            let blocks = MessageBuilder.buildPermissionBlocks(request: request)
            let fallbackText = MessageBuilder.buildFallbackText(request: request)

            let messageTs = try await slackClient.postMessage(
                channel: config.slackChannelId,
                blocks: blocks,
                text: fallbackText
            )

            // 5. ボタン押下を待機
            let expectedActions: Set<String> = [
                MessageBuilder.approveActionId,
                MessageBuilder.denyActionId
            ]

            let (action, userId, envelopeId) = try await socketConnection.waitForBlockAction(
                expectedActionIds: expectedActions,
                expectedValue: request.toolUseId
            )

            // 6. Acknowledge を送信
            try await socketConnection.acknowledge(envelopeId: envelopeId)

            // 7. 決定を判定
            let approved = action.actionId == MessageBuilder.approveActionId

            // 8. メッセージを更新（ボタン削除 + 結果表示）
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

            // 9. stdout に結果を出力
            let response: PermissionResponse
            if approved {
                response = .allow()
                Logger.info("Permission approved by user: \(userId)")
            } else {
                response = .deny(message: "Denied by user via Slack")
                Logger.info("Permission denied by user: \(userId)")
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
