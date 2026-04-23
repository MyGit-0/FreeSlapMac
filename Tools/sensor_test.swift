// Live sensor test — confirms IMU samples arrive and prints a short summary.
// Build:
//   swiftc -framework IOKit -framework Foundation -framework OSLog \
//     Shared/Logging.swift Helper/HIDSensor.swift Tools/sensor_test.swift -o build/sensor_test
// Run:
//   ./build/sensor_test         # default 5 seconds
//   ./build/sensor_test 10      # custom duration
import Foundation
import IOKit
import IOKit.hid

@main struct SensorTest {
    static func main() throws {
        let durationSec = CommandLine.arguments.dropFirst().first.flatMap(Double.init) ?? 5.0
        var count = 0
        var maxMag = 0.0
        var minMag = Double.greatestFiniteMagnitude
        let sensor = HIDSensor(log: FSLog(component: "sensor-test", category: "tool")) { x, y, z, _ in
            let mag = (x*x + y*y + z*z).squareRoot()
            maxMag = max(maxMag, mag)
            minMag = min(minMag, mag)
            count += 1
            if count <= 5 || count % 50 == 0 || mag > 2.0 {
                let flag = mag > 2.0 ? " *** IMPACT ***" : ""
                print(String(format: "  [%5d]  x=%+.3f  y=%+.3f  z=%+.3f  |a|=%.3fg%@", count, x, y, z, mag, flag))
                fflush(stdout)
            }
        }
        try sensor.start()
        print(String(format: "Sensor started. Sampling for %.1f seconds.\n", durationSec))
        RunLoop.main.run(until: Date().addingTimeInterval(durationSec))
        sensor.stop()

        if count == 0 {
            print("ERROR: no samples received")
            Foundation.exit(2)
        }

        print(String(format: "\nSummary: %d samples, |a| range %.3fg ... %.3fg", count, minMag, maxMag))
    }
}
