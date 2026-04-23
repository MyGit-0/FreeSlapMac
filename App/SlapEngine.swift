import AVFoundation
import AppKit
import Combine
import Foundation
import ServiceManagement

@MainActor
final class SlapEngine: NSObject, ObservableObject, SlapClientProtocol {
    struct LiveSensorPoint: Identifiable {
        let id = UUID()
        let timestamp: Date
        let magnitude: Double
    }

    @Published var running = false
    @Published var slapCount: Int = UserDefaults.standard.integer(forKey: "slapCount")
    @Published var sensitivity: Double = UserDefaults.standard.double(forKey: "sensitivity").nonZeroOr(3.0)
    @Published var cooldownMs: Int = UserDefaults.standard.integer(forKey: "cooldownMs").nonZeroOr(750)
    @Published var helperInstalled = false
    @Published var helperStatusText = "Not installed"
    @Published var relaxTrackName: String = "Bundled: calm"
    @Published var lastEvent: String = "(no events yet)"
    @Published var liveSensorX = 0.0
    @Published var liveSensorY = 0.0
    @Published var liveSensorZ = 0.0
    @Published var liveSensorMagnitude = 0.0
    @Published var liveSensorSampleCount = 0
    @Published var liveSensorSampleRateHz = 0.0
    @Published var liveSensorHistory: [LiveSensorPoint] = []
    @Published var sensorRecording = false
    @Published var sensorRecordingStatus = "Not recording"
    @Published var detectedSensors: [MotionDeviceInfo] = []
    @Published var sensorSource = "Inactive"

    private let log = FSLog(component: "app", category: "engine")
    private var xpc: NSXPCConnection?
    private var reactionPlayer: AVAudioPlayer?
    private var relaxPlayer: AVAudioPlayer?
    private var relaxBookmark: Data? = UserDefaults.standard.data(forKey: "relaxBookmark")
    private var liveSensorStartedAt: Date?
    private var recordingFileHandle: FileHandle?
    private var recordingFileURL: URL?
    private let localDetector = SlapDetector()
    private var localSensor: HIDSensor?

    private static let helperService = SMAppService.daemon(plistName: "com.freeslapmac.helper.plist")

    private static let audioExts: Set<String> = ["mp3", "wav", "m4a", "aac", "aif", "aiff", "flac", "caf"]

    override init() {
        super.init()
        log.info("SlapEngine init; bundle=\(Bundle.main.bundlePath)")
        refreshHelperStatus()
        refreshDetectedSensors()
        loadRelaxTrackName()
        observeUnlock()
        // Auto-connect if helper is already enabled
        if helperInstalled {
            log.info("helper enabled on launch; auto-starting")
            running = true
            startDetection()
        }
    }

    func toggleRunning() {
        log.info("toggleRunning currentlyRunning=\(running)")
        if running {
            running = false
            stopDetection()
        } else {
            running = true
            startDetection()
        }
    }

    func pushSensitivity(_ v: Double) {
        UserDefaults.standard.set(v, forKey: "sensitivity")
        log.info("pushSensitivity \(v)")
        var cfg = localDetector.config
        cfg.staLtaTriggerRatio = max(1.2, min(v, 20.0))
        localDetector.updateConfig(cfg)
        helperProxy()?.setSensitivity(v)
    }

    func pushCooldown(_ v: Double) {
        UserDefaults.standard.set(Int(v), forKey: "cooldownMs")
        log.info("pushCooldown \(Int(v))ms")
        var cfg = localDetector.config
        cfg.cooldownMs = max(50, min(Int(v), 10_000))
        localDetector.updateConfig(cfg)
        helperProxy()?.setCooldownMs(Int(v))
    }

    // MARK: - Helper install

    func refreshHelperStatus() {
        let status = Self.helperService.status
        helperInstalled = status == .enabled
        helperStatusText = switch status {
        case .notRegistered: "Not installed — click Install Helper"
        case .enabled: "Installed"
        case .requiresApproval: "Approve in System Settings → Login Items"
        case .notFound: "Plist missing from bundle"
        @unknown default: "Unknown"
        }
        log.info("helperStatus=\(status.rawValue) (\(helperStatusText))")
    }

    func installHelper() {
        log.info("installHelper requested")
        do {
            try Self.helperService.register()
            log.info("helper register() succeeded")
        } catch {
            log.error("helper register() failed: \(error)")
            helperStatusText = "Install failed: \(error.localizedDescription)"
        }
        refreshHelperStatus()
        if Self.helperService.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
        if helperInstalled, !running { startDetection(); running = true }
    }

