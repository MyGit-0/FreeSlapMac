import Foundation

public struct SlapDetectorConfig: Sendable {
    public var sampleRateHz: Double = 200.0
    public var shortWindowSec: Double = 0.030
    public var longWindowSec: Double = 1.000
    public var staLtaTriggerRatio: Double = 3.0
    public var peakMadTrigger: Double = 8.0
    public var cooldownMs: Int = 750
    public var minSamplesBeforeTrigger: Int = 200

    public init() {}
}

public struct SlapHit: Sendable, Equatable {
    public let peakG: Double
    public let staLtaRatio: Double
    public let timestampNs: UInt64
}

/// Port of spank's vibration pipeline (STA/LTA + peak/MAD + cooldown).
/// Fed |a|=√(x²+y²+z²) in g. Emits a `SlapHit` on confirmed impacts.
public final class SlapDetector {
    public private(set) var config: SlapDetectorConfig

    private var shortBuf: RingBuffer
    private var longBuf: RingBuffer
    private var samplesSeen: Int = 0
    private var lastTriggerNs: UInt64 = 0

    public init(config: SlapDetectorConfig = SlapDetectorConfig()) {
        self.config = config
        let shortN = max(4, Int((config.shortWindowSec * config.sampleRateHz).rounded()))
        let longN = max(shortN * 4, Int((config.longWindowSec * config.sampleRateHz).rounded()))
        self.shortBuf = RingBuffer(capacity: shortN)
        self.longBuf = RingBuffer(capacity: longN)
    }

    public func updateConfig(_ new: SlapDetectorConfig) {
        self.config = new
        let shortN = max(4, Int((new.shortWindowSec * new.sampleRateHz).rounded()))
        let longN = max(shortN * 4, Int((new.longWindowSec * new.sampleRateHz).rounded()))
        self.shortBuf = RingBuffer(capacity: shortN)
        self.longBuf = RingBuffer(capacity: longN)
        self.samplesSeen = 0
    }

    /// Feed one magnitude sample (in g). Returns a hit if this sample completes a detection.
    public func push(magnitudeG: Double, timestampNs: UInt64) -> SlapHit? {
        let deviation = abs(magnitudeG - 1.0)
        shortBuf.append(deviation * deviation)
        longBuf.append(deviation * deviation)
        samplesSeen += 1

        guard samplesSeen >= config.minSamplesBeforeTrigger else { return nil }

        let sta = shortBuf.mean()
        let lta = longBuf.mean()
        guard lta > 1e-9 else { return nil }
        let ratio = sta / lta

        let longMad = longBuf.medianAbsDeviation()
        let peakOverMad = longMad > 1e-9 ? deviation / longMad : 0

        let triggered = ratio >= config.staLtaTriggerRatio
            && peakOverMad >= config.peakMadTrigger

        guard triggered else { return nil }

        let cooldownNs = UInt64(config.cooldownMs) * 1_000_000
        if timestampNs &- lastTriggerNs < cooldownNs, lastTriggerNs != 0 {
            return nil
        }
        lastTriggerNs = timestampNs
        return SlapHit(peakG: magnitudeG, staLtaRatio: ratio, timestampNs: timestampNs)
    }
}

struct RingBuffer {
    private(set) var storage: [Double]
    private(set) var head: Int = 0
    private(set) var count: Int = 0
    let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
        self.storage = [Double](repeating: 0, count: capacity)
    }

    mutating func append(_ v: Double) {
        storage[head] = v
        head = (head + 1) % capacity
        if count < capacity { count += 1 }
    }

    func mean() -> Double {
        guard count > 0 else { return 0 }
        var s = 0.0
        for i in 0..<count { s += storage[i] }
        return s / Double(count)
    }

    func medianAbsDeviation() -> Double {
        guard count > 1 else { return 0 }
        var vals = Array(storage.prefix(count))
        vals.sort()
        let median = vals[vals.count / 2]
        var devs = vals.map { abs($0 - median) }
        devs.sort()
        return devs[devs.count / 2]
    }
}
