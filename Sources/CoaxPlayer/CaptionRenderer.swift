import CAribCaption
import CoreGraphics
import Foundation

/// 描いた字幕。frame は描いた枠（映像の表示領域）のピクセル数、rect はその中で image が占める位置
struct CaptionImage {
    let image: CGImage
    let frame: CGSize
    let rect: CGRect
}

/// 字幕を libaribcaption で解読し、映像の表示領域の実ピクセル数で描く。
/// libaribcaption はスレッドセーフでないので、解読と描画は専用のキューで行う
final class CaptionRenderer {
    private let queue = DispatchQueue(label: "caption")
    private let context: OpaquePointer
    private let decoder: OpaquePointer
    private let renderer: OpaquePointer

    // 以下は queue 上でのみ触る
    private var profile: aribcc_profile_t?
    private var frameWidth = 0
    private var frameHeight = 0
    /// 字幕を表示中か。消えたときだけ通知するのに使う
    private var shown = false
    /// 行ごとに半透明の黒を敷くか。縁取りはどちらでも付ける
    private var background: Bool

    init?(background: Bool) {
        guard let context = aribcc_context_alloc() else { return nil }
        guard let decoder = aribcc_decoder_alloc(context), let renderer = aribcc_renderer_alloc(context),
              aribcc_renderer_initialize(renderer, ARIBCC_CAPTIONTYPE_CAPTION,
                                         ARIBCC_FONTPROVIDER_TYPE_AUTO, ARIBCC_TEXTRENDERER_TYPE_AUTO) else {
            aribcc_context_free(context)
            return nil
        }
        // 放送側の背景は描かない。背景は設定で選んだときだけ、こちらで敷く
        aribcc_renderer_set_force_no_background(renderer, true)
        aribcc_renderer_set_stroke_width(renderer, Self.strokeWidth(background: background))
        self.context = context
        self.decoder = decoder
        self.renderer = renderer
        self.background = background
    }

    /// 半透明の黒の背景を敷くかを切り替える。描き直したときに変わるので、次に出る字幕から変わる
    func setBackground(_ background: Bool) {
        queue.async { [self] in
            self.background = background
            aribcc_renderer_set_stroke_width(renderer, Self.strokeWidth(background: background))
        }
    }

    /// 縁の太さ（字幕の座標 960x540 のドット数）。背景なしでは既定の 1.5 だと明るい場面で細く見えるので太くし、
    /// 背景を敷くときは縁は補いなので既定のままにする
    private static func strokeWidth(background: Bool) -> Float {
        background ? 1.5 : 3
    }

    deinit {
        aribcc_renderer_free(renderer)
        aribcc_decoder_free(decoder)
        aribcc_context_free(context)
    }

    /// 字幕の PES を解読してためる。pts はミリ秒
    func decode(_ data: Data, pts: Int64, profile: aribcc_profile_t) {
        queue.async { [self] in
            if self.profile != profile {
                // 別の番組の字幕に替わった（ワンセグとフルセグなど）
                if self.profile == nil {
                    aribcc_decoder_initialize(decoder, ARIBCC_ENCODING_SCHEME_AUTO, ARIBCC_CAPTIONTYPE_CAPTION,
                                              profile, ARIBCC_LANGUAGEID_FIRST)
                    // 半角の枠（MSZ）の英数字を ASCII に置き換えると、CoreText の描画は縮めずに描くので、
                    // ヒラギノの数字（幅 0.65 文字）が枠（0.5 文字）からはみ出して重なる。全角のまま半分に縮めて描かせる
                    aribcc_decoder_set_replace_msz_fullwidth_ascii(decoder, false)
                } else {
                    aribcc_decoder_set_profile(decoder, profile)
                    aribcc_decoder_flush(decoder)
                    aribcc_renderer_flush(renderer)
                }
                self.profile = profile
            }
            var caption = aribcc_caption_t()
            let status = data.withUnsafeBytes {
                aribcc_decoder_decode(decoder, $0.bindMemory(to: UInt8.self).baseAddress, data.count, pts, &caption)
            }
            if status == ARIBCC_DECODE_STATUS_GOT_CAPTION {
                addBlackStroke(&caption)
                aribcc_renderer_append_caption(renderer, &caption)
                aribcc_caption_cleanup(&caption)
            }
        }
    }

