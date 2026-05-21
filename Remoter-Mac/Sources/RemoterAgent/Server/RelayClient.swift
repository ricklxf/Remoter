import Foundation

// Connects to the relay server as a host and bridges messages to/from Session
final class RelayClient {
    var onText:       ((String) -> Void)?
    var onBinary:     ((Data) -> Void)?
    var onConnected:  ((String) -> Void)?   // session ID
    var onDisconnected: (() -> Void)?

    private var task: URLSessionWebSocketTask?
    private let session = URLSession(configuration: .default)

    func connect(relayURL: URL, pin: String) {
        let url = relayURL.appendingPathComponent("") // keep base
        var comps = URLComponents(url: relayURL, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "role", value: "host"),
            URLQueryItem(name: "pin",  value: pin)
        ]
        guard let final = comps.url else { return }
        task = session.webSocketTask(with: final)
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
                    if let data = text.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let type = json["type"] as? String, type == "registered",
                       let sid = json["session_id"] as? String {
                        self?.onConnected?(sid)
                    } else {
                        self?.onText?(text)
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
