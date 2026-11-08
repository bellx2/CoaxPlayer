import AppKit
import SwiftUI

@main
struct CoaxPlayerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("CoaxPlayer", id: "main") {
            ContentView(model: delegate.model)
        }
        .defaultSize(width: 960, height: 600)
        .commands {
            // 「CoaxPlayer について」に作者と GitHub へのリンクを出す
            CommandGroup(replacing: .appInfo) {
                Button("CoaxPlayer について") { showAbout() }
                // 新しい版があるときだけ出す。目立たないよう一覧には出さない
                UpdateMenuItem(updater: delegate.updater)
            }
        }
        Settings {
            SettingsView(model: delegate.model)
        }
    }
}

@MainActor private func showAbout() {
    let url = "https://github.com/bellx2/CoaxPlayer"
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    let credits = NSMutableAttributedString(string: "Bellx2\n", attributes: [
        .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor, .paragraphStyle: style,
    ])
    credits.append(NSAttributedString(string: url, attributes: [
        .font: NSFont.systemFont(ofSize: 11), .link: URL(string: url)!, .paragraphStyle: style,
    ]))
    NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    NSApp.activate(ignoringOtherApps: true)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor lazy var model = PlayerModel(config: Config.parse(CommandLine.arguments))
    @MainActor lazy var updater = Updater()
    private var signalSources: [DispatchSourceSignal] = []
    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // swift run で起動しても Dock に出て前面に来るようにする
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Ctrl-C / SIGTERM でも通常終了の経路を通し、子プロセスを止める
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { NSApp.terminate(nil) }
            src.resume()
            signalSources.append(src)
        }

        // 数字キー（テンキーも）で選局し、上下の矢印で音量を、左右の矢印でチャンネルを変え、
        // M でミュートを、I で番組詳細を、G で番組表を切り替える。
        // メインのウィンドウで修飾キーなしのときだけ
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window?.title == "CoaxPlayer",
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return event }
            if event.keyCode == 126 || event.keyCode == 125 {  // 上・下の矢印で音量を 5 ずつ変える
                let step: Double = event.keyCode == 126 ? 5 : -5
                let handled = MainActor.assumeIsolated {
                    guard self.model.playing != nil else { return false }
                    self.model.volume = min(100, max(0, self.model.volume + step))
                    return true
                }
                return handled ? nil : event
            }
            if event.keyCode == 123 || event.keyCode == 124 {  // 左・右の矢印で前・次のチャンネルへ
                let offset = event.keyCode == 124 ? 1 : -1
                let handled = MainActor.assumeIsolated {
                    guard self.model.current != nil else { return false }
                    self.model.switchChannel(by: offset)
                    return true
                }
                return handled ? nil : event
            }
            guard let key = event.charactersIgnoringModifiers, key.count == 1 else { return event }
            if key.lowercased() == "m" {
                let handled = MainActor.assumeIsolated {
                    guard self.model.playing != nil else { return false }
                    self.model.toggleMute()
                    return true
                }
                return handled ? nil : event
            }
            if key.lowercased() == "i" {
                let handled = MainActor.assumeIsolated {
                    guard self.model.playingChannel != nil else { return false }
                    self.model.showsDetail.toggle()
                    return true
                }
                return handled ? nil : event
            }
            if key.lowercased() == "g" {
                let handled = MainActor.assumeIsolated {
                    guard !self.model.channels.isEmpty else { return false }
                    self.model.showsGuide.toggle()
                    return true
                }
                return handled ? nil : event
            }
            guard let digit = key.first, digit.isASCII, digit.isNumber else { return event }
            MainActor.assumeIsolated { self.model.typeDigit(digit) }
            return nil
        }

        MainActor.assumeIsolated {
            model.startFromArguments()
            updater.check()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { model.shutdown() }
    }
}

