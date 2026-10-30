import AppKit

/// 起動引数。
///   CoaxPlayer [--coax <path>] [--ch <n>] [--debug] [<ts file>]
struct Config {
    var coaxPath: String?
    var channel: String?
    var file: String?
    var debug = false

    static func parse(_ args: [String]) -> Config {
        var c = Config()
        var it = args.dropFirst().makeIterator()
        while let a = it.next() {
            switch a {
            case "--coax": c.coaxPath = it.next()
            case "--ch": c.channel = it.next()
            case "--debug": c.debug = true
            default:
                // AppKit が付ける -NSxxx などは無視する
                if !a.hasPrefix("-") { c.file = a }
            }
        }
        return c
    }
}

@MainActor
final class PlayerModel: ObservableObject {
    @Published var channel = "27"
    @Published var stats = ""
    @Published var status = "停止中"
    @Published var playing = false

    let config: Config
    let player: MPVPlayer
    private var tuner: TunerProcess?
    private var debugTimer: Timer?

    init(config: Config) {
        self.config = config
        player = MPVPlayer(debug: config.debug)
        player.onEndFile = { [weak self] reason in
            guard let self, reason != "停止" else { return }
            self.status = reason
        }
        if config.debug { startDebugLog() }
    }

    /// 起動引数でファイルかチャンネルが渡されていれば再生を始める
    func startFromArguments() {
        if let ch = config.channel {
            channel = ch
            playChannel()
            return
        }
        guard let file = config.file else { return }
        status = "ファイル再生: \((file as NSString).lastPathComponent)"
        playing = true
        player.load(file)
    }

    func playChannel() {
        let ch = channel.trimmingCharacters(in: .whitespaces)
        guard !ch.isEmpty else { return }
        stop()

        // --coax 未指定なら、.app に同梱した coax（実行ファイルと同じ場所）を使い、
        // それも無ければ PATH 上の coax を env 経由で起動する（env は exec するので pid は coax のもの）
        let exe: URL
        var args = ["tune", "--ch", ch, "--stats"]
        let bundled = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("coax")
        if let path = config.coaxPath {
            exe = URL(fileURLWithPath: path)
        } else if let bundled, FileManager.default.isExecutableFile(atPath: bundled.path) {
            exe = bundled
        } else {
            exe = URL(fileURLWithPath: "/usr/bin/env")
            args.insert("coax", at: 0)
        }

        let t = TunerProcess(executable: exe, arguments: args)
        t.onLine = { [weak self] line in
            guard let self else { return }
            self.stats = line
            if self.config.debug { FileHandle.standardError.write(Data("stats: \(line)\n".utf8)) }
        }
        t.onExit = { [weak self, weak t] code in
            guard let self, let t, self.tuner === t else { return }
            self.tuner = nil
            self.playing = false
            self.status = "coax 終了 (status \(code))"
        }
        do {
            let fd = try t.start()
            tuner = t
            playing = true
            stats = ""
            status = "ch \(ch) 再生中"
            // fdclose:// は mpv が読み終えたら fd を閉じる
            player.load("fdclose://\(fd)")
        } catch {
            status = "起動失敗: \(error.localizedDescription)"
        }
    }

    func stop() {
        // 先に子プロセスを止めてチューナーを解放する
        tuner?.stop()
        tuner = nil
        player.stop()
        playing = false
        status = "停止中"
    }

    /// アプリ終了時の後始末
    func shutdown() {
        debugTimer?.invalidate()
        tuner?.stop()
        tuner = nil
        player.destroy()
    }

    /// 描画できているかを客観的に確かめるため、1 秒ごとに mpv の状態を stderr へ出す
    private func startDebugLog() {
        debugTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let p = self.player
                let pos = p.doubleProperty("time-pos").map { String(format: "%.2f", $0) } ?? "-"
                let fps = p.doubleProperty("estimated-vf-fps").map { String(format: "%.2f", $0) } ?? "-"
                let w = p.int64Property("dwidth") ?? 0, h = p.int64Property("dheight") ?? 0
                let line = "debug: time-pos=\(pos) estimated-vf-fps=\(fps) size=\(w)x\(h) rendered=\(p.renderedFrames) luma=\(p.lastLuma) layer=\(Int(p.layer.bounds.width))x\(Int(p.layer.bounds.height)) contents=\(p.layer.contents != nil) windows=\(NSApp.windows.filter(\.isVisible).count) tuner-pid=\(self.tuner?.pid ?? 0)\n"
                FileHandle.standardError.write(Data(line.utf8))
            }
        }
    }
}
