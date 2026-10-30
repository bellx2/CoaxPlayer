import AppKit
import CMpv
import Foundation

/// libmpv をソフトウェアレンダラで動かし、フレームを CALayer に貼る。
final class MPVPlayer {
    /// 映像を表示するレイヤ。NSView の layer としてそのまま使う
    let layer = CALayer()

    private var mpv: OpaquePointer?
    private var renderContext: OpaquePointer?
    private let renderQueue = DispatchQueue(label: "mpv.render")
    private let debug: Bool
    private let eventLoopDone = DispatchSemaphore(value: 0)

    // 以下は renderQueue 上でのみ触る
    private var buffer: [UInt8] = []
    private(set) var renderCount = 0
    private var luma = 0

    /// 再生の終了（EOF・エラー・stop）を通知する。メインスレッドで呼ぶ
    var onEndFile: ((String) -> Void)?

    init(debug: Bool) {
        self.debug = debug
        layer.backgroundColor = NSColor.black.cgColor
        layer.contentsGravity = .resizeAspect

        mpv = mpv_create()
        guard let mpv else { fatalError("mpv_create に失敗") }

        // ワンセグは低ビットレートなので、既定のプローブ量では表示まで非常に時間がかかる。
        // プローブを小さくし、キャッシュを切って低遅延で再生する。
        let options: [(String, String)] = [
            ("vo", "libmpv"),
            ("hwdec", "no"),
            ("profile", "low-latency"),
            ("cache", "no"),
            ("demuxer-lavf-probesize", "200000"),
            ("demuxer-lavf-analyzeduration", "0.5"),
            ("demuxer-readahead-secs", "0"),
            ("keep-open", "no"),
            ("idle", "yes"),
            ("terminal", "no"),
            ("input-default-bindings", "no"),
        ]
        for (name, value) in options {
            let r = mpv_set_option_string(mpv, name, value)
            if r < 0 { log("オプション設定失敗 \(name)=\(value): \(String(cString: mpv_error_string(r)))") }
        }
        if debug { mpv_request_log_messages(mpv, "info") }
        check(mpv_initialize(mpv), "mpv_initialize")

        // ソフトウェアレンダラの描画コンテキストを作る
        var apiType = Array(MPV_RENDER_API_TYPE_SW.utf8CString)
        apiType.withUnsafeMutableBufferPointer { api in
            var params = [
                mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(api.baseAddress)),
                mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
            ]
            check(mpv_render_context_create(&renderContext, mpv, &params), "mpv_render_context_create")
        }
        mpv_render_context_set_update_callback(renderContext, { ctx in
            // mpv のスレッドから呼ばれる。ここでは描画せず、描画用キューへ回す
            let player = Unmanaged<MPVPlayer>.fromOpaque(ctx!).takeUnretainedValue()
            player.renderQueue.async { player.renderIfNeeded() }
        }, Unmanaged.passUnretained(self).toOpaque())