    func uninstallHelper() {
        do { try Self.helperService.unregister() } catch { log.error("unregister failed: \(error)") }
        stopSensorRecording()
        refreshHelperStatus()
    }

    func openHelperApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    // MARK: - XPC

    private func startDetection() {
        refreshDetectedSensors()
        do {
            try startLocalSensor()
            sensorSource = "Direct sensor access"
            helperStatusText = helperInstalled ? "Connected (direct sensors)" : "Direct sensors active"
            log.info("local sensor path active")
        } catch {
            log.error("local sensor start failed: \(error)")
            sensorSource = "Helper fallback"
            connectAndStart()
        }
    }

    private func stopDetection() {
        stopLocalSensor()
        stopXPC()
        running = false
        if helperInstalled {
            helperStatusText = "Installed"
        } else {
            helperStatusText = "Not installed — click Install Helper"
        }
    }

    private func connectAndStart() {
        log.info("connecting to XPC mach service \(kFreeSlapMacHelperMachName)")
        if let existing = xpc {
            log.warn("replacing existing XPC connection before reconnect")
            existing.invalidationHandler = nil
            existing.interruptionHandler = nil
            existing.invalidate()
            xpc = nil
        }

        let c = NSXPCConnection(machServiceName: kFreeSlapMacHelperMachName, options: .privileged)
        c.remoteObjectInterface = NSXPCInterface(with: SlapHelperProtocol.self)
        c.exportedInterface = NSXPCInterface(with: SlapClientProtocol.self)
        c.exportedObject = self
        c.invalidationHandler = { [weak self] in
            Task { @MainActor in
                self?.log.warn("XPC invalidated")
                self?.running = false
            }
        }
        c.interruptionHandler = { [weak self] in
            Task { @MainActor in
                self?.log.warn("XPC interrupted")
                self?.running = false
            }
        }
        c.resume()
        xpc = c

        let proxy = c.remoteObjectProxyWithErrorHandler { [weak self] err in
            Task { @MainActor in self?.log.error("XPC proxy error: \(err)") }
        } as? SlapHelperProtocol

        proxy?.ping { [weak self] reply in
            Task { @MainActor in self?.log.info("helper ping: \(reply)") }
        }
        proxy?.setSensitivity(sensitivity)
        proxy?.setCooldownMs(cooldownMs)
        proxy?.start { [weak self] ok, msg in
            Task { @MainActor in
                guard let self else { return }
                self.running = ok
                if !ok {
                    self.helperStatusText = msg ?? "Start failed"
                    self.sensorSource = "Unavailable"
                    self.log.error("helper.start failed: \(msg ?? "?")")
                } else {
                    self.sensorSource = "Helper"
                    self.helperStatusText = "Connected (helper)"
                    self.log.info("helper.start OK")
                }
            }
        }
    }

    private func stopXPC() {
        log.info("stopXPC")
        (xpc?.remoteObjectProxy as? SlapHelperProtocol)?.stop()
        xpc?.invalidate()
        xpc = nil
        if sensorRecording {
            stopSensorRecording()
        }
        resetLiveSensor()
    }

    private func helperProxy() -> SlapHelperProtocol? {
        xpc?.remoteObjectProxyWithErrorHandler { _ in } as? SlapHelperProtocol
    }

    // MARK: - SlapClientProtocol

    nonisolated func slapDetected(peakG: Double, staLtaRatio: Double, timestamp: UInt64) {
        Task { @MainActor in
            slapCount += 1
            UserDefaults.standard.set(slapCount, forKey: "slapCount")
            lastEvent = String(format: "Slap #%d  peak=%.2fg  ratio=%.1f", slapCount, peakG, staLtaRatio)
            log.info(lastEvent)
            playReaction(peakG: peakG)
        }
    }

    nonisolated func helperStatus(running: Bool, message: String) {
        Task { @MainActor in
            self.running = running
            self.helperStatusText = message
            self.sensorSource = running ? "Helper" : "Unavailable"
            if !running {
                if self.sensorRecording {
                    self.stopSensorRecording()
                }
                self.resetLiveSensor()
            }
        }
    }

    nonisolated func sensorSample(x: Double, y: Double, z: Double, magnitude: Double, timestamp: UInt64) {
        Task { @MainActor in
            self.handleSensorSample(x: x, y: y, z: z, magnitude: magnitude, timestamp: timestamp)
        }
    }

