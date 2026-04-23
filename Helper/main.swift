import Foundation

let log = FSLog(component: "helper", category: "main")

final class HelperService: NSObject, SlapHelperProtocol, NSXPCListenerDelegate {
    private let detector = SlapDetector()
    private var sensor: HIDSensor?
    private var clients = NSHashTable<NSXPCConnection>.weakObjects()
    private let queue = DispatchQueue(label: "com.freeslapmac.helper.detector")
    private var hitsEmitted = 0
    private var lastSensorBroadcastNs: UInt64 = 0
    private let sensorBroadcastIntervalNs: UInt64 = 50_000_000

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection c: NSXPCConnection) -> Bool {
        log.info("incoming XPC connection pid=\(c.processIdentifier)")
        c.exportedInterface = NSXPCInterface(with: SlapHelperProtocol.self)
        c.exportedObject = self
        c.remoteObjectInterface = NSXPCInterface(with: SlapClientProtocol.self)
        c.invalidationHandler = { [weak self, weak c] in
            guard let self, let c else { return }
            self.clients.remove(c)
            log.info("client invalidated")
        }
        clients.add(c)
        c.resume()
        return true
    }

    func ping(reply: @escaping (String) -> Void) {
        reply("FreeSlapMac helper alive pid=\(getpid()) hits=\(hitsEmitted)")
    }

    func setSensitivity(_ staLtaRatio: Double) {
        queue.async {
            var cfg = self.detector.config
            cfg.staLtaTriggerRatio = max(1.2, min(staLtaRatio, 20.0))
            self.detector.updateConfig(cfg)
            log.info("sensitivity=\(cfg.staLtaTriggerRatio)")
        }
    }

    func setCooldownMs(_ ms: Int) {
        queue.async {
            var cfg = self.detector.config
            cfg.cooldownMs = max(50, min(ms, 10_000))
            self.detector.updateConfig(cfg)
            log.info("cooldown=\(cfg.cooldownMs)ms")
        }
    }

    func start(reply: @escaping (Bool, String?) -> Void) {
        guard sensor == nil else { reply(true, "already running"); return }
        let s = HIDSensor(log: FSLog(component: "helper", category: "hid")) { [weak self] x, y, z, ts in
            guard let self else { return }
            let mag = (x * x + y * y + z * z).squareRoot()
            if ts &- self.lastSensorBroadcastNs >= self.sensorBroadcastIntervalNs || self.lastSensorBroadcastNs == 0 {
                self.lastSensorBroadcastNs = ts
                self.broadcastSensorSample(x: x, y: y, z: z, magnitude: mag, timestamp: ts)
            }
            self.queue.async {
                if let hit = self.detector.push(magnitudeG: mag, timestampNs: ts) {
                    self.hitsEmitted += 1
                    log.info("IMPACT #\(self.hitsEmitted) peakG=\(String(format: "%.2f", hit.peakG)) ratio=\(String(format: "%.1f", hit.staLtaRatio))")
                    self.broadcast(hit)
                }
            }
        }
        do {
            try s.start()
            sensor = s
            lastSensorBroadcastNs = 0
            log.info("sensor started; \(clients.count) client(s) subscribed")
            broadcastStatus(running: true, message: "Connected")
            reply(true, nil)
        } catch {
            log.error("HIDSensor start failed: \(error)")
            broadcastStatus(running: false, message: "Sensor start failed")
            reply(false, "HIDSensor start failed: \(error)")
        }
    }

    func stop() {
        log.info("stop requested")
        sensor?.stop()
        sensor = nil
        broadcastStatus(running: false, message: clients.allObjects.isEmpty ? "Installed" : "Stopped")
    }

    private func broadcast(_ hit: SlapHit) {
        for c in clients.allObjects {
            let proxy = c.remoteObjectProxyWithErrorHandler { err in
                log.error("XPC proxy error: \(err)")
            } as? SlapClientProtocol
            proxy?.slapDetected(peakG: hit.peakG, staLtaRatio: hit.staLtaRatio, timestamp: hit.timestampNs)
        }
    }

    private func broadcastStatus(running: Bool, message: String) {
        for c in clients.allObjects {
            let proxy = c.remoteObjectProxyWithErrorHandler { err in
                log.error("XPC proxy error: \(err)")
            } as? SlapClientProtocol
            proxy?.helperStatus(running: running, message: message)
        }
    }

    private func broadcastSensorSample(x: Double, y: Double, z: Double, magnitude: Double, timestamp: UInt64) {
        for c in clients.allObjects {
            let proxy = c.remoteObjectProxyWithErrorHandler { err in
                log.error("XPC proxy error: \(err)")
            } as? SlapClientProtocol
            proxy?.sensorSample(x: x, y: y, z: z, magnitude: magnitude, timestamp: timestamp)
        }
    }
}

log.info("helper daemon boot uid=\(getuid()) euid=\(geteuid())")
let service = HelperService()
let listener = NSXPCListener(machServiceName: kFreeSlapMacHelperMachName)
listener.delegate = service
listener.resume()
log.info("XPC listener on \(kFreeSlapMacHelperMachName) — entering run loop")
RunLoop.main.run()
