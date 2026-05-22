import Foundation

// 连接中继服务器作为 host，将消息转发给/接收自对端 Session
final class RelayClient {
    var onText:         ((String) -> Void)?
    var onBinary:       ((Data) -> Void)?
    var onConnected:    ((String) -> Void)?   // session ID
    var onDisconnected: (() -> Void)?

    private var task: URLSessionWebSocketTask?
    private let urlSession = URLSession(configuration: .default)

    func connect(relayURL: URL, pin: String) {
        var comps = URLComponents(url: relayURL, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "role", value: "host"),
            URLQueryItem(name: "pin",  value: pin)
        ]
        guard let url = comps.url else { return }
        task = urlSession.webSocketTask(with: url)
        task?.resume()
        receive()
    }

    func send(text: String) {
        task?.send(.string(text)) { _ in }
    }

    func send(data: Data) {
        task?.send(.data(data)) { _ in }
    }

    func disconnect() {
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
    }

    // MARK: - Private

    private func receive() {
        task?.receive { [weak self] result in
            switch result {
            case .success(let msg):
                switch msg {
                case .string(let text):
                    // 过滤中继自身的 registered 消息
                    if let data = text.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let type = json["type"] as? String {
                        if type == "registered", let sid = json["session_id"] as? String {
                            self?.onConnected?(sid)
                        } else {
                            self?.onText?(text)
                        }
                    }
                case .data(let d):
                    self?.onBinary?(d)
                @unknown default: break
                }
                self?.receive()
            case .failure:
                self?.onDisconnected?()
            }
        }
    }
}