    // MARK: - Audio — reactions

    private func playReaction(peakG: Double) {
        guard let url = pickReactionURL() else {
            log.warn("no reaction audio file in bundle")
            return
        }
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.volume = Float(min(1.0, max(0.2, (peakG - 1.0) / 3.0)))
            p.play()
            reactionPlayer = p
            log.debug("play reaction \(url.lastPathComponent) vol=\(p.volume)")
        } catch {
            log.error("reaction play failed: \(error)")
        }
    }

    private func pickReactionURL() -> URL? {
        guard let base = Bundle.main.resourceURL?.appendingPathComponent("Sounds/Reactions") else {
            return nil
        }
        let items = (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? []
        return items.filter { Self.audioExts.contains($0.pathExtension.lowercased()) }.randomElement()
    }

    // MARK: - Rage Quit

    func rageQuit() {
        log.info("RAGE QUIT triggered")
        startRelax(looped: true)
        lockScreen()
    }

    func previewRelax() {
        log.info("preview relax")
        startRelax(looped: false)
    }

    private func startRelax(looped: Bool) {
        guard let url = relaxURL() else {
            log.warn("no relax track available")
            return
        }
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.numberOfLoops = looped ? -1 : 0
            p.volume = 0.6
            p.play()
            relaxPlayer = p
            log.info("relax playing: \(url.lastPathComponent) looped=\(looped)")
        } catch {
            log.error("relax play failed: \(error)")
        }
    }

    private func relaxURL() -> URL? {
        if let data = relaxBookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data,
                                  options: .withSecurityScope,
                                  bookmarkDataIsStale: &stale),
               url.startAccessingSecurityScopedResource() {
                return url
            }
        }
        // Search bundle for any audio file in Sounds/Relax
        if let base = Bundle.main.resourceURL?.appendingPathComponent("Sounds/Relax"),
           let items = try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) {
            return items.first { Self.audioExts.contains($0.pathExtension.lowercased()) }
        }
        return nil
    }

    private func lockScreen() {
        // Try known lock-screen paths in order; newer macOS removed the old CGSession helper.
        let candidates: [(String, [String])] = [
            ("/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession", ["-suspend"]),
            ("/System/Library/CoreServices/RemoteManagement/AppleVNCServer.bundle/Contents/Support/LockScreen.app/Contents/MacOS/LockScreen", []),
            ("/usr/bin/pmset", ["displaysleepnow"]),
        ]
        for (path, args) in candidates where FileManager.default.isExecutableFile(atPath: path) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            do { try p.run(); log.info("lockScreen via \(path)"); return }
            catch { log.warn("lockScreen candidate \(path) failed: \(error)") }
        }
        log.error("no working lockScreen path on this system")
    }

    func pickRelaxTrack() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] resp in
            guard resp == .OK, let url = panel.url else { return }
            if let data = try? url.bookmarkData(options: .withSecurityScope) {
                UserDefaults.standard.set(data, forKey: "relaxBookmark")
                self?.relaxBookmark = data
                self?.relaxTrackName = url.lastPathComponent
                self?.log.info("relax track set to \(url.lastPathComponent)")
            }
        }
    }

    private func loadRelaxTrackName() {
        if relaxBookmark != nil {
            relaxTrackName = "User-selected track"
        } else if let base = Bundle.main.resourceURL?.appendingPathComponent("Sounds/Relax"),
                  let items = try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil),
                  let first = items.first(where: { Self.audioExts.contains($0.pathExtension.lowercased()) }) {
            relaxTrackName = "Bundled: \(first.lastPathComponent)"
        } else {
            relaxTrackName = "(none)"
        }
    }

    // MARK: - Log helpers

    func openLogFile() {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/FreeSlapMac/app.log")
        NSWorkspace.shared.open(url)
    }

    func openLogFolder() {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/FreeSlapMac")
        NSWorkspace.shared.open(url)
    }

    func toggleSensorRecording() {
        if sensorRecording {
            stopSensorRecording()
        } else {
            startSensorRecording()
        }
    }

    func refreshDetectedSensors() {
        detectedSensors = MotionInventory.scan()
    }

    // MARK: - Live sensor

    private func handleSensorSample(x: Double, y: Double, z: Double, magnitude: Double, timestamp: UInt64) {
        liveSensorX = x
        liveSensorY = y
        liveSensorZ = z
        liveSensorMagnitude = magnitude
        liveSensorSampleCount += 1

        let now = Date()
        if liveSensorStartedAt == nil {
            liveSensorStartedAt = now
        }
        if let startedAt = liveSensorStartedAt {
            let elapsed = now.timeIntervalSince(startedAt)
            if elapsed > 0 {
                liveSensorSampleRateHz = Double(liveSensorSampleCount) / elapsed
            }
        }

        liveSensorHistory.append(LiveSensorPoint(timestamp: now, magnitude: magnitude))
        if liveSensorHistory.count > 180 {
            liveSensorHistory.removeFirst(liveSensorHistory.count - 180)
        }

        if sensorRecording {
            appendSensorRecording(x: x, y: y, z: z, magnitude: magnitude, timestamp: timestamp)
        }
    }

    private func resetLiveSensor() {
        liveSensorX = 0
        liveSensorY = 0
        liveSensorZ = 0
        liveSensorMagnitude = 0
        liveSensorSampleCount = 0
        liveSensorSampleRateHz = 0
        liveSensorHistory.removeAll()
        liveSensorStartedAt = nil
        sensorSource = running ? sensorSource : "Inactive"
    }

    private func startLocalSensor() throws {
        guard localSensor == nil else { return }

        var cfg = localDetector.config
        cfg.staLtaTriggerRatio = max(1.2, min(sensitivity, 20.0))
        cfg.cooldownMs = max(50, min(cooldownMs, 10_000))
        localDetector.updateConfig(cfg)

        let sensor = HIDSensor(log: FSLog(component: "app", category: "local-hid")) { [weak self] x, y, z, ts in
            guard let self else { return }
            Task { @MainActor in
                let mag = (x * x + y * y + z * z).squareRoot()
                self.handleSensorSample(x: x, y: y, z: z, magnitude: mag, timestamp: ts)
                if let hit = self.localDetector.push(magnitudeG: mag, timestampNs: ts) {
                    self.slapDetected(peakG: hit.peakG, staLtaRatio: hit.staLtaRatio, timestamp: hit.timestampNs)
                }
            }
        }
        try sensor.start()
        localSensor = sensor
    }

    private func stopLocalSensor() {
        localSensor?.stop()
        localSensor = nil
    }

    private func startSensorRecording() {
        let logsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/FreeSlapMac")
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        let stamp = String(Int(Date().timeIntervalSince1970))
        let url = logsDir.appendingPathComponent("sensor-capture-\(stamp).csv")
        let header = "timestamp_ns,x_g,y_g,z_g,magnitude_g\n"

        FileManager.default.createFile(atPath: url.path, contents: header.data(using: .utf8))
        do {
            let handle = try FileHandle(forWritingTo: url)
            _ = try? handle.seekToEnd()
            recordingFileHandle = handle
            recordingFileURL = url
            sensorRecording = true
            sensorRecordingStatus = "Recording to \(url.lastPathComponent)"
            log.info("sensor recording started at \(url.path)")
        } catch {
            sensorRecording = false
            sensorRecordingStatus = "Recording failed: \(error.localizedDescription)"
            log.error("sensor recording failed to start: \(error)")
        }
    }

    private func stopSensorRecording() {
        recordingFileHandle?.closeFile()
        recordingFileHandle = nil
        sensorRecording = false
        if let url = recordingFileURL {
            sensorRecordingStatus = "Saved \(url.lastPathComponent)"
            log.info("sensor recording saved to \(url.path)")
        } else {
            sensorRecordingStatus = "Not recording"
        }
        recordingFileURL = nil
    }

    private func appendSensorRecording(x: Double, y: Double, z: Double, magnitude: Double, timestamp: UInt64) {
        guard let handle = recordingFileHandle else { return }
        let line = String(format: "%llu,%.6f,%.6f,%.6f,%.6f\n", timestamp, x, y, z, magnitude)
        if let data = line.data(using: .utf8) {
            try? handle.write(contentsOf: data)
        }
    }

    // MARK: - Unlock observer

    private func observeUnlock() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.log.info("screen unlocked; stopping relax")
                self?.relaxPlayer?.stop()
                self?.relaxPlayer = nil
            }
        }
    }
}

private extension Double {
    func nonZeroOr(_ fallback: Double) -> Double { self == 0 ? fallback : self }
}
private extension Int {
    func nonZeroOr(_ fallback: Int) -> Int { self == 0 ? fallback : self }
}
