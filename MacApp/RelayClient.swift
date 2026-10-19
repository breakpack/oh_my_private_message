import Foundation

@MainActor final class RelayClient {
    var onFrame: ((String, String, Data) -> Void)?
    var onAcknowledgement: ((UUID, String) -> Void)?
    var onReady: (() -> Void)?
    var onStatus: ((String) -> Void)?

    private var task: URLSessionWebSocketTask?
    private var reconnectTask: Task<Void, Never>?
    private var configuredURL: URL?
    private var retryAttempt = 0
    private let identity: DeviceIdentity
    private let session = URLSession(configuration: .ephemeral)

    init(identity: DeviceIdentity) { self.identity = identity }

    func connect(to url: URL) {
        disconnect()
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if components?.path.isEmpty == true || components?.path == "/" { components?.path = "/relay" }
        configuredURL = components?.url ?? url
        retryAttempt = 0
        openSocket()
    }

    private func openSocket() {
        guard let url = configuredURL else { return }
        let socket = session.webSocketTask(with: url)
        task = socket
        socket.resume()
        onStatus?("연결 중")
        Task { await receive(from: socket) }
    }

    func disconnect() {
        configuredURL = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        onStatus?("오프라인")
    }

    func send(id: UUID, to peerID: String, ciphertext: Data) async throws {
        let frame: [String: Any] = ["type": "frame", "id": id.uuidString,
                                   "to": peerID, "ciphertext": ciphertext.base64URL]
        try await sendJSON(frame)
    }

    func acknowledge(id: String, to peerID: String) {
        Task { try? await sendJSON(["type": "ack", "id": id, "to": peerID]) }
    }

    private func sendJSON(_ object: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let task else { throw RelayError.disconnected }
        try await task.send(.string(String(decoding: data, as: UTF8.self)))
    }

    private func receive(from socket: URLSessionWebSocketTask) async {
        do {
            while task === socket {
                let message = try await socket.receive()
                let data: Data
                switch message {
                case .data(let bytes): data = bytes
                case .string(let text): data = Data(text.utf8)
                @unknown default: continue
                }
                try handle(data)
            }
        } catch {
            if task === socket {
                task = nil
                onStatus?("연결 끊김: \(error.localizedDescription)")
                scheduleReconnect()
            }
        }
    }

    private func handle(_ data: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return }
        switch type {
        case "challenge":
            guard let encoded = object["nonce"] as? String, let nonce = Data(base64URL: encoded) else { throw RelayError.badChallenge }
            let hello: [String: Any] = ["type": "hello", "deviceId": identity.id,
                                        "signingPublicKey": identity.signingPublicKey.base64URL,
                                        "signature": try identity.sign(nonce).base64URL]
            Task { try? await sendJSON(hello) }
        case "ready":
            retryAttempt = 0
            reconnectTask?.cancel()
            reconnectTask = nil
            onStatus?("연결됨")
            onReady?()
        case "frame":
            guard let sender = object["from"] as? String, let id = object["id"] as? String,
                  let ciphertext = (object["ciphertext"] as? String).flatMap(Data.init(base64URL:)) else { return }
            onFrame?(sender, id, ciphertext)
        case "ack":
            if let id = (object["id"] as? String).flatMap(UUID.init(uuidString:)),
               let sender = object["from"] as? String { onAcknowledgement?(id, sender) }
        case "unavailable":
            onStatus?("상대가 오프라인입니다. 전송 대기 중")
        default: break
        }
    }

    private func scheduleReconnect() {
        guard configuredURL != nil, reconnectTask == nil else { return }
        let delay = min(60, 2 << min(retryAttempt, 5))
        retryAttempt = min(retryAttempt + 1, 6)
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.configuredURL != nil else { return }
            self.reconnectTask = nil
            self.openSocket()
        }
    }
}

enum RelayError: LocalizedError {
    case disconnected, badChallenge
    var errorDescription: String? {
        switch self {
        case .disconnected: "릴레이 서버에 연결되어 있지 않습니다."
        case .badChallenge: "서버 인증 요청을 읽을 수 없습니다."
        }
    }
}
