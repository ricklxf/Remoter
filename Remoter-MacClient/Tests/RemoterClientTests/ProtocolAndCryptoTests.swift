import Foundation
import Testing
@testable import RemoterClient

@Suite("Protocol and E2E Crypto Tests")
struct ProtocolAndCryptoTests {

    // MARK: - E2ECrypto Tests

    @Test("E2E P-256 ECDH + HKDF-SHA256 + AES-256-GCM round-trip")
    func e2eCryptoRoundTripAndFormat() throws {
        let client = E2ECrypto()
        let server = E2ECrypto()

        #expect(!client.isReady)
        #expect(!server.isReady)

        let clientPub = client.generateKeyPairAndGetPublicKeyBase64()
        let serverPub = server.generateKeyPairAndGetPublicKeyBase64()

        let clientPubBytes = try #require(Data(base64Encoded: clientPub))
        let serverPubBytes = try #require(Data(base64Encoded: serverPub))
        #expect(clientPubBytes.count == 65)
        #expect(clientPubBytes[0] == 0x04)
        #expect(serverPubBytes.count == 65)
        #expect(serverPubBytes[0] == 0x04)

        try client.deriveSharedKey(peerBase64: serverPub)
        try server.deriveSharedKey(peerBase64: clientPub)

        #expect(client.isReady)
        #expect(server.isReady)

        let message = Data("{\"type\":\"auth_credentials\",\"username\":\"alice\",\"password\":\"s3cr3t\"}".utf8)
        let encrypted = try client.encrypt(message)
        #expect(encrypted.count == 12 + message.count + 16)

        let decrypted = try server.decrypt(encrypted)
        #expect(decrypted == message)

        // Reverse direction
        let reply = Data("{\"type\":\"auth_ok\",\"token\":\"tok_123\"}".utf8)
        let replyEnc = try server.encrypt(reply)
        let replyDec = try client.decrypt(replyEnc)
        #expect(replyDec == reply)

        // Tampered ciphertext must fail authentication
        var tampered = encrypted
        tampered[tampered.count - 1] ^= 0xFF
        #expect(throws: (any Error).self) {
            _ = try server.decrypt(tampered)
        }