// coax-gpui と同じ配色
extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double(hex >> 16 & 0xff) / 255,
            green: Double(hex >> 8 & 0xff) / 255,
            blue: Double(hex & 0xff) / 255)
    }
    static let panel = Color(hex: 0x1c1c1c)
    static let button = Color(hex: 0x2a2a2a)
    static let buttonHover = Color(hex: 0x3a3a3a)
    static let text = Color(hex: 0xe0e0e0)
    static let placeholder = Color(hex: 0x808080)
    static let logoPlaceholder = Color(hex: 0x4a4a4a)
    static let recording = Color(hex: 0xb03030)
    /// 番組表の放送中の番組
    static let onAir = Color(hex: 0x23394d)
    /// 番組表で、見ている局の局名
    static let watching = Color(hex: 0x4a90d9)
}

/// 視聴画面だけの 1 ページ。下に受信状態の行
struct ContentView: View {
    @ObservedObject var model: PlayerModel

    var body: some View {
        VStack(spacing: 0) {
            PlayerPage(model: model)
            // 受信状態などの行
            // 受信状態の詳細は、設定画面で選んだときだけ出す
            Text(model.showsReception && model.playing != nil ? model.reception ?? model.status : model.status)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.panel)
        }
        .font(.system(size: 14))
        .foregroundStyle(Color.text)
        .background(Color.black)
        .frame(minWidth: 480, minHeight: 300)
    }
}

/// アプリのメニューの更新の項目。新しい版があるときだけ出す。押すと更新する（Homebrew で入れていなければ Release のページを開く）
struct UpdateMenuItem: View {
    @ObservedObject var updater: Updater

    var body: some View {
        switch updater.state {
        case .idle:
            EmptyView()
        case .available(let version):
            Button("新しい版 \(version) に更新…") { updater.update() }
        case .updating:
            Button("更新中…") {}
                .disabled(true)
        case .failed(let reason):
            // 失敗したら Release のページから入れてもらう。理由はメニューに出せないので項目名に含める
            Button("更新に失敗しました（Release を開く）: \(reason)") { NSWorkspace.shared.open(Updater.releasesURL) }
        }
    }
}

/// デバイスの状態。色の点と名前（見つからなければ理由）
struct DeviceStatusView: View {
    let device: DeviceState

    var body: some View {
        let (color, text): (Color, String) = switch device {
        case .checking: (.placeholder, "デバイスを確認中…")
        case .found(let name): (.green, name)
        case .missing(let reason): (.recording, reason)
        }
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .help(text)
    }
}

/// 局ロゴ。まだ受け取っていない局は、同じ大きさの灰色の枠にテレビの印を出す（局名の位置もそろう）
struct StationLogo: View {
    let image: NSImage?

    var body: some View {
        if let image {
            Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
        } else {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.logoPlaceholder)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .overlay {
                    Image(systemName: "tv")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(5)
                        .foregroundStyle(Color.placeholder)
                }
        }
    }
}

