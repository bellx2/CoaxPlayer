import AppKit

/// 起動引数。
///   CoaxPlayer [--coax <path>] [--scan <path>] [--decoder <path>] [--ch <n> [--record]] [--debug] [<ts file>]
struct Config {
    var coaxPath: String?
    /// 選局した TS を通す外部のデコーダー。設定画面の指定より優先する
    var decoderPath: String?
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
            case "--decoder": c.decoderPath = it.next()
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
    @Published private(set) var channels: [Channel] = [] {
        didSet { loadLogos() }
    }
    /// 再生中のチャンネル（"1 ＮＨＫ総合１・東京"）かファイル名
    @Published private(set) var playing: String?
    /// 再生中のチャンネル名。一覧で強調する
    @Published private(set) var playingChannel: String?
    /// `--stats` やスキャンの進捗の最新の行。止まっているときやエラーのときはその旨
    @Published private(set) var status = "停止中"
    /// 今の番組（`--program` の now の行の「開始-終了 番組名」）
    @Published private(set) var nowProgram: String?
    /// 今の番組の詳細。パネルに出す
    @Published private(set) var nowDetail: ProgramDetail?
    /// 番組詳細のパネルを出すか。次の起動でも使う
    @Published var showsDetail = UserDefaults.standard.bool(forKey: "showsDetail") {
        didSet { UserDefaults.standard.set(showsDetail, forKey: "showsDetail") }
    }
    /// 各チャンネルの今の番組（物理チャンネルごとの「開始-終了 番組名」）。一覧に出す
    @Published private(set) var programs: [String: String] = [:]
    /// 一覧のチャンネルを順に選局して、今の番組を集めている
    @Published private(set) var refreshing = false
    private var programTuner: CoaxProcess?
    /// DT295 で番組を集めるときの pix-ts
    private var programPixTS: CoaxProcess?
    private var programTimer: Timer?
    /// 取得できなかった局の数と、最後のエラー（デバイスが無いときなどに一覧へ出す）
    private var programFailures = 0
    private var programError: String?
    /// チューナーのデバイスの状態。一覧の左上に出す
    @Published private(set) var device = DeviceState.checking
    private var deviceChecker: CoaxProcess?
    /// 一覧のプレビュー（物理チャンネルごと）。番組情報を取るときにワンセグの映像から作り、保存しておく
    @Published private(set) var previews: [String: NSImage] = [:]
    /// 前回の起動などで保存したプレビューのうち、まだ取り直していないもの。一覧では薄く出す
    @Published private(set) var stalePreviews: Set<String> = []
    private var programPreview: PreviewGrabber?
    /// 局ロゴ（物理チャンネルごと）。受け取って保存したものだけ
    @Published private(set) var logos: [String: NSImage] = [:]
    /// 録画中のファイル
    @Published private(set) var recording: URL?
    /// スキャンする範囲。ScanRange.all と同じ並び
    @Published var ranges = [true, false]
    @Published private(set) var scanning = false
    /// スキャンの進み具合（設定画面に出す）
    @Published private(set) var scanStatus = ""
    /// coax の受信状態の行（CNR、ビットレートなど）。設定画面で表示を選んだときだけ画面下に出す
    @Published private(set) var reception: String?
    @Published var showsReception = UserDefaults.standard.bool(forKey: "showsReception") {
        didSet { UserDefaults.standard.set(showsReception, forKey: "showsReception") }
    }
    /// 設定画面で選んだデコーダー。空なら Homebrew で入れたものを探す
    @Published var decoderSetting = UserDefaults.standard.string(forKey: "decoderPath") ?? "" {
        didSet {
            UserDefaults.standard.set(decoderSetting, forKey: "decoderPath")
            decoderFailed = false
            // 次の選局から使う。カードのソケットがまだ無ければ立てる
            if decoderPath != nil && pcsc == nil && !usesPix { startPCSC() }
        }
    }
    static let homebrewDecoderPath = "/opt/homebrew/bin/arib-b25-stream-test"
    /// 使うチューナー。coax のチューナーか、pix-userland の PIX-DT295 か
    @Published var tunerKind = TunerKind(rawValue: UserDefaults.standard.string(forKey: "tunerKind") ?? "") ?? .coax {
        didSet {
            guard tunerKind != oldValue else { return }
            UserDefaults.standard.set(tunerKind.rawValue, forKey: "tunerKind")
            switchTuner()
        }
    }
    /// DT295 のファームウェア（dt295.bin）のパス。空なら未設定
    @Published var pixFirmware = UserDefaults.standard.string(forKey: "pixFirmware") ?? "" {
        didSet {
            guard pixFirmware != oldValue else { return }
            UserDefaults.standard.set(pixFirmware, forKey: "pixFirmware")
            if usesPix { switchTuner() }
        }
    }
    var usesPix: Bool { tunerKind == .pix }
    var pixUserland: PixUserland? { pixFirmware.isEmpty ? nil : PixUserland(firmware: URL(fileURLWithPath: pixFirmware)) }
    /// 録画を止めたあとに ffmpeg に渡す引数。空なら TS のまま残す。
    /// {in} は TS のパス、{out} は拡張子を除いたパス、{video}・{audio} は止めた時点で再生していた映像と音声
    @Published var convertArguments = UserDefaults.standard.string(forKey: "convertArguments") ?? "" {
        didSet { UserDefaults.standard.set(convertArguments, forKey: "convertArguments") }
    }
    /// 設定画面の「例を入れる」で入れる引数。主音声だけの MP4 にする
    static let convertExample = "-dual_mono_mode main -i {in} -map {video} -map {audio} -c:v copy -c:a aac -b:a 128k -movflags +faststart {out}.mp4"

    /// 選局した TS を通す外部のデコーダー。stdin から TS を読んで stdout に書くもの。
    /// 起動引数、設定画面、Homebrew で入れたものの順に探し、どれも無ければワンセグを再生する
    var decoderPath: String? {
        if let path = config.decoderPath { return path }
        if !decoderSetting.isEmpty { return decoderSetting }
        return FileManager.default.isExecutableFile(atPath: Self.homebrewDecoderPath) ? Self.homebrewDecoderPath : nil
    }