        // Reset clears readiness
        client.reset()
        #expect(!client.isReady)
        #expect(throws: E2ECrypto.E2EError.notReady) {
            _ = try client.encrypt(message)
        }
    }

    @Test("E2E rejects invalid peer public keys")
    func e2eCryptoInvalidKeyRejected() {
        let crypto = E2ECrypto()
        _ = crypto.generateKeyPairAndGetPublicKeyBase64()
        #expect(throws: E2ECrypto.E2EError.invalidKey) {
            try crypto.deriveSharedKey(peerBase64: "not-valid-base64!!!")
        }
        #expect(throws: E2ECrypto.E2EError.invalidKey) {
            try crypto.deriveSharedKey(peerBase64: Data(repeating: 0x02, count: 33).base64EncodedString())
        }
    }

    // MARK: - Binary Frames Tests

    @Test("Parse 0x01 binary video frame")
    func parseVideoFrame() throws {
        var frame = Data()
        frame.append(FrameType.videoFrame.rawValue)
        // frameId = 0x01020304
        frame.append(contentsOf: [0x01, 0x02, 0x03, 0x04])
        // ptsMs = 0x00001388 (5000)
        frame.append(contentsOf: [0x00, 0x00, 0x13, 0x88])
        // flags = 0x01 (keyframe)
        frame.append(0x01)
        // Annex-B payload
        let payload = Data([0x00, 0x00, 0x00, 0x01, 0x67, 0x42])
        frame.append(payload)

        let parsed = try #require(BinaryFrames.parseVideoFrame(frame, activeCodec: .h265))
        #expect(parsed.frameId == 0x01020304)
        #expect(parsed.ptsMs == 5000)
        #expect(parsed.isKeyframe == true)
        #expect(parsed.codec == .h265)
        #expect(parsed.data == payload)

        // Too short rejected
        #expect(BinaryFrames.parseVideoFrame(Data([0x01, 0x00, 0x00]), activeCodec: .h264) == nil)
    }

    @Test("Parse 0x03 binary audio frame")
    func parseAudioFrame() throws {
        let adts = Data([0xFF, 0xF1, 0x4C, 0x80, 0x02, 0x1F, 0xFC])
        var frame = Data([FrameType.audioFrame.rawValue])
        frame.append(adts)

        let parsed = try #require(BinaryFrames.parseAudioFrame(frame))
        #expect(parsed.data == adts)
        #expect(BinaryFrames.parseAudioFrame(Data([0x03])) == nil)
    }

    @Test("Build and parse 0x02 file chunk round-trip")
    func fileChunkRoundTrip() throws {
        let payload = Data("Hello chunked file transfer!".utf8)
        let pkt = BinaryFrames.buildFileChunkPacket(fileId: "abc123", offset: 65536, chunk: payload)
        #expect(pkt.count == 1 + 16 + 4 + payload.count)
        #expect(pkt[0] == FrameType.fileChunk.rawValue)

        let parsed = try #require(BinaryFrames.parseFileChunk(pkt))
        #expect(parsed.fileId == "abc123")
        #expect(parsed.offset == 65536)
        #expect(parsed.chunk == payload)
    }

    // MARK: - JSON Wire Protocol Tests

    @Test("Outbound ClientMessages JSON wire format")
    func clientMessagesWireFormat() throws {
        func decode(_ data: Data) throws -> [String: Any] {
            try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }

        let auth = try decode(ClientMessages.authPin("123456"))
        #expect(auth["type"] as? String == "auth")
        #expect(auth["pin"] as? String == "123456")

        let scroll = try decode(ClientMessages.mouseScroll(
            dx: 0, dy: -3, px: 10, py: -20, isPrecise: true, phase: 2, momentumPhase: 0
        ))
        #expect(scroll["type"] as? String == "mouse_scroll")
        #expect(scroll["isPrecise"] as? Bool == true)
        #expect(scroll["px"] as? Int == 10)
        #expect(scroll["py"] as? Int == -20)

        let stats = try decode(ClientMessages.clientStats(fps: 60, rttMs: 12, rx: ""))
        #expect(stats["type"] as? String == "client_stats")
        #expect(stats["rtt_ms"] as? Int == 12)

        let res = try decode(ClientMessages.resolution(tier: .res2k, width: 2560, height: 1440, scale: 2.0))
        #expect(res["type"] as? String == "resolution")
        #expect(res["tier"] as? String == "2k")
        #expect(res["width"] as? Int == 2560)
    }

    @Test("Inbound ServerMessage JSON parsing")
    func serverMessageParsing() {
        let helloJson = Data("""
        {"type":"hello","version":"2.0.121","os":"macos","pubkey":"QUJD","computerName":"MacBook-Pro","modelId":"Mac15,6","inputLocked":false}
        """.utf8)
        guard case .hello(let hello) = ServerMessage.parse(jsonData: helloJson) else {
            Issue.record("Expected .hello")
            return
        }
        #expect(hello.version == "2.0.121")
        #expect(hello.os == "macos")
        #expect(hello.pubkey == "QUJD")
        #expect(hello.computerName == "MacBook-Pro")
        #expect(hello.inputLocked == false)

        let streamJson = Data("""
        {"type":"stream_started","width":2560,"height":1440,"codec":"hevc","fps":60,"display":2,"displays":[{"id":1,"name":"Built-in","width":1920,"height":1080},{"id":2,"name":"External","width":2560,"height":1440}]}
        """.utf8)
        guard case .streamStarted(let info) = ServerMessage.parse(jsonData: streamJson) else {
            Issue.record("Expected .streamStarted")
            return
        }
        #expect(info.width == 2560)
        #expect(info.height == 1440)
        #expect(info.codec == .h265)
        #expect(info.fps == 60)
        #expect(info.activeDisplayId == 2)
        #expect(info.displays.count == 2)
        #expect(info.displays[1].name == "External")

        let dirJson = Data("""
        {"type":"dir_listing","path":"/Users/test","entries":[{"name":"docs","size":0,"isDir":true,"modified":1700000000000}]}
        """.utf8)
        guard case .dirListing(let path, let entries) = ServerMessage.parse(jsonData: dirJson) else {
            Issue.record("Expected .dirListing")
            return
        }
        #expect(path == "/Users/test")
        #expect(entries.count == 1)
        #expect(entries[0].isDir == true)
    }

    // MARK: - ConnectParams URL Tests

    @Test("Build direct, IPv6, and relay WebSocket URLs")
    func buildWebSocketURL() throws {
        let directTls = ConnectParams(mode: .direct, host: "192.168.1.10", port: 7788, useTls: true)
        #expect(try directTls.buildWebSocketURL().absoluteString == "wss://192.168.1.10:7788")

        let ipv6 = ConnectParams(mode: .direct, host: "::1", port: 7788, useTls: false)
        #expect(try ipv6.buildWebSocketURL().absoluteString == "ws://[::1]:7788")

        let relay = ConnectParams(
            mode: .relay,
            relayUrl: "wss://relay.example.com:7789/",
            sessionId: "abc 123",
            pin: "99+88"
        )
        #expect(
            try relay.buildWebSocketURL().absoluteString ==
            "wss://relay.example.com:7789?role=client&session=abc%20123&pin=99%2B88"
        )
    }

    // MARK: - FNV-1a Hash Tests

    @Test("FNV-1a 64-bit standard vectors")
    func fnv1a64KnownVectors() {
        #expect(ProtocolHelpers.fnv1a64("") == 0xcbf29ce484222325)
        #expect(ProtocolHelpers.fnv1a64("foobar") == 0x85944171f73967e8)
    }

    // MARK: - DeviceStore Persistence Tests

    @Test("DeviceStore atomic persistence and reload")
    func deviceStorePersistence() {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("remoter_store_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let fileURL = tmpDir.appendingPathComponent("devices.json")

        let store = DeviceStore(customFileURL: fileURL)
        let dev = SavedDevice(
            name: "Studio Mac",
            host: "10.0.0.5",
            port: 7788,
            useTls: true,
            authMode: .pin,
            pin: "654321"
        )
        store.upsertDevice(dev)
        store.updateMachineInfo(host: "10.0.0.5", port: 7788, computerName: "Mac Studio", modelId: "Mac14,13", serverOs: "macos")
        store.updateToken(host: "10.0.0.5", port: 7788, username: "lxf", token: "tok_xyz")

        var settings = store.getSettings()
        settings.preferredCodec = .h265
        settings.fps = 120
        store.saveSettings(settings)

        // Reload from disk in a fresh instance
        let reloaded = DeviceStore(customFileURL: fileURL)
        let devices = reloaded.getDevices()
        #expect(devices.count == 1)
        #expect(devices[0].computerName == "Mac Studio")
        #expect(devices[0].token == "tok_xyz")
        #expect(reloaded.getSettings().preferredCodec == .h265)
        #expect(reloaded.getSettings().fps == 120)

        #expect(reloaded.removeDevice(id: devices[0].id) == true)
        #expect(reloaded.getDevices().isEmpty)
    }

    // MARK: - FileTransferClient Tests

    @Test("FileTransferClient chunked upload and download round-trip")
    func fileTransferUploadAndDownload() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("remoter_ft_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let sourceURL = tmpDir.appendingPathComponent("sample.bin")
        let sourceData = Data((0..<150_000).map { UInt8($0 & 0xFF) })
        try sourceData.write(to: sourceURL)

        let dlDir = tmpDir.appendingPathComponent("Downloads")
        var sentJson: [Data] = []
        var sentBinary: [Data] = []

        let client = FileTransferClient(
            sendJsonBytes: { sentJson.append($0) },
            sendBinaryAsync: { sentBinary.append($0) },
            downloadDirectory: dlDir
        )

        try await client.uploadFile(at: sourceURL, resume: false)
        #expect(sentJson.count == 2) // file_start + file_end
        #expect(sentBinary.count == 3) // 64K + 64K + remaining

        // Replay uploaded packets back into download side
        let startMsg = ServerMessage.parse(jsonData: sentJson[0])
        guard case .fileStart(let id, let name, let size, _) = startMsg else {
            Issue.record("Expected file_start")
            return
        }
        client.handleFileStart(id: id, name: name, size: size)
        for pkt in sentBinary {
            let chunk = try #require(BinaryFrames.parseFileChunk(pkt))
            client.handleFileChunk(id: chunk.fileId, offset: chunk.offset, chunk: chunk.chunk)
        }
        var completedPath: String?
        client.onDownloadCompleted = { _, path in completedPath = path }
        client.handleFileEnd(id: id)

        let savedPath = try #require(completedPath)
        let downloaded = try Data(contentsOf: URL(fileURLWithPath: savedPath))
        #expect(downloaded == sourceData)
    }

    @Test("Item 4 & Item 5 protocol messages and resumable transfer round-trip")
    func clipboardFilesAndResumableTransfer() async throws {
        func decode(_ data: Data) throws -> [String: Any] {
            try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }

        let startDict = try decode(ClientMessages.fileStart(
            id: "f1", name: "a.txt", size: 1024, relPath: "dir/a.txt", destDir: "/tmp", resume: true, purpose: "clipboard"
        ))
        #expect(startDict["relPath"] as? String == "dir/a.txt")
        #expect(startDict["destDir"] as? String == "/tmp")
        #expect(startDict["resume"] as? Bool == true)
        #expect(startDict["purpose"] as? String == "clipboard")

        let reqDict = try decode(ClientMessages.requestFile(path: "/a/b.bin", offset: 4096))
        #expect(reqDict["type"] as? String == "request_file")
        #expect(reqDict["offset"] as? Int == 4096)

        let treeReq = try decode(ClientMessages.listDirRecursive(path: "/Users/test/folder"))
        #expect(treeReq["type"] as? String == "list_dir_recursive")

        let cbSet = try decode(ClientMessages.clipboardSetFiles(paths: ["/tmp/1.txt", "/tmp/2.txt"]))
        #expect(cbSet["type"] as? String == "clipboard_set_files")
        #expect((cbSet["paths"] as? [String])?.count == 2)

        guard case .fileAck(let ackId, let ackOff, let resumed) = ServerMessage.parse(
            jsonData: Data(#"{"type":"file_ack","id":"f1","offset":65536,"resumed":true}"#.utf8)
        ) else {
            Issue.record("Expected .fileAck")
            return
        }
        #expect(ackId == "f1" && ackOff == 65536 && resumed)

        guard case .fileDone(let doneId, let donePath) = ServerMessage.parse(
            jsonData: Data(#"{"type":"file_done","id":"f1","path":"/Users/host/Downloads/a.txt"}"#.utf8)
        ) else {
            Issue.record("Expected .fileDone")
            return
        }
        #expect(doneId == "f1" && donePath == "/Users/host/Downloads/a.txt")

        guard case .dirTree(let root, let files) = ServerMessage.parse(
            jsonData: Data(#"{"type":"dir_tree","root":"/src","files":[{"relPath":"sub/a.txt","path":"/src/sub/a.txt","size":12}]}"#.utf8)
        ) else {
            Issue.record("Expected .dirTree")
            return
        }
        #expect(root == "/src" && files.count == 1 && files[0].relPath == "sub/a.txt")

        guard case .clipboardFilesFromTarget(let cbFiles) = ServerMessage.parse(
            jsonData: Data(#"{"type":"clipboard_files_from_target","files":[{"name":"a.png","path":"/tmp/a.png","size":500,"isDir":false}]}"#.utf8)
        ) else {
            Issue.record("Expected .clipboardFilesFromTarget")
            return
        }
        #expect(cbFiles.count == 1 && cbFiles[0].name == "a.png" && !cbFiles[0].isDir)

        guard case .clipboardFilesReady(let readyCount) = ServerMessage.parse(
            jsonData: Data(#"{"type":"clipboard_files_ready","count":3}"#.utf8)
        ) else {
            Issue.record("Expected .clipboardFilesReady")
            return
        }
        #expect(readyCount == 3)

        // Resumable download test with pre-existing .remoter.part
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("remoter_resume_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let fullData = Data((0..<100_000).map { UInt8($0 & 0xFF) })
        let destURL = tmpDir.appendingPathComponent("resumed.bin")
        let partURL = URL(fileURLWithPath: destURL.path + ".remoter.part")
        try fullData.prefix(40_000).write(to: partURL)

        let client = FileTransferClient(sendJsonBytes: { _ in }, sendBinaryAsync: { _ in }, downloadDirectory: tmpDir)
        let existingOff = client.prepareDownloadTarget(remotePath: "/remote/resumed.bin", destURL: destURL, overwriteExisting: true)
        #expect(existingOff == 40_000)

        client.handleFileStart(id: "r1", name: "resumed.bin", size: Int64(fullData.count), offset: existingOff)
        client.handleFileChunk(id: "r1", offset: UInt32(existingOff), chunk: fullData.suffix(from: 40_000))
        client.handleFileEnd(id: "r1")

        let finalData = try Data(contentsOf: destURL)
        #expect(finalData == fullData)
        #expect(!FileManager.default.fileExists(atPath: partURL.path))
    }

    // MARK: - LAN Helper Tests

    @Test("IPv4 loopback detected as LAN")
    func ipv4LoopbackIsLan() throws {
        let loopback = try #require(RemoterConnection.parseIPv4HostOrder("127.0.0.1"))
        #expect(RemoterConnection.isSameIPv4Subnet(targetHostOrder: loopback) == true)
        #expect(RemoterConnection.parseIPv4HostOrder("not-an-ip") == nil)
    }

    // MARK: - RFC 5389 STUN Client Tests

    @Test("RFC 5389 STUN Binding Request and XOR-MAPPED-ADDRESS round-trip")
    func stunRfc5389XorMappedAddressRoundTrip() throws {
        let txID = Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C])
        let req = StunClient.buildBindingRequest(txID: txID)
        #expect(req.count == 20)
        #expect(req[0] == 0x00 && req[1] == 0x01) // Binding Request
        #expect(req[4] == 0x21 && req[5] == 0x12 && req[6] == 0xA4 && req[7] == 0x42) // Magic Cookie
        #expect(req.subdata(in: 8..<20) == txID)

        // Build a synthetic Binding Success Response (0x0101) with XOR-MAPPED-ADDRESS (203.0.113.42:54321)
        let attr = try #require(StunClient.encodeXorMappedAddressAttribute(ip: "203.0.113.42", port: 54321))
        #expect(attr.count == 12)
        var resp = Data([
            0x01, 0x01, // Binding Success Response
            0x00, UInt8(attr.count), // Message Length = 12
            0x21, 0x12, 0xA4, 0x42   // Magic Cookie
        ])
        resp.append(txID)
        resp.append(attr)

        let parsed = try #require(StunClient.parseBindingResponse(resp, expectedTxID: txID))
        #expect(parsed.publicIp == "203.0.113.42")
        #expect(parsed.publicPort == 54321)

        // Mismatched transaction ID must be rejected
        let wrongTx = Data(repeating: 0xAA, count: 12)
        #expect(StunClient.parseBindingResponse(resp, expectedTxID: wrongTx) == nil)

        // Fallback MAPPED-ADDRESS (0x0001) response (198.51.100.7:12345)
        let mappedAttr = Data([
            0x00, 0x01, // MAPPED-ADDRESS
            0x00, 0x08, // Length = 8
            0x00, 0x01, // IPv4
            0x30, 0x39, // 12345 BE
            198, 51, 100, 7
        ])
        var mappedResp = Data([0x01, 0x01, 0x00, 12, 0x21, 0x12, 0xA4, 0x42])
        mappedResp.append(txID)
        mappedResp.append(mappedAttr)

        let parsedMapped = try #require(StunClient.parseBindingResponse(mappedResp, expectedTxID: txID))
        #expect(parsedMapped.publicIp == "198.51.100.7")
        #expect(parsedMapped.publicPort == 12345)
    }
}
