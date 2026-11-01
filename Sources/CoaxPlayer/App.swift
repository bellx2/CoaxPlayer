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

        // 数字キー（テンキーも）で選局し、映像のページでは delete で一覧に戻る。メインのウィンドウで修飾キーなしのときだけ
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window?.title == "CoaxPlayer",
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return event }
            if event.keyCode == 51 {  // delete
                let handled = MainActor.assumeIsolated {
                    guard self.model.playing != nil else { return false }
                    self.model.backToList()
                    return true
                }
                return handled ? nil : event
            }
            guard let key = event.charactersIgnoringModifiers, key.count == 1,
                  let digit = key.first, digit.isASCII, digit.isNumber else { return event }
            MainActor.assumeIsolated { self.model.typeDigit(digit) }
            return nil
        }

        MainActor.assumeIsolated { model.startFromArguments() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { model.shutdown() }
    }
}

// coax-gpui と同じ配色
private extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double(hex >> 16 & 0xff) / 255,
            green: Double(hex >> 8 & 0xff) / 255,
            blue: Double(hex & 0xff) / 255)
    }
    static let panel = Color(hex: 0x1c1c1c)
    static let button = Color(hex: 0x2a2a2a)
    static let buttonHover = Color(hex: 0x3a3a3a)
    static let buttonActive = Color(hex: 0x2f5f9f)
    static let text = Color(hex: 0xe0e0e0)
    static let placeholder = Color(hex: 0x808080)
    static let recording = Color(hex: 0xb03030)
}

/// 1 ページ目はチャンネル一覧、選ぶと映像のページに切り替わる。下に受信状態の行
struct ContentView: View {
    @ObservedObject var model: PlayerModel

    var body: some View {
        VStack(spacing: 0) {
            if model.playing == nil {
                ChannelListPage(model: model)
            } else {
                PlayerPage(model: model)
            }
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

/// チャンネル一覧。番号、局ロゴ（受け取ったことがあれば）、局名、今の番組のカードを 2 列に並べる
struct ChannelListPage: View {
    @ObservedObject var model: PlayerModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                DeviceStatusView(device: model.device)
                IconButton(symbol: "arrow.clockwise", help: "デバイスを再スキャン", active: false) {
                    model.checkDevices()
                }
                IconButton(symbol: "power", help: "coax を再起動", active: false) {
                    model.restartCoax()
                }
                Spacer()
                if !model.channels.isEmpty {
                    ListButton(label: model.refreshing ? "番組情報を取得中…" : "番組情報を更新", active: model.refreshing) {
                        model.refreshPrograms()
                    }
                    .fixedSize()
                }
            }
            .disabled(model.device == .checking || model.scanning)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            if model.channels.isEmpty {
                // 一覧が無いときは、設定画面でスキャンしてもらう
                VStack(spacing: 12) {
                    Text("チャンネル一覧がありません")
                        .foregroundStyle(Color.placeholder)
                    OpenSettingsButton(label: "設定を開いてスキャン")
                        .fixedSize()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                        ForEach(model.channels) { channel in
                            ChannelCard(channel: channel, logo: model.logos[channel.channel],
                                        program: model.programs[channel.channel]) { model.play(channel) }
                        }
                    }
                    .padding(16)
                }
            }
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

struct ChannelCard: View {
    let channel: Channel
    let logo: NSImage?
    /// 今の番組（「開始-終了 番組名」）。まだ取っていなければ nil
    let program: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(channel.number)
                .font(.system(size: 26, weight: .semibold))
                .monospacedDigit()
                .frame(minWidth: 34, alignment: .trailing)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    // ロゴがまだ無い局も、局名の位置をそろえる
                    Group {
                        if let logo {
                            Image(nsImage: logo).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                        } else {
                            Color.clear
                        }
                    }
                    .frame(width: 48, height: 27)
                    Text(channel.name)
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(1)
                }
                // 番組がまだ無いときも高さをそろえる
                Text(program ?? " ")
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(hovering ? Color.buttonHover : Color.button)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
    }
}

