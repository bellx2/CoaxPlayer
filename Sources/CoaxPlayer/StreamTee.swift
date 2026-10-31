import Foundation

/// coax tune の出力（TS）を mpv へ中継し、録画中は同じバイト列をファイルにも書く。
/// 受信したままの TS を残すので、番組情報や字幕などのデータも落ちない。
/// 字幕はアプリで描くので、ここで取り出す。
final class StreamTee {
    /// mpv に渡す読み口（fdclose:// で渡し、mpv が閉じる）
    let mpvFD: Int32
    private let source: Int32
    private let sink: Int32
    private let lock = NSLock()
    private var file: FileHandle?
    /// 字幕の PES を取り出す。中継のスレッドで読ませる
    let captions = CaptionExtractor()

    /// 読み終えたとき（coax が終わったとき）に呼ぶ。メインスレッドで呼ぶ
    var onEnd: (() -> Void)?

    /// source は coax の標準出力。所有権はこのオブジェクトに移る
    init?(source: Int32) {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return nil }
        self.source = source
        mpvFD = fds[0]
        sink = fds[1]
        // mpv が先に閉じても SIGPIPE でアプリごと落ちないようにする
        _ = fcntl(sink, F_SETNOSIGPIPE, 1)
    }

    func start() {
        let thread = Thread { [self] in run() }
        thread.name = "coax.tee"
        thread.start()
    }

    /// 録画を始める。ファイルは新しく作る
    func startRecording(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        let handle = try FileHandle(forWritingTo: url)
        lock.withLock { file = handle }
    }

    func stopRecording() {
        let handle = lock.withLock {
            defer { file = nil }
            return file
        }
        try? handle?.close()
    }

    private func run() {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var mpvOpen = true
        while true {
            let count = buffer.withUnsafeMutableBytes { read(source, $0.baseAddress, $0.count) }
            if count <= 0 { break }
            captions.feed(buffer[0..<count])
            // mpv が閉じたあとも、録画のために読み続ける
            if mpvOpen {
                mpvOpen = buffer.withUnsafeBytes { writeAll(sink, $0.baseAddress!, count) }
            }
            lock.withLock {
                try? file?.write(contentsOf: buffer[0..<count])
            }
        }
        close(source)
        close(sink)
        stopRecording()
        DispatchQueue.main.async { [weak self] in self?.onEnd?() }
    }

    /// 全部書けたら true。読み手が閉じていたら false
    private func writeAll(_ fd: Int32, _ data: UnsafeRawPointer, _ count: Int) -> Bool {
        var written = 0
        while written < count {
            let n = write(fd, data + written, count - written)
            if n < 0 {
                if errno == EINTR { continue }
                return false
            }
            written += n
        }
        return true
    }
}