    /// 中止したスキャンがあり、次は続きから始める
    private var scanResumable = false
    /// 字幕を表示するか。チャンネルを替えても保ち、次の起動でも使う（最初は非表示）
    @Published private(set) var subtitles = UserDefaults.standard.bool(forKey: "subtitles") {
        didSet { UserDefaults.standard.set(subtitles, forKey: "subtitles") }
    }
    /// フルセグを再生できるときも、ワンセグを見る
    @Published private(set) var oneSeg = false
    /// 今の選局はデコーダーを通していないので、ワンセグしか見られない（フルセグはスクランブルがかかっている）
    @Published private(set) var oneSegOnly = false
    /// 今の字幕。消えているときは nil。表示しないときも描いておき、切り替えたらすぐ出す
    @Published private(set) var caption: CaptionImage?
    /// 映像の縦横比（表示サイズ）
    @Published private(set) var videoAspect: CGFloat = 16.0 / 9.0
    /// 字幕を描く枠のピクセル数。画面の映像の表示領域に合わせて、画面側が設定する
    var captionPixelSize = CGSize.zero

    let config: Config
    let player: MPVPlayer
    private var tuner: CoaxProcess?
    /// DT295 のとき、coax tune の前段で TS を出す pix-ts
    private var pixTS: CoaxProcess?
    /// DT295 を受け持つ pixd。準備ができると pixdReady になる
    private var pixd: CoaxProcess?
    private var pixdReady = false
    /// pixd の準備ができるのを待っている選局
    private var pixWaiting: Channel?
    /// pixd を受け持つ権利（PixUserland.lockPath に flock をかけた fd）。持っていなければ -1
    private var pixLock: Int32 = -1
    /// coax tune と中継の間に挟むデコーダー
    private var decoder: CoaxProcess?
    /// デコーダーに渡す PC/SC ソケット（coax pcsc）
    private var pcsc: CoaxProcess?
    /// coax pcsc がソケットを出したか。それまでの選局は pcscWaiting に取っておく
    private var pcscReady = false
    private var pcscWaiting: Channel?
    /// デコーダーが再生中に終わった（カードが無いなど）。デコーダーを通さず、ワンセグで再生する。
    /// 選局のたびにカードを確かめ、差し直されていれば戻す。デコーダーの設定を変えたときと、coax を再起動したときも戻す
    private var decoderFailed = false
    /// カードを確かめている間の選局。確かめ終わる前にほかを選んだら、前のものは選局しない
    private var cardChecking: Channel?
    private let pcscSocket = FileManager.default.temporaryDirectory
        .appendingPathComponent("CoaxPlayer").appendingPathComponent("pcscd.comm")
    /// coax の出力を mpv へ中継し、録画中はファイルにも書く
    private var tee: StreamTee?
    /// 再生中のチャンネル。録画のファイル名と、映像の下の行に使う
    @Published private(set) var current: Channel?
    private var scanner: CoaxProcess?
    private var debugTimer: Timer?
    private var captionRenderer: CaptionRenderer?
    /// 字幕を再生の時刻に合わせて描き直す
    private var captionTimer: Timer?

