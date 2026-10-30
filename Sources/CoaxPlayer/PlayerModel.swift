import AppKit

/// 起動引数。
///   CoaxPlayer [--coax <path>] [--scan <path>] [--ch <n>] [--debug] [<ts file>]
struct Config {
    var coaxPath: String?
    var scanPath = ScanFile.defaultPath
    var channel: String?
    var file: String?
    var debug = false

    static func parse(_ args: [String]) -> Config {
        var c = Config()
        var it = args.dropFirst().makeIterator()
        while let a = it.next() {
            switch a {
            case "--coax": c.coaxPath = it.next()
            case "--scan": c.scanPath = it.next() ?? c.scanPath
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
    @Published private(set) var channels: [Channel] = []
    /// 再生中のチャンネル（"27 ＮＨＫ総合１・東京"）かファイル名
    @Published private(set) var playing: String?
    /// 再生中のチャンネル名。一覧で強調する
    @Published private(set) var playingChannel: String?
    /// `--stats` やスキャンの進捗の最新の行。止まっているときやエラーのときはその旨
    @Published private(set) var status = "停止中"
    /// 今の番組と次の番組（`--program` の行の「開始-終了 番組名」）
    @Published private(set) var nowProgram: String?
    @Published private(set) var nextProgram: String?
    /// スキャンする範囲。ScanRange.all と同じ並び
    @Published var ranges = [true, false, false]
    @Published private(set) var scanning = false
    /// この Mac と OS で高精細化が使えるか。使えなければボタンを出さない
    let enhanceAvailable = enhancerAvailable()
    /// 高精細化（ノイズ除去と超解像）。次の起動にも引き継ぐ
    @Published var enhance: Bool {
        didSet {
            UserDefaults.standard.set(enhance, forKey: "enhance")
            player.setEnhance(enhance && enhanceAvailable)
        }
    }

    let config: Config
    let player: MPVPlayer
    private var tuner: CoaxProcess?
    private var scanner: CoaxProcess?
    private var debugTimer: Timer?

    init(config: Config) {
        self.config = config
        player = MPVPlayer(debug: config.debug)
        enhance = UserDefaults.standard.object(forKey: "enhance") as? Bool ?? true
        player.setEnhance(enhance && enhanceAvailable)
        channels = (try? ScanFile.load(config.scanPath)) ?? []
        if channels.isEmpty {
            status = "チャンネル一覧がありません。範囲を選んでスキャンしてください"
        }
        if config.debug { startDebugLog() }
    }

    /// 起動引数でファイルかチャンネルが渡されていれば再生を始める
    func startFromArguments() {
        if let file = config.file {
            playFile(file)
        } else if let ch = config.channel {
            if let channel = channels.first(where: { $0.channel == ch }) {
                play(channel)
            } else {
                status = "\(ch) は scan.json にありません"
            }
        }
    }

    /// coax を起動するコマンド。--coax 未指定なら、.app に同梱した coax（実行ファイルと同じ場所）を使い、
    /// それも無ければ PATH 上の coax を env 経由で起動する（env は exec するので pid は coax のもの）
    private func coax(_ arguments: [String]) -> CoaxProcess {
        let bundled = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("coax")
        if let path = config.coaxPath {
            return CoaxProcess(executable: URL(fileURLWithPath: path), arguments: arguments)
        } else if let bundled, FileManager.default.isExecutableFile(atPath: bundled.path) {
            return CoaxProcess(executable: bundled, arguments: arguments)
        }
        return CoaxProcess(executable: URL(fileURLWithPath: "/usr/bin/env"), arguments: ["coax"] + arguments)
    }

    func play(_ channel: Channel) {
        stop()

        let t = coax(["tune", "--ch", channel.channel, "--stats", "--program"])
        t.onLine = { [weak self, weak t] line in
            guard let self, let t, self.tuner === t else { return }
            // 「時刻 now|next 開始-終了 番組名」は番組の行、それ以外は受信状態の行
            let words = line.split(separator: " ", maxSplits: 2)
            switch words.count == 3 ? words[1] : "" {
            case "now": self.nowProgram = String(words[2])
            case "next": self.nextProgram = String(words[2])
            default: self.status = line
            }
            if self.config.debug { FileHandle.standardError.write(Data("stats: \(line)\n".utf8)) }
        }
        // 終わっても最後の行（エラーならそのメッセージ）は残す
        t.onExit = { [weak self, weak t] _ in
            guard let self, let t, self.tuner === t else { return }
            self.tuner = nil
        }
        do {
            let fd = try t.start()
            tuner = t
            playing = "\(channel.channel) \(channel.name)"
            playingChannel = channel.channel
            status = "選局中..."
            // fdclose:// は mpv が読み終えたら fd を閉じる
            player.load("fdclose://\(fd)")
        } catch {
            status = "coax: \(error.localizedDescription)"
        }
    }

    func playFile(_ file: String) {
        stop()
        playing = file
        status = "ファイル: \(file)"
        player.load(file)
    }

    func stop() {
        // 先に子プロセスを止めてチューナーを解放する
        tuner?.stop()
        tuner = nil
        player.stop()
        playing = nil
        playingChannel = nil
        nowProgram = nil
        nextProgram = nil
        status = "停止中"
    }

    /// 選んだ範囲を `coax scan` で調べ、結果を scan.json に書いて一覧を読み直す
    func startScan() {
        let patterns = zip(ScanRange.all, ranges).filter(\.1).map(\.0.pattern)
        guard !patterns.isEmpty else {
            status = "範囲を選んでください"
            return
        }
        stop()
        let output = URL(fileURLWithPath: config.scanPath)
        do {
            try FileManager.default.createDirectory(
                at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            status = "\(output.deletingLastPathComponent().path): \(error.localizedDescription)"
            return
        }

        let s = coax([
            // ロックは約 1 秒、チューナーを開いた直後でも 2.5 秒だった。既定の 5 秒だと、電波の無いチャンネルで待ちすぎる
            "scan", "--discover=ISDBT", "--lock-timeout", "3s",
            "--include", "^(\(patterns.joined(separator: "|")))$",
            "--output", output.path,
        ])
        var stdout: Int32 = -1
        // 進捗の行（[n/N] ...）とエラーだけを拾う。見つかったサービスの一覧の行は出さない
        s.onLine = { [weak self, weak s] line in
            guard let self, let s, self.scanner === s,
                  line.hasPrefix("[") || line.hasPrefix("coax:") else { return }
            self.status = line
        }
        s.onExit = { [weak self, weak s] code in
            // 標準出力は使わないが、終わるまで開けておく（閉じると書き込みで落ちる）
            close(stdout)
            guard let self, let s, self.scanner === s else { return }
            self.scanner = nil
            self.scanning = false
            // 失敗したときは最後の行（エラー）を残す
            if code == 0 {
                self.channels = (try? ScanFile.load(self.config.scanPath)) ?? []
                self.status = "スキャン完了: \(self.channels.count) チャンネル"
            }
        }
        do {
            stdout = try s.start()
            scanner = s
            scanning = true
            status = "スキャンを始めます..."
        } catch {
            status = "coax: \(error.localizedDescription)"
        }
    }

    /// スキャンを止める。coax は進捗を残すので、次は続きから
    func cancelScan() {
        scanner?.stop()
        scanner = nil
        scanning = false
        status = "スキャンを中止しました（次は続きから）"
    }

    /// アプリ終了時の後始末
    func shutdown() {
        debugTimer?.invalidate()
        tuner?.stop()
        tuner = nil
        scanner?.stop()
        scanner = nil
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
                let line = "debug: time-pos=\(pos) estimated-vf-fps=\(fps) size=\(w)x\(h) rendered=\(p.renderedFrames) enhanced=\(p.enhancedFrames) luma=\(p.lastLuma) layer=\(Int(p.layer.bounds.width))x\(Int(p.layer.bounds.height)) contents=\(p.layer.contents != nil) gravity=\(p.layer.contentsGravity.rawValue) windows=\(NSApp.windows.filter(\.isVisible).count) tuner-pid=\(self.tuner?.pid ?? 0) now=\(self.nowProgram ?? "-") next=\(self.nextProgram ?? "-")\n"
                FileHandle.standardError.write(Data(line.utf8))
            }
        }
    }
}
