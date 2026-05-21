import Foundation
import Network

typealias MessageHandler = (NWConnection, String) -> Void
typealias BinaryHandler  = (NWConnection, Data) -> Void
typealias DisconnectHandler = (NWConnection) -> Void

final class WebSocketServer {
    var onText:       MessageHandler?
    var onBinary:     BinaryHandler?
    var onDisconnect: DisconnectHandler?

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "remoter.server", qos: .userInteractive)

    func start(port: UInt16) throws {
        let params = NWParameters.tcp
        let wsOpts = NWProtocolWebSocket.Options()
        wsOpts.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(wsOpts, at: 0)

        let p = NWEndpoint.Port(rawValue: port)!
        let l = try NWListener(using: params, on: p)
        l.stateUpdateHandler = { state in
            switch state {
            case .ready:   print("[Server] Listening on :\(port)")
            case .failed(let e): print("[Server] Failed: \(e)")
            default: break
            }
        }
        l.newConnectionHandler = { [weak self] conn in
            self?.accept(conn)
        }
        l.start(queue: queue)
        self.listener = l
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    func sendText(_ text: String, to conn: NWConnection) {
        guard let data = text.data(using: .utf8) else { return }
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "ws-text", metadata: [meta])
        conn.send(content: data, contentContext: ctx, isComplete: true, completion: .idempotent)
    }

    func sendBinary(_ data: Data, to conn: NWConnection) {
        let meta = NWProtocolWebSocket.Metadata(opcode: .binary)
        let ctx = NWConnection.ContentContext(identifier: "ws-bin", metadata: [meta])
        conn.send(content: data, contentContext: ctx, isComplete: true, completion: .idempotent)
    }

    // MARK: - Private

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(from: conn)
    }

    private func receive(from conn: NWConnection) {
        conn.receiveMessage { [weak self] content, ctx, _, error in
            if let error {
                if case .posix(let code) = error, code == .ECONNRESET { } else {
                    print("[Server] Receive error: \(error)")
                }
                self?.onDisconnect?(conn)
                return
            }

            if let meta = ctx?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata {
                if meta.opcode == .text, let data = content, let text = String(data: data, encoding: .utf8) {
                    self?.onText?(conn, text)
                } else if meta.opcode == .binary, let data = content {
                    self?.onBinary?(conn, data)
                } else if meta.opcode == .close {
                    self?.onDisconnect?(conn)
                    conn.cancel()
                    return
                }
            }

            self?.receive(from: conn)
        }
    }
}
