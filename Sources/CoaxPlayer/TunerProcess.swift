import Foundation

/// `coax tune --ch N --stats` を子プロセスとして動かす。
/// stdout（TS）は mpv に渡す fd として返し、stderr は 1 行ずつ通知する。
final class TunerProcess {
    private let process = Process()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private var pending = Data()

    /// stderr の 1 行（stats 行など）。メインスレッドで呼ぶ
    var onLine: ((String) -> Void)?
    /// プロセス終了。メインスレッドで呼ぶ
    var onExit: ((Int32) -> Void)?

    init(executable: URL, arguments: [String]) {
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice
    }

    var pid: Int32 { process.processIdentifier }

    /// 起動して、TS を読める fd を返す。返した fd の所有権は呼び出し側（mpv の fdclose://）に移る
    func start() throws -> Int32 {
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            // EOF では空データで呼ばれ続けるので外す
            if data.isEmpty { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async { self?.consume(data) }
        }
        process.terminationHandler = { [weak self] p in
            let status = p.terminationStatus
            DispatchQueue.main.async { self?.onExit?(status) }
        }
        try process.run()
        // 書き込み側を親で閉じておかないと、子が終わっても mpv に EOF が届かない
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()
        let fd = dup(stdoutPipe.fileHandleForReading.fileDescriptor)
        try? stdoutPipe.fileHandleForReading.close()
        return fd
    }

    /// SIGTERM で止め、timeout 秒で終わらなければ SIGKILL する。終了まで待つ
    func stop(timeout: TimeInterval = 3) {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            usleep(20_000)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
        stderrPipe.fileHandleForReading.readabilityHandler = nil
    }

    private func consume(_ data: Data) {
        pending.append(data)
        while let nl = pending.firstIndex(of: 0x0A) {
            let line = String(decoding: pending[pending.startIndex..<nl], as: UTF8.self)
            pending.removeSubrange(pending.startIndex...nl)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { onLine?(trimmed) }
        }
    }
}
