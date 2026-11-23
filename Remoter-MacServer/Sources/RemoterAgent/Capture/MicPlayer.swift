import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox

/// Opt-in microphone passthrough player on macOS host.
/// Routes incoming 48kHz mono 16-bit LE PCM frames from the remote client ONLY to an
/// installed virtual audio device ("BlackHole", "VB-Cable", "Soundflower") so remote
/// voice never plays back through physical speakers and causes acoustic echo.
final class MicPlayer {
    private static let virtualDeviceKeywords = ["blackhole", "vb-cable", "vbcable", "soundflower"]

    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var playFormat: AVAudioFormat?

    private(set) var isRunning = false
    private(set) var activeDeviceName: String = ""

    /// Finds a virtual audio output device and starts playback routing.
    /// Returns `false` if no virtual audio device is installed on this Mac.
    @discardableResult
    func start() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if isRunning { return true }

        guard let (deviceID, deviceName) = Self.findVirtualOutputDevice() else {
            ConnectionLogger.shared.logStep(sessionId: "mic", step: "mic_unavailable", detail: "no_virtual_audio_device")
            return false
        }

        let eng = AVAudioEngine()
        let node = AVAudioPlayerNode()
        guard let outputUnit = eng.outputNode.audioUnit else { return false }

        var devID = deviceID
        let status = AudioUnitSetProperty(
            outputUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &devID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            ConnectionLogger.shared.logStep(sessionId: "mic", step: "mic_device_bind_failed", detail: "status=\(status)")
            return false
        }

        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false) else {
            return false
        }
        eng.attach(node)
        eng.connect(node, to: eng.mainMixerNode, format: fmt)

        do {
            try eng.start()
            node.play()
        } catch {
            ConnectionLogger.shared.logStep(sessionId: "mic", step: "mic_engine_start_failed", detail: "\(error)")
            return false
        }

        engine = eng
        playerNode = node
        playFormat = fmt
        activeDeviceName = deviceName
        isRunning = true
        ConnectionLogger.shared.logStep(sessionId: "mic", step: "mic_started", detail: "device=\(deviceName)")
        return true
    }

    /// Enqueues 48kHz mono 16-bit signed little-endian PCM bytes to the virtual audio device.
    func enqueuePcm(_ pcmInt16Data: Data) {
        let sampleCount = pcmInt16Data.count / 2
        guard sampleCount > 0 else { return }

        lock.lock()
        guard isRunning, let node = playerNode, let fmt = playFormat else {
            lock.unlock()
            return
        }
        lock.unlock()

        guard let buffer = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(sampleCount)),
              let ch = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(sampleCount)

        pcmInt16Data.withUnsafeBytes { rawBuf in
            guard let ptr = rawBuf.bindMemory(to: Int16.self).baseAddress else { return }
            let scale: Float = 1.0 / 32768.0
            for i in 0..<sampleCount {
                ch[i] = Float(Int16(littleEndian: ptr[i])) * scale
            }
        }
        node.scheduleBuffer(buffer, completionHandler: nil)
    }

    func stop() {
        lock.lock()
        let eng = engine
        let node = playerNode
        engine = nil
        playerNode = nil
        playFormat = nil
        let wasRunning = isRunning
        isRunning = false
        activeDeviceName = ""
        lock.unlock()

        node?.stop()
        eng?.stop()
        if wasRunning {
            ConnectionLogger.shared.logStep(sessionId: "mic", step: "mic_stopped")
        }
    }

    // MARK: - CoreAudio device discovery

    private static func findVirtualOutputDevice() -> (AudioDeviceID, String)? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr,
              size > 0 else { return nil }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devices) == noErr else {
            return nil
        }

        for dev in devices {
            guard hasOutputStreams(deviceID: dev), let name = deviceName(deviceID: dev) else { continue }
            let lower = name.lowercased()
            if virtualDeviceKeywords.contains(where: { lower.contains($0) }) {
                return (dev, name)
            }
        }
        return nil
    }

    private static func hasOutputStreams(deviceID: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size) == noErr && size > 0
    }

    private static func deviceName(deviceID: AudioDeviceID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfName: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &cfName) == noErr,
              let name = cfName?.takeRetainedValue() as String? else {
            return nil
        }
        return name
    }
}
