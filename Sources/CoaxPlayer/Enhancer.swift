import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// ワンセグのような小さな映像を、時間方向のノイズ除去と低遅延の超解像で拡大する（macOS 26 以降）。
/// MPVPlayer の描画用キューからだけ使う。
@available(macOS 26.0, *)
final class Enhancer {
    private static let packed = kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarVideoRange
    private static let nv12 = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

    let width: Int, height: Int
    private let outWidth: Int, outHeight: Int
    private let noiseConfig: VTTemporalNoiseFilterConfiguration
    private let scalerConfig: VTLowLatencySuperResolutionScalerConfiguration
    private let noise = VTFrameProcessor()
    private let scaler = VTFrameProcessor()
    private let transfer: VTPixelTransferSession
    /// ノイズ除去で参照する直前のフレーム。nil なら次のフレームを列の始まりとして扱う
    private var previous: VTFrameProcessorFrame?
    private var frameIndex: CMTimeValue = 0
    /// 拡大した結果（BGRA）。表示中のものに書き込まないよう、3 枚を順に使う
    private var outputs: [CVPixelBuffer] = []
    private var outputIndex = 0

    /// この大きさに使えなければ nil
    init?(width: Int, height: Int) {
        guard VTTemporalNoiseFilterConfiguration.isSupported,
              VTLowLatencySuperResolutionScalerConfiguration.isSupported,
              // 一番大きな倍率を使う。大きすぎる映像（フルセグなど）では空になる
              let scale = VTLowLatencySuperResolutionScalerConfiguration
                  .__supportedScaleFactors(forFrameWidth: width, frameHeight: height).map(\.floatValue).max(),
              let noiseConfig = VTTemporalNoiseFilterConfiguration(
                  frameWidth: width, frameHeight: height, sourcePixelFormat: Self.packed)
        else { return nil }
        self.width = width
        self.height = height
        self.noiseConfig = noiseConfig
        scalerConfig = VTLowLatencySuperResolutionScalerConfiguration(frameWidth: width, frameHeight: height, scaleFactor: scale)
        outWidth = Int(Float(width) * scale)
        outHeight = Int(Float(height) * scale)

        var session: VTPixelTransferSession?
        VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &session)
        guard let session else { return nil }
        transfer = session
        do {
            try noise.startSession(configuration: noiseConfig)
            try scaler.startSession(configuration: scalerConfig)
        } catch {
            return nil
        }
    }

    deinit {
        noise.endSession()
        scaler.endSession()
        VTPixelTransferSessionInvalidate(transfer)
    }

    /// BGRA の 1 フレームを拡大して、BGRA（IOSurface 付き）で返す。失敗したら nil
    func process(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let time = CMTime(value: frameIndex, timescale: 1000)
        frameIndex += 1

        // ノイズ除去は Apple の可逆圧縮のピクセル形式しか受け付けない。後ろのフレームは待たない（遅れが出るため）
        guard let packed = convert(source, Self.packed, noiseConfig.sourcePixelBufferAttributes),
              let denoised = makeBuffer(width, height, Self.packed, noiseConfig.destinationPixelBufferAttributes),
              let current = VTFrameProcessorFrame(buffer: packed, presentationTimeStamp: time),
              let denoisedFrame = VTFrameProcessorFrame(buffer: denoised, presentationTimeStamp: time),
              let noiseParameters = VTTemporalNoiseFilterParameters(
                  sourceFrame: current, nextFrames: [], previousFrames: previous.map { [$0] } ?? [],
                  destinationFrame: denoisedFrame, filterStrength: 0.5, hasDiscontinuity: previous == nil),
              run(noise, noiseParameters)
        else { return nil }
        previous = current

        guard let small = convert(denoised, Self.nv12, scalerConfig.sourcePixelBufferAttributes),
              let large = makeBuffer(outWidth, outHeight, Self.nv12, scalerConfig.destinationPixelBufferAttributes),
              let smallFrame = VTFrameProcessorFrame(buffer: small, presentationTimeStamp: time),
              let largeFrame = VTFrameProcessorFrame(buffer: large, presentationTimeStamp: time),
              run(scaler, VTLowLatencySuperResolutionScalerParameters(sourceFrame: smallFrame, destinationFrame: largeFrame))
        else { return nil }

        if outputs.isEmpty {
            outputs = (0..<3).compactMap { _ in makeBuffer(outWidth, outHeight, kCVPixelFormatType_32BGRA, [:]) }
        }
        guard !outputs.isEmpty else { return nil }
        outputIndex = (outputIndex + 1) % outputs.count
        let output = outputs[outputIndex]
        guard VTPixelTransferSessionTransferImage(transfer, from: large, to: output) == noErr else { return nil }
        return output
    }

    /// 終わるまで待って成否を返す。Swift の非同期シーケンス版は品質重視の超解像で何も処理しなかったので、
    /// 完了時に呼ばれる形を使う
    private func run(_ processor: VTFrameProcessor, _ parameters: any VTFrameProcessorParameters) -> Bool {
        let done = DispatchSemaphore(value: 0)
        var failed = false
        processor.process(parameters: parameters) { _, error in
            failed = error != nil
            done.signal()
        }
        done.wait()
        return !failed
    }

    /// 設定が求める属性（行の揃えなど）で作る。大きさと形式は引数で決める
    private func makeBuffer(_ width: Int, _ height: Int, _ format: OSType, _ attributes: [String: Any]) -> CVPixelBuffer? {
        var attrs = attributes
        for key in [kCVPixelBufferWidthKey, kCVPixelBufferHeightKey, kCVPixelBufferPixelFormatTypeKey] {
            attrs.removeValue(forKey: key as String)
        }
        attrs[kCVPixelBufferIOSurfacePropertiesKey as String] = [:] as [String: Any]
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, format, attrs as CFDictionary, &buffer)
        return buffer
    }

    private func convert(_ from: CVPixelBuffer, _ format: OSType, _ attributes: [String: Any]) -> CVPixelBuffer? {
        guard let to = makeBuffer(CVPixelBufferGetWidth(from), CVPixelBufferGetHeight(from), format, attributes),
              VTPixelTransferSessionTransferImage(transfer, from: from, to: to) == noErr
        else { return nil }
        return to
    }
}

/// この Mac と OS で高精細化が使えるか
func enhancerAvailable() -> Bool {
    guard #available(macOS 26.0, *) else { return false }
    return VTTemporalNoiseFilterConfiguration.isSupported && VTLowLatencySuperResolutionScalerConfiguration.isSupported
}