    /// pts（ミリ秒）の字幕を width x height の枠に描く。変わったときだけ、メインスレッドで update を呼ぶ（消えたら nil）
    func render(at pts: Int64, width: Int, height: Int, update: @escaping (CaptionImage?) -> Void) {
        queue.async { [self] in
            guard profile != nil, width > 0, height > 0 else { return }
            if width != frameWidth || height != frameHeight {
                aribcc_renderer_set_frame_size(renderer, Int32(width), Int32(height))
                frameWidth = width
                frameHeight = height
            }
            var result = aribcc_render_result_t()
            let status = aribcc_renderer_render(renderer, pts, &result)
            defer { aribcc_render_result_cleanup(&result) }
            switch status {
            case ARIBCC_RENDER_STATUS_GOT_IMAGE:
                let image = compose(result, width: width, height: height)
                shown = image != nil
                DispatchQueue.main.async { update(image) }
            case ARIBCC_RENDER_STATUS_NO_IMAGE where shown:
                shown = false
                DispatchQueue.main.async { update(nil) }
            default:
                break
            }
        }
    }

    /// すべての文字に不透明の黒の縁を付ける。libaribcaption の強制縁取り（force_stroke_text）は
    /// 縁の色に背景色を使うので、背景が半透明や透明だと縁が黒くならない
    private func addBlackStroke(_ caption: inout aribcc_caption_t) {
        let black = aribcc_color_t(0xff00_0000)  // ARIBCC_MAKE_RGBA(0, 0, 0, 255)
        for r in 0..<Int(caption.region_count) {
            let region = caption.regions[r]
            for c in 0..<Int(region.char_count) {
                region.chars[c].style = aribcc_charstyle_t(region.chars[c].style.rawValue | ARIBCC_CHARSTYLE_STROKE.rawValue)
                region.chars[c].stroke_color = black
            }
        }
    }

    /// 描かれた画像（字幕の領域ごと）を、それらを囲む 1 枚にまとめる
    private func compose(_ result: aribcc_render_result_t, width: Int, height: Int) -> CaptionImage? {
        let images = UnsafeBufferPointer(start: result.images, count: Int(result.image_count))
        var rects = images.map { CGRect(x: Int($0.dst_x), y: Int($0.dst_y), width: Int($0.width), height: Int($0.height)) }
        if profile == ARIBCC_PROFILE_C {
            // ワンセグの字幕には位置の情報が無い（TR-B14）。FFmpeg と同じく、左右の中央で下から積む
            var y = CGFloat(height) - rects.reduce(0) { $0 + $1.height }
            for i in rects.indices {
                rects[i].origin = CGPoint(x: ((CGFloat(width) - rects[i].width) / 2).rounded(), y: y)
                y += rects[i].height
            }
        }
        guard let bounds = rects.dropFirst().reduce(rects.first, { $0?.union($1) }), !bounds.isEmpty else { return nil }

        // libaribcaption の画像は RGBA の順で、透明な下地に重ねて描いているので乗算済み
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let ctx = CGContext(data: nil, width: Int(bounds.width), height: Int(bounds.height),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: info) else { return nil }
        for (image, rect) in zip(images, rects) {
            guard let data = CFDataCreate(nil, image.bitmap, Int(image.bitmap_size)),
                  let provider = CGDataProvider(data: data),
                  let cg = CGImage(width: Int(image.width), height: Int(image.height), bitsPerComponent: 8,
                                   bitsPerPixel: 32, bytesPerRow: Int(image.stride),
                                   space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: info),
                                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
            else { continue }
            // CGContext は下が原点なので、上からの位置を反転する
            let target = CGRect(x: rect.minX - bounds.minX, y: bounds.maxY - rect.maxY,
                                width: rect.width, height: rect.height)
            if background {
                // 縁取りだけでは細かい模様の上で読みにくいときのため、行ごとに半透明の黒を敷く
                ctx.setFillColor(CGColor(gray: 0, alpha: 0.5))
                ctx.fill(target)
            }
            ctx.draw(cg, in: target)
        }
        guard let image = ctx.makeImage() else { return nil }
        return CaptionImage(image: image, frame: CGSize(width: width, height: height), rect: bounds)
    }
}