        let thread = Thread { [weak self] in self?.eventLoop() }
        thread.name = "mpv.events"
        thread.start()
    }

    /// URL（ファイルパスや fdclose://N）を再生する
    func load(_ url: String) {
        command(["loadfile", url, "replace"])
    }

    func stop() {
        command(["stop"])
    }

    /// 検証用に double のプロパティを読む
    func doubleProperty(_ name: String) -> Double? {
        guard let mpv else { return nil }
        var value = 0.0
        return mpv_get_property(mpv, name, MPV_FORMAT_DOUBLE, &value) >= 0 ? value : nil
    }

    func int64Property(_ name: String) -> Int64? {
        guard let mpv else { return nil }
        var value: Int64 = 0
        return mpv_get_property(mpv, name, MPV_FORMAT_INT64, &value) >= 0 ? value : nil
    }

    var renderedFrames: Int { renderQueue.sync { renderCount } }
    /// 検証用: 直近に描いたフレームの平均輝度（0-255）。真っ黒でないことの確認に使う
    var lastLuma: Int { renderQueue.sync { luma } }

    /// 描画コンテキストと mpv を破棄する。アプリ終了時に一度だけ呼ぶ
    func destroy() {
        renderQueue.sync {
            if let renderContext {
                mpv_render_context_set_update_callback(renderContext, nil, nil)
                mpv_render_context_free(renderContext)
            }
            renderContext = nil
        }
        guard let mpv else { return }
        // quit で SHUTDOWN を受けたイベントスレッドが抜けるのを待ってからハンドルを解放する
        "quit".withCString { q in
            var cargs: [UnsafePointer<CChar>?] = [q, nil]
            _ = mpv_command(mpv, &cargs)
        }
        _ = eventLoopDone.wait(timeout: .now() + 2)
        mpv_terminate_destroy(mpv)
        self.mpv = nil
    }

    // MARK: - 内部

    private func command(_ args: [String]) {
        guard let mpv else { return }
        var cargs: [UnsafePointer<CChar>?] = args.map { UnsafePointer(strdup($0)) }
        cargs.append(nil)
        defer { cargs.forEach { free(UnsafeMutablePointer(mutating: $0)) } }
        check(mpv_command_async(mpv, 0, &cargs), "command \(args.first ?? "")")
    }

    /// renderQueue 上で、新しいフレームがあれば描いてレイヤへ反映する
    private func renderIfNeeded() {
        guard let renderContext, let mpv else { return }
        let flags = mpv_render_context_update(renderContext)
        guard flags & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue) != 0 else { return }

        // 映像の表示サイズ（アスペクト補正後）でそのまま描く。拡大はレイヤに任せる
        var w: Int64 = 0, h: Int64 = 0
        guard mpv_get_property(mpv, "dwidth", MPV_FORMAT_INT64, &w) >= 0,
              mpv_get_property(mpv, "dheight", MPV_FORMAT_INT64, &h) >= 0,
              w > 0, h > 0 else { return }

        var size: [Int32] = [Int32(w), Int32(h)]
        var stride = Int(w) * 4
        if buffer.count != stride * Int(h) { buffer = [UInt8](repeating: 0, count: stride * Int(h)) }
        var format = Array("rgb0".utf8CString)

        let r: Int32 = size.withUnsafeMutableBufferPointer { sizePtr in
            format.withUnsafeMutableBufferPointer { formatPtr in
                buffer.withUnsafeMutableBytes { pixels in
                    withUnsafeMutablePointer(to: &stride) { stridePtr in
                        var params = [
                            mpv_render_param(type: MPV_RENDER_PARAM_SW_SIZE, data: UnsafeMutableRawPointer(sizePtr.baseAddress)),
                            mpv_render_param(type: MPV_RENDER_PARAM_SW_FORMAT, data: UnsafeMutableRawPointer(formatPtr.baseAddress)),
                            mpv_render_param(type: MPV_RENDER_PARAM_SW_STRIDE, data: UnsafeMutableRawPointer(stridePtr)),
                            mpv_render_param(type: MPV_RENDER_PARAM_SW_POINTER, data: pixels.baseAddress),
                            mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
                        ]
                        return mpv_render_context_render(renderContext, &params)
                    }
                }
            }
        }
        guard r >= 0 else {
            log("描画失敗: \(String(cString: mpv_error_string(r)))")
            return
        }
        renderCount += 1
        if debug && renderCount % 15 == 0 { luma = averageLuma() }

        // rgb0 は R,G,B,未使用 の順のバイト列
        guard let provider = CGDataProvider(data: Data(buffer) as CFData),
              let image = CGImage(
                width: Int(w), height: Int(h), bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: stride, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return }
        DispatchQueue.main.async { [layer] in
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.contents = image
            CATransaction.commit()
        }
    }

    private func averageLuma() -> Int {
        var sum = 0
        for i in Swift.stride(from: 0, to: buffer.count, by: 4) {
            sum += (Int(buffer[i]) * 3 + Int(buffer[i + 1]) * 6 + Int(buffer[i + 2])) / 10
        }
        return sum / max(1, buffer.count / 4)
    }

    private func eventLoop() {
        guard let mpv else { return }
        defer { eventLoopDone.signal() }
        while true {
            guard let event = mpv_wait_event(mpv, -1)?.pointee else { continue }
            switch event.event_id {
            case MPV_EVENT_SHUTDOWN:
                return
            case MPV_EVENT_LOG_MESSAGE:
                if let msg = event.data?.assumingMemoryBound(to: mpv_event_log_message.self).pointee {
                    let text = String(cString: msg.text).trimmingCharacters(in: .newlines)
                    log("[\(String(cString: msg.prefix))] \(text)")
                }
            case MPV_EVENT_END_FILE:
                if let end = event.data?.assumingMemoryBound(to: mpv_event_end_file.self).pointee {
                    let reason: String
                    switch end.reason {
                    case MPV_END_FILE_REASON_EOF: reason = "ストリーム終了"
                    case MPV_END_FILE_REASON_STOP: reason = "停止"
                    case MPV_END_FILE_REASON_ERROR: reason = "再生エラー: \(String(cString: mpv_error_string(end.error)))"
                    default: reason = "終了"
                    }
                    if debug { log("end-file: \(reason)") }
                    // replace で次の再生に切り替わったときも STOP が来るので、そのまま通知する
                    DispatchQueue.main.async { [weak self] in self?.onEndFile?(reason) }
                }
            case MPV_EVENT_FILE_LOADED:
                if debug { log("file-loaded") }
            default:
                break
            }
        }
    }

    private func check(_ r: Int32, _ what: String) {
        if r < 0 { log("\(what) 失敗: \(String(cString: mpv_error_string(r)))") }
    }

    private func log(_ s: String) {
        FileHandle.standardError.write(Data("mpv: \(s)\n".utf8))
    }
}