/// 映像のページ。上に一覧へ戻るボタンと再生中の操作、その下に映像
struct PlayerPage: View {
    @ObservedObject var model: PlayerModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                // 一覧に戻る（Esc と delete でも戻る）
                Button {
                    model.backToList()
                } label: {
                    Label("チャンネル一覧", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                Spacer()
                if model.playingChannel != nil {
                    IconButton(symbol: model.recording == nil ? "record.circle" : "record.circle.fill",
                               help: model.recording == nil ? "録画" : "録画停止",
                               active: model.recording != nil, activeColor: .recording) {
                        model.toggleRecording()
                    }
                }
                IconButton(symbol: model.subtitles ? "captions.bubble.fill" : "captions.bubble",
                           help: "字幕", active: model.subtitles) { model.toggleSubtitles() }
                IconButton(symbol: "", title: model.dualMono.label,
                           help: "音声（主・副・主副）", active: model.dualMono != .main) { model.cycleDualMono() }
                IconButton(symbol: model.oneSeg ? "1.square.fill" : "1.square",
                           help: "ワンセグ", active: model.oneSeg) { model.toggleOneSeg() }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.panel)
            VideoArea(model: model)
        }
    }
}

/// 映像と字幕。映像は縦横比を保って領域の上に寄せ（左右は中央）、字幕は映像の表示領域の実ピクセル数で描いたものを重ねる。
/// 映像のすぐ下に、見ているチャンネルと今の番組を出す
struct VideoArea: View {
    @ObservedObject var model: PlayerModel
    @Environment(\.displayScale) private var scale

    var body: some View {
        GeometryReader { geometry in
            let video = videoRect(in: geometry.size)
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
                if let playing = model.playing {
                    // 「開始-終了 番組名」
                    HStack(spacing: 12) {
                        // チャンネルは「局ロゴ 局名」。ファイルの再生ではファイル名
                        if let channel = model.current {
                            HStack(spacing: 8) {
                                if let logo = model.logos[channel.channel] {
                                    Image(nsImage: logo).resizable().interpolation(.high)
                                        .aspectRatio(contentMode: .fit).frame(height: 30)
                                }
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

    /// 映像を置く位置。余白は下と左右に出す。下にはチャンネルと番組の行の分を空けておく
    private func videoRect(in size: CGSize) -> CGRect {
        let aspect = model.videoAspect
        let width = min(size.width, max(0, size.height - Self.infoHeight) * aspect)
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

/// 一覧と停止のボタン。押されているチャンネルは青く、カーソルが乗ると明るくする
struct ListButton: View {
    let label: String
    let active: Bool
    /// active のときの背景色
    var activeColor: Color = .buttonActive
    /// 先頭に出す番号（リモコンの番号）
    var number: String? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            if let number {
                Text(number).monospacedDigit()
                    .frame(minWidth: 18, alignment: .trailing)
            }
            Text(label)
                .lineLimit(1)
        }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(hovering ? Color.buttonHover : active ? activeColor : Color.button)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture(perform: action)
    }
}

/// 映像のページの上のアイコンのボタン。名前はカーソルを乗せると出す
struct IconButton: View {
    let symbol: String
    /// アイコンの代わりに出す短い文字
    var title: String? = nil
    let help: String
    let active: Bool
    /// active のときの背景色
    var activeColor: Color = .buttonActive
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Group {
                if let title {
                    Text(title).font(.system(size: 13, weight: .semibold))
                } else {
                    Image(systemName: symbol).font(.system(size: 16))
                }
            }
            .frame(minWidth: 32, minHeight: 26)
            .padding(.horizontal, title == nil ? 0 : 4)
            .background(hovering ? Color.buttonHover : active ? activeColor : Color.button)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
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
        }
        .formStyle(.grouped)
        .frame(width: 480)
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
