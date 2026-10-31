import Foundation

/// coax のサブコマンド（`coax tune --ch N --stats`、`coax scan` など）やデコーダーを子プロセスとして動かす。
/// stdout は fd として返し（tune なら TS を mpv に渡す）、stderr は 1 行ずつ通知する。
final class CoaxProcess {
    private let process = Process()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private var pending = Data()

    /// stderr の 1 行（stats や進捗の行など）。メインスレッドで呼ぶ
    var onLine: ((String) -> Void)?
    /// プロセス終了。メインスレッドで呼ぶ
    var onExit: ((Int32) -> Void)?

    /// input を渡すと stdin にする（デコーダーに coax tune の出力をつなぐ）。fd の所有権はここに移る。
    /// outputLines なら stdout も stderr と同じく 1 行ずつ通知する（coax pcsc は準備できたことを stdout に書く）
    init(executable: URL, arguments: [String], input: Int32? = nil, environment: [String: String] = [:],
         outputLines: Bool = false) {
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = outputLines ? stderrPipe : stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = input.map { FileHandle(fileDescriptor: $0, closeOnDealloc: true) } ?? FileHandle.nullDevice
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        }
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
        // stdin に渡した fd も子に任せる。親が持っていると、子が終わっても前段に書き込みエラーが届かない
        if let input = process.standardInput as? FileHandle, input !== FileHandle.nullDevice { try? input.close() }
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
        // デコーダーの進み具合のように \r で上書きする行もあるので、\r も行の区切りにする
        while let nl = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let line = String(decoding: pending[pending.startIndex..<nl], as: UTF8.self)
            pending.removeSubrange(pending.startIndex...nl)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { onLine?(trimmed) }
        }
    }
}
