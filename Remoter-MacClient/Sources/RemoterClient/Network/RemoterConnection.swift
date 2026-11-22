import Foundation
import Security
import Darwin

/// Pure native macOS WebSocket connection to Remoter-Mac and Remoter-Win agents.
/// Implements P-256 ECDH + AES-256-GCM E2E encryption, self-signed CN=Remoter TLS validation,
/// LAN subnet `net_hint` detection (`getifaddrs`), priority send queue with `mouse_move` and
/// `mouse_scroll` coalescing, 2s heartbeat / 6s stale timeout, 5x exponential backoff auto-reconnect,
/// clipboard FNV-1a anti-loop, and chunked file transfer.
public final class RemoterConnection: @unchecked Sendable {
    private static let maxReconnects = 5
    private static let statsIntervalMs: UInt64 = 2000
    private static let staleTimeoutMs: UInt64 = 6000
    private static let maxBulkQueueDepth = 8
    private static let maxWebSocketMessageSize = 16 * 1024 * 1024

    // MARK: - Outbound Queue Types

    private enum OutboundItem {
        case rawText(Data)
        case cryptoHello(Data)
        case controlJson(Data)
        case rawBinary(Data)
        case coalescedMouseMove
        case coalescedScroll
    }

    private struct PendingMouseMove {
        var x: Double
        var y: Double
        var dragging: String?
    }

    private struct PendingScroll {
        var dx: Int
        var dy: Int
        var px: Int?
        var py: Int?
        var isPrecise: Bool?
        var phase: Int?
        var momentumPhase: Int?
    }

    /// Thread-safe priority queue: high-priority control/input preempts bounded bulk file chunks.
    private final class SendQueue: @unchecked Sendable {
        private let lock = NSLock()
        private var controlItems: [OutboundItem] = []
        private var controlHead = 0
        private var bulkItems: [Data] = []
        private var bulkHead = 0
        private var closed = false

        private var pendingMouseMove: PendingMouseMove?
        private var mouseMoveQueued = false
        private var pendingScroll: PendingScroll?
        private var scrollQueued = false

        private var consumerWaiter: CheckedContinuation<Void, Never>?
        private var bulkSpaceWaiters: [CheckedContinuation<Void, Error>] = []

        enum Dequeued {
            case control(OutboundItem)
            case bulk(Data)
            case closed
        }

        func enqueueControl(_ item: OutboundItem) {
            lock.lock()
            if closed {
                lock.unlock()
                return
            }
            controlItems.append(item)
            let waiter = consumerWaiter
            consumerWaiter = nil
            lock.unlock()
            waiter?.resume()
        }

        func enqueueMouseMove(x: Double, y: Double, dragging: String?) {
            lock.lock()
            if closed {
                lock.unlock()
                return
            }
            pendingMouseMove = PendingMouseMove(x: x, y: y, dragging: dragging)
            var waiter: CheckedContinuation<Void, Never>?
            if !mouseMoveQueued {
                mouseMoveQueued = true
                controlItems.append(.coalescedMouseMove)
                waiter = consumerWaiter
                consumerWaiter = nil
            }
            lock.unlock()
            waiter?.resume()
        }

        func enqueueScroll(
            dx: Int,
            dy: Int,
            px: Int?,
            py: Int?,
            isPrecise: Bool?,
            phase: Int?,
            momentumPhase: Int?
        ) {
            lock.lock()
            if closed {
                lock.unlock()
                return
            }
            if var cur = pendingScroll {
                cur.dx += dx
                cur.dy += dy
                if let px { cur.px = (cur.px ?? 0) + px }
                if let py { cur.py = (cur.py ?? 0) + py }
                if let isPrecise { cur.isPrecise = isPrecise }
                if let phase { cur.phase = phase }
                if let momentumPhase { cur.momentumPhase = momentumPhase }
                pendingScroll = cur
            } else {
                pendingScroll = PendingScroll(
                    dx: dx,
                    dy: dy,
                    px: px,
                    py: py,
                    isPrecise: isPrecise,
                    phase: phase,
                    momentumPhase: momentumPhase
                )
            }
            var waiter: CheckedContinuation<Void, Never>?
            if !scrollQueued {
                scrollQueued = true
                controlItems.append(.coalescedScroll)
                waiter = consumerWaiter
                consumerWaiter = nil
            }
            lock.unlock()
            waiter?.resume()
        }

        func takeCoalescedMouseMove() -> PendingMouseMove? {
            lock.lock()
            defer { lock.unlock() }
            let move = pendingMouseMove
            pendingMouseMove = nil
            mouseMoveQueued = false
            return move
        }

        func takeCoalescedScroll() -> PendingScroll? {
            lock.lock()
            defer { lock.unlock() }
            let scroll = pendingScroll
            pendingScroll = nil
            scrollQueued = false
            return scroll
        }

        func enqueueBulk(_ data: Data) async throws {
            while true {
                try Task.checkCancellation()
                enum EnqueueOutcome {
                    case closed
                    case enqueued(CheckedContinuation<Void, Never>?)
                    case full
                }
                let outcome: EnqueueOutcome = lock.withLock {
                    if closed { return .closed }
                    let count = bulkItems.count - bulkHead
                    if count < RemoterConnection.maxBulkQueueDepth {
                        bulkItems.append(data)
                        let waiter = consumerWaiter
                        consumerWaiter = nil
                        return .enqueued(waiter)
                    }
                    return .full
                }

                switch outcome {
                case .closed:
                    throw CancellationError()
                case .enqueued(let waiter):
                    waiter?.resume()
                    return
                case .full:
                    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                        enum WaitOutcome {
                            case closed
                            case ready
                            case parked
                        }
                        let waitOutcome: WaitOutcome = lock.withLock {
                            if closed { return .closed }
                            if (bulkItems.count - bulkHead) < RemoterConnection.maxBulkQueueDepth {
                                return .ready
                            }
                            bulkSpaceWaiters.append(cont)
                            return .parked
                        }
                        switch waitOutcome {
                        case .closed: cont.resume(throwing: CancellationError())
                        case .ready:  cont.resume()
                        case .parked: break
                        }
                    }
                }
            }
        }

