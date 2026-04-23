import Testing
@testable import FreeSlapMacCore

@Suite("SlapDetector")
struct SlapDetectorTests {
    @Test func idleProducesNoHits() {
        let d = SlapDetector()
        var hits = 0
        for i in 0..<2_000 {
            let t = UInt64(i) * 5_000_000
            let noise = 1.0 + Double.random(in: -0.02...0.02)
            if d.push(magnitudeG: noise, timestampNs: t) != nil { hits += 1 }
        }
        #expect(hits == 0, "idle noise should not trigger")
    }

    @Test func impulseTriggersAfterWarmup() {
        let d = SlapDetector()
        for i in 0..<1_000 {
            let t = UInt64(i) * 5_000_000
            _ = d.push(magnitudeG: 1.0 + Double.random(in: -0.01...0.01), timestampNs: t)
        }
        let t = UInt64(1_200) * 5_000_000
        let hit = d.push(magnitudeG: 5.0, timestampNs: t)
        #expect(hit != nil)
        #expect((hit?.peakG ?? 0) > 4.0)
    }

    @Test func cooldownSuppressesReTrigger() {
        let d = SlapDetector()
        for i in 0..<1_000 {
            let t = UInt64(i) * 5_000_000
            _ = d.push(magnitudeG: 1.0 + Double.random(in: -0.01...0.01), timestampNs: t)
        }
        let t1: UInt64 = 1_200 * 5_000_000
        let t2: UInt64 = t1 + 100_000_000
        let h1 = d.push(magnitudeG: 5.0, timestampNs: t1)
        let h2 = d.push(magnitudeG: 5.0, timestampNs: t2)
        #expect(h1 != nil)
        #expect(h2 == nil, "second impulse within cooldown must be suppressed")
    }
}