/// 視聴画面。上にデバイスの状態と再生の操作、その下に映像。局は番組表の局名か数字キー・左右の矢印で選ぶ
struct PlayerPage: View {
    @ObservedObject var model: PlayerModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                // デバイスの状態と、見えないときに確かめ直すボタン
                DeviceStatusView(device: model.device)
                IconButton(symbol: "arrow.clockwise", help: "デバイスを再スキャン", active: false) {
                    model.checkDevices()
                }
                .disabled(model.device == .checking || model.scanning)
                IconButton(symbol: "power", help: "coax を再起動", active: false) {
                    model.restartCoax()
                }
                .disabled(model.device == .checking || model.scanning)
                Spacer()
                if !model.channels.isEmpty {
                    IconButton(symbol: "calendar", help: "番組表（G）", active: model.showsGuide) { model.showsGuide.toggle() }
                }
                if model.playingChannel != nil {
                    IconButton(symbol: model.showsDetail ? "info.circle.fill" : "info.circle",
                               help: "番組詳細（I）", active: model.showsDetail) { model.showsDetail.toggle() }
                    IconButton(symbol: model.recording == nil ? "record.circle" : "record.circle.fill",
                               help: model.recording == nil ? "録画" : "録画停止",
                               active: model.recording != nil, activeColor: .recording) {
                        model.toggleRecording()
                    }
                }
                IconButton(symbol: model.subtitles ? "captions.bubble.fill" : "captions.bubble",
                           help: "字幕", active: model.subtitles) { model.toggleSubtitles() }
                // 音量。ミュート（M でも切り替える）と、0〜100 のスライダー
                IconButton(symbol: model.muted ? "speaker.slash.fill" : "speaker.wave.2",
                           help: model.muted ? "ミュート解除（M）" : "ミュート（M）", active: model.muted) { model.toggleMute() }
                Slider(value: $model.volume, in: 0...100)
                    .frame(width: 90)
                    .controlSize(.small)
                    .help("音量（上下の矢印）")
                IconButton(symbol: "", title: model.dualMono.label,
                           help: "音声（主・副・主副）", active: model.dualMono != .main) { model.cycleDualMono() }
                // デコーダーを通していないときはワンセグしか見られないので、点けたままにして押せなくする
                let oneSeg = model.oneSeg || model.oneSegOnly
                IconButton(symbol: oneSeg ? "1.square.fill" : "1.square",
                           help: model.oneSegOnly ? "ワンセグ（フルセグには外部デコーダーとカードが要る）" : "ワンセグ",
                           active: oneSeg) { model.toggleOneSeg() }
                    .disabled(model.oneSegOnly)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.panel)
            VideoArea(model: model)
                // 番組表か番組詳細を出しているときに映像を押したら、どちらも閉じる。
                // 番組詳細と番組表はこの上に重ねるので、それらの中を押しても閉じない
                .overlay {
                    if model.showsGuide || (model.showsDetail && model.playingChannel != nil) {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture {
                                model.showsGuide = false
                                model.showsDetail = false
                            }
                    }
                }
                // 映像の右に重ねる。ファイルの再生には番組情報が無いので、チャンネルを見ているときだけ出す
                .overlay(alignment: .trailing) {
                    if model.showsDetail && model.playingChannel != nil {
                        ProgramPanel(detail: model.nowDetail)
                            .frame(width: 320)
                    }
                }
                // チャンネル一覧が無いときは、設定画面でスキャンしてもらう
                .overlay {
                    if model.channels.isEmpty {
                        VStack(spacing: 12) {
                            Text("チャンネル一覧がありません")
                                .foregroundStyle(Color.placeholder)
                            OpenSettingsButton(label: "設定を開いてスキャン")
                                .fixedSize()
                        }
                    }
                }
                // 番組表は映像の下半分に半透明で重ねる
                .overlay(alignment: .bottom) {
                    if model.showsGuide && !model.channels.isEmpty {
                        GeometryReader { geometry in
                            GuidePage(model: model, guide: model.guide)
                                .frame(height: geometry.size.height / 2)
                                .frame(maxHeight: .infinity, alignment: .bottom)
                        }
                    }
                }
        }
    }
}

/// 今の番組の詳細。映像の右に重ねて出す。番組情報（EIT）の説明と、届いていれば詳しい説明の項目を出す
struct ProgramPanel: View {
    let detail: ProgramDetail?

