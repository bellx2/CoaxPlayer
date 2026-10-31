import CAribCaption
import Foundation

/// TS から、再生中の映像と同じ番組の字幕（ARIB）の PES を取り出す。
/// PAT から PMT を探すほか、PAT を含まないワンセグの TS のため、決まった PID（0x1FC8〜0x1FCF）の PMT も読む。
/// feed は中継のスレッドから、select はメインスレッドから呼ぶ。
final class CaptionExtractor {
    struct Caption {
        let pid: UInt16
        let profile: aribcc_profile_t
    }

    /// 取り出した PES のペイロードと PTS（ミリ秒）。中継のスレッドで呼ぶ
    var onPES: ((Data, Int64, aribcc_profile_t) -> Void)?

    private let lock = NSLock()
    // 以下の 2 つは lock で守る
    /// mpv が再生している映像の PID
    private var selectedVideo: UInt16?
    /// 映像の PID ごとの、同じ番組の字幕
    private var captions: [UInt16: Caption] = [:]

    // 以下は中継のスレッドでのみ触る
    private var pmtPIDs = Set<UInt16>(0x1fc8...0x1fcf)
    /// 188 バイトに満たず、次に回す分
    private var pending: [UInt8] = []
    /// 組み立て中の PES と、その字幕
    private var pes: [UInt8] = []
    private var current: Caption?

    func select(videoPID: UInt16?) {
        lock.withLock { selectedVideo = videoPID }
    }

    func feed(_ data: ArraySlice<UInt8>) {
        let bytes = pending + data
        // mpv が映像を選ぶまでの間も先読みで TS は流れるので、その間は見つかった字幕を取り出す
        let caption = lock.withLock {
            selectedVideo.flatMap { captions[$0] } ?? captions.values.min { $0.pid < $1.pid }
        }
        if caption?.pid != current?.pid {
            current = caption
            pes = []
        }
        var i = 0
        while i + 188 <= bytes.count {
            // 同期が外れていたら、次の同期バイトまで飛ばす
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
        let start = p[base + 1] & 0x40 != 0
        guard p[base + 3] & 0x10 != 0 else { return }  // ペイロードが無い
        var offset = base + 4
        if p[base + 3] & 0x20 != 0 { offset += 1 + Int(p[base + 4]) }
        guard offset < p.endIndex else { return }
        let payload = p[offset...]

        if pid == current?.pid {
            appendPES(payload, start: start)
        } else if start && (pid == 0 || pmtPIDs.contains(pid)) {
            // PSI は 1 パケットに収まるものだけを読む（PAT と字幕の PMT は収まる）
            let pointer = Int(payload[payload.startIndex])
            let section = Array(payload.dropFirst(1 + pointer))
            if pid == 0 {
                parsePAT(section)
            } else {
                parsePMT(section)
            }
        }
    }

    private func parsePAT(_ s: [UInt8]) {
        guard s.count >= 8, s[0] == 0x00 else { return }
        let end = min(s.count, 3 + (Int(s[1] & 0x0f) << 8 | Int(s[2]))) - 4
        var i = 8
        while i + 4 <= end {
            let number = UInt16(s[i]) << 8 | UInt16(s[i + 1])
            if number != 0 { pmtPIDs.insert(UInt16(s[i + 2] & 0x1f) << 8 | UInt16(s[i + 3])) }
            i += 4
        }
    }

    private func parsePMT(_ s: [UInt8]) {
        guard s.count >= 12, s[0] == 0x02 else { return }
        let end = min(s.count, 3 + (Int(s[1] & 0x0f) << 8 | Int(s[2]))) - 4
        var i = 12 + (Int(s[10] & 0x0f) << 8 | Int(s[11]))
        var videos: [UInt16] = []
        var caption: Caption?
        while i + 5 <= end {
            let type = s[i]
            let pid = UInt16(s[i + 1] & 0x1f) << 8 | UInt16(s[i + 2])
            let infoEnd = min(end, i + 5 + (Int(s[i + 3] & 0x0f) << 8 | Int(s[i + 4])))
            switch type {
            case 0x02, 0x1b:  // MPEG-2 映像、H.264
                videos.append(pid)
            case 0x06 where caption == nil:
                caption = captionProfile(s[(i + 5)..<infoEnd]).map { Caption(pid: pid, profile: $0) }
            default:
                break
            }
            i = infoEnd
        }
        guard let caption else { return }
        lock.withLock {
            for video in videos { captions[video] = caption }
        }
    }

    /// 記述子から字幕の種類を読む。文字スーパーなど字幕でないものは nil
    private func captionProfile(_ d: ArraySlice<UInt8>) -> aribcc_profile_t? {
        var tag: UInt8?
        var component: UInt16?
        var i = d.startIndex
        while i + 2 <= d.endIndex {
            let length = Int(d[i + 1])
            guard i + 2 + length <= d.endIndex else { break }
            switch d[i] {
            case 0x52 where length >= 1:  // ストリーム識別記述子
                tag = d[i + 2]
            case 0xfd where length >= 2:  // データ符号化方式記述子
                component = UInt16(d[i + 2]) << 8 | UInt16(d[i + 3])
            default:
                break
            }
            i += 2 + length
        }
        // コンポーネントタグは TR-B14 で、字幕が 0x30〜0x37（ワンセグは 0x87）と決まっている
        switch (component, tag) {
        case (0x0008, .some(0x30...0x37)): return ARIBCC_PROFILE_A
        case (0x0012, .some(0x87)): return ARIBCC_PROFILE_C
        default: return nil
        }
    }

    private func appendPES(_ payload: ArraySlice<UInt8>, start: Bool) {
        guard let current else { return }
        if start {
            pes = Array(payload)
        } else if !pes.isEmpty {
            pes += payload
        }
        // PES_packet_length の分がそろったら渡す
        guard pes.count >= 9 else { return }
        let length = 6 + (Int(pes[4]) << 8 | Int(pes[5]))
        guard pes.count >= length else { return }
        defer { pes = [] }
        // 字幕は private_stream_1 で、PTS を持つ
        guard pes[0] == 0, pes[1] == 0, pes[2] == 1, pes[3] == 0xbd, pes[7] & 0x80 != 0 else { return }
        let header = 9 + Int(pes[8])
        guard header <= length, pes.count >= 14 else { return }
        let pts = Int64(pes[9] >> 1 & 0x07) << 30 | Int64(pes[10]) << 22 | Int64(pes[11] >> 1) << 15
            | Int64(pes[12]) << 7 | Int64(pes[13] >> 1)
        onPES?(Data(pes[header..<length]), pts / 90, current.profile)
    }
}
