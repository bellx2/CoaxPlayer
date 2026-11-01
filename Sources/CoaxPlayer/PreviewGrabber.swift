import AppKit

/// 一覧のプレビュー。番組情報を取るときの TS からワンセグの番組だけを抜き出して ffmpeg に渡し、映像の 1 コマを小さな JPEG にする。
/// フルセグはスクランブルがかかっていて取り出せないのでワンセグを使う。ほかの番組も渡すと、ffmpeg が
/// それらを調べ終えるまで待つので、PAT と、ワンセグの PMT・映像だけを渡す。feed は TS を読むスレッドから呼ぶ
final class PreviewGrabber: @unchecked Sendable {
    static let width = 320
    static let height = 180

    /// 取れた JPEG（取れなければ nil）。ffmpeg の出力を読むスレッドで 1 回だけ呼ぶ
    var onDone: ((Data?) -> Void)?

    private let serviceID: Int
    private let process: Process
    private let sink: Int32

    // 以下は feed のスレッドでのみ触る
    private var pending: [UInt8] = []
    private var pmtPID: Int?
    private var videoPID: Int?
    private var closed = false

    /// ffmpeg を起動する。起動できなければ nil
    init?(serviceID: Int, ffmpeg: Process) {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return nil }
        // ffmpeg が 1 コマで先に終わっても、SIGPIPE でアプリごと落ちないようにする
        _ = fcntl(fds[1], F_SETNOSIGPIPE, 1)
        self.serviceID = serviceID
        process = ffmpeg
        sink = fds[1]
        let output = Pipe()
        process.arguments = (process.arguments ?? []) + [
            "-hide_banner", "-loglevel", "error",
            // ワンセグの映像だけなので、調べる量を小さくして早く始める
            "-analyzeduration", "200000", "-probesize", "32768",
            "-f", "mpegts", "-i", "pipe:0", "-map", "0:v:0", "-frames:v", "1",
            "-vf", "scale=\(Self.width):\(Self.height)", "-pix_fmt", "rgb24", "-f", "rawvideo", "pipe:1",
        ]
        process.standardInput = FileHandle(fileDescriptor: fds[0], closeOnDealloc: true)
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            close(fds[0])
            close(fds[1])
            return nil
        }
        // 読み口は ffmpeg に任せる。親が持っていると、ffmpeg が終わっても書き込みエラーにならない
        try? (process.standardInput as? FileHandle)?.close()
        DispatchQueue.global().async { [self] in
            let data = output.fileHandleForReading.readDataToEndOfFile()
            onDone?(data.count == Self.width * Self.height * 3 ? Self.jpeg(data) : nil)
        }
    }

    func feed(_ data: ArraySlice<UInt8>) {
        guard !closed else { return }
        let bytes = pending + data
        var out: [UInt8] = []
        var i = 0
        while i + 188 <= bytes.count {
            guard bytes[i] == 0x47 else {
                i += 1
                continue
            }
            let packet = bytes[i..<i + 188]
            if keep(packet) { out += packet }
            i += 188
        }
        pending = Array(bytes[i...])
        guard !out.isEmpty else { return }
        let written = out.withUnsafeBytes { write(sink, $0.baseAddress, $0.count) }
        // ffmpeg が 1 コマ書いて終わったら、それ以上は渡さない
        if written < 0 { finish() }
    }

    /// 入力を閉じる（ffmpeg はそこで終わる）。止めるときは stop を使う
    func finish() {
        guard !closed else { return }
        closed = true
        close(sink)
    }

    /// まだ動いていれば止める。メインスレッドから呼ぶ
    func stop() {
        if process.isRunning { process.terminate() }
    }

    /// PAT、ワンセグの PMT、ワンセグの映像の TS パケットだけを残す。PMT と映像の PID はここで読む
    private func keep(_ p: ArraySlice<UInt8>) -> Bool {
        let base = p.startIndex
        let pid = Int(p[base + 1] & 0x1f) << 8 | Int(p[base + 2])
        let start = p[base + 1] & 0x40 != 0
        if pid == 0 {
            if pmtPID == nil, start, let section = Self.section(p) {
                // PAT: 番組番号と PMT の PID の組が 4 バイトずつ並ぶ
                var j = 8
                while j + 4 <= section.count - 4 {
                    if Int(section[j]) << 8 | Int(section[j + 1]) == serviceID {
                        pmtPID = Int(section[j + 2] & 0x1f) << 8 | Int(section[j + 3])
                    }
                    j += 4
                }
            }
            return true
        }
        if pid == pmtPID {
            if videoPID == nil, start, let section = Self.section(p), section.count > 12 {
                // PMT: 番組の記述子のあとに、ストリームの種類と PID が並ぶ。H.264（0x1B）を探す
                var j = 12 + (Int(section[10] & 0x0f) << 8 | Int(section[11]))
                while j + 5 <= section.count - 4 {
                    let length = Int(section[j + 3] & 0x0f) << 8 | Int(section[j + 4])
                    if section[j] == 0x1b {
                        videoPID = Int(section[j + 1] & 0x1f) << 8 | Int(section[j + 2])
                        break
                    }
                    j += 5 + length
                }
            }
            return true
        }
        return pid == videoPID
    }

    /// 1 パケットに収まるセクションを取り出す（PAT とワンセグの PMT は収まる）
    private static func section(_ p: ArraySlice<UInt8>) -> [UInt8]? {
        let base = p.startIndex
        var offset = base + 4
        if p[base + 3] & 0x20 != 0 { offset += 1 + Int(p[base + 4]) }
        guard offset < p.endIndex else { return nil }
        offset += 1 + Int(p[offset])  // pointer_field
        guard offset + 3 <= p.endIndex else { return nil }
        let length = 3 + (Int(p[offset + 1] & 0x0f) << 8 | Int(p[offset + 2]))
        guard offset + length <= p.endIndex else { return nil }
        return Array(p[offset..<offset + length])
    }

    private static func jpeg(_ rgb: Data) -> Data? {
        guard let provider = CGDataProvider(data: rgb as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 24,
                                  bytesPerRow: width * 3, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }
}