    init(config: Config) {
        self.config = config
        player = MPVPlayer(debug: config.debug)
        player.setVolume(volume)
        channels = (try? ScanFile.load(config.scanPath)) ?? []
        // init の中では didSet が呼ばれないので、ここで読む
        loadLogos()
        if channels.isEmpty {
            status = "チャンネル一覧がありません。設定（⌘,）でスキャンしてください"
        }
        if config.debug { startDebugLog() }
        Trace.enabled = config.debug
        if decoderPath != nil && !usesPix { startPCSC() }
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
        } else {
            checkDevices()
        }
    }

    /// `coax list --tuners` でデバイスを開いて確かめる。見つかれば番組情報を取りに行く
    func checkDevices() {
        if usesPix {
            checkPix()
            return
        }
        guard deviceChecker == nil else { return }
        // 番組情報の選局中だとデバイスを開けないので止める（見つかれば取り直す）
        cancelRefresh()
        device = .checking
        var lastLine = ""
        let p = coax(["list", "--tuners", "--json"])
        p.onLine = { lastLine = $0 }
        do {
            let fd = try p.start()
            deviceChecker = p
            // JSON は stdout に出るので、終わりまで読んでから解く
            DispatchQueue.global().async { [weak self] in
                let data = FileHandle(fileDescriptor: fd, closeOnDealloc: true).readDataToEndOfFile()
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.deviceChecker = nil
                    self.device = DeviceState(json: data, error: lastLine)
                    if case .found = self.device { self.refreshPrograms() }
                }
            }
        } catch {
            device = .missing("coax: \(error.localizedDescription)")
        }
    }

    /// coaxd を止めて立て直す。デバイスを差し直したのに見えないときなどに使う。
    /// coax pcsc も coaxd につないでいるので、立て直す
    func restartCoax() {
        guard playing == nil, !scanning, deviceChecker == nil else { return }
        cancelRefresh()
        if usesPix {
            stopPixd()
            checkPix()
            return
        }
        pcsc?.stop()
        pcsc = nil
        pcscReady = false
        decoderFailed = false
        device = .checking
        DispatchQueue.global().async { [weak self] in
            // 次の coax が新しい coaxd を立てるので、止まりきるまで待つ（最大 3 秒）
            Self.runTool("pkill", ["-x", "coaxd"])
            for _ in 0..<30 where Self.runTool("pgrep", ["-x", "coaxd"]) == 0 { usleep(100_000) }
            DispatchQueue.main.async {
                guard let self else { return }
                if self.decoderPath != nil { self.startPCSC() }
                self.checkDevices()
            }
        }
    }

    /// /usr/bin のコマンドを動かして、終了コードを返す
    @discardableResult
    nonisolated private static func runTool(_ name: String, _ arguments: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/\(name)")
        p.arguments = arguments
        guard (try? p.run()) != nil else { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    /// 映像のページから一覧に戻る。再生を止め、番組情報を取り直す。
    /// --ch で起動したときはデバイスをまだ確かめていないので、ここで確かめる（見つかれば番組情報も取る）
    func backToList() {
        stop()
        if device == .checking {
            checkDevices()
        } else {
            refreshPrograms()
        }
    }

    /// 数字キーで打った番号（リモコンの番号）。2 桁の番号を待っている間だけ持つ
    private var typedNumber = ""
    private var typedTimer: Timer?

    /// 数字キー（テンキーも）で選局する。続く数字がありうる間は 1 秒待ち、無ければすぐ選ぶ
    func typeDigit(_ digit: Character) {
        typedTimer?.invalidate()
        typedNumber.append(digit)
        let typed = typedNumber
        let longer = channels.contains { $0.remoteKey.map(String.init)?.hasPrefix(typed) == true && String($0.remoteKey!) != typed }
        guard longer else {
            selectTyped()
            return
        }
        status = "チャンネル \(typed)-"
        typedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.selectTyped() }
        }
    }

    /// 一覧の並び（リモコンの番号の順）で、見ているチャンネルの前後へ切り替える。端からは反対の端へ回る
    func switchChannel(by offset: Int) {
        guard let current, let index = channels.firstIndex(where: { $0.channel == current.channel }) else { return }
        let count = channels.count
        play(channels[((index + offset) % count + count) % count])
    }

    private func selectTyped() {
        let typed = typedNumber
        typedNumber = ""
        if let channel = channels.first(where: { $0.remoteKey.map(String.init) == typed }) {
            play(channel)
        } else {
            status = "チャンネル \(typed) はありません"
        }
    }

    /// 一覧のチャンネルを順に短く選局し、今の番組を集める。再生中とスキャン中は何もしない
    func refreshPrograms() {
        guard playing == nil, !refreshing, !scanning, !channels.isEmpty, !usesPix || pixdReady else { return }
        refreshing = true
        programFailures = 0
        programError = nil
        Trace.begin("番組情報を集め始めた")
        fetchProgram(at: 0)
    }

    /// 1 局ずつ短く選局して集める。番組名を早くそろえるため、まず全局の今の番組だけを集め（.programs）、
    /// そのあとワンセグのある局をもう一周してプレビューを集める（.previews）。プレビューはワンセグの映像の
    /// キーフレームを待つので 1 局 1〜3 秒かかり、番組（約 1 秒）と一緒に待つと番組名がそろうのが遅れる
    private enum RefreshPass { case programs, previews }

    private func fetchProgram(at index: Int, pass: RefreshPass = .programs) {
        guard refreshing else { return }
        let targets = pass == .programs ? channels : channels.filter { $0.oneSegServiceID != nil }
        guard index < targets.count else {
            if pass == .programs {
                if programFailures == channels.count {
                    // 番組が 1 局も取れなかったときは（デバイスが無いなど）、プレビューも取れないので終える
                    refreshing = false
                    status = "番組情報を取得できませんでした" + (programError.map { ": \($0)" } ?? "")
                    return
                }
                Trace.mark("番組情報: 番組をすべて集めた")
                // DT295 は 1 局の選局に 2〜3 秒（上流の pix-userland では約 9 秒）かかるので、プレビューまでは集めない
                if !usesPix {
                    fetchProgram(at: 0, pass: .previews)
                    return
                }
                refreshing = false
                status = programFailures > 0
                    ? "番組情報を更新しました（\(programFailures) 局は取得できませんでした）"
                    : "番組情報を更新しました"
                return
            }
            Trace.mark("番組情報: すべて終わった")
            refreshing = false
            if programFailures > 0 {
                status = "番組情報を更新しました（\(programFailures) 局は取得できませんでした）"
            } else {
                status = "番組情報を更新しました"
            }
            return
        }
        let channel = targets[index]
        Trace.mark("番組情報: \(channel.channel) を選局（\(pass == .programs ? "番組" : "プレビュー")）")
        status = pass == .programs
            ? "番組情報を取得中（\(index + 1)/\(targets.count)）\(channel.name)"
            : "プレビューを取得中（\(index + 1)/\(targets.count)）\(channel.name)"
        // ワンセグの映像の 1 コマをプレビューにする。ffmpeg を起動できなければ、選局せずに次の局へ
        let preview = pass == .previews
            ? channel.oneSegServiceID.flatMap { PreviewGrabber(serviceID: $0, ffmpeg: Self.ffmpeg()) }
            : nil
        if pass == .previews && preview == nil {
            fetchProgram(at: index + 1, pass: pass)
            return
        }
        // 止めた直後は coaxd がまだチューナーを持っていて、続く視聴の選局が in use になる。
        // 優先度を下げておき、視聴の選局（既定の 0）がチューナーを奪えるようにする
        let t: CoaxProcess
        do {
            (t, programPixTS) = try tuneProcess(channel, coaxOptions: ["--program", "--priority", "-1"])
        } catch {
            programFailures += 1
            programError = (error as? PixError)?.message ?? error.localizedDescription
            fetchProgram(at: index + 1, pass: pass)
            return
        }
        programPreview = preview
        // 番組の周では今の番組が届いたら、プレビューの周ではプレビューが取れたら次の局へ。
        // 終わったときと時間切れのときも次へ
        let advance = { [weak self, weak t] in
            guard let self, let t, self.programTuner === t else { return }
            self.programTimer?.invalidate()
            self.programTuner = nil
            self.programPreview = nil
            preview?.stop()
            self.programPixTS?.stop()
            self.programPixTS = nil
            t.stop()
            self.fetchProgram(at: index + 1, pass: pass)
        }
        preview?.onDone = { [weak self] jpeg in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let jpeg, let image = NSImage(data: jpeg) {
                        self.previews[channel.channel] = image
                        self.stalePreviews.remove(channel.channel)
                        let url = Self.previewURL(channel)
                        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try? jpeg.write(to: url)
                    }
                    Trace.mark("番組情報: \(channel.channel) のプレビュー\(jpeg == nil ? "なし" : "")")
                    advance()
                }
            }
        }
        t.onLine = { [weak self] line in
            guard let self else { return }
            let words = line.split(separator: " ", maxSplits: 2)
            guard words.count == 3, words[1] == "now" else {
                // 番組の行（次の番組や詳細の行を含む）でなければエラーなどの行
                if pass == .programs, words.count < 2 || !(words[1].hasPrefix("now") || words[1].hasPrefix("next")) {
                    self.programError = line
                }
                return
            }
            // プレビューの周でも、届いた番組は新しいので反映する
            self.programs[channel.channel] = String(words[2])
            if pass == .programs {
                Trace.mark("番組情報: \(channel.channel) の番組")
                advance()
            }
        }
        t.onExit = { [weak self, weak t] code in
            // 番組が届く前に異常終了したものを失敗として数える（時間切れで止めたものは数えない）
            if let self, let t, self.programTuner === t, code != 0, pass == .programs { self.programFailures += 1 }
            advance()
        }
        do {
            let fd = try t.start()
            programTuner = t
            // プレビューに使うほかは捨てる。読まずに閉じると coax が書き込みで終わるので、終わりまで読む
            DispatchQueue.global().async {
                var buffer = [UInt8](repeating: 0, count: 64 * 1024)
                while true {
                    let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                    guard n > 0 else { break }
                    preview?.feed(buffer[0..<n])
                }
                preview?.finish()
                close(fd)
            }
            // DT295 は流れ始めるまでに 2〜3 秒（上流の pix-userland では約 9 秒）かかる
            programTimer = Timer.scheduledTimer(withTimeInterval: usesPix ? 15 : 10, repeats: false) { _ in
                MainActor.assumeIsolated { advance() }
            }
        } catch {
            programPixTS?.stop()
            programPixTS = nil
            if pass == .programs {
                programFailures += 1
                programError = error.localizedDescription
            }
            fetchProgram(at: index + 1, pass: pass)
        }
    }

    private func cancelRefresh() {
        guard refreshing else { return }
        refreshing = false
        programTimer?.invalidate()
        programPixTS?.stop()
        programPixTS = nil
        programTuner?.stop()
        programTuner = nil
        programPreview?.stop()
        programPreview = nil
    }

    /// coax を起動するコマンド。--coax 未指定なら、.app に同梱した coax（実行ファイルと同じ場所）を使い、
    /// それも無ければ PATH 上の coax を env 経由で起動する（env は exec するので pid は coax のもの）
    private func coax(_ arguments: [String], input: Int32? = nil, outputLines: Bool = false) -> CoaxProcess {
        let bundled = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("coax")
        if let path = config.coaxPath {
            return CoaxProcess(executable: URL(fileURLWithPath: path), arguments: arguments, input: input,
                               outputLines: outputLines)
        } else if let bundled, FileManager.default.isExecutableFile(atPath: bundled.path) {
            return CoaxProcess(executable: bundled, arguments: arguments, input: input, outputLines: outputLines)
        }
        return CoaxProcess(executable: URL(fileURLWithPath: "/usr/bin/env"), arguments: ["coax"] + arguments,
                           input: input, outputLines: outputLines)
    }

    /// 選局する coax tune を作る（まだ起動しない）。DT295 では pix-ts を先に起動し、その出力を
    /// `coax tune --input -` に流す。そのとき coaxOptions のうち --stats と --program だけを渡す
    private func tuneProcess(_ channel: Channel, coaxOptions: [String]) throws -> (CoaxProcess, CoaxProcess?) {
        guard usesPix else {
            return (coax(["tune", "--ch", channel.channel] + coaxOptions), nil)
        }
        guard let pix = pixUserland else { throw PixError("PIX-DT295 のファームウェア（dt295.bin）を設定してください（⌘,）") }
        guard pixdReady else { throw PixError("PIX-DT295 の準備ができていません") }
        guard let arguments = pix.tuneArguments(channel: channel.channel) else {
            throw PixError("PIX-DT295 は \(channel.channel) を受信できません（地上波 13〜62ch だけ）")
        }
        let front = CoaxProcess(executable: pix.pixTS, arguments: arguments)
        let fd = try front.start()
        let options = coaxOptions.filter { $0 == "--stats" || $0 == "--program" }
        return (coax(["tune", "--input", "-"] + options, input: fd), front)
    }

    /// pix-ts が異常終了したら、最後の行（エラー）を出す。止めたときは先に pixTS を外すので、ここには来ない
    private func watchPixTS(_ front: CoaxProcess) {
        var last = ""
        front.onLine = { [weak self] line in
            last = line
            if self?.config.debug == true { FileHandle.standardError.write(Data("pix-ts: \(line)\n".utf8)) }
        }
        front.onExit = { [weak self, weak front] code in
            guard let self, let front, self.pixTS === front else { return }
            self.pixTS = nil
            if code != 0 { self.status = "pix-ts が終了しました（\(code)）: \(last)" }
        }
    }

    /// 設定でチューナーかファームウェアを変えたとき。再生と番組集めを止め、デバイスを確かめ直す
    private func switchTuner() {
        cancelRefresh()
        stop()
        stopPixd()
        if usesPix {
            pcsc?.stop()
            pcsc = nil
            pcscReady = false
        } else if decoderPath != nil && pcsc == nil {
            startPCSC()
        }
        checkDevices()
    }

    /// DT295 の pixd が動いていれば番組を集め、動いていなければ起動する。
    /// `pixd --list-json` で USB の位置を調べてから、その位置を指定して起動する（DT295 はシリアル番号を返さない個体がある）
    private func checkPix() {
        if pixdReady {
            device = .found("PIX-DT295")
            refreshPrograms()
            return
        }
        guard pixd == nil else { return }
        guard let pix = pixUserland else {
            device = .missing("PIX-DT295 のファームウェア（dt295.bin）を設定してください（⌘,）")
            failPixWaiting()
            return
        }
        if let problem = pix.problem {
            device = .missing("PIX-DT295: \(problem)")
            failPixWaiting()
            return
        }
        guard acquirePixLock() else {
            Trace.mark("PIX: ほかの CoaxPlayer が使用中")
            device = .missing("ほかの CoaxPlayer が PIX-DT295 を使っています")
            failPixWaiting()
            return
        }
        device = .checking
        Trace.mark("PIX: DT295 を探す")
        DispatchQueue.global().async { [weak self] in
            // アプリが落ちて残った pixd は DT295 を持ったままなので止める。ロックを取れたので、
            // 動いている pixd があっても、それを受け持っていた CoaxPlayer はもういない
            // 止めきるまで待つ。後始末中の pixd が DT295 とソケットを持っているうちに起動すると失敗する
            let stale = "pixd .*--instance \(PixUserland.instance) "
            if Self.runTool("pkill", ["-f", stale]) == 0 {
                for _ in 0..<30 where Self.runTool("pgrep", ["-f", stale]) == 0 { usleep(100_000) }
                Self.runTool("pkill", ["-KILL", "-f", stale])
            }
            let list = Process()
            let pipe = Pipe()
            list.executableURL = pix.pixd
            list.arguments = ["--list-json"]
            list.standardOutput = pipe
            list.standardError = FileHandle.nullDevice
            var result: Result<String, PixError>
            do {
                try list.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                list.waitUntilExit()
                result = PixUserland.port(listJSON: data)
            } catch {
                result = .failure(PixError("pixd: \(error.localizedDescription)"))
            }
            DispatchQueue.main.async {
                guard let self, self.usesPix, self.pixd == nil else { return }
                Trace.mark("PIX: \(result)")
                switch result {
                case .success(let port): self.startPixd(pix, port: port)
                case .failure(let error):
                    self.device = .missing(error.message)
                    self.failPixWaiting()
                }
            }
        }
    }

    private func startPixd(_ pix: PixUserland, port: String) {
        // pixd は自分だけが読み書きできるディレクトリでないと使わない
        let fm = FileManager.default
        try? fm.createDirectory(at: PixUserland.runtimeDir, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: PixUserland.runtimeDir.path)
        let p = CoaxProcess(executable: pix.pixd, arguments: pix.daemonArguments(port: port), outputLines: true)
        var last = ""
        p.onLine = { [weak self, weak p] line in
            guard let self, let p, self.pixd === p else { return }
            last = line
            if self.config.debug { FileHandle.standardError.write(Data("pixd: \(line)\n".utf8)) }
            // 「pixd ready: model=PIX-DT295 ...」が出たら選局できる
            guard !self.pixdReady, line.hasPrefix("pixd ready") else { return }
            Trace.mark("PIX: pixd の準備ができた")
            self.pixdReady = true
            self.device = .found("PIX-DT295")
            if let channel = self.pixWaiting {
                self.pixWaiting = nil
                self.play(channel)
            } else {
                self.refreshPrograms()
            }
        }
        p.onExit = { [weak self, weak p] code in
            guard let self, let p, self.pixd === p else { return }
            self.pixd = nil
            self.pixdReady = false
            Trace.mark("PIX: pixd が終了した（\(code)）: \(last)")
            self.device = .missing("pixd が終了しました（\(code)）: \(last)")
            self.failPixWaiting()
        }
        do {
            close(try p.start())
            pixd = p
        } catch {
            device = .missing("pixd: \(error.localizedDescription)")
        }
    }

    /// pixd を使えないとき、待っていた選局をやめて理由を出す
    private func failPixWaiting() {
        guard pixWaiting != nil, case .missing(let reason) = device else { return }
        pixWaiting = nil
        status = reason
    }

    private func stopPixd() {
        let p = pixd
        pixd = nil
        pixdReady = false
        p?.stop()
        releasePixLock()
    }

    /// pixd を受け持つ権利を取る。flock は持ち主のプロセスが終わると（落ちても）外れる。
    /// 子プロセスに引き継ぐと、アプリが落ちても pixd が持ち続けてしまうので O_CLOEXEC で開く
    private func acquirePixLock() -> Bool {
        if pixLock >= 0 { return true }
        let fd = open(PixUserland.lockPath, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return false
        }
        pixLock = fd
        return true
    }

    private func releasePixLock() {
        guard pixLock >= 0 else { return }
        flock(pixLock, LOCK_UN)
        close(pixLock)
        pixLock = -1
    }

    func play(_ channel: Channel) {
        Trace.begin("選局: \(channel.channel)")
        videoRetried = nil
        cancelRefresh()
        stop()
        Trace.mark("前の再生を止めた")
        guard decoderFailed && decoderPath != nil && !usesPix else {
            tune(channel)
            return
        }
        // デコーダーをやめたあとは、カードが差し直されていればデコーダーに戻す
        cardChecking = channel
        checkCard { [weak self] present in
            guard let self, self.cardChecking?.channel == channel.channel else { return }
            self.cardChecking = nil
            if present { self.decoderFailed = false }
            self.tune(channel)
        }
    }

    /// `coax card --status` でカードが差さっているかを確かめる。確かめられなければ無いとみなす
    private func checkCard(_ done: @escaping (Bool) -> Void) {
        let p = coax(["card", "--status", "--json"])
        guard let fd = try? p.start() else { return done(false) }
        DispatchQueue.global().async {
            let data = FileHandle(fileDescriptor: fd, closeOnDealloc: true).readDataToEndOfFile()
            let present = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["present"] as? Bool ?? false
            DispatchQueue.main.async { done(present) }
        }
    }

    private func tune(_ channel: Channel) {
        // DT295 は pixd の準備ができてから選局する（--ch で起動したときは、まだ pixd を起動していない）
        if usesPix && !pixdReady {
            pixWaiting = channel
            status = "PIX-DT295 の準備中..."
            checkPix()
            return
        }
        // coax pcsc が動いている間は準備を待つ。終わってしまったら、デコーダーを通さずワンセグで再生する
        if decoderPath != nil && !decoderFailed && pcsc != nil && !pcscReady && !usesPix {
            pcscWaiting = channel
            status = "デコーダーの準備中..."
            return
        }

        let t: CoaxProcess
        do {
            (t, pixTS) = try tuneProcess(channel, coaxOptions: ["--stats", "--program"])
        } catch {
            status = (error as? PixError)?.message ?? "pix-ts: \(error.localizedDescription)"
            return
        }
        if let front = pixTS { watchPixTS(front) }
        t.onLine = { [weak self, weak t] line in
            guard let self, let t, self.tuner === t else { return }
            // 「時刻 now|next 開始-終了 番組名」は番組の行で、そのあとに「時刻 now-text 説明」「時刻 now-item 見出し<TAB>内容」が続く。
            // 「時刻 locked ...」などは受信状態の行、それ以外はエラーなど
            let words = line.split(separator: " ", maxSplits: 2)
            if words.count >= 2, self.reception == nil, words[1] != "now" && !words[1].hasPrefix("now-") && !words[1].hasPrefix("next") {
                Trace.mark("coax: 最初の受信状態 \(line)")
            }
            let rest = words.count == 3 ? String(words[2]) : ""
            switch words.count == 3 ? words[1] : "" {
            case "now":
                self.nowProgram = rest
                self.programs[channel.channel] = self.nowProgram
                self.nowDetail = ProgramDetail(program: rest)
            case "now-text":
                self.nowDetail?.text = ProgramDetail.unescape(rest)
            case "now-item":
                self.nowDetail?.append(item: rest)
            case "next", "next-text", "next-item": break
            default:
                if line.range(of: #"^\d\d:\d\d:\d\d "#, options: .regularExpression) != nil {
                    // DT295 は流れ始めるまでの時間が pix-userland の版で大きく違うので、
                    // 最初の受信状態の行（coax tune --input はデータが届くまで出さない）から映像を見張る
                    if self.usesPix, self.reception == nil, let tee = self.tee {
                        self.watchVideo(channel, tee: tee, frames: self.player.renderedFrames)
                    }
                    self.reception = line
                    if self.status == "選局中..." { self.status = "" }
                } else {
                    self.status = line
                }
            }
            if self.config.debug { FileHandle.standardError.write(Data("stats: \(line)\n".utf8)) }
        }
        // 終わっても最後の行（エラーならそのメッセージ）は残す
        t.onExit = { [weak self, weak t] _ in
            guard let self, let t, self.tuner === t else { return }
            self.tuner = nil
        }
        do {
            var fd = try t.start()
            Trace.mark("coax を起動した")
            // DT295 の TS はスクランブルが解けているので、デコーダーを通さない
            if let path = decoderPath, pcscReady, !decoderFailed, !usesPix {
                let d = CoaxProcess(executable: URL(fileURLWithPath: path), arguments: [], input: fd,
                                    environment: ["PCSCLITE_CSOCK_NAME": pcscSocket.path])
                watchDecoder(d)
                fd = try d.start()
                Trace.mark("デコーダーを起動した")
                decoder = d
            }
            guard let tee = StreamTee(source: fd) else {
                close(fd)
                pixTS?.stop()
                pixTS = nil
                t.stop()
                decoder?.stop()
                decoder = nil
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
            startLogo(channel, tee)
            current = channel
            playing = "\(channel.number) \(channel.name)"
            playingChannel = channel.channel
            status = "選局中..."
            // fdclose:// は mpv が読み終えたら fd を閉じる
            player.load("fdclose://\(tee.mpvFD)", decoded: decoder != nil || usesPix)
            if !usesPix { watchVideo(channel, tee: tee, frames: player.renderedFrames) }
            oneSegOnly = decoder == nil && !usesPix
            startCaptions(tee)
            tee.start()
        } catch {
            pixTS?.stop()
            pixTS = nil
            status = "coax: \(error.localizedDescription)"
        }
    }

    /// デコーダーは、ソケットが選局より先にあることを前提にする（`coax tune --pcsc` では間に合わない）。
    /// 起動時に coax pcsc を立てておき、終了まで残す
    private func startPCSC() {
        try? FileManager.default.createDirectory(at: pcscSocket.deletingLastPathComponent(), withIntermediateDirectories: true)
        // アプリが落ちると coax pcsc は残り、ソケットとカードを持ったままになるので、前回の分を止める
        Self.runTool("pkill", ["-f", "coax pcsc --socket \(pcscSocket.path)"])
        let p = coax(["pcsc", "--socket", pcscSocket.path], outputLines: true)
        p.onLine = { [weak self] line in
            guard let self else { return }
            if self.config.debug { FileHandle.standardError.write(Data("pcsc: \(line)\n".utf8)) }
            // 「serving PC/SC on <path>」が出たらつなげる
            guard !self.pcscReady, line.hasPrefix("serving PC/SC") else { return }
            self.pcscReady = true
            if let channel = self.pcscWaiting {
                self.pcscWaiting = nil
                self.play(channel)
            }
        }
        p.onExit = { [weak self, weak p] _ in
            guard let self, let p, self.pcsc === p else { return }
            self.pcsc = nil
            self.pcscReady = false
            self.status = "coax pcsc が終了しました。ワンセグで再生します"
            if let channel = self.pcscWaiting {
                self.pcscWaiting = nil
                self.play(channel)
            }
        }
        do {
            close(try p.start())
            pcsc = p
        } catch {
            status = "coax pcsc: \(error.localizedDescription)"
        }
    }

    /// デコーダーの stderr は進み具合などで多いので、異常終了したときに最後の行だけ出す
    private func watchDecoder(_ d: CoaxProcess) {
        var last = ""
        d.onLine = { [weak self] line in
            last = line
            if self?.config.debug == true { FileHandle.standardError.write(Data("decoder: \(line)\n".utf8)) }
        }
        d.onExit = { [weak self, weak d] code in
            guard let self, let d, self.decoder === d else { return }
            self.decoder = nil
            // 止めたときは先に decoder を外すので、ここに来るのは再生中に終わったとき。
            // カードを読めないときは終了コード 0 で何も出さずに終わり、ワンセグまで見られなくなるので、
            // デコーダーを通さずに選び直す（ワンセグはスクランブルが無いので見られる）
            self.decoderFailed = true
            guard let channel = self.current else { return }
            // 選局を先に止めておく。画面は映像のページのまま
            self.tuner?.stop()
            self.tuner = nil
            let message = "デコーダーが終了したので、ワンセグで再生します（\(code)）: \(last)"
            self.status = message
            self.retune(channel, message: message, attempts: 5)
        }
    }

    /// 選局し直したチャンネル。見張りで選び直すのは 1 回だけにする
    private var videoRetried: String?

    /// 選局してから（DT295 では TS が流れ始めてから）5 秒経っても映像が 1 コマも出なければ、1 回だけ選び直す。
    /// mpv が最初の解析で映像を見つけ損ねると、その再生の間ずっと映像が出ないため（まれに起きる）
    private func watchVideo(_ channel: Channel, tee: StreamTee, frames: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self, weak tee] in
            guard let self, let tee, self.tee === tee, self.player.renderedFrames == frames,
                  self.videoRetried != channel.channel else { return }
            Trace.mark("映像が出ないので選局し直す")
            self.play(channel)
            self.videoRetried = channel.channel
            self.status = "映像が出なかったので選局し直しました"
        }
    }

    /// 止めた直後は coaxd がまだチューナーを持っていて in use になることがあるので、
    /// 1 秒おきに選び直す。選局が続いていれば（tuner が残っていれば）やめる
    private func retune(_ channel: Channel, message: String, attempts: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            // その間にほかのチャンネルを選んだり、一覧に戻ったりしていれば何もしない
            guard let self, attempts > 0, self.current?.channel == channel.channel, self.tuner == nil else { return }
            // カードは確かめずにデコーダーなしで選ぶ。確かめると、カード以外の理由で終わるデコーダーを繰り返し使ってしまう
            self.stop()
            self.tune(channel)
            self.status = message
            // 選局が in use で終わったら tuner が外れるので、もう一度
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, self.tuner == nil else { return }
                self.retune(channel, message: message, attempts: attempts - 1)
            }
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
        // 先に子プロセスを止めてチューナーを解放する。中継は coax が終わると自分で閉じる。
        // DT295 は pix-ts を先に止める（coax tune --input は入力が終わると自分で終わる）
        pixTS?.stop()
        pixTS = nil
        tuner?.stop()
        tuner = nil
        decoder?.stop()
        decoder = nil
        pcscWaiting = nil
        pixWaiting = nil
        cardChecking = nil
        tee = nil
        current = nil
        player.stop()
        playing = nil
        playingChannel = nil
        nowProgram = nil
        nowDetail = nil
        reception = nil
        oneSegOnly = false
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

    /// 局ロゴは数分おきにしか送られないので、受け取ったものを保存しておき、選局したらまずそれを出す
    private func startLogo(_ channel: Channel, _ tee: StreamTee) {
        let url = Self.logoURL(channel)
        var saved = try? Data(contentsOf: url)
        guard let source = channel.logoSource else { return }
        let extractor = LogoExtractor(downloadDataID: source.downloadDataID, logoID: source.logoID)
        extractor.onLogo = { [weak self, weak tee] png in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let tee, self.tee === tee, png != saved, let image = NSImage(data: png) else { return }
                    saved = png
                    self.logos[channel.channel] = image
                    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? png.write(to: url)
                }
            }
        }
        tee.logos = extractor
    }

    private static func logoURL(_ channel: Channel) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CoaxPlayer/logos/\(channel.channel).png")
    }

    /// 保存してある局ロゴとプレビューを読む。チャンネル一覧が変わったときに呼ぶ
    private func loadLogos() {
        logos = Dictionary(uniqueKeysWithValues: channels.compactMap { channel in
            NSImage(contentsOf: Self.logoURL(channel)).map { (channel.channel, $0) }
        })
        previews = Dictionary(uniqueKeysWithValues: channels.compactMap { channel in
            NSImage(contentsOf: Self.previewURL(channel)).map { (channel.channel, $0) }
        })
        stalePreviews = Set(previews.keys)
    }

    private static func previewURL(_ channel: Channel) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CoaxPlayer/previews/\(channel.channel).jpg")
    }

    /// 今の番組名（「開始-終了 番組名」の番組名）
    var nowTitle: String? {
        nowProgram?.split(separator: " ", maxSplits: 1).last.map(String.init)
    }

    func toggleSubtitles() {
        subtitles.toggle()
    }

    /// デュアルモノで鳴らす音声。主音声、副音声、主と副（左右）の順に切り替える。チャンネルを替えても保つ
    @Published private(set) var dualMono = DualMono.main

    enum DualMono: String, CaseIterable {
        case main, sub, both

        var label: String {
            switch self {
            case .main: "主"
            case .sub: "副"
            case .both: "主副"
            }
        }
    }

    func cycleDualMono() {
        let all = DualMono.allCases
        dualMono = all[(all.firstIndex(of: dualMono)! + 1) % all.count]
        player.setDualMono(dualMono.rawValue)
    }

    /// 音量（0〜100）。チャンネルを替えても保ち、次の起動でも使う。変えるとミュートを解く
    @Published var volume = UserDefaults.standard.object(forKey: "volume") as? Double ?? 100 {
        didSet {
            UserDefaults.standard.set(volume, forKey: "volume")
            player.setVolume(volume)
            if muted { toggleMute() }
        }
    }
    /// ミュート。チャンネルを替えても保つ（次の起動には持ち越さない）
    @Published private(set) var muted = false

    func toggleMute() {
        muted.toggle()
        player.setMute(muted)
    }

    func toggleOneSeg() {
        oneSeg.toggle()
        player.prefersOneSeg = oneSeg
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
        // 変換では再生中の映像と音声を選べるようにする。フルセグも届いているときに、再生していない方を選ばないため
        let video = player.int64Property("current-tracks/video/src-id")
        let audio = player.int64Property("current-tracks/audio/src-id")
        convert(url, video: video, audio: audio)
    }

    /// 録画の TS から、主音声だけの MP4 を作る。TS は残す。映像はそのまま、音声は主音声だけにして AAC にし直す
    /// ffmpeg を起動する Process。引数は arguments に足す。
    /// .app では同梱した ffmpeg、無ければ PATH 上のもの（env は exec するので、止めると ffmpeg が止まる）
    private static func ffmpeg() -> Process {
        let process = Process()
        let bundled = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("ffmpeg")
        if let bundled, FileManager.default.isExecutableFile(atPath: bundled.path) {
            process.executableURL = bundled
            process.arguments = []
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["ffmpeg"]
        }
        return process
    }

    /// 設定画面の引数で、録画した TS を ffmpeg で変換する。引数が空なら何もしない（TS は残る）
    private func convert(_ ts: URL, video: Int64?, audio: Int64?) {
        let template = convertArguments.split(whereSeparator: \.isWhitespace)
        guard !template.isEmpty else { return }
        // 空白で分けてから置き換えるので、パスに空白があっても 1 つの引数のまま渡る
        let values = [
            "{in}": ts.path,
            "{out}": ts.deletingPathExtension().path,
            "{video}": video.map { "0:i:\($0)" } ?? "0:v:0",
            "{audio}": audio.map { "0:i:\($0)" } ?? "0:a:0",
        ]
        let arguments = template.map { word in
            values.reduce(String(word)) { $0.replacingOccurrences(of: $1.key, with: $1.value) }
        }
        let process = Self.ffmpeg()
        process.arguments = (process.arguments ?? []) + ["-hide_banner", "-loglevel", "error", "-y"] + arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        // 画面には出さないので、失敗したときだけ stderr に残す
        let failed = "録画を変換できませんでした（TS は保存済み）: \(ts.path)\n"
        process.terminationHandler = { finished in
            if finished.terminationStatus != 0 { FileHandle.standardError.write(Data(failed.utf8)) }
        }
        do {
            try process.run()
        } catch {
            FileHandle.standardError.write(Data(failed.utf8))
        }
    }


    /// ~/Movies/coax/日時_リモコンの番号_局名_番組名.ts
    private func recordingURL(_ channel: Channel) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmm"
        var parts = [formatter.string(from: Date()), channel.number, channel.name]
        if let title = nowTitle {
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
            scanStatus = "範囲を選んでください"
            return
        }
        // DT295 は pix-ts でチャンネルごとに選局するので、pixd が動いている必要がある
        if usesPix && !pixdReady {
            scanStatus = "PIX-DT295 の準備ができていません（デバイスの状態を確かめてください）"
            return
        }
        cancelRefresh()
        stop()
        let output = URL(fileURLWithPath: config.scanPath)
        do {
            try FileManager.default.createDirectory(
                at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            scanStatus = "\(output.deletingLastPathComponent().path): \(error.localizedDescription)"
            return
        }

        var arguments = [
            // ロックは約 1 秒、チューナーを開いた直後でも 2.5 秒だった。既定の 5 秒だと、電波の無いチャンネルで待ちすぎる
            "scan", "--discover=ISDBT", "--lock-timeout", "3s",
            "--include", "^(\(patterns.joined(separator: "|")))$",
            "--output", output.path,
        ]
        // DT295 は coax のチューナーではないので、pix-ts を外部コマンドとして選局させる。
        // ロックが分からず、受信できない局はデータが来ないことで見分けるので、--data-timeout を
        // 流れ始めるまでの時間（2〜3 秒）より長くする
        if usesPix, let pix = pixUserland {
            arguments += ["--data-timeout", "5s", "--tune-command", pix.scanCommand]
        }
        // 中止したものの続きでなければ、前の進捗を捨てて最初から調べ直す
        if !scanResumable { arguments.append("--restart") }
        let s = coax(arguments)
        var stdout: Int32 = -1
        // 進捗の行（[n/N] ...）とエラーだけを拾う。見つかったサービスの一覧の行は出さない
        s.onLine = { [weak self, weak s] line in
            guard let self, let s, self.scanner === s,
                  line.hasPrefix("[") || line.hasPrefix("coax:") else { return }
            self.scanStatus = line
        }
        s.onExit = { [weak self, weak s] code in
            // 標準出力は使わないが、終わるまで開けておく（閉じると書き込みで落ちる）
            close(stdout)
            guard let self, let s, self.scanner === s else { return }
            self.scanner = nil
            self.scanning = false
            // 失敗したときは、設定画面に最後の行（エラー）を残す
            if code == 0 {
                self.scanResumable = false
                self.channels = (try? ScanFile.load(self.config.scanPath)) ?? []
                self.scanStatus = "スキャン完了: \(self.channels.count) チャンネル"
                self.status = self.scanStatus
                self.refreshPrograms()
            } else {
                self.status = "スキャンに失敗しました（設定画面に理由）"
            }
        }
        do {
            stdout = try s.start()
            scanner = s
            scanning = true
            scanStatus = "スキャンを始めます..."
            status = "スキャン中..."
        } catch {
            scanStatus = "coax: \(error.localizedDescription)"
        }
    }

    /// スキャンを止める。coax は進捗を残すので、次は続きから
    func cancelScan() {
        scanner?.stop()
        scanner = nil
        scanning = false
        scanResumable = true
        scanStatus = "スキャンを中止しました（次は続きから）"
        status = scanStatus
    }

    /// アプリ終了時の後始末
    func shutdown() {
        cancelRefresh()
        debugTimer?.invalidate()
        finishRecording()
        pixTS?.stop()
        pixTS = nil
        tuner?.stop()
        tuner = nil
        decoder?.stop()
        decoder = nil
        pcsc?.stop()
        pcsc = nil
        stopPixd()
        scanner?.stop()
        scanner = nil
        deviceChecker?.stop()
        player.destroy()
    }

    /// 描画できているかを客観的に確かめるため、1 秒ごとに mpv の状態を stderr へ出す
    private func startDebugLog() {
        debugTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let p = self.player
                let pos = p.doubleProperty("time-pos").map { String(format: "%.2f", $0) } ?? "-"
                // 放送からの遅れ。届いた最新の PCR と再生位置の差（PCR は 33 ビットで一周する）
                var lag = "-"
                if let pcr = self.tee?.latestPCR, let time = p.doubleProperty("time-pos") {
                    var d = pcr - time
                    if d < -47721 { d += 95443.7176888889 }
                    lag = String(format: "%.2f", d)
                }
                let fps = p.doubleProperty("estimated-vf-fps").map { String(format: "%.2f", $0) } ?? "-"
                let w = p.int64Property("dwidth") ?? 0, h = p.int64Property("dheight") ?? 0
                let line = "debug: lag=\(lag) time-pos=\(pos) estimated-vf-fps=\(fps) size=\(w)x\(h) rendered=\(p.renderedFrames) enhanced=\(p.enhancedFrames) luma=\(p.lastLuma) layer=\(Int(p.layer.bounds.width))x\(Int(p.layer.bounds.height)) contents=\(p.layer.contents != nil) gravity=\(p.layer.contentsGravity.rawValue) windows=\(NSApp.windows.filter(\.isVisible).count) tuner-pid=\(self.tuner?.pid ?? 0) caption=\(self.caption.map { "\(Int($0.rect.width))x\(Int($0.rect.height))" } ?? "-") recording=\(self.recording?.lastPathComponent ?? "-") now=\(self.nowProgram ?? "-")\n"
                FileHandle.standardError.write(Data(line.utf8))
            }
        }
    }
}

