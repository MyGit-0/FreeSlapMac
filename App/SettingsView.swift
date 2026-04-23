import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @ObservedObject var engine: SlapEngine
    @AppStorage("launchAtLogin") private var launchAtLogin = false

    var body: some View {
        Form {
            helperSection
            sensorSection
            detectionSection
            rageQuitSection
            debugSection
            generalSection
        }
        .formStyle(.grouped)
        .padding()
    }

    private var helperSection: some View {
        Section("Helper & Permissions") {
            HStack {
                Circle().fill(engine.helperInstalled ? .green : .orange).frame(width: 8, height: 8)
                Text(engine.helperStatusText)
                Spacer()
                Button(engine.helperInstalled ? "Reinstall" : "Install Helper") {
                    engine.installHelper()
                }
                Button("Open Login Items") { engine.openHelperApprovalSettings() }
                Button("Remove Helper") { engine.uninstallHelper() }
                    .disabled(!engine.helperInstalled)
                Button("Refresh") { engine.refreshHelperStatus() }
            }

            Text("FreeSlapMac now prefers direct HID access to the motion sensors on Apple Silicon, so detection can still work even if the helper is blocked. There is no separate sensor privacy prompt on macOS for this path. The Login Items approval only matters for the optional helper.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var sensorSection: some View {
        Section("Live Sensor") {
            HStack {
                MetricChip(label: "X", value: engine.liveSensorX, color: .blue)
                MetricChip(label: "Y", value: engine.liveSensorY, color: .green)
                MetricChip(label: "Z", value: engine.liveSensorZ, color: .orange)
                MetricChip(label: "|a|", value: engine.liveSensorMagnitude, color: .red)
            }

            HStack {
                Text("Samples: \(engine.liveSensorSampleCount)")
                Spacer()
                Text("Source: \(engine.sensorSource)")
                Spacer()
                Text(String(format: "UI rate: %.1f Hz", engine.liveSensorSampleRateHz))
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            SensorTraceView(points: engine.liveSensorHistory)
                .frame(height: 120)

            HStack {
                Text(engine.sensorRecordingStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Refresh Sensors") { engine.refreshDetectedSensors() }
                Button(engine.sensorRecording ? "Stop Recording" : "Record Sensor CSV") {
                    engine.toggleSensorRecording()
                }
                .disabled(!engine.running)
            }

            if engine.detectedSensors.isEmpty {
                Text("No motion-class HID sensors were detected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(engine.detectedSensors) { sensor in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(sensor.kind)
                        Text(String(
                            format: "transport=%@ vid=0x%04X pid=0x%04X page=0x%04X usage=0x%04X report=%d",
                            sensor.transport, sensor.vendorID, sensor.productID, sensor.usagePage, sensor.usage, sensor.maxInputReportSize
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var detectionSection: some View {
        Section("Detection") {
            VStack(alignment: .leading) {
                Text("Sensitivity (STA/LTA trigger): \(engine.sensitivity, specifier: "%.1f")")
                Slider(value: $engine.sensitivity, in: 1.5...10.0, step: 0.1)
                    .onChange(of: engine.sensitivity) { _, v in engine.pushSensitivity(v) }
                Text("Lower = more sensitive. 3.0 is a good start.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading) {
                Text("Cooldown: \(engine.cooldownMs) ms")
                Slider(value: .init(
                    get: { Double(engine.cooldownMs) },
                    set: { engine.cooldownMs = Int($0); engine.pushCooldown($0) }
                ), in: 100...3000, step: 50)
            }

            HStack {
                Text("Last event: \(engine.lastEvent)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    private var rageQuitSection: some View {
        Section("Rage Quit") {
            HStack {
                Text(engine.relaxTrackName)
                Spacer()
                Button("Choose Song…") { engine.pickRelaxTrack() }
            }
            Button("Test Rage Quit (no lock)") { engine.previewRelax() }
        }
    }

    private var debugSection: some View {
        Section("Debug") {
            HStack {
                Text("Logs at ~/Library/Logs/FreeSlapMac/")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Open app.log") { engine.openLogFile() }
                Button("Reveal folder") { engine.openLogFolder() }
            }
            Text("Helper (root) logs at /var/log/FreeSlapMac/helper.log")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var generalSection: some View {
        Section("General") {
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, v in
                    do {
                        if v { try SMAppService.mainApp.register() }
                        else { try SMAppService.mainApp.unregister() }
                    } catch {
                        NSLog("Login item toggle failed: \(error)")
                    }
                }
        }
    }
}

private struct MetricChip: View {
    let label: String
    let value: Double
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(String(format: "%+.3fg", value))
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct SensorTraceView: View {
    let points: [SlapEngine.LiveSensorPoint]

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.secondary.opacity(0.08))

                if points.isEmpty {
                    Text("Start detection to see live motion samples")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Path { path in
                        let minValue = points.map(\.magnitude).min() ?? 0.95
                        let maxValue = points.map(\.magnitude).max() ?? 1.05
                        let low = min(minValue, 0.95)
                        let high = max(maxValue, 1.05)
                        let span = max(high - low, 0.01)

                        for (index, point) in points.enumerated() {
                            let x = proxy.size.width * CGFloat(index) / CGFloat(max(points.count - 1, 1))
                            let normalized = (point.magnitude - low) / span
                            let y = proxy.size.height * (1 - CGFloat(normalized))
                            if index == 0 {
                                path.move(to: CGPoint(x: x, y: y))
                            } else {
                                path.addLine(to: CGPoint(x: x, y: y))
                            }
                        }
                    }
                    .stroke(Color.accentColor, lineWidth: 2)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 8)
                }
            }
        }
    }
}
