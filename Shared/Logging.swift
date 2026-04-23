import Foundation
import OSLog

/// Unified logger for FreeSlapMac.
/// Writes to:
///   1. Apple unified logging (subsystem `com.freeslapmac.<component>`)
///      View with:
///        log stream --predicate 'subsystem BEGINSWITH "com.freeslapmac"'
///        log show   --predicate 'subsystem BEGINSWITH "com.freeslapmac"' --last 10m
///   2. A plaintext file at ~/Library/Logs/FreeSlapMac/<component>.log
///      (helper writes to /var/log/FreeSlapMac/helper.log since it runs as root)
public struct FSLog {
    public let subsystem: String
    public let category: String
    private let osLog: Logger
    private let fileHandle: FileHandle?
    private let formatter: DateFormatter

    public init(component: String, category: String = "general") {
        let subsys = "com.freeslapmac.\(component)"
        self.subsystem = subsys
        self.category = category
        self.osLog = Logger(subsystem: subsys, category: category)

        let fm = FileManager.default
        let baseDir: URL
        if geteuid() == 0 {
            baseDir = URL(fileURLWithPath: "/var/log/FreeSlapMac")
        } else {
            baseDir = fm.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/FreeSlapMac")
        }
        try? fm.createDirectory(at: baseDir, withIntermediateDirectories: true)
        let fileURL = baseDir.appendingPathComponent("\(component).log")
        if !fm.fileExists(atPath: fileURL.path) {
            fm.createFile(atPath: fileURL.path, contents: nil)
        }
        self.fileHandle = try? FileHandle(forWritingTo: fileURL)
        _ = try? fileHandle?.seekToEnd()

        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        self.formatter = f

        log(level: "INFO", "—— FSLog started subsystem=\(subsys) category=\(category) pid=\(getpid()) ——")
    }

    public func info(_ msg: String)  { log(level: "INFO",  msg); osLog.info("\(msg, privacy: .public)") }
    public func warn(_ msg: String)  { log(level: "WARN",  msg); osLog.warning("\(msg, privacy: .public)") }
    public func error(_ msg: String) { log(level: "ERROR", msg); osLog.error("\(msg, privacy: .public)") }
    public func debug(_ msg: String) { log(level: "DEBUG", msg); osLog.debug("\(msg, privacy: .public)") }

    private func log(level: String, _ msg: String) {
        let line = "\(formatter.string(from: Date())) [\(level)] [\(category)] \(msg)\n"
        if let data = line.data(using: .utf8) {
            try? fileHandle?.write(contentsOf: data)
        }
    }
}