    var body: some View {
        ScrollView {
            content
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        // 映像に重ねるので、下の映像が少し透けるようにする
        .background(Color.panel.opacity(0.85))
        .foregroundStyle(Color.text)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let detail {
                Text(detail.span).font(.system(size: 12)).foregroundStyle(Color.placeholder)
                Text(detail.title).font(.system(size: 15, weight: .semibold))
                if !detail.text.isEmpty {
                    Text(Self.linked(detail.text)).font(.system(size: 13))
                }
                ForEach(detail.items) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.heading).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.placeholder)
                        Text(Self.linked(item.value)).font(.system(size: 13))
                    }
                }
            } else {
                Text("番組情報を待っています").font(.system(size: 13)).foregroundStyle(Color.placeholder)
            }
        }
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// 文中の http・https の URL をリンクにする。放送では URL が全角で来ることがあるので、
    /// 全角の英数字と記号を半角に直した写しで探し、見た目は元の文字のままリンクを付ける
    static func linked(_ text: String) -> AttributedString {
        // 全角の ASCII（U+FF01〜FF5E）だけを半角に直す。UTF-16 の長さが変わらないので、見つけた位置をそのまま元の文に使える
        let folded = String(decoding: text.utf16.map { (0xff01...0xff5e).contains($0) ? $0 - 0xfee0 : $0 }, as: UTF16.self)
        var result = AttributedString(text)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return result }
        for match in detector.matches(in: folded, range: NSRange(location: 0, length: (folded as NSString).length)) {
            guard let url = match.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  let range = Range(match.range, in: text), let attributed = Range(range, in: result) else { continue }
            result[attributed].link = url
        }
        return result
    }
}

/// 映像と字幕。映像は縦横比を保って領域の上に寄せ（左右は中央）、字幕は映像の表示領域の実ピクセル数で描いたものを重ねる。
/// 映像のすぐ下に、見ているチャンネルと今の番組を出す
struct VideoArea: View {
    @ObservedObject var model: PlayerModel
    @Environment(\.displayScale) private var scale

