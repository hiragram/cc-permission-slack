import Foundation

/// Slack Web API クライアント
actor SlackClient {
    private let botToken: String
    private let session: URLSession

    init(botToken: String) {
        self.botToken = botToken
        self.session = URLSession.shared
    }

    /// メッセージを投稿
    func postMessage(channel: String, blocks: [Block], text: String) async throws -> String {
        let url = URL(string: "https://slack.com/api/chat.postMessage")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(botToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "channel": channel,
            "text": text,
            "blocks": try blocksToJSON(blocks)
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        Logger.debug("Posting message to channel: \(channel)")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CCPermissionError.messagePostFailed(NSError(domain: "SlackClient", code: -1))
        }

        Logger.debug("chat.postMessage response status: \(httpResponse.statusCode)")

        let postResponse = try JSONDecoder().decode(PostMessageResponse.self, from: data)

        guard postResponse.ok, let ts = postResponse.ts else {
            let error = postResponse.error ?? "Unknown error"
            Logger.error("chat.postMessage failed: \(error)")
            throw CCPermissionError.slackAPIError(method: "chat.postMessage", error: error)
        }

        Logger.info("Message posted successfully: ts=\(ts)")
        return ts
    }

    /// メッセージを更新
    func updateMessage(channel: String, ts: String, blocks: [Block], text: String) async throws {
        let url = URL(string: "https://slack.com/api/chat.update")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(botToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "channel": channel,
            "ts": ts,
            "text": text,
            "blocks": try blocksToJSON(blocks)
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        Logger.debug("Updating message: ts=\(ts)")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CCPermissionError.messageUpdateFailed(NSError(domain: "SlackClient", code: -1))
        }

        Logger.debug("chat.update response status: \(httpResponse.statusCode)")

        let updateResponse = try JSONDecoder().decode(UpdateMessageResponse.self, from: data)

        guard updateResponse.ok else {
            let error = updateResponse.error ?? "Unknown error"
            Logger.error("chat.update failed: \(error)")
            throw CCPermissionError.slackAPIError(method: "chat.update", error: error)
        }

        Logger.info("Message updated successfully")
    }

    /// Block 配列を JSON シリアライズ可能な形式に変換
    private func blocksToJSON(_ blocks: [Block]) throws -> [[String: Any]] {
        let encoder = JSONEncoder()
        let data = try encoder.encode(blocks)
        guard let jsonArray = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw CCPermissionError.encodingFailed
        }
        return jsonArray
    }
}
