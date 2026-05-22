import Foundation

// 简单 AIMD 自适应码率控制器
// 客户端每 2 秒上报实际帧率，Mac 端根据此调整编码器码率
final class ABRController {
    private let targetFPS: Double
    private(set) var currentBitrate: Int
    private var goodCount = 0          // 连续达标次数

    let minBitrate =  1_000_000        //  1 Mbps
    let maxBitrate = 20_000_000        // 20 Mbps

    init(targetFPS: Double, initialBitrate: Int) {
        self.targetFPS      = targetFPS
        self.currentBitrate = initialBitrate
    }

    /// 返回新码率（若需要调整），nil 表示无需变化
    func update(fps: Double, rttMs: Int) -> Int? {
        let ratio = fps / targetFPS

        if ratio < 0.80 {
            // 帧率严重不足：激进降低 30%
            goodCount = 0
            return applyDelta(factor: 0.70)
        } else if rttMs > 150 {
            // RTT 过高说明网络拥塞：温和降低
            goodCount = 0
            return applyDelta(factor: 0.85)
        } else if ratio >= 0.95 {
            // 连续 3 次达标才加码（谨慎增加）
            goodCount += 1
            if goodCount >= 3 {
                goodCount = 0
                return applyDelta(factor: 1.15)
            }
        } else {
            goodCount = 0
        }

        return nil
    }

    // MARK: - Private

    private func applyDelta(factor: Double) -> Int? {
        let clamped = max(minBitrate, min(maxBitrate, Int(Double(currentBitrate) * factor)))
        guard clamped != currentBitrate else { return nil }
        currentBitrate = clamped
        return clamped
    }
}
