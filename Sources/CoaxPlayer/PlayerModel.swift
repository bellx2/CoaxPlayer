import AppKit

/// 起動引数。
///   CoaxPlayer [--coax <path>] [--scan <path>] [--ch <n> [--record]] [--debug] [<ts file>]
struct Config {
    var coaxPath: String?
    var scanPath = ScanFile.defaultPath
    var channel: String?
    /// --ch で選局したものを、そのまま録画する
    var record = false
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
            case "--record": c.record = true
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
    /// 再生中のチャンネル（"1 ＮＨＫ総合１・東京"）かファイル名
    @Published private(set) var playing: String?
    /// 再生中のチャンネル名。一覧で強調する
    @Published private(set) var playingChannel: String?
    /// `--stats` やスキャンの進捗の最新の行。止まっているときやエラーのときはその旨
    @Published private(set) var status = "停止中"
    /// 今の番組と次の番組（`--program` の行の「開始-終了 番組名」）
    @Published private(set) var nowProgram: String?
    @Published private(set) var nextProgram: String?
    /// 録画中のファイル
    @Published private(set) var recording: URL?
    /// 録画を終えたあとの MP4 への変換の状況。画面下に出す
    @Published private(set) var recordingNote: String?
    /// スキャンする範囲。ScanRange.all と同じ並び
    @Published var ranges = [true, false, false]
    @Published private(set) var scanning = false
    /// 字幕を表示するか。チャンネルを替えても保つ
    @Published private(set) var subtitles = true
    /// 今の字幕。消えているときは nil。表示しないときも描いておき、切り替えたらすぐ出す
    @Published private(set) var caption: CaptionImage?
    /// 映像の縦横比（表示サイズ）
    @Published private(set) var videoAspect: CGFloat = 16.0 / 9.0
    /// 字幕を描く枠のピクセル数。画面の映像の表示領域に合わせて、画面側が設定する
    var captionPixelSize = CGSize.zero

    let config: Config
    let player: MPVPlayer
    private var tuner: CoaxProcess?
    /// coax の出力を mpv へ中継し、録画中はファイルにも書く
    private var tee: StreamTee?
    /// 再生中のチャンネル。録画のファイル名に使う
    private var current: Channel?
    private var scanner: CoaxProcess?
    private var debugTimer: Timer?
    private var captionRenderer: CaptionRenderer?
    /// 字幕を再生の時刻に合わせて描き直す
    private var captionTimer: Timer?

    init(config: Config) {
        self.config = config
        player = MPVPlayer(debug: config.debug)
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
                if config.record { toggleRecording() }
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
            guard let tee = StreamTee(source: fd) else {
                close(fd)
                t.stop()
                status = "パイプを作れません"
                return
            }
            // coax が終わったら録画も終わる
            tee.onEnd = { [weak self, weak tee] in
                guard let self, let tee, self.tee === tee else { return }
                self.finishRecording()
                self.tee = nil
            }
            tuner = t
            self.tee = tee
            current = channel
            playing = "\(channel.number) \(channel.name)"
            playingChannel = channel.channel
            status = "選局中..."
            // fdclose:// は mpv が読み終えたら fd を閉じる
            player.load("fdclose://\(tee.mpvFD)")
            startCaptions(tee)
            tee.start()
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
        finishRecording()
        // 先に子プロセスを止めてチューナーを解放する。中継は coax が終わると自分で閉じる
        tuner?.stop()
        tuner = nil
        tee = nil
        current = nil
        player.stop()
        playing = nil
        playingChannel = nil
        nowProgram = nil
        nextProgram = nil
        captionTimer?.invalidate()
        captionTimer = nil
        captionRenderer = nil
        caption = nil
        status = "停止中"
    }

    func toggleRecording() {
        if recording != nil {
            finishRecording()
            return
        }
        guard let tee, let current else { return }
        let url = recordingURL(current)
        do {
            try tee.startRecording(to: url)
            recording = url
        } catch {
            status = "録画を始められません: \(error.localizedDescription)"
        }
    }

    func toggleSubtitles() {
        subtitles.toggle()
    }