/// 使うチューナー。coax のチューナーか、pix-userland の PIX-DT295 か
enum TunerKind: String {
    case coax
    case pix
}

/// チューナーのデバイスの状態
enum DeviceState: Equatable {
    case checking
    /// 見つかったデバイスの名前（複数なら並べる）
    case found(String)
    /// 見つからない、または開けない。理由を添える
    case missing(String)

    /// `coax list --tuners --json` の出力から。開けたデバイスだけを数える
    /// （tuners は開けなくても型番から埋まるので、probe_error が無いことで見る）
    init(json: Data, error: String) {
        let boards = (try? JSONSerialization.jsonObject(with: json)) as? [[String: Any]] ?? []
        let names = boards
            .filter { $0["probe_error"] == nil && !($0["tuners"] as? [Any] ?? []).isEmpty }
            .compactMap { $0["description"] as? String ?? $0["name"] as? String }
        if !names.isEmpty {
            self = .found(names.joined(separator: "、"))
        } else if let problem = boards.compactMap({ $0["probe_error"] as? String }).first {
            self = .missing("デバイスを開けません: \(problem)")
        } else {
            self = .missing(error.isEmpty ? "デバイスが見つかりません" : "デバイスが見つかりません: \(error)")
        }
    }
}

/// 番組の詳細。coax の `--program` の番組の行と、それに続く説明（-text）と詳しい説明の項目（-item）の行から作る
struct ProgramDetail: Equatable {
    /// 「開始-終了 番組名」
    let program: String
    var text = ""
    var items: [Item] = []

    struct Item: Equatable, Identifiable {
        let id: Int
        let heading: String
        let value: String
    }

    /// 開始-終了
    var span: String { program.split(separator: " ", maxSplits: 1).first.map(String.init) ?? "" }
    var title: String { program.split(separator: " ", maxSplits: 1).dropFirst().first.map(String.init) ?? program }

    /// 「見出し<TAB>内容」の行を足す
    mutating func append(item line: String) {
        let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
        items.append(Item(id: items.count, heading: Self.unescape(String(parts[0])),
                          value: parts.count > 1 ? Self.unescape(String(parts[1])) : ""))
    }

    /// coax が 1 行に収めるために書いた「\n」「\t」「\\」を元に戻す
    static func unescape(_ text: String) -> String {
        var result = ""
        var escaping = false
        for c in text {
            if escaping {
                result.append(c == "n" ? "\n" : c == "t" ? "\t" : c)
                escaping = false
            } else if c == "\\" {
                escaping = true
            } else {
                result.append(c)
            }
        }
        return result
    }
}
