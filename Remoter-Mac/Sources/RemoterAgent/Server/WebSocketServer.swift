import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOWebSocket
import NIOSSL

// MARK: - WSClient

/// Connection handle exposed to the rest of the app.  Replaces NWConnection.
/// Wraps a SwiftNIO channel; all sends are queued on the channel's event loop.
/// TLS private key is loaded from PEM bytes in process memory — never touches
/// macOS keychain, so no keychain authorization dialog can appear.
final class WSClient: Hashable, @unchecked Sendable {
    let endpoint: String        // Remote address string, used for logging
    private let ch: Channel

    init(channel: Channel, endpoint: String) {
        self.ch = channel
        self.endpoint = endpoint
    }

    var isActive: Bool { ch.isActive }

    func sendText(_ text: String) {
        guard ch.isActive, let data = text.data(using: .utf8) else { return }
        var buf = ch.allocator.buffer(capacity: data.count)
        buf.writeBytes(data)
        ch.writeAndFlush(WebSocketFrame(fin: true, opcode: .text, data: buf), promise: nil)
    }

    func sendBinary(_ data: Data) {
        guard ch.isActive else { return }
        var buf = ch.allocator.buffer(capacity: data.count)
        buf.writeBytes(data)
        ch.writeAndFlush(WebSocketFrame(fin: true, opcode: .binary, data: buf), promise: nil)
    }

    /// Video-frame variant: calls onSent when TCP has accepted the data, providing
    /// backpressure.  Cancels the connection if TCP stalls for more than 5 seconds.
    func sendBinaryVideo(_ data: Data, onSent: @escaping () -> Void) {
        guard ch.isActive else { onSent(); return }
        var buf = ch.allocator.buffer(capacity: data.count)
        buf.writeBytes(data)

        let lock = NSLock()
        var done = false
        let finish: (Bool) -> Void = { [weak self] cancel in
            lock.lock(); let already = done; done = true; lock.unlock()
            guard !already else { return }
            if cancel { self?.ch.close(promise: nil) }
            onSent()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) { finish(true) }
        ch.writeAndFlush(WebSocketFrame(fin: true, opcode: .binary, data: buf))
            .whenComplete { _ in finish(false) }
    }

    func close() { ch.close(promise: nil) }

    static func == (lhs: WSClient, rhs: WSClient) -> Bool {
        lhs.ch === (rhs.ch as AnyObject)
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(ch as AnyObject))
    }
}

// MARK: - Type aliases (keep call sites in Session.swift / main.swift unchanged)

typealias MessageHandler    = (WSClient, String) -> Void
typealias BinaryHandler     = (WSClient, Data)   -> Void
typealias DisconnectHandler = (WSClient)          -> Void

// MARK: - WebSocketServer

final class WebSocketServer {
    var onConnect:    ((WSClient) -> Void)?
    var onText:       MessageHandler?
    var onBinary:     BinaryHandler?
    var onDisconnect: DisconnectHandler?

    /// When set, plain HTTP GET requests are served from this directory.
    var webDir: URL?

    private var serverChannel: Channel?
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)

    deinit { try? group.syncShutdownGracefully() }

    func start(port: UInt16) throws {
        let sslCtx = loadSSLContext()
        let scheme = sslCtx != nil ? "wss/https" : "ws/http"
        ConnectionLogger.shared.logStep(sessionId: "tls", step: "listen_scheme", detail: scheme)

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.backlog, value: 256)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [weak self] ch in
                self?.initPipeline(ch, sslCtx: sslCtx)
                    ?? ch.eventLoop.makeSucceededVoidFuture()
            }
            .childChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(.maxMessagesPerRead, value: 16)
            .childChannelOption(.recvAllocator, value: AdaptiveRecvByteBufferAllocator())

        serverChannel = try bootstrap.bind(host: "0.0.0.0", port: Int(port)).wait()
        print("[Server] Listening on :\(port) (\(scheme))")
    }

    func stop() {
        serverChannel?.close(promise: nil)
        serverChannel = nil
    }

    // MARK: - Pipeline setup

    private func initPipeline(_ ch: Channel, sslCtx: NIOSSLContext?) -> EventLoopFuture<Void> {
        let webDir = self.webDir
        // Keep a reference so upgradePipelineHandler can insert WSFrameHandler BEFORE it.
        // After WebSocket upgrade the inbound order becomes:
        //   NIOSSL → WS dec → WSFrameHandler → HTTPFileHandler (tail)
        // WSFrameHandler consumes every WebSocketFrame and does NOT call fireChannelRead,
        // so HTTPFileHandler only ever sees HTTPServerRequestPart from normal HTTP requests.
        let httpHandler = HTTPFileHandler(webDir: webDir)

        let upgrader = NIOWebSocketServerUpgrader(
            shouldUpgrade: { ch, _ in ch.eventLoop.makeSucceededFuture(HTTPHeaders()) },
            upgradePipelineHandler: { [weak self] ch, _ in
                guard let self else { return ch.eventLoop.makeSucceededVoidFuture() }
                let addr   = ch.remoteAddress?.description ?? "?"
                let client = WSClient(channel: ch, endpoint: addr)
                self.onConnect?(client)
                // NIOWebSocketServerUpgrader adds WS dec/enc at .last (AFTER httpHandler).
                // Remove httpHandler first so WSFrameHandler lands after WS dec/enc:
                //   NIOSSL → WS dec → WS enc → WSFrameHandler   (after HTTP handlers removed)
                // If .last were used without removal the order would be wrong:
                //   NIOSSL → httpHandler → WS dec → WS enc → WSFrameHandler → crash
                return ch.pipeline.removeHandler(name: "http-file")
                    .flatMapError { _ in ch.eventLoop.makeSucceededVoidFuture() }
                    .flatMap { ch.pipeline.addHandler(WSFrameHandler(client: client, server: self)) }
            }
        )

        if let ctx = sslCtx, let handler = try? NIOSSLServerHandler(context: ctx) {
            return ch.pipeline.addHandler(handler).flatMap {
                ch.pipeline.configureHTTPServerPipeline(
                    withServerUpgrade: (upgraders: [upgrader], completionHandler: { _ in })
                )
            }.flatMap { ch.pipeline.addHandler(httpHandler, name: "http-file") }
        } else {
            return ch.pipeline.configureHTTPServerPipeline(
                withServerUpgrade: (upgraders: [upgrader], completionHandler: { _ in })
            ).flatMap { ch.pipeline.addHandler(httpHandler, name: "http-file") }
        }
    }

    // MARK: - TLS — key loaded from PEM bytes, never touches macOS keychain

    private func loadSSLContext() -> NIOSSLContext? {
        guard let certURL  = Bundle.main.url(forResource: "server", withExtension: "crt"),
              let keyURL   = Bundle.main.url(forResource: "server", withExtension: "key"),
              let certBytes = try? [UInt8](Data(contentsOf: certURL)),
              let keyBytes  = try? [UInt8](Data(contentsOf: keyURL)) else {
            ConnectionLogger.shared.logStep(sessionId: "tls", step: "pem_not_found")
            return nil
        }
        do {
            let certs = try NIOSSLCertificate.fromPEMBytes(certBytes)
            let key   = try NIOSSLPrivateKey(bytes: keyBytes, format: .pem)
            var cfg   = TLSConfiguration.makeServerConfiguration(
                certificateChain: certs.map { .certificate($0) },
                privateKey: .privateKey(key)
            )
            cfg.minimumTLSVersion = .tlsv12
            let ctx = try NIOSSLContext(configuration: cfg)
            ConnectionLogger.shared.logStep(sessionId: "tls", step: "identity_ok")
            return ctx
        } catch {
            ConnectionLogger.shared.logStep(sessionId: "tls", step: "ssl_ctx_failed",
                detail: "\(error)")
            return nil
        }
    }
}

