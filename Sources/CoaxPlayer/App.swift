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
                    VideoView(layer: model.player.layer)
                        .opacity(model.playing == nil ? 0 : 1)
                    if model.playing == nil {
                        Text("チャンネルを選んでください")
                            .foregroundStyle(Color.placeholder)
                    }
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(model.playing ?? "")
                    if let now = model.nowProgram {
                        Text("今　\(now)").lineLimit(1).truncationMode(.tail)
                    }
                    if let next = model.nextProgram {
                        Text("次　\(next)").lineLimit(1).truncationMode(.tail)
                            .foregroundStyle(Color.placeholder)
                    }
                    Text(model.status)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
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

/// 一覧と停止のボタン。押されているチャンネルは青く、カーソルが乗ると明るくする
struct ListButton: View {
    let label: String
    let active: Bool
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
            .background(hovering ? Color.buttonHover : active ? Color.buttonActive : Color.button)
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
