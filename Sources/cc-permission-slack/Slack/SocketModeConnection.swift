import Foundation

/// ボタン押下またはスレッド返信の結果
enum InteractionResult: Sendable {
    case buttonAction(action: SlackAction, userId: String, envelopeId: String)
    case threadReply(text: String, userId: String, envelopeId: String)
}

/// Slack Socket Mode 接続管理
actor SocketModeConnection {
    private let appToken: String
    private var webSocketTask: URLSessionWebSocketTask?
    private let session: URLSession
    private var isConnected = false

    init(appToken: String) {
        self.appToken = appToken
        self.session = URLSession.shared
    }

    /// Socket Mode 接続を開始
    func connect() async throws {
        Logger.info("Opening Socket Mode connection...")

        // apps.connections.open で WebSocket URL を取得
        let wsUrl = try await openConnection()

        Logger.info("Got WebSocket URL, connecting...")

        // WebSocket 接続
        guard let url = URL(string: wsUrl) else {
            throw CCPermissionError.invalidConfiguration("Invalid WebSocket URL")
        }

        webSocketTask = session.webSocketTask(with: url)
        webSocketTask?.resume()

        // hello メッセージを待機
        try await waitForHello()

        isConnected = true
        Logger.info("Socket Mode connection established")
    }

    /// apps.connections.open API を呼び出し
    private func openConnection() async throws -> String {
        let url = URL(string: "https://slack.com/api/apps.connections.open")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(appToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CCPermissionError.connectionOpenFailed("Invalid response")
        }

        Logger.debug("apps.connections.open response status: \(httpResponse.statusCode)")

        let connectionResponse = try JSONDecoder().decode(ConnectionOpenResponse.self, from: data)

        guard connectionResponse.ok, let wsUrl = connectionResponse.url else {
            let error = connectionResponse.error ?? "Unknown error"
            throw CCPermissionError.connectionOpenFailed(error)
        }

        return wsUrl
    }

    /// hello メッセージを待機
    private func waitForHello() async throws {
        guard let task = webSocketTask else {
            throw CCPermissionError.webSocketDisconnected
        }

        let message = try await task.receive()

        switch message {
        case .string(let text):
            Logger.debug("Received WebSocket message: \(text.prefix(500))")
            guard let data = text.data(using: .utf8) else {
                throw CCPermissionError.connectionOpenFailed("Failed to decode message as UTF-8")
            }
            do {
                let envelope = try JSONDecoder().decode(SocketModeEnvelope.self, from: data)
                guard envelope.type == "hello" else {
                    throw CCPermissionError.connectionOpenFailed("Expected hello but got: \(envelope.type)")
                }
                Logger.debug("Received hello message")
            } catch {
                Logger.error("JSON decode error: \(error)")
                throw CCPermissionError.connectionOpenFailed("Failed to parse message: \(error)")
            }

        case .data(let data):
            Logger.debug("Received WebSocket data: \(data.count) bytes")
            do {
                let envelope = try JSONDecoder().decode(SocketModeEnvelope.self, from: data)
                guard envelope.type == "hello" else {
                    throw CCPermissionError.connectionOpenFailed("Expected hello but got: \(envelope.type)")
                }
                Logger.debug("Received hello message")
            } catch {
                Logger.error("JSON decode error: \(error)")
                throw CCPermissionError.connectionOpenFailed("Failed to parse message: \(error)")
            }

        @unknown default:
            throw CCPermissionError.connectionOpenFailed("Unknown message type")
        }
    }

    /// block_actions イベントを待機
    /// 指定した actionId かつ送信したメッセージのts に一致するものを待機
    /// - Parameters:
    ///   - expectedActionIds: 期待するactionIdのセット
    ///   - expectedMessageTs: 期待するメッセージts（nilの場合はtsチェックをスキップ）
    func waitForBlockAction(expectedActionIds: Set<String>, expectedMessageTs: String? = nil) async throws -> (action: SlackAction, userId: String, envelopeId: String) {
        guard let task = webSocketTask else {
            throw CCPermissionError.webSocketDisconnected
        }

        Logger.info("Waiting for button click...")

        while true {
            let message = try await task.receive()

            let envelope: SocketModeEnvelope

            switch message {
            case .string(let text):
                guard let data = text.data(using: .utf8) else { continue }
                envelope = try JSONDecoder().decode(SocketModeEnvelope.self, from: data)

            case .data(let data):
                envelope = try JSONDecoder().decode(SocketModeEnvelope.self, from: data)

            @unknown default:
                continue
            }

            Logger.debug("Received envelope type: \(envelope.type)")

            // disconnect イベントの処理
            if envelope.type == "disconnect" {
                Logger.warning("Received disconnect event")
                throw CCPermissionError.webSocketDisconnected
            }

            // interactive イベント (block_actions) の処理
            if envelope.type == "interactive",
               let payload = envelope.payload,
               payload.type == "block_actions",
               let actions = payload.actions {

                let messageTs = payload.message?.ts
                Logger.debug("Checking action: actionId=\(actions.first?.actionId ?? "nil"), messageTs=\(messageTs ?? "nil"), expected=\(expectedMessageTs ?? "any")")

                // メッセージtsが一致するか確認（expectedMessageTsがnilの場合はスキップ）
                if let expectedTs = expectedMessageTs, messageTs != expectedTs {
                    Logger.debug("Ignoring action for different message: ts=\(messageTs ?? "nil") (expected: \(expectedTs))")
                    // 自分のリクエストでなくてもacknowledgeは返す（Slackのタイムアウトを防ぐ）
                    if let envelopeId = envelope.envelopeId {
                        try await acknowledge(envelopeId: envelopeId)
                    }
                    continue
                }

                for action in actions {
                    if expectedActionIds.contains(action.actionId) {
                        // 自分のリクエストに対するボタン押下のみ処理
                        let userId = payload.user?.id ?? "unknown"
                        guard let envelopeId = envelope.envelopeId else {
                            Logger.error("Missing envelope_id in block_actions")
                            continue
                        }
                        try await acknowledge(envelopeId: envelopeId)
                        Logger.info("Received action: \(action.actionId) from user: \(userId) for message: \(messageTs ?? "unknown")")
                        return (action, userId, envelopeId)
                    }
                }
            }
        }
    }

    /// block_actions イベントまたはスレッド返信を待機
    /// - Parameters:
    ///   - expectedActionIds: 期待するactionIdのセット
    ///   - expectedMessageTs: ボタンアクション用の期待するメッセージts
    ///   - expectedThreadTs: スレッド返信用の期待するスレッドts（省略時はexpectedMessageTsを使用）
    ///   - replyAfterTs: この時刻より後のスレッド返信のみ受け付ける（省略時はチェックなし）
    func waitForBlockActionOrThreadReply(
        expectedActionIds: Set<String>,
        expectedMessageTs: String,
        expectedThreadTs: String? = nil,
        replyAfterTs: String? = nil
    ) async throws -> InteractionResult {
        let threadTs = expectedThreadTs ?? expectedMessageTs
        guard let task = webSocketTask else {
            throw CCPermissionError.webSocketDisconnected
        }

        Logger.info("Waiting for button click or thread reply...")

        while true {
            let message = try await task.receive()

            let envelope: SocketModeEnvelope

            switch message {
            case .string(let text):
                guard let data = text.data(using: .utf8) else { continue }
                envelope = try JSONDecoder().decode(SocketModeEnvelope.self, from: data)

            case .data(let data):
                envelope = try JSONDecoder().decode(SocketModeEnvelope.self, from: data)

            @unknown default:
                continue
            }

            Logger.debug("Received envelope type: \(envelope.type)")

            // disconnect イベントの処理
            if envelope.type == "disconnect" {
                Logger.warning("Received disconnect event")
                throw CCPermissionError.webSocketDisconnected
            }

            // interactive イベント (block_actions) の処理
            if envelope.type == "interactive",
               let payload = envelope.payload,
               payload.type == "block_actions",
               let actions = payload.actions {

                let messageTs = payload.message?.ts
                Logger.debug("Checking action: actionId=\(actions.first?.actionId ?? "nil"), messageTs=\(messageTs ?? "nil"), expected=\(expectedMessageTs)")

                // メッセージtsが一致するか確認
                if messageTs != expectedMessageTs {
                    Logger.debug("Ignoring action for different message: ts=\(messageTs ?? "nil") (expected: \(expectedMessageTs))")
                    // 自分のリクエストでなくてもacknowledgeは返す（Slackのタイムアウトを防ぐ）
                    if let envelopeId = envelope.envelopeId {
                        try await acknowledge(envelopeId: envelopeId)
                    }
                    continue
                }

                for action in actions {
                    if expectedActionIds.contains(action.actionId) {
                        let userId = payload.user?.id ?? "unknown"
                        guard let envelopeId = envelope.envelopeId else {
                            Logger.error("Missing envelope_id in block_actions")
                            continue
                        }
                        try await acknowledge(envelopeId: envelopeId)
                        Logger.info("Received action: \(action.actionId) from user: \(userId)")
                        return .buttonAction(action: action, userId: userId, envelopeId: envelopeId)
                    }
                }
            }

            // events_api イベント (message) の処理 - スレッド返信
            if envelope.type == "events_api",
               let payload = envelope.payload,
               payload.type == "event_callback",
               let event = payload.event,
               event.type == "message",
               event.threadTs == threadTs {

                // ボットからのメッセージは無視（自分自身の質問投稿などを除外）
                if event.botId != nil {
                    Logger.debug("Ignoring bot message in thread")
                    // acknowledgeは送るが、返信としては扱わない
                    if let envelopeId = envelope.envelopeId {
                        try await acknowledge(envelopeId: envelopeId)
                    }
                    continue
                }

                // replyAfterTsより前の返信は無視（前の質問への回答を除外）
                if let afterTs = replyAfterTs, let eventTs = event.ts {
                    if eventTs <= afterTs {
                        Logger.debug("Ignoring old thread reply: ts=\(eventTs) <= afterTs=\(afterTs)")
                        if let envelopeId = envelope.envelopeId {
                            try await acknowledge(envelopeId: envelopeId)
                        }
                        continue
                    }
                }

                let text = event.text ?? ""
                let userId = event.user ?? "unknown"

                guard let envelopeId = envelope.envelopeId else {
                    Logger.error("Missing envelope_id in events_api")
                    continue
                }

                try await acknowledge(envelopeId: envelopeId)
                Logger.info("Received thread reply from user: \(userId): \(text.prefix(100))")
                return .threadReply(text: text, userId: userId, envelopeId: envelopeId)
            }
        }
    }

    /// acknowledge を送信
    func acknowledge(envelopeId: String) async throws {
        guard let task = webSocketTask else {
            throw CCPermissionError.webSocketDisconnected
        }

        let ack = SocketModeAck(envelopeId: envelopeId)
        let data = try JSONEncoder().encode(ack)

        try await task.send(.data(data))
        Logger.debug("Sent acknowledge for envelope: \(envelopeId)")
    }

    /// 接続を切断
    func disconnect() async {
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        isConnected = false
        Logger.info("Socket Mode connection closed")
    }
}
