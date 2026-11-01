// アプリのアイコン（Resources/AppIcon.icns）を描く。
//   swift scripts/make-icon.swift
// 1024px の元絵を CoreGraphics で描き、sips で各サイズに縮めて iconutil で .icns にまとめる。
import AppKit

let size: CGFloat = 1024
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

func gradient(_ ctx: CGContext, _ path: CGPath, _ top: UInt32, _ bottom: UInt32) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let box = path.boundingBox
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(top), color(bottom)] as CFArray,
                       locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: box.midX, y: box.maxY), end: CGPoint(x: box.midX, y: box.minY), options: [])
    ctx.restoreGState()
}

let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

// 下地。macOS のアイコンの枠（1024 の中に 824 角、角の丸み 185）に合わせる
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
ctx.addPath(CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil))
ctx.setFillColor(color(0x0f172a))
ctx.fillPath()
ctx.restoreGState()
gradient(ctx, CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil), 0x1e3a8a, 0x0b1023)

// アンテナ
ctx.setLineCap(.round)
ctx.setLineWidth(26)
ctx.setStrokeColor(color(0xcbd5e1))
ctx.move(to: CGPoint(x: 512, y: 700)); ctx.addLine(to: CGPoint(x: 400, y: 820))
ctx.move(to: CGPoint(x: 512, y: 700)); ctx.addLine(to: CGPoint(x: 624, y: 820))
ctx.strokePath()
ctx.setFillColor(color(0xcbd5e1))
ctx.fillEllipse(in: CGRect(x: 482, y: 670, width: 60, height: 60))

// 画面の枠と画面
let frame = CGRect(x: 190, y: 250, width: 644, height: 450)
ctx.addPath(CGPath(roundedRect: frame, cornerWidth: 70, cornerHeight: 70, transform: nil))
ctx.setFillColor(color(0xe2e8f0))
ctx.fillPath()
let screen = frame.insetBy(dx: 34, dy: 34)
gradient(ctx, CGPath(roundedRect: screen, cornerWidth: 42, cornerHeight: 42, transform: nil), 0x38bdf8, 0x1d4ed8)

// 再生の三角
let play = CGMutablePath()
play.move(to: CGPoint(x: 462, y: 395))
play.addLine(to: CGPoint(x: 462, y: 555))
play.addLine(to: CGPoint(x: 592, y: 475))
play.closeSubpath()
ctx.addPath(play)
ctx.setFillColor(color(0xffffff))
ctx.fillPath()

// 台
ctx.addPath(CGPath(roundedRect: CGRect(x: 412, y: 186, width: 200, height: 40), cornerWidth: 20, cornerHeight: 20, transform: nil))
ctx.setFillColor(color(0xcbd5e1))
ctx.fillPath()

// 書き出し
let work = FileManager.default.temporaryDirectory.appendingPathComponent("CoaxPlayerIcon")
let iconset = work.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: work)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
let master = work.appendingPathComponent("icon_1024.png")
let png = NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
try png.write(to: master)

func run(_ tool: String, _ args: [String]) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    try! p.run()
    p.waitUntilExit()
    precondition(p.terminationStatus == 0, "\(tool) が失敗しました")
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let px = String(base * scale)
        run("/usr/bin/sips", ["-z", px, px, master.path, "--out", iconset.appendingPathComponent(name).path])
    }
}
let output = root.appendingPathComponent("Resources/AppIcon.icns")
run("/usr/bin/iconutil", ["-c", "icns", iconset.path, "-o", output.path])
print(output.path)