        func dequeueNext() async -> Dequeued {
            while true {
                enum DequeueAttempt {
                    case control(OutboundItem)
                    case bulk(Data, CheckedContinuation<Void, Error>?)
                    case closed
                    case empty
                }
                let attempt: DequeueAttempt = lock.withLock {
                    if controlHead < controlItems.count {
                        let item = controlItems[controlHead]
                        controlHead += 1
                        if controlHead >= 64 && controlHead * 2 >= controlItems.count {
                            controlItems.removeFirst(controlHead)
                            controlHead = 0
                        }
                        return .control(item)
                    }

                    if bulkHead < bulkItems.count {
                        let chunk = bulkItems[bulkHead]
                        bulkHead += 1
                        if bulkHead >= 16 && bulkHead * 2 >= bulkItems.count {
                            bulkItems.removeFirst(bulkHead)
                            bulkHead = 0
                        }
                        let spaceWaiter = bulkSpaceWaiters.isEmpty ? nil : bulkSpaceWaiters.removeFirst()
                        return .bulk(chunk, spaceWaiter)
                    }

                    if closed { return .closed }
                    return .empty
                }

                switch attempt {
                case .control(let item):
                    return .control(item)
                case .bulk(let chunk, let spaceWaiter):
                    spaceWaiter?.resume()
                    return .bulk(chunk)
                case .closed:
                    return .closed
                case .empty:
                    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                        let shouldResumeImmediately: Bool = lock.withLock {
                            if controlHead < controlItems.count || bulkHead < bulkItems.count || closed {
                                return true
                            }
                            consumerWaiter = cont
                            return false
                        }
                        if shouldResumeImmediately {
                            cont.resume()
                        }
                    }
                }
            }
        }

        func close() {
            lock.lock()
            closed = true
            pendingMouseMove = nil
            mouseMoveQueued = false
            pendingScroll = nil
            scrollQueued = false
            let consumer = consumerWaiter
            consumerWaiter = nil
            let bulkWaiters = bulkSpaceWaiters
            bulkSpaceWaiters.removeAll()
            lock.unlock()

            consumer?.resume()
            for w in bulkWaiters {
                w.resume(throwing: CancellationError())
            }
        }
    }

    // MARK: - URLSession WebSocket Delegate (TLS CN=Remoter Validation)

    private final class SessionDelegate: NSObject, URLSessionWebSocketDelegate {
        private let lock = NSLock()
        private var openContinuation: CheckedContinuation<Void, Error>?
        private var didOpen = false
        private var failedError: Error?

        func waitForOpen() async throws {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                lock.lock()
                if didOpen {
                    lock.unlock()
                    cont.resume()
                    return
                }
                if let err = failedError {
                    lock.unlock()
                    cont.resume(throwing: err)
                    return
                }
                openContinuation = cont
                lock.unlock()
            }
        }

        func cancelWait(_ error: Error) {
            lock.lock()
            if !didOpen && failedError == nil {
                failedError = error
            }
            let cont = openContinuation
            openContinuation = nil
            lock.unlock()
            cont?.resume(throwing: error)
        }

        func urlSession(
            _ session: URLSession,
            webSocketTask: URLSessionWebSocketTask,
            didOpenWithProtocol protocol: String?
        ) {
            lock.lock()
            didOpen = true
            let cont = openContinuation
            openContinuation = nil
            lock.unlock()
            cont?.resume()
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            didCompleteWithError error: Error?
        ) {
            guard let error else { return }
            lock.lock()
            if !didOpen && failedError == nil {
                failedError = error
            }
            let cont = openContinuation
            openContinuation = nil
            lock.unlock()
            cont?.resume(throwing: error)
        }

        func urlSession(
            _ session: URLSession,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  let serverTrust = challenge.protectionSpace.serverTrust else {
                completionHandler(.performDefaultHandling, nil)
                return
            }

            if Self.validateRemoterTrust(serverTrust) {
                completionHandler(.useCredential, URLCredential(trust: serverTrust))
            } else {
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        }

        static func validateRemoterTrust(_ serverTrust: SecTrust) -> Bool {
            // 1. Accept any standard CA-trusted certificate
            var error: CFError?
            if SecTrustEvaluateWithError(serverTrust, &error) {
                return true
            }

            // 2. Accept self-signed certificates with CN=Remoter (case-insensitive)
            guard let chain = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate],
                  let leaf = chain.first else {
                return false
            }

            var cnRef: CFString?
            if SecCertificateCopyCommonName(leaf, &cnRef) == errSecSuccess,
               let cn = cnRef as String?,
               cn.caseInsensitiveCompare("Remoter") == .orderedSame {
                return true
            }

            if let summary = SecCertificateCopySubjectSummary(leaf) as String?,
               summary.caseInsensitiveCompare("Remoter") == .orderedSame {
                return true
            }

            return false
        }
    }

    // MARK: - State & Properties

    private let e2e = E2ECrypto()
    private let stateLock = NSLock()
    private let statsLock = NSLock()
    private let clipboardLock = NSLock()

    private var _params: ConnectParams?
    private var _state: ConnectionState = .idle
    private var _activeCodec: VideoCodec = .h264
    private var _streamInfo: StreamStartedInfo?
    private var _serverOs: String = ""
    private var _serverComputerName: String = ""
    private var _serverModelId: String = ""

    private var _intentionalClose = false
    private var _wasStreaming = false
    private var _e2eSendActive = false
    private var _reconnectCount = 0

    private var _supervisorTask: Task<Void, Never>?
    private var _activeSession: URLSession?
    private var _activeWebSocket: URLSessionWebSocketTask?
    private var _sendQueue: SendQueue?
    private var _udpReceiver: UdpVideoReceiver?
    private var _udpActive = false
    private var _lastUdpKeyframeReqMs: UInt64 = 0

    // Clipboard anti-loop state (FNV-1a 64-bit)
    private var _clipboardEnabled = true
    private var _reverseClipboardActive = true
    private var _lastSentTextHash: UInt64 = 0
    private var _lastInjectedTextHash: UInt64 = 0
    private var _lastSentImageHash: UInt64 = 0
    private var _lastInjectedImageHash: UInt64 = 0

    // Stats & heartbeat tracking
    private var _lastRecvMs: UInt64 = 0
    private var _pingSentMs: UInt64 = 0
    private var _rttMs: Int = 0
    private var _encodeMs: Int = 0
    private var _frameCount: Int = 0
    private var _bytesCount: Int64 = 0

    public private(set) var fileTransfer: FileTransferClient!

    public var state: ConnectionState {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _state
    }

    public var activeCodec: VideoCodec {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _activeCodec
    }

    public var currentStreamInfo: StreamStartedInfo? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _streamInfo
    }

    public var serverOs: String {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _serverOs
    }

    public var serverComputerName: String {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _serverComputerName
    }

    public var serverModelId: String {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _serverModelId
    }

    public var isConnected: Bool {
        let s = state
        return s == .streaming || s == .authenticating
    }

    public var isEncrypted: Bool {
        e2e.isReady
    }

    public var rttMs: Int {
        statsLock.lock()
        defer { statsLock.unlock() }
        return _rttMs
    }

    public var encodeMs: Int {
        statsLock.lock()
        defer { statsLock.unlock() }
        return _encodeMs
    }

    /// Optional callback supplied by the video decoder to report decode latency (ms) in `ClientStats`.
    public var decodeMsProvider: (() -> Double)?
    /// Optional callback supplied by the video decoder to report HW/SW decode badge in `ClientStats`.
    public var isHardwareDecodedProvider: (() -> Bool)?

    // MARK: - Events / Callbacks (invoked on background thread; UI should dispatch to MainActor)

    public var onStateChanged: ((ConnectionState) -> Void)?
    public var onStreamStarted: ((StreamStartedInfo) -> Void)?
    public var onVideoFrame: ((VideoFramePacket) -> Void)?
    public var onAudioFrame: ((AudioFramePacket) -> Void)?
    public var onCodecChanged: ((VideoCodec) -> Void)?
    public var onQualityActiveChanged: ((_ fps: Int, _ bitrate: Int) -> Void)?
    public var onChromaActiveChanged: ((ChromaMode) -> Void)?
    public var onHdrActiveChanged: ((Bool) -> Void)?
    public var onForceCanvasChanged: ((Bool) -> Void)?
    public var onCursorShape: ((CursorShapeInfo) -> Void)?
    public var onClipboardReceived: ((ClipboardData) -> Void)?
    public var onInputLockChanged: ((Bool) -> Void)?
    public var onStatsUpdated: ((ClientStats) -> Void)?
    public var onServerStats: ((ServerStats) -> Void)?
    public var onFileTransferProgress: ((FileTransferProgress) -> Void)?
    public var onDirListing: ((_ path: String, _ entries: [RemoteFileEntry]) -> Void)?
    public var onAuthSucceeded: ((_ username: String, _ token: String) -> Void)?
    public var onServerHello: ((ServerHello) -> Void)?
    public var onError: ((String) -> Void)?
    public var onDisconnected: ((String) -> Void)?

    // MARK: - Init / Deinit

    public init(downloadDirectory: URL? = nil) {
        self.fileTransfer = nil
        let ft = FileTransferClient(
            sendJsonBytes: { [weak self] data in
                self?.enqueueControlJson(data)
            },
            sendBinaryAsync: { [weak self] data in
                guard let self else { throw CancellationError() }
                try await self.sendBinaryQueued(data)
            },
            downloadDirectory: downloadDirectory
        )
        ft.onProgress = { [weak self] progress in
            self?.onFileTransferProgress?(progress)
        }
        self.fileTransfer = ft
    }

    deinit {
        stopCurrentLifecycle(intentional: true)
        e2e.reset()
        fileTransfer.cancelAllDownloads()
    }

    // MARK: - Connection Lifecycle

    public func connect(_ params: ConnectParams) {
        stopCurrentLifecycle(intentional: false)

        stateLock.lock()
        _params = params
        _intentionalClose = false
        _wasStreaming = false
        _reconnectCount = 0
        let task: Task<Void, Never> = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.connectionSupervisorLoop(params: params)
        }
        _supervisorTask = task
        stateLock.unlock()
    }

    public func disconnect() {
        stopCurrentLifecycle(intentional: true)
        e2e.reset()
        fileTransfer.cancelAllDownloads()
        setState(.disconnected)
        onDisconnected?("Disconnected by user")
    }

    private func stopCurrentLifecycle(intentional: Bool) {
        stateLock.lock()
        _intentionalClose = intentional
        if intentional {
            _wasStreaming = false
            _reconnectCount = 0
        }
        _e2eSendActive = false
        let task = _supervisorTask
        _supervisorTask = nil
        let ws = _activeWebSocket
        _activeWebSocket = nil
        let session = _activeSession
        _activeSession = nil
        let queue = _sendQueue
        _sendQueue = nil
        let udp = _udpReceiver
        _udpReceiver = nil
        _udpActive = false
        stateLock.unlock()

        udp?.stop()
        queue?.close()
        task?.cancel()
        ws?.cancel(with: .normalClosure, reason: Data("Client disconnect".utf8))
        session?.invalidateAndCancel()
    }

    private func connectionSupervisorLoop(params: ConnectParams) async {
        var lastReason = "Connection closed"

        while !Task.isCancelled {
            let (intentional, attempt): (Bool, Int) = stateLock.withLock {
                (_intentionalClose, _reconnectCount)
            }
            if intentional { return }

            if attempt == 0 {
                setState(.connecting)
            }

            do {
                lastReason = try await runSingleSession(params: params)
            } catch is CancellationError {
                let isIntentional = stateLock.withLock { _intentionalClose }
                if isIntentional || Task.isCancelled { return }
                lastReason = "Connection cancelled"
            } catch {
                lastReason = error.localizedDescription
                let shouldEmit = stateLock.withLock { !_wasStreaming || _reconnectCount == 0 }
                if shouldEmit {
                    onError?(lastReason)
                }
            }

            let (isIntentional, canReconnect, wasStreamingSnapshot, nextAttempt): (Bool, Bool, Bool, Int) = stateLock.withLock {
                let intentional = _intentionalClose
                let canRec = _wasStreaming && _reconnectCount < Self.maxReconnects
                let wasStream = _wasStreaming
                if !intentional && canRec {
                    _reconnectCount += 1
                }
                return (intentional, canRec, wasStream, _reconnectCount)
            }

            if isIntentional || Task.isCancelled { return }

            if !canReconnect {
                setState(wasStreamingSnapshot ? .disconnected : .error)
                onDisconnected?(lastReason)
                return
            }

            let delayMs = min(500 * (1 << (nextAttempt - 1)), 5000)
            setState(.reconnecting)

            do {
                try await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
            } catch {
                return
            }
        }
    }

    private func runSingleSession(params: ConnectParams) async throws -> String {
        e2e.reset()
        resetSessionCounters()

        let url = try params.buildWebSocketURL()
        let delegate = SessionDelegate()
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 0

        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.qualityOfService = .userInitiated

        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: delegateQueue)
        let ws = session.webSocketTask(with: url)
        ws.maximumMessageSize = Self.maxWebSocketMessageSize

        let sendQueue = SendQueue()

        stateLock.withLock {
            _e2eSendActive = false
            _activeSession = session
            _activeWebSocket = ws
            _sendQueue = sendQueue
        }

        defer {
            sendQueue.close()
            let udp: UdpVideoReceiver? = stateLock.withLock {
                if _activeWebSocket === ws { _activeWebSocket = nil }
                if _activeSession === session { _activeSession = nil }
                if _sendQueue === sendQueue { _sendQueue = nil }
                _e2eSendActive = false
                _udpActive = false
                let u = _udpReceiver
                _udpReceiver = nil
                return u
            }
            udp?.stop()
            ws.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
        }

        ws.resume()

        // Wait for WebSocket handshake with 10s timeout
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await delegate.waitForOpen()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 10_000_000_000)
                throw URLError(.timedOut)
            }
            do {
                try await group.next()
                group.cancelAll()
            } catch {
                delegate.cancelWait(error)
                group.cancelAll()
                throw error
            }
        }

        statsLock.withLock {
            _lastRecvMs = Self.monotonicMs()
        }

        setState(.authenticating)

        // Start priority send loop & 2s stats/heartbeat loop
        let sendTask = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.sendLoop(ws: ws, queue: sendQueue)
        }
        let statsTask = Task.detached(priority: .utility) { [weak self] in
            await self?.statsLoop(ws: ws)
        }

        // Match Remoter-WinClient & Remoter-Client: Direct + PIN sends plaintext auth immediately on WS open
        if params.mode == .direct && params.authMode == .pin {
            sendQueue.enqueueControl(.controlJson(ClientMessages.authPin(params.pin)))
        }

        let closeReason = await receiveLoop(ws: ws)

        sendQueue.close()
        sendTask.cancel()
        statsTask.cancel()
        _ = await sendTask.value
        _ = await statsTask.value

        return closeReason
    }

    private func resetSessionCounters() {
        stateLock.lock()
        _serverOs = ""
        _serverComputerName = ""
        _serverModelId = ""
        stateLock.unlock()

        clipboardLock.lock()
        _lastSentTextHash = 0
        _lastInjectedTextHash = 0
        _lastSentImageHash = 0
        _lastInjectedImageHash = 0
        clipboardLock.unlock()

        statsLock.lock()
        _frameCount = 0
        _bytesCount = 0
        _rttMs = 0
        _encodeMs = 0
        _pingSentMs = 0
        _lastRecvMs = Self.monotonicMs()
        statsLock.unlock()
    }

    // MARK: - Send, Receive & Stats Loops

    private func sendLoop(ws: URLSessionWebSocketTask, queue: SendQueue) async {
        while !Task.isCancelled {
            let next = await queue.dequeueNext()
            switch next {
            case .closed:
                return

            case .control(let item):
                do {
                    switch item {
                    case .rawText(let utf8):
                        let str = String(decoding: utf8, as: UTF8.self)
                        try await ws.send(.string(str))

                    case .cryptoHello(let utf8):
                        let str = String(decoding: utf8, as: UTF8.self)
                        try await ws.send(.string(str))
                        stateLock.withLock {
                            _e2eSendActive = true
                        }

                    case .controlJson(let utf8):
                        try await sendJsonPayload(ws: ws, utf8Json: utf8)

                    case .rawBinary(let data):
                        try await ws.send(.data(data))

                    case .coalescedMouseMove:
                        if let move = queue.takeCoalescedMouseMove() {
                            let json = ClientMessages.mouseMove(x: move.x, y: move.y, dragging: move.dragging)
                            try await sendJsonPayload(ws: ws, utf8Json: json)
                        }

                    case .coalescedScroll:
                        if let s = queue.takeCoalescedScroll() {
                            let json = ClientMessages.mouseScroll(
                                dx: s.dx,
                                dy: s.dy,
                                px: s.px,
                                py: s.py,
                                isPrecise: s.isPrecise,
                                phase: s.phase,
                                momentumPhase: s.momentumPhase
                            )
                            try await sendJsonPayload(ws: ws, utf8Json: json)
                        }
                    }
                } catch {
                    return
                }

            case .bulk(let chunk):
                do {
                    try await ws.send(.data(chunk))
                } catch {
                    return
                }
            }
        }
    }

    private func sendJsonPayload(ws: URLSessionWebSocketTask, utf8Json: Data) async throws {
        let encrypted = stateLock.withLock { _e2eSendActive && e2e.isReady }

        if encrypted {
            let cipher = try e2e.encrypt(utf8Json)
            var frame = Data(capacity: 1 + cipher.count)
            frame.append(FrameType.encrypted.rawValue)
            frame.append(cipher)
            try await ws.send(.data(frame))
        } else {
            let str = String(decoding: utf8Json, as: UTF8.self)
            try await ws.send(.string(str))
        }
    }

    private func receiveLoop(ws: URLSessionWebSocketTask) async -> String {
        while !Task.isCancelled {
            do {
                let message = try await ws.receive()
                statsLock.withLock {
                    _lastRecvMs = Self.monotonicMs()
                }

                switch message {
                case .string(let text):
                    handleTextMessage(Data(text.utf8))
                case .data(let data):
                    handleBinaryMessage(data)
                @unknown default:
                    break
                }
            } catch {
                if ws.closeCode != .invalid {
                    if let reasonData = ws.closeReason,
                       let reasonStr = String(data: reasonData, encoding: .utf8),
                       !reasonStr.isEmpty {
                        return reasonStr
                    }
                    return "Server closed (\(ws.closeCode.rawValue))"
                }
                return error.localizedDescription
            }
        }
        return "WebSocket closed"
    }

    private func statsLoop(ws: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: Self.statsIntervalMs * 1_000_000)
            } catch {
                return
            }

            if state != .streaming { continue }

            let now = Self.monotonicMs()
            let lastRecv = statsLock.withLock { _lastRecvMs }

            if lastRecv > 0 && now >= lastRecv && (now - lastRecv) > Self.staleTimeoutMs {
                // Stale connection — abort socket to trigger auto-reconnect
                ws.cancel(with: .goingAway, reason: Data("Heartbeat timeout".utf8))
                return
            }

            let (frames, bytes, rtt, encode): (Int, Int64, Int, Int) = statsLock.withLock {
                let f = _frameCount
                _frameCount = 0
                let b = _bytesCount
                _bytesCount = 0
                let r = _rttMs
                let e = _encodeMs
                _pingSentMs = now
                return (f, b, r, e)
            }

            let fps = Double(frames) / (Double(Self.statsIntervalMs) / 1000.0)
            let bitrateKbps = Int((Double(bytes) * 8.0 / Double(Self.statsIntervalMs)).rounded())
            let decodeMs = Int((decodeMsProvider?() ?? 0.0).rounded())
            let isHw = isHardwareDecodedProvider?() ?? true

            enqueueControlJson(ClientMessages.ping())
            enqueueControlJson(ClientMessages.clientStats(fps: fps.rounded(), rttMs: rtt, rx: ""))

            let isUdp = stateLock.withLock { _udpActive }
            onStatsUpdated?(ClientStats(
                fps: fps,
                rttMs: rtt,
                bitrateKbps: bitrateKbps,
                encodeMs: encode,
                decodeMs: decodeMs,
                transport: isUdp ? "UDP" : "TCP",
                codec: activeCodec,
                isHardwareDecoded: isHw
            ))
        }
    }

    // MARK: - Inbound Message Handling

    private func handleTextMessage(_ utf8Json: Data) {
        let msg = ServerMessage.parse(jsonData: utf8Json)
        routeServerMessage(msg)
    }

    private func handleBinaryMessage(_ data: Data) {
        guard let prefix = data.first else { return }

        switch prefix {
        case FrameType.encrypted.rawValue:
            guard data.count > 1 else { return }
            do {
                let plain = try e2e.decrypt(data.subdata(in: 1..<data.count))
                let msg = ServerMessage.parse(jsonData: plain)
                routeServerMessage(msg)
            } catch {
                // Ignore decrypt failure
            }

        case FrameType.videoFrame.rawValue:
            statsLock.lock()
            _frameCount += 1
            _bytesCount += Int64(data.count)
            statsLock.unlock()

            if let packet = BinaryFrames.parseVideoFrame(data, activeCodec: activeCodec) {
                onVideoFrame?(packet)
            }

        case FrameType.audioFrame.rawValue:
            if let packet = BinaryFrames.parseAudioFrame(data) {
                onAudioFrame?(packet)
            }

        case FrameType.fileChunk.rawValue:
            if let parsed = BinaryFrames.parseFileChunk(data) {
                fileTransfer.handleFileChunk(id: parsed.fileId, offset: parsed.offset, chunk: parsed.chunk)
            }

        default:
            break
        }
    }

    private func routeServerMessage(_ msg: ServerMessage) {
        switch msg {
        case .hello(let hello):
            stateLock.lock()
            _serverOs = hello.os
            _serverComputerName = hello.computerName
            _serverModelId = hello.modelId
            stateLock.unlock()

            onServerHello?(hello)
            if let locked = hello.inputLocked {
                onInputLockChanged?(locked)
            }

            if let pubkey = hello.pubkey, !pubkey.isEmpty {
                do {
                    let myPub = e2e.generateKeyPairAndGetPublicKeyBase64()
                    try e2e.deriveSharedKey(peerBase64: pubkey)
                    stateLock.lock()
                    let queue = _sendQueue
                    stateLock.unlock()
                    // Send crypto_hello as plaintext; sendLoop flips _e2eSendActive right after it goes out
                    queue?.enqueueControl(.cryptoHello(ClientMessages.cryptoHello(pubkeyBase64: myPub)))
                } catch {
                    e2e.reset()
                    sendDeferredAuth()
                }
            } else {
                sendDeferredAuth()
            }

        case .cryptoOk:
            sendDeferredAuth()

        case .authOk(let token, let username):
            if let token, !token.isEmpty {
                stateLock.lock()
                let fallbackUser = _params?.username ?? ""
                stateLock.unlock()
                onAuthSucceeded?(username ?? fallbackUser, token)
            }
            sendNetHint()

        case .streamStarted(let info):
            stateLock.lock()
            _wasStreaming = true
            _reconnectCount = 0
            _activeCodec = info.codec
            _streamInfo = info
            stateLock.unlock()

            setState(.streaming)
            onStreamStarted?(info)

        case .codecChanged(let codec):
            stateLock.lock()
            _activeCodec = codec
            stateLock.unlock()
            onCodecChanged?(codec)

        case .qualityActive(let fps, let bitrate):
            onQualityActiveChanged?(fps, bitrate)

        case .chromaActive(let mode):
            onChromaActiveChanged?(mode)

        case .hdrActive(let enabled):
            onHdrActiveChanged?(enabled)

        case .inputLockChanged(let locked):
            onInputLockChanged?(locked)

        case .cursorShape(let cursor):
            onCursorShape?(cursor)

        case .pong(let encodeMs):
            let now = Self.monotonicMs()
            statsLock.lock()
            let sent = _pingSentMs
            _pingSentMs = 0
            if sent > 0 && now >= sent {
                _rttMs = Int(now - sent)
            }
            _encodeMs = encodeMs
            statsLock.unlock()

        case .serverStats(let stats):
            onServerStats?(stats)

        case .fileStart(let id, let name, let size):
            fileTransfer.handleFileStart(id: id, name: name, size: size)

        case .fileEnd(let id):
            fileTransfer.handleFileEnd(id: id)

        case .dirListing(let path, let entries):
            onDirListing?(path, entries)

        case .clipboardFromTarget(let cb):
            clipboardLock.lock()
            let reverseActive = _reverseClipboardActive
            if !reverseActive {
                clipboardLock.unlock()
                return
            }
            var isEcho = false
            if let text = cb.text {
                let hash = ProtocolHelpers.fnv1a64(text)
                if hash == _lastSentTextHash {
                    isEcho = true
                } else {
                    _lastInjectedTextHash = hash
                }
            }
            if !isEcho, let img = cb.imagePngData, !img.isEmpty {
                let hash = ProtocolHelpers.fnv1a64(img)
                if hash == _lastSentImageHash {
                    isEcho = true
                } else {
                    _lastInjectedImageHash = hash
                }
            }
            clipboardLock.unlock()

            if !isEcho {
                onClipboardReceived?(cb)
            }

        case .hostDisconnected:
            setState(.disconnected)
            onDisconnected?("Host disconnected")

        case .error(_, let message):
            onError?(message)
            let cur = state
            if cur == .authenticating || cur == .connecting {
                setState(.error)
            }

        case .forceCanvas(let enabled):
            onForceCanvasChanged?(enabled)

        case .udpOffer(let port, let tokenHex):
            handleUdpOffer(port: port, tokenHex: tokenHex)

        case .udpActive(let enabled):
            stateLock.withLock {
                _udpActive = enabled
            }

        case .keepalive, .unknown:
            break
        }
    }

    private func sendDeferredAuth() {
        stateLock.lock()
        let params = _params
        stateLock.unlock()
        guard let params, params.mode == .direct else { return }

        switch params.authMode {
        case .credentials:
            enqueueControlJson(ClientMessages.authCredentials(
                username: params.username ?? "",
                password: params.password ?? ""
            ))
        case .token:
            enqueueControlJson(ClientMessages.authToken(params.token ?? ""))
        case .pin:
            break
        }
    }

    // MARK: - Direct UDP Video Channel

    private func handleUdpOffer(port: Int, tokenHex: String) {
        guard port > 0 && port <= Int(UInt16.max),
              let token = UdpVideoReceiver.decodeHexToken(tokenHex) else {
            return
        }

        let params = stateLock.withLock { _params }
        guard let params,
              params.mode == .direct,
              let url = try? params.buildWebSocketURL(),
              let host = url.host,
              !host.isEmpty else {
            return
        }

        let receiver = UdpVideoReceiver()
        receiver.onConnected = { [weak self] connected in
            self?.stateLock.withLock {
                self?._udpActive = connected
            }
        }
        receiver.onFrame = { [weak self] packet in
            guard let self else { return }
            let now = Self.monotonicMs()
            self.statsLock.lock()
            self._lastRecvMs = now
            self._frameCount += 1
            self._bytesCount += Int64(packet.data.count)
            self.statsLock.unlock()
            self.onVideoFrame?(packet)
        }
        receiver.onFrameDropped = { [weak self] in
            guard let self else { return }
            let now = Self.monotonicMs()
            let shouldRequest: Bool = self.stateLock.withLock {
                if now >= self._lastUdpKeyframeReqMs && (now - self._lastUdpKeyframeReqMs) >= 500 {
                    self._lastUdpKeyframeReqMs = now
                    return true
                }
                return false
            }
            if shouldRequest {
                self.sendRequestKeyframe()
            }
        }

        let previous: UdpVideoReceiver? = stateLock.withLock {
            let prev = _udpReceiver
            _udpReceiver = receiver
            _udpActive = false
            return prev
        }
        previous?.stop()
        receiver.start(host: host, port: UInt16(port), token: token)
    }

    // MARK: - LAN Subnet Detection (net_hint via getifaddrs)

    private func sendNetHint() {
        stateLock.lock()
        let params = _params
        stateLock.unlock()
        guard let params, params.mode == .direct,
              let url = try? params.buildWebSocketURL(),
              let host = url.host else {
            return
        }
        guard let targetIP = Self.parseIPv4HostOrder(host) else { return }
        let isLan = Self.isSameIPv4Subnet(targetHostOrder: targetIP)
        enqueueControlJson(ClientMessages.netHint(lan: isLan))
    }

    internal static func parseIPv4HostOrder(_ ipString: String) -> UInt32? {
        var addr = in_addr()
        guard inet_pton(AF_INET, ipString, &addr) == 1 else { return nil }
        return UInt32(bigEndian: addr.s_addr)
    }

    internal static func isSameIPv4Subnet(targetHostOrder target: UInt32) -> Bool {
        // 127.0.0.0/8 loopback
        if (target & 0xFF00_0000) == 0x7F00_0000 {
            return true
        }

        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else {
            return false
        }
        defer { freeifaddrs(first) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let current = ptr {
            let flags = Int32(current.pointee.ifa_flags)
            let isUp = (flags & IFF_UP) != 0
            if isUp,
               let addrPtr = current.pointee.ifa_addr,
               addrPtr.pointee.sa_family == UInt8(AF_INET),
               let maskPtr = current.pointee.ifa_netmask {
                let sinAddr = addrPtr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                let sinMask = maskPtr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                let local = UInt32(bigEndian: sinAddr.s_addr)
                let mask = UInt32(bigEndian: sinMask.s_addr)
                if mask != 0 && (local & mask) == (target & mask) {
                    return true
                }
            }
            ptr = current.pointee.ifa_next
        }
        return false
    }

    // MARK: - Public Send API (Thread-Safe, Non-Blocking)

    public func sendMouseMove(x: Double, y: Double, dragging: String? = nil) {
        stateLock.lock()
        let queue = _sendQueue
        stateLock.unlock()
        queue?.enqueueMouseMove(x: x, y: y, dragging: dragging)
    }

    public func sendMouseButton(button: String, down: Bool, x: Double, y: Double) {
        enqueueControlJson(ClientMessages.mouseButton(button: button, down: down, x: x, y: y))
    }

    public func sendMouseDoubleClick(button: String, x: Double, y: Double) {
        enqueueControlJson(ClientMessages.mouseDoubleClick(button: button, x: x, y: y))
    }

    public func sendMouseScroll(
        dx: Int,
        dy: Int,
        px: Int? = nil,
        py: Int? = nil,
        isPrecise: Bool? = nil,
        phase: Int? = nil,
        momentumPhase: Int? = nil
    ) {
        stateLock.lock()
        let queue = _sendQueue
        stateLock.unlock()
        queue?.enqueueScroll(
            dx: dx,
            dy: dy,
            px: px,
            py: py,
            isPrecise: isPrecise,
            phase: phase,
            momentumPhase: momentumPhase
        )
    }

    public func sendKey(code: String, down: Bool, modifiers: [String]) {
        enqueueControlJson(ClientMessages.key(code: code, down: down, modifiers: modifiers))
    }

    public func sendTextInput(_ text: String) {
        guard !text.isEmpty else { return }
        enqueueControlJson(ClientMessages.textInput(text))
    }

    public func sendClipboardText(_ text: String) {
        let hash = ProtocolHelpers.fnv1a64(text)
        clipboardLock.lock()
        guard _clipboardEnabled else {
            clipboardLock.unlock()
            return
        }
        if hash == _lastSentTextHash || hash == _lastInjectedTextHash {
            clipboardLock.unlock()
            return
        }
        _lastSentTextHash = hash
        clipboardLock.unlock()
        enqueueControlJson(ClientMessages.clipboardSet(text: text))
    }

    public func sendClipboardImage(_ pngData: Data) {
        guard !pngData.isEmpty else { return }
        let hash = ProtocolHelpers.fnv1a64(pngData)
        clipboardLock.lock()
        guard _clipboardEnabled else {
            clipboardLock.unlock()
            return
        }
        if hash == _lastSentImageHash || hash == _lastInjectedImageHash {
            clipboardLock.unlock()
            return
        }
        _lastSentImageHash = hash
        clipboardLock.unlock()
        enqueueControlJson(ClientMessages.clipboardSetImage(base64Png: pngData.base64EncodedString()))
    }

    public func sendClipboardImageBase64(_ base64Png: String) {
        guard !base64Png.isEmpty else { return }
        let hash: UInt64
        if let decoded = Data(base64Encoded: base64Png) {
            hash = ProtocolHelpers.fnv1a64(decoded)
        } else {
            hash = ProtocolHelpers.fnv1a64(base64Png)
        }
        clipboardLock.lock()
        guard _clipboardEnabled else {
            clipboardLock.unlock()
            return
        }
        if hash == _lastSentImageHash || hash == _lastInjectedImageHash {
            clipboardLock.unlock()
            return
        }
        _lastSentImageHash = hash
        clipboardLock.unlock()
        enqueueControlJson(ClientMessages.clipboardSetImage(base64Png: base64Png))
    }

    public func setClipboardSyncEnabled(_ enabled: Bool) {
        clipboardLock.lock()
        _clipboardEnabled = enabled
        clipboardLock.unlock()
    }

    public func setReverseClipboardActive(_ active: Bool) {
        clipboardLock.lock()
        _reverseClipboardActive = active
        clipboardLock.unlock()
        enqueueControlJson(ClientMessages.setReverseClipboardSync(enabled: active))
    }

    public func sendFps(_ fps: Int, auto: Bool = false) {
        enqueueControlJson(ClientMessages.fps(fps, auto: auto))
    }

    public func sendBitrate(_ bitrateBps: Int, auto: Bool = false) {
        enqueueControlJson(ClientMessages.bitrate(bitrateBps, auto: auto))
    }

    public func sendResolution(tier: ResolutionTier, width: Int? = nil, height: Int? = nil, scale: Double? = nil) {
        enqueueControlJson(ClientMessages.resolution(tier: tier, width: width, height: height, scale: scale))
    }

    public func sendChroma(_ mode: ChromaMode) {
        enqueueControlJson(ClientMessages.chroma(mode))
    }

    public func sendChroma(_ mode: String) {
        enqueueControlJson(ClientMessages.chroma(ChromaMode(wireString: mode)))
    }

    public func sendHdr(enabled: Bool) {
        enqueueControlJson(ClientMessages.hdr(enabled: enabled))
    }

    public func sendHdr(_ enabled: Bool) {
        enqueueControlJson(ClientMessages.hdr(enabled: enabled))
    }

    public func sendLowLatency(_ enabled: Bool) {
        enqueueControlJson(ClientMessages.lowLatency(enabled: enabled))
    }

    public func sendSetCodec(_ codec: VideoCodec) {
        enqueueControlJson(ClientMessages.setCodec(codec))
    }

    public func sendSetAudio(enabled: Bool) {
        enqueueControlJson(ClientMessages.setAudio(enabled: enabled))
    }

    public func sendSetMuted(_ muted: Bool) {
        enqueueControlJson(ClientMessages.setMuted(muted))
    }

    public func sendSetPrivacyScreen(enabled: Bool) {
        enqueueControlJson(ClientMessages.setPrivacyScreen(enabled: enabled))
    }

    public func sendInputLock(_ locked: Bool) {
        enqueueControlJson(ClientMessages.setInputLock(locked: locked))
    }

    public func sendSetInputEnabled(_ enabled: Bool) {
        enqueueControlJson(ClientMessages.setInputEnabled(enabled: enabled))
    }

    public func sendSetDisplay(_ displayId: UInt32) {
        enqueueControlJson(ClientMessages.setDisplay(id: displayId))
    }

    public func sendRequestKeyframe() {
        enqueueControlJson(ClientMessages.requestKeyframe())
    }

    public func sendCtrlAltDel() {
        enqueueControlJson(ClientMessages.ctrlAltDel())
    }

    public func sendLockScreen() {
        enqueueControlJson(ClientMessages.lockScreen())
    }

    public func sendLogout() {
        enqueueControlJson(ClientMessages.logout())
    }

    public func sendRestart() {
        enqueueControlJson(ClientMessages.restart())
    }

    public func sendListDir(path: String) {
        enqueueControlJson(ClientMessages.listDir(path: path))
    }

    public func sendRequestFile(remotePath: String) {
        enqueueControlJson(ClientMessages.requestFile(path: remotePath))
    }

    public func uploadFile(at url: URL) async throws {
        try await fileTransfer.uploadFile(at: url)
    }

    // MARK: - Queue & State Helpers

    private func enqueueControlJson(_ utf8Json: Data) {
        stateLock.lock()
        let queue = _sendQueue
        stateLock.unlock()
        queue?.enqueueControl(.controlJson(utf8Json))
    }

    private func sendBinaryQueued(_ data: Data) async throws {
        let queue = stateLock.withLock { _sendQueue }
        guard let queue else {
            throw URLError(.notConnectedToInternet)
        }
        try await queue.enqueueBulk(data)
    }

    private func setState(_ next: ConnectionState) {
        stateLock.lock()
        if _state == next {
            stateLock.unlock()
            return
        }
        _state = next
        stateLock.unlock()
        onStateChanged?(next)
    }

    private static func monotonicMs() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds / 1_000_000
    }
}
