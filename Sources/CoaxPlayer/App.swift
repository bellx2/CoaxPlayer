import AppKit
import SwiftUI

@main
struct CoaxPlayerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("coax", id: "main") {
            ContentView(model: delegate.model)
        }
        .defaultSize(width: 960, height: 600)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor lazy var model = PlayerModel(config: Config.parse(CommandLine.arguments))
    private var signalSources: [DispatchSourceSignal] = []

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

/// 左にチャンネル一覧と停止、右に映像、その下に再生中のものと受信状態。coax-gpui と同じ配置
struct ContentView: View {
    @ObservedObject var model: PlayerModel

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if model.channels.isEmpty {
                        // 一覧が無いときは、範囲を選んでスキャンする
                        Text("スキャンする範囲")
                            .foregroundStyle(Color.placeholder)
                        ForEach(ScanRange.all.indices, id: \.self) { index in
                            ListButton(label: ScanRange.all[index].label, active: model.ranges[index]) {
                                if !model.scanning { model.ranges[index].toggle() }
                            }
                        }
                        Spacer().frame(height: 8)
                        if model.scanning {
                            ListButton(label: "スキャン中止", active: false) { model.cancelScan() }
                        } else {
                            ListButton(label: "スキャン開始", active: false) { model.startScan() }
                        }
                    } else {
                        ForEach(model.channels) { channel in
                            ListButton(
                                label: channel.name,
                                active: model.playingChannel == channel.channel,
                                number: channel.number,
                                badge: channel.logo
                            ) { model.play(channel) }
                        }
                        Spacer().frame(height: 8)
                        ListButton(label: "停止", active: false) { model.stop() }
                        if model.playingChannel != nil {
                            ListButton(label: model.recording == nil ? "録画" : "録画停止",
                                       active: model.recording != nil, activeColor: .recording) {
                                model.toggleRecording()
                            }
                        }
                        ListButton(label: "字幕", active: model.subtitles) { model.toggleSubtitles() }
                        ListButton(label: "ワンセグ", active: model.oneSeg) { model.toggleOneSeg() }
                        ListButton(label: "情報", active: model.pinsInfo) { model.toggleInfo() }
                    }
                }
                .padding(8)
            }
            .frame(width: 200)
            .background(Color.panel)

            VStack(spacing: 0) {
                ZStack {
                    Color.black
                    // レイヤは止めても最後のフレームを持っているので、止まっているときは隠す
                    VideoArea(model: model)
                        .opacity(model.playing == nil ? 0 : 1)
                    if model.playing == nil {
                        Text("チャンネルを選んでください")
                            .foregroundStyle(Color.placeholder)
                    }
                }
                // 受信状態などの行。チャンネルと番組名は映像の左上に出す
                Text(model.status)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.panel)
            }
        }
        .font(.system(size: 14))
        .foregroundStyle(Color.text)
        .background(Color.black)
        .frame(minWidth: 480, minHeight: 300)
    }
}

/// 映像と字幕。映像は縦横比を保って領域の中央に置き、字幕は映像の表示領域の実ピクセル数で描いたものを重ねる
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
                if model.showsInfo || model.pinsInfo, let playing = model.playing {
                    OverlayView(content: ChannelInfo(channel: playing, program: model.nowTitle))
                        .fixedSize()
                        .offset(x: video.minX + 12, y: video.minY + 12)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .task(id: pixels) { model.captionPixelSize = pixels }
        }
    }

    /// 映像を置く位置
    private func videoRect(in size: CGSize) -> CGRect {
        let aspect = model.videoAspect
        let width = min(size.width, size.height * aspect)
        let height = width / aspect
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
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
    /// 名前の前に枠付きで出す短い文字（簡易ロゴ）
    var badge: String? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            if let number {
                Text(number).monospacedDigit()
                    .frame(minWidth: 18, alignment: .trailing)
            }
            if let badge {
                Text(badge)
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 3)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.text.opacity(0.6)))
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

/// 映像の左上に出す、チャンネル（番号と放送局名）と番組名
struct ChannelInfo: View {
    let channel: String
    let program: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(channel).font(.system(size: 18, weight: .semibold))
            if let program {
                Text(program).font(.system(size: 14)).lineLimit(1)
            }
        }
        .foregroundStyle(Color.text)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// SwiftUI の部品を映像の上に重ねる。そのままでは映像の NSView の下に隠れるので、NSView に包む
struct OverlayView<Content: View>: NSViewRepresentable {
    let content: Content

    func makeNSView(context: Context) -> NSHostingView<Content> { NSHostingView(rootView: content) }

    func updateNSView(_ nsView: NSHostingView<Content>, context: Context) { nsView.rootView = content }
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
