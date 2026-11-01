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
            // 既定の coreaudio は、音声機器が変わった通知が音声出力の片付けと重なると落ちる（mpv の hotplug_cb）。
            // 通知を NSNotificationCenter で受ける avfoundation を使う
            ("ao", "avfoundation"),
            // CPU での拡大（フルセグの 1440→1920）は既定の lanczos だと重い。表示時に GPU でも拡大するので軽い方式で足りる
            ("sws-scaler", "bilinear"),
            // フルセグは 1080i。インターレースのままだと動きに櫛状の縞が出るので、インターレースの映像だけ解除する
            ("deinterlace", "auto"),
            // 二か国語や解説の番組（デュアルモノ）は左に主音声、右に副音声が入っていて、そのままだと両方鳴る。
            // 主音声だけにする。普通のステレオには効かない
            ("ad-lavc-o", "dual_mono_mode=main"),
            // 字幕はアプリが別のレイヤーに描く（CaptionRenderer）。mpv は映像の大きさでしか描けず粗いため。
            // 字幕の PTS と比べるので、time-pos は放送の時刻（PTS）のままにする
            ("sid", "no"),
            ("rebase-start-time", "no"),
            ("profile", "low-latency"),
            ("cache", "no"),
            ("demuxer-lavf-probe-info", "yes"),
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

        check(mpv_hook_add(mpv, 0, "on_preloaded", 0), "mpv_hook_add")

        let thread = Thread { [weak self] in self?.eventLoop() }
        thread.name = "mpv.events"
        thread.start()
    }

    /// URL（ファイルパスや fdclose://N）を再生する。decoded はデコーダーを通した TS か
    func load(_ url: String, decoded: Bool = false) {
        trackLock.withLock { self.decoded = decoded }
        // 別の映像になるので、ノイズ除去が前の映像のフレームを参照しないよう作り直す
        renderQueue.async { self.enhancer = nil }
        clear()
        command(["loadfile", url, "replace"])
    }

    func stop() {
        command(["stop"])
        clear()
    }

    /// 前の映像の最後のフレームを消す。描画キューに残った分の後で消えるよう、描画キューを通す
    private func clear() {
        renderQueue.async { [layer] in
            DispatchQueue.main.async { layer.contents = nil }
        }
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

    /// 高精細化（ノイズ除去と超解像）した結果。使えない環境や大きな映像では nil で、そのまま表示する
    private func enhanced(_ surface: CVPixelBuffer, width: Int, height: Int) -> CVPixelBuffer? {
        guard #available(macOS 26.0, *) else { return nil }
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
            case MPV_EVENT_HOOK:
                if let hook = event.data?.assumingMemoryBound(to: mpv_event_hook.self).pointee {
                    selectTracks()
                    mpv_hook_continue(mpv, hook.id)
                }
            case MPV_EVENT_FILE_LOADED:
                if debug { log("file-loaded") }
            case MPV_EVENT_AUDIO_RECONFIG:
                // 音量とミュートはメインスレッドで変えるので、掛け直しもメインスレッドで行う
                DispatchQueue.main.async { [weak self] in self?.applyAudioLevel() }
            default:
                break
            }
        }
    }

    /// 二か国語などのデュアルモノで鳴らす音声（FFmpeg の AAC の dual_mono_mode: main・sub・both）。
    /// デコーダーの設定なので、音声のトラックを外して付け直し、デコーダーを作り直す
    func setDualMono(_ mode: String) {
        guard let mpv else { return }
        check(mpv_set_property_string(mpv, "ad-lavc-o", "dual_mono_mode=\(mode)"), "ad-lavc-o")
        guard let aid = stringProperty("aid"), aid != "no" else { return }
        _ = mpv_set_property_string(mpv, "aid", "no")
        _ = mpv_set_property_string(mpv, "aid", aid)
    }

    /// 音量（0〜100）とミュート。avfoundation の出力は約 2 秒先まで音声をためるので、mpv の volume・mute
    /// （ためる前に掛かる）ではすぐに変わらない。出力側の ao-volume・ao-mute で変える。
    /// 出力は選局などで作り直されて設定が消えるので、作り直されたら（AUDIO_RECONFIG）掛け直す
    private var volume = 100.0
    private var muted = false

    func setVolume(_ volume: Double) {
        self.volume = volume
        applyAudioLevel()
    }

    func setMute(_ mute: Bool) {
        muted = mute
        applyAudioLevel()
    }

    /// 出力がまだ無いとき（再生前）は失敗するが、作り直されたときに掛けるので無視する
    private func applyAudioLevel() {
        guard let mpv else { return }
        _ = mpv_set_property_string(mpv, "ao-volume", String(volume))
        _ = mpv_set_property_string(mpv, "ao-mute", muted ? "yes" : "no")
    }

    /// ワンセグとフルセグの両方が見られるとき、ワンセグを選ぶか。チャンネルを替えても保つ
    var prefersOneSeg: Bool {
        get { trackLock.withLock { oneSeg } }
        set {
            trackLock.withLock { oneSeg = newValue }
            selectTracks()
        }
    }
    // イベントスレッド（on_preloaded）とメインスレッドの両方から読むので、ロックで守る
    private let trackLock = NSLock()
    private var oneSeg = false
    private var decoded = false

    /// 映像と音声のトラックを選ぶ。on_preloaded と、ワンセグ・フルセグの切り替えで呼ぶ。
    /// フルセグを再生できないと、mpv は先頭のフルセグを選んで何も映らないので、ワンセグ（H.264）にする。
    /// デコーダーを通しているか、解析で映像の大きさが分かった（再生できるファイル）ときは、prefersOneSeg に従う。
    /// デコーダーを通していても、選局直後の解析ではフルセグの大きさが分からないことが多いので、大きさは待たない
    private func selectTracks() {
        guard let mpv, let count = int64Property("track-list/count") else { return }
        struct Track { let id: Int64, type: String, codec: String, program: Int64?, width: Int64? }
        let tracks = (0..<count).compactMap { n -> Track? in
            guard let id = int64Property("track-list/\(n)/id"),
                  let type = stringProperty("track-list/\(n)/type") else { return nil }
            return Track(id: id, type: type, codec: stringProperty("track-list/\(n)/codec") ?? "",
                         program: int64Property("track-list/\(n)/program-id"),
                         width: int64Property("track-list/\(n)/demux-w"))
        }
        let (preferOneSeg, decoded) = trackLock.withLock { (oneSeg, self.decoded) }
        let fullSeg = tracks.first { $0.type == "video" && $0.codec != "h264" && (decoded || $0.width != nil) }
        let oneSeg = tracks.first { $0.type == "video" && $0.codec == "h264" }
        // どちらも無ければ（再生できないフルセグだけなど）mpv に任せる
        guard let video = preferOneSeg ? (oneSeg ?? fullSeg) : (fullSeg ?? oneSeg) else {
            _ = mpv_set_property_string(mpv, "vid", "auto")
            _ = mpv_set_property_string(mpv, "aid", "auto")
            return
        }
        _ = mpv_set_property_string(mpv, "vid", String(video.id))
        let audio = tracks.first { $0.type == "audio" && $0.program != nil && $0.program == video.program }
        _ = mpv_set_property_string(mpv, "aid", audio.map { String($0.id) } ?? "auto")
        if debug { log("映像を選ぶ: vid=\(video.id) codec=\(video.codec) program=\(video.program ?? -1)") }
    }

    private func stringProperty(_ name: String) -> String? {
        guard let mpv, let s = mpv_get_property_string(mpv, name) else { return nil }
        defer { mpv_free(s) }
        return String(cString: s)
    }

    private func check(_ r: Int32, _ what: String) {
        if r < 0 { log("\(what) 失敗: \(String(cString: mpv_error_string(r)))") }
    }

    private func log(_ s: String) {
        FileHandle.standardError.write(Data("mpv: \(s)\n".utf8))
    }
}
