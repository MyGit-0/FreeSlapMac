import Foundation

public let kFreeSlapMacHelperMachName = "com.freeslapmac.helper"

@objc public protocol SlapHelperProtocol {
    func ping(reply: @escaping (String) -> Void)
    func setSensitivity(_ staLtaRatio: Double)
    func setCooldownMs(_ ms: Int)
    func start(reply: @escaping (Bool, String?) -> Void)
    func stop()
}

@objc public protocol SlapClientProtocol {
    func slapDetected(peakG: Double, staLtaRatio: Double, timestamp: UInt64)
    func helperStatus(running: Bool, message: String)
    func sensorSample(x: Double, y: Double, z: Double, magnitude: Double, timestamp: UInt64)
}

public struct SlapEvent: Codable, Sendable {
    public let peakG: Double
    public let staLtaRatio: Double
    public let timestamp: UInt64

    public init(peakG: Double, staLtaRatio: Double, timestamp: UInt64) {
        self.peakG = peakG
        self.staLtaRatio = staLtaRatio
        self.timestamp = timestamp
    }
}