    /// 中継から字幕の PES を受け取って解読し、mpv の再生位置に合わせて描く
    private func startCaptions(_ tee: StreamTee) {
        guard let renderer = CaptionRenderer() else { return }
        captionRenderer = renderer
        tee.captions.onPES = { data, pts, profile in renderer.decode(data, pts: pts, profile: profile) }
        captionTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateCaptions() }
        }
    }

    private func updateCaptions() {
        guard let extractor = tee?.captions, let renderer = captionRenderer else { return }
        // フルセグも届いているときは、mpv が再生している方の番組の字幕を選ぶ
        let video = player.int64Property("current-tracks/video/src-id")
        extractor.select(videoPID: video.map { UInt16(truncatingIfNeeded: $0) })
        if let w = player.int64Property("dwidth"), let h = player.int64Property("dheight"), w > 0, h > 0,
           CGFloat(w) / CGFloat(h) != videoAspect {
            videoAspect = CGFloat(w) / CGFloat(h)
        }

        guard let position = player.doubleProperty("time-pos") else { return }
        // mpv は PTS が一巡（33 ビット、約 26.5 時間）しても数え続けるので、字幕の PTS に合わせて折り返す
        let pts = Int64(position * 1000) % ((Int64(1) << 33) / 90)
        let id = ObjectIdentifier(renderer)
        renderer.render(at: pts, width: Int(captionPixelSize.width), height: Int(captionPixelSize.height)) {
            [weak self] image in
            MainActor.assumeIsolated {
                // 描いている間にチャンネルが替わっていたら捨てる
                guard let self, self.captionRenderer.map(ObjectIdentifier.init) == id else { return }
                self.caption = image
            }
        }
    }

    private func finishRecording() {
        guard let url = recording else { return }
        tee?.stopRecording()
        recording = nil
        // 再生中の映像と音声を MP4 に入れる。フルセグも届いているときに、スクランブルのかかった方を選ばないため
        let video = player.int64Property("current-tracks/video/src-id")
        let audio = player.int64Property("current-tracks/audio/src-id")
        convertToMP4(url, video: video, audio: audio)
    }

    /// 録画の TS から、主音声だけの MP4 を作る。TS は残す。映像はそのまま、音声は主音声だけにして AAC にし直す
    private func convertToMP4(_ ts: URL, video: Int64?, audio: Int64?) {
        let mp4 = ts.deletingPathExtension().appendingPathExtension("mp4")
        var arguments = ["-hide_banner", "-loglevel", "error", "-y", "-dual_mono_mode", "main", "-i", ts.path]
        if let video, let audio {
            arguments += ["-map", "0:i:\(video)", "-map", "0:i:\(audio)"]
        }
        arguments += ["-c:v", "copy", "-c:a", "aac", "-b:a", "128k", "-movflags", "+faststart", mp4.path]

        // .app では同梱した ffmpeg、無ければ PATH 上のもの
        let process = Process()
        let bundled = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("ffmpeg")
        if let bundled, FileManager.default.isExecutableFile(atPath: bundled.path) {
            process.executableURL = bundled
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["ffmpeg"] + arguments
        }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] finished in
            let ok = finished.terminationStatus == 0
            DispatchQueue.main.async {
                self?.recordingNote = ok
                    ? "保存しました　\(mp4.path)（TS も残しています）"
                    : "MP4 にできませんでした（TS は保存済み）　\(ts.path)"
            }
        }
        do {
            try process.run()
            recordingNote = "MP4 に変換中　\(mp4.lastPathComponent)"
        } catch {
            recordingNote = "MP4 にできませんでした（TS は保存済み）　\(ts.path)"
        }
    }

    /// ~/Movies/coax/日時_リモコンの番号_局名_番組名.ts
    private func recordingURL(_ channel: Channel) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmm"
        var parts = [formatter.string(from: Date()), channel.number, channel.name]
        // 今の番組は「開始-終了 番組名」なので、番組名だけを使う
        if let title = nowProgram?.split(separator: " ", maxSplits: 1).last.map(String.init) {
            parts.append(String(title.prefix(40)))
        }
        // パスに使えない文字は全角にする
        let name = parts.joined(separator: "_")
            .replacingOccurrences(of: "/", with: "／")
            .replacingOccurrences(of: ":", with: "：")
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Movies/coax")
            .appendingPathComponent(name + ".ts")
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
        finishRecording()
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
                let line = "debug: time-pos=\(pos) estimated-vf-fps=\(fps) size=\(w)x\(h) rendered=\(p.renderedFrames) enhanced=\(p.enhancedFrames) luma=\(p.lastLuma) layer=\(Int(p.layer.bounds.width))x\(Int(p.layer.bounds.height)) contents=\(p.layer.contents != nil) gravity=\(p.layer.contentsGravity.rawValue) windows=\(NSApp.windows.filter(\.isVisible).count) tuner-pid=\(self.tuner?.pid ?? 0) caption=\(self.caption.map { "\(Int($0.rect.width))x\(Int($0.rect.height))" } ?? "-") recording=\(self.recording?.lastPathComponent ?? "-") now=\(self.nowProgram ?? "-") next=\(self.nextProgram ?? "-")\n"
                FileHandle.standardError.write(Data(line.utf8))
            }
        }
    }
}
