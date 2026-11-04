import Foundation

/// 選局の速さを測るための印。`--debug` のときだけ、選局を始めてからの経過を stderr へ出す
enum Trace {
    nonisolated(unsafe) static var enabled = false
    private static let lock = NSLock()
    nonisolated(unsafe) private static var origin: TimeInterval = 0

    /// 選局を始めた時刻を起点にする
    static func begin(_ what: String) {
        guard enabled else { return }
        lock.withLock { origin = ProcessInfo.processInfo.systemUptime }
        write("0.000 \(what)")
    }

    static func mark(_ what: String) {
        guard enabled else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - lock.withLock { origin }
        write(String(format: "%.3f ", elapsed) + what)
    }

    private static func write(_ line: String) {
        FileHandle.standardError.write(Data("trace: \(line)\n".utf8))
    }
}
