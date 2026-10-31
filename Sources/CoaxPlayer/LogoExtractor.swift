import Foundation

/// TS の CDT（PID 0x29）から、局ロゴの PNG を取り出す。
/// ロゴは数分おきにしか送られないので、取れたものはアプリが保存しておく。
/// feed は中継のスレッドから呼ぶ。
final class LogoExtractor {
    /// 探すロゴ（scan.json の局ロゴの情報）
    private let downloadDataID: Int
    private let logoID: Int

    /// 取り出したロゴ（パレットを足した PNG）。中継のスレッドで呼ぶ
    var onLogo: ((Data) -> Void)?

    // 以下は中継のスレッドでのみ触る
    private var pending: [UInt8] = []
    /// 組み立て中のセクション
    private var section: [UInt8] = []

    init(downloadDataID: Int, logoID: Int) {
        self.downloadDataID = downloadDataID
        self.logoID = logoID
    }

    func feed(_ data: ArraySlice<UInt8>) {
        let bytes = pending + data
        var i = 0
        while i + 188 <= bytes.count {
            guard bytes[i] == 0x47 else {
                i += 1
                continue
            }
            packet(bytes[i..<i + 188])
            i += 188
        }
        pending = Array(bytes[i...])
    }

    private func packet(_ p: ArraySlice<UInt8>) {
        let base = p.startIndex
        let pid = UInt16(p[base + 1] & 0x1f) << 8 | UInt16(p[base + 2])
        guard pid == 0x29, p[base + 3] & 0x10 != 0 else { return }
        let start = p[base + 1] & 0x40 != 0
        var offset = base + 4
        if p[base + 3] & 0x20 != 0 { offset += 1 + Int(p[base + 4]) }
        guard offset < p.endIndex else { return }
        var payload = p[offset...]

        if start {
            // pointer_field の前は、組み立て中のセクションの続き
            let pointer = Int(payload[payload.startIndex])
            payload = payload.dropFirst()
            if !section.isEmpty {
                section += payload.prefix(pointer)
                takeSections()
            }
            section = Array(payload.dropFirst(pointer))
        } else if !section.isEmpty {
            section += payload
        }
        takeSections()
    }

    /// そろったセクションを読む。1 パケットに複数のセクションが入ることもある
    private func takeSections() {
        while section.count >= 3 {
            if section[0] == 0xff {  // 詰め物
                section = []
                return
            }
            let length = 3 + (Int(section[1] & 0x0f) << 8 | Int(section[2]))
            guard section.count >= length else { return }
            parseCDT(Array(section[0..<length]))
            section.removeFirst(length)
        }
    }

    /// CDT（ARIB STD-B21）。データの種類がロゴのものから、目当てのロゴの「HD 大」（64x36）を探す
    private func parseCDT(_ s: [UInt8]) {
        guard s.count >= 17, s[0] == 0xc8,
              Int(s[3]) << 8 | Int(s[4]) == downloadDataID,
              s[10] == 0x01 else { return }
        let end = s.count - 4  // CRC
        var i = 13 + (Int(s[11] & 0x0f) << 8 | Int(s[12]))
        guard i + 7 <= end else { return }
        let type = s[i]
        let id = Int(s[i + 1] & 0x01) << 8 | Int(s[i + 2])
        let size = Int(s[i + 5]) << 8 | Int(s[i + 6])
        i += 7
        guard type == 5, id == logoID, size > 0, i + size <= end else { return }
        if let png = Self.addPalette(Array(s[i..<i + size])) { onLogo?(png) }
    }

    /// ロゴの PNG にはパレットが無く、ARIB の共通固定色（128 色）を使う決まりなので、PLTE と tRNS を足す
    static func addPalette(_ png: [UInt8]) -> Data? {
        // シグネチャ（8）と IHDR（4+4+13+4）
        guard png.count > 33, png[12..<16].elementsEqual("IHDR".utf8) else { return nil }
        // 念のため、パレットが入っていればそのまま使う
        var i = 8
        while i + 8 <= png.count {
            if png[i + 4..<i + 8].elementsEqual("PLTE".utf8) { return Data(png) }
            i += 12 + (Int(png[i]) << 24 | Int(png[i + 1]) << 16 | Int(png[i + 2]) << 8 | Int(png[i + 3]))
        }
        let colors = fixedColors
        let plte = chunk("PLTE", colors.flatMap { [$0.r, $0.g, $0.b] })
        let trns = chunk("tRNS", colors.map(\.a))
        return Data(png[0..<33] + plte + trns + png[33...])
    }

    private static func chunk(_ type: String, _ data: [UInt8]) -> [UInt8] {
        let body = Array(type.utf8) + data
        let length = UInt32(data.count), crc = crc32(body)
        return withUnsafeBytes(of: length.bigEndian, Array.init) + body + withUnsafeBytes(of: crc.bigEndian, Array.init)
    }

    private static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xffff_ffff
        for b in bytes {
            c ^= UInt32(b)
            for _ in 0..<8 { c = c & 1 != 0 ? 0xedb8_8320 ^ (c >> 1) : c >> 1 }
        }
        return ~c
    }

    /// 共通固定色（ARIB STD-B24）。0〜64 は不透明、65〜127 は 0〜63（8 の透明を除く）の半透明
    private static let fixedColors: [(r: UInt8, g: UInt8, b: UInt8, a: UInt8)] = {
        // 0〜15: 原色、透明、暗い原色
        var opaque: [(UInt8, UInt8, UInt8)] = [
            (0, 0, 0), (255, 0, 0), (0, 255, 0), (255, 255, 0), (0, 0, 255), (255, 0, 255), (0, 255, 255), (255, 255, 255),
            (0, 0, 0), (170, 0, 0), (0, 170, 0), (170, 170, 0), (0, 0, 170), (170, 0, 170), (0, 170, 170), (170, 170, 170),
        ]
        // 16〜64: 各成分 0/85/170/255 の組み合わせのうち、0〜15 に無いもの
        let levels: [UInt8] = [0, 85, 170, 255]
        for r in levels { for g in levels { for b in levels {
            let c = [r, g, b]
            if c.allSatisfy({ $0 == 0 || $0 == 255 }) || c.allSatisfy({ $0 == 0 || $0 == 170 }) { continue }
            opaque.append((r, g, b))
        } } }
        var colors = opaque.enumerated().map { (r: $1.0, g: $1.1, b: $1.2, a: UInt8($0 == 8 ? 0 : 255)) }
        colors += opaque[0..<64].enumerated().filter { $0.offset != 8 }.map { (r: $1.0, g: $1.1, b: $1.2, a: UInt8(128)) }
        return colors
    }()
}