    var body: some View {
        GeometryReader { geometry in
            let showsInfo = showsInfo(in: geometry.size)
            let video = videoRect(in: geometry.size, info: showsInfo)
            let pixels = CGSize(width: (video.width * scale).rounded(), height: (video.height * scale).rounded())
            ZStack(alignment: .topLeading) {
                VideoView(layer: model.player.layer)
                    .frame(width: video.width, height: video.height)
                    .offset(x: video.minX, y: video.minY)
                if model.subtitles, let caption = model.caption {
                    let rect = captionRect(caption, video: video)
                    CaptionView(image: caption.image)
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                }
                if showsInfo, let playing = model.playing {
                    // 「開始-終了 番組名」
                    HStack(spacing: 12) {
                        // チャンネルは「局ロゴ 局名」。ファイルの再生ではファイル名
                        if let channel = model.current {
                            HStack(spacing: 8) {
                                StationLogo(image: model.logos[channel.channel])
                                    .frame(width: 53, height: 30)
                                Text(channel.name)
                            }
                            .font(.system(size: 22, weight: .semibold))
                        } else {
                            Text(playing).font(.system(size: 22, weight: .semibold))
                        }
                        Text(model.nowProgram ?? "").font(.system(size: 19)).lineLimit(1).truncationMode(.tail)
                    }
                    .padding(.horizontal, 8)
                    .frame(width: video.width, height: Self.infoHeight, alignment: .leading)
                    .offset(x: video.minX, y: video.maxY)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .task(id: pixels) { model.captionPixelSize = pixels }
        }
    }

    /// 映像の下のチャンネルと番組の行の高さ
    private static let infoHeight: CGFloat = 46
    /// 映像の幅がこれより狭くなるときは、チャンネルと番組の行を出さずに映像を大きくする
    private static let infoMinWidth: CGFloat = 560

    private func showsInfo(in size: CGSize) -> Bool {
        videoRect(in: size, info: true).width >= Self.infoMinWidth
    }

    /// 映像を置く位置。余白は下と左右に出す。行を出すときは、下にその分を空けておく
    private func videoRect(in size: CGSize, info: Bool) -> CGRect {
        let aspect = model.videoAspect
        let width = min(size.width, max(0, size.height - (info ? Self.infoHeight : 0)) * aspect)
        let height = width / aspect
        return CGRect(x: (size.width - width) / 2, y: 0, width: width, height: height)
    }

    /// 字幕を置く位置。描いた枠（ピクセル）を映像の表示領域（ポイント）に合わせる
    private func captionRect(_ caption: CaptionImage, video: CGRect) -> CGRect {
        let sx = video.width / caption.frame.width
        let sy = video.height / caption.frame.height
        return CGRect(x: video.minX + caption.rect.minX * sx, y: video.minY + caption.rect.minY * sy,
                      width: caption.rect.width * sx, height: caption.rect.height * sy)
    }
}

/// 上に並べるアイコンのボタン。背景は出さず、オンの状態は塗りのアイコン（symbol を呼び出し側で .fill に替える）と色で示す。
/// 名前はカーソルを乗せると出す
struct IconButton: View {
    let symbol: String
    /// アイコンの代わりに出す短い文字。SF Symbols の「1.square」と同じく、オフは枠で囲み、オンは塗った四角に抜く
    var title: String? = nil
    let help: String
    let active: Bool
    /// active のときのアイコンの色
    var activeColor: Color = .white
    /// 処理中はアイコンを回す（1 秒で 1 回転）
    var spinning = false
    let action: () -> Void
    @State private var hovering = false
    /// 回し始めた時刻。処理がすぐ終わっても見えるよう、終わったあとも 1 回転の切れ目まで回してから nil に戻す
    @State private var spinStart: Date?

    var body: some View {
        Button(action: action) {
            Group {
                if let title {
                    titleGlyph(title)
                } else {
                    // symbolEffect は macOS 14 以降なので、TimelineView で角度を変えて回す
                    TimelineView(.animation(paused: spinStart == nil)) { context in
                        let elapsed = spinStart.map { context.date.timeIntervalSince($0) } ?? 0
                        Image(systemName: symbol).font(.system(size: 16))
                            .rotationEffect(.degrees(elapsed * 360))
                    }
                    .task(id: spinning) {
                        if spinning {
                            if spinStart == nil { spinStart = Date() }
                        } else if let start = spinStart {
                            let elapsed = Date().timeIntervalSince(start)
                            try? await Task.sleep(for: .seconds(max(1, elapsed.rounded(.up)) - elapsed))
                            if !Task.isCancelled { spinStart = nil }
                        }
                    }
                }
            }
            .foregroundStyle(active ? activeColor : Color.text)
            .frame(minWidth: 28, minHeight: 26)
            .background(hovering ? Color.buttonHover : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }

    @ViewBuilder
    private func titleGlyph(_ title: String) -> some View {
        let shape = RoundedRectangle(cornerRadius: 3)
        let text = Text(title)
            .font(.system(size: 11, weight: .bold))
            .padding(.horizontal, 2)
            .frame(minWidth: 18, minHeight: 18)
        if active {
            text.foregroundStyle(Color.panel).background(shape.fill(activeColor))
        } else {
            text.overlay(shape.stroke(lineWidth: 1.5))
        }
    }
}

/// MPVPlayer のレイヤを backing layer として使う NSView。
/// layer-backed にしておくと、レイヤの大きさは AppKit がビューに合わせてくれる
final class LayerView: NSView {
    private let videoLayer: CALayer

    init(layer: CALayer) {
        videoLayer = layer
        super.init(frame: .zero)
        wantsLayer = true
        // 裏のレイヤーの contentsGravity は AppKit がこれで上書きする（既定は縦横を別々に伸ばす）。
        // 縦横比を保ったまま収める
        layerContentsPlacement = .scaleProportionallyToFit
    }

    required init?(coder: NSCoder) { fatalError() }

    override func makeBackingLayer() -> CALayer { videoLayer }
}

struct VideoView: NSViewRepresentable {
    let layer: CALayer

    func makeNSView(context: Context) -> LayerView { LayerView(layer: layer) }

    func updateNSView(_ nsView: LayerView, context: Context) {}
}

/// 字幕の画像を貼る。SwiftUI の Image だと映像の NSView の下に隠れるので、字幕もレイヤーに貼る
struct CaptionView: NSViewRepresentable {
    let image: CGImage

    func makeNSView(context: Context) -> LayerView { LayerView(layer: CALayer()) }

    func updateNSView(_ nsView: LayerView, context: Context) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        nsView.layer?.contents = image
        CATransaction.commit()
    }
}

/// 設定画面（⌘,）。チャンネルのスキャンを置く
struct SettingsView: View {
    @ObservedObject var model: PlayerModel

    var body: some View {
        Form {
            Section("チューナー") {
                Picker("使うチューナー", selection: $model.tunerKind) {
                    Text("coax").tag(TunerKind.coax)
                    Text("PIX-DT295（pix-userland）").tag(TunerKind.pix)
                }
                if model.tunerKind == .pix {
                    LabeledContent("ファームウェア") {
                        Text(model.pixFirmware.isEmpty ? "未設定" : model.pixFirmware)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    Button("dt295.bin を選ぶ…") { choosePixFirmware() }
                    Text("PIX-DT295 のファームウェア（pix-userland の firmware/dt295.bin）。メーカー由来で再配布が制限されるので、このアプリには含まれない。チャンネルスキャンも PIX-DT295 で行う（地上 UHF だけ）。選局してから映るまで 2〜3 秒かかる")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("チャンネルスキャン") {
                ForEach(ScanRange.all.indices, id: \.self) { index in
                    Toggle(ScanRange.all[index].label, isOn: $model.ranges[index])
                        .disabled(model.scanning)
                }
                HStack {
                    if model.scanning {
                        Button("中止") { model.cancelScan() }
                        ProgressView().controlSize(.small)
                    } else {
                        Button("スキャン開始") { model.startScan() }
                    }
                    Text(model.scanStatus)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(.secondary)
                }
                Text("今の一覧: \(model.channels.count) チャンネル。スキャン中は再生を止め、終わると一覧を作り直す")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("デバッグ") {
                Toggle("画面下に受信状態の詳細を表示", isOn: $model.showsReception)
                Text("CNR、信号の強さ、ビットレート、エラー数など")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("外部デコーダー") {
                LabeledContent("デコーダー") {
                    Text(model.decoderPath ?? "なし")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                HStack {
                    Button("選ぶ…") { chooseDecoder() }
                    Button("自動に戻す") { model.decoderSetting = "" }
                        .disabled(model.decoderSetting.isEmpty)
                }
                .disabled(model.config.decoderPath != nil)
                Text(model.config.decoderPath != nil
                     ? "起動引数の --decoder を使っている"
                     : "選局した TS を通すコマンド。選ばなければ、Homebrew で入れた \(PlayerModel.homebrewDecoderPath) があれば使う。次の選局から使う")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("録画の変換") {
                TextField("ffmpeg の引数", text: $model.convertArguments, prompt: Text("空なら TS のまま"), axis: .vertical)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(2...4)
                HStack {
                    Button("例を入れる") { model.convertArguments = PlayerModel.convertExample }
                    Button("消す") { model.convertArguments = "" }
                        .disabled(model.convertArguments.isEmpty)
                }
                Text("録画を止めたあと、同梱の ffmpeg にこの引数を渡す。{in} は TS、{out} は拡張子を除いたパス、{video}・{audio} は再生していた映像と音声。例は主音声だけの MP4 を作る")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
    }

    private func choosePixFirmware() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.pixFirmware = url.path
    }

    private func chooseDecoder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.decoderSetting = url.path
    }
}

/// 設定画面を開くボタン。macOS 14 からは SettingsLink でしか開けない
struct OpenSettingsButton: View {
    let label: String

    var body: some View {
        if #available(macOS 14, *) {
            SettingsLink { Text(label).frame(maxWidth: .infinity, alignment: .leading) }
        } else {
            Button(label) { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
        }
    }
}