// MARK: - WebSocket frame handler

private final class WSFrameHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn   = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private let client: WSClient
    private weak var server: WebSocketServer?
    private var closed = false

    init(client: WSClient, server: WebSocketServer) {
        self.client = client
        self.server = server
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        switch frame.opcode {
        case .text:
            var buf = frame.unmaskedData
            if let text = buf.readString(length: buf.readableBytes) {
                server?.onText?(client, text)
            }
        case .binary:
            let buf = frame.unmaskedData
            server?.onBinary?(client, Data(buf.readableBytesView))
        case .connectionClose:
            if !closed { closed = true; server?.onDisconnect?(client) }
            context.close(promise: nil)
        case .ping:
            var pong = frame; pong.opcode = .pong
            context.writeAndFlush(wrapOutboundOut(pong), promise: nil)
        default:
            break
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        if !closed { closed = true; server?.onDisconnect?(client) }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}

// MARK: - HTTP static-file handler

private final class HTTPFileHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn   = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let webDir: URL?
    private var pendingHead: HTTPRequestHead?

    init(webDir: URL?) { self.webDir = webDir }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let h): pendingHead = h
        case .end:
            if let h = pendingHead { serve(context: context, head: h) }
            pendingHead = nil
        case .body: break
        }
    }

    private func serve(context: ChannelHandlerContext, head: HTTPRequestHead) {
        guard let webDir, head.method == .GET else {
            respond(context: context, version: head.version, status: .notFound, body: nil)
            return
        }
        let rawPath = head.uri.components(separatedBy: "?").first ?? "/"
        let rel = rawPath == "/" ? "index.html" : String(rawPath.drop { $0 == "/" })
        var fileURL = webDir.appendingPathComponent(rel)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            fileURL = webDir.appendingPathComponent("index.html")
        }
        guard let body = try? Data(contentsOf: fileURL) else {
            respond(context: context, version: head.version, status: .notFound, body: nil)
            return
        }
        respond(context: context, version: head.version, status: .ok,
                body: body, contentType: mime(ext: fileURL.pathExtension))
    }

    private func respond(context: ChannelHandlerContext, version: HTTPVersion,
                         status: HTTPResponseStatus, body: Data?,
                         contentType: String = "application/octet-stream") {
        var headers = HTTPHeaders()
        if let body {
            headers.add(name: "Content-Type",   value: contentType)
            headers.add(name: "Content-Length", value: "\(body.count)")
        }
        headers.add(name: "Cache-Control", value: "no-cache")
        headers.add(name: "Connection",    value: "close")

        context.write(wrapOutboundOut(.head(
            HTTPResponseHead(version: version, status: status, headers: headers)
        )), promise: nil)

        if let body {
            var buf = context.channel.allocator.buffer(capacity: body.count)
            buf.writeBytes(body)
            context.write(wrapOutboundOut(.body(.byteBuffer(buf))), promise: nil)
        }
        context.writeAndFlush(wrapOutboundOut(.end(nil)))
            .whenComplete { _ in context.close(promise: nil) }
    }

    private func mime(ext: String) -> String {
        switch ext.lowercased() {
        case "html":        return "text/html; charset=utf-8"
        case "js", "mjs":  return "application/javascript"
        case "css":         return "text/css"
        case "ico":         return "image/x-icon"
        case "png":         return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "svg":         return "image/svg+xml"
        case "woff2":       return "font/woff2"
        case "woff":        return "font/woff"
        case "json":        return "application/json"
        default:            return "application/octet-stream"
        }
    }
}
