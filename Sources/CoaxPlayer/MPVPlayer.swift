import AppKit
import CMpv
import CoreVideo
import Foundation

/// libmpv をソフトウェアレンダラで動かし、フレームを CALayer に貼る。
/// 描く先は IOSurface 付きの CVPixelBuffer で、そのままレイヤの contents にする（GPU と共有するのでコピーが要らない）。
final class MPVPlayer {
    /// 映像を表示するレイヤ。NSView の layer としてそのまま使う
    let layer = CALayer()

    private var mpv: OpaquePointer?
    private var renderContext: OpaquePointer?
    private let renderQueue = DispatchQueue(label: "mpv.render")
    private let debug: Bool
    private let eventLoopDone = DispatchSemaphore(value: 0)

    // 以下は renderQueue 上でのみ触る
    /// 描画先。表示中のものに書き込まないよう、3 枚を順に使う
    private var surfaces: [CVPixelBuffer] = []
    private var surfaceIndex = 0
    private(set) var renderCount = 0
    private var luma = 0
    /// 高精細化するか。使えない環境や大きな映像では、オンでも何もしない
    private var enhance = false
    /// 高精細化の処理（macOS 26 以降の Enhancer）。映像の大きさが変わったら作り直す
    private var enhancer: AnyObject?
    /// enhancer を作れなかった大きさ。毎フレーム作り直そうとしないよう覚えておく
    private var enhancerUnsupported: (Int, Int)?
    private var enhancedCount = 0

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
            // CPU での拡大（フルセグの 1440→1920）は既定の lanczos だと重い。表示時に GPU でも拡大するので軽い方式で足りる
            ("sws-scaler", "bilinear"),
            // 二か国語や解説の番組（デュアルモノ）は左に主音声、右に副音声が入っていて、そのままだと両方鳴る。
            // 主音声だけにする。普通のステレオには効かない
            ("ad-lavc-o", "dual_mono_mode=main"),
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
        // 別の映像になるので、ノイズ除去が前の映像のフレームを参照しないよう作り直す
        renderQueue.async { self.enhancer = nil }
        command(["loadfile", url, "replace"])
    }

    /// 高精細化（ノイズ除去と超解像）を使うか
    func setEnhance(_ on: Bool) {
        renderQueue.async {
            self.enhance = on
            self.enhancer = nil
        }
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
    /// 検証用: 高精細化して表示したフレーム数
    var enhancedFrames: Int { renderQueue.sync { enhancedCount } }
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

        guard let surface = nextSurface(width: Int(w), height: Int(h)) else { return }
        CVPixelBufferLockBaseAddress(surface, [])
        var size: [Int32] = [Int32(w), Int32(h)]
        var stride = CVPixelBufferGetBytesPerRow(surface)
        // Mac の標準の並び（B,G,R,A）で描かせ、レイヤ側での並べ替えを避ける。bgra なら A も埋まる
        var format = Array("bgra".utf8CString)
        let pixels = CVPixelBufferGetBaseAddress(surface)

        let r: Int32 = size.withUnsafeMutableBufferPointer { sizePtr in
            format.withUnsafeMutableBufferPointer { formatPtr in
                withUnsafeMutablePointer(to: &stride) { stridePtr in
                    var params = [
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_SIZE, data: UnsafeMutableRawPointer(sizePtr.baseAddress)),
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_FORMAT, data: UnsafeMutableRawPointer(formatPtr.baseAddress)),
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_STRIDE, data: UnsafeMutableRawPointer(stridePtr)),
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_POINTER, data: pixels),
                        mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
                    ]
                    return mpv_render_context_render(renderContext, &params)
                }
            }
        }
        if r >= 0 && debug && renderCount % 15 == 0, let pixels {
            luma = averageLuma(pixels, width: Int(w), height: Int(h), stride: stride)
        }
        CVPixelBufferUnlockBaseAddress(surface, [])
        guard r >= 0 else {
            log("描画失敗: \(String(cString: mpv_error_string(r)))")
            return
        }
        renderCount += 1

        let shown = enhanced(surface, width: Int(w), height: Int(h)) ?? surface
        guard let ioSurface = CVPixelBufferGetIOSurface(shown)?.takeUnretainedValue() else { return }
        DispatchQueue.main.async { [layer] in
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.contents = ioSurface
            CATransaction.commit()
        }
    }

    /// 高精細化した結果。使わない・使えないときは nil で、そのまま表示する
    private func enhanced(_ surface: CVPixelBuffer, width: Int, height: Int) -> CVPixelBuffer? {
        guard enhance, #available(macOS 26.0, *) else { return nil }
        if let current = enhancer as? Enhancer, current.width != width || current.height != height {
            enhancer = nil
        }
        if enhancer == nil {
            if let unsupported = enhancerUnsupported, unsupported == (width, height) { return nil }
            enhancer = Enhancer(width: width, height: height)
            if enhancer == nil {
                enhancerUnsupported = (width, height)
                if debug { log("高精細化は \(width)x\(height) には使えない") }
                return nil
            }
        }
        guard let result = (enhancer as? Enhancer)?.process(surface) else { return nil }
        enhancedCount += 1
        return result
    }

    /// 次に描く CVPixelBuffer。大きさが変わったら作り直す
    private func nextSurface(width: Int, height: Int) -> CVPixelBuffer? {
        if let first = surfaces.first,
           CVPixelBufferGetWidth(first) != width || CVPixelBufferGetHeight(first) != height {
            surfaces = []
        }
        if surfaces.isEmpty {
            let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
            for _ in 0..<3 {
                var buffer: CVPixelBuffer?
                CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer)
                guard let buffer else {
                    log("CVPixelBuffer を作れません (\(width)x\(height))")
                    surfaces = []
                    return nil
                }
                surfaces.append(buffer)
            }
        }
        surfaceIndex = (surfaceIndex + 1) % surfaces.count
        return surfaces[surfaceIndex]
    }

    private func averageLuma(_ pixels: UnsafeMutableRawPointer, width: Int, height: Int, stride: Int) -> Int {
        let bytes = pixels.assumingMemoryBound(to: UInt8.self)
        var sum = 0
        for y in 0..<height {
            let row = bytes + y * stride
            for x in Swift.stride(from: 0, to: width * 4, by: 4) {
                // B,G,R,A の順
                sum += (Int(row[x + 2]) * 3 + Int(row[x + 1]) * 6 + Int(row[x])) / 10
            }
        }
        return sum / max(1, width * height)
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
