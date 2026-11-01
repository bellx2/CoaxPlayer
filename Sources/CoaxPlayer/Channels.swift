import Foundation

/// `coax scan` の結果のうち、受信できたチャンネル。
struct Channel: Identifiable {
    /// `coax tune --ch` に渡す名前
    let channel: String
    let name: String
    /// リモコンの番号（NIT の TS 情報記述子）。視聴者が普段使う番号はこちら
    let remoteKey: Int?
    /// 局ロゴを CDT で送っているときの、ロゴの在りか（ダウンロードデータ識別とロゴ識別）
    var logoSource: (downloadDataID: Int, logoID: Int)? = nil
    /// ワンセグの番組番号（部分受信のサービス）。一覧のプレビューに使う
    var oneSegServiceID: Int? = nil

    /// 画面に出す番号。リモコンの番号が無ければ物理チャンネル
    var number: String { remoteKey.map(String.init) ?? "\(channel)ch" }

    var id: String { channel }
}

/// スキャンで選べる範囲。pattern は `coax scan --include` に渡すチャンネル名の条件。
/// 地デジは UHF 13〜52ch だけを使う（53〜62 は 2012 年に空いた）。VHF 1〜12ch はケーブルの再送信でだけ使う
struct ScanRange {
    let label: String
    let pattern: String

    static let all = [
        ScanRange(label: "地上 UHF 13〜52", pattern: "1[3-9]|[2-4][0-9]|5[0-2]"),
        ScanRange(label: "ケーブル VHF 1〜12・C13〜C63", pattern: "[1-9]|1[0-2]|C(?:1[3-9]|[2-5][0-9]|6[0-3])"),
    ]
}

enum ScanFile {
    /// scan.json の既定の場所。Finder から開くと作業ディレクトリが / なので、ユーザーの領域に置く
    static var defaultPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CoaxPlayer/scan.json").path
    }

    /// `coax scan` の結果から、受信できたチャンネルだけを並べる
    static func load(_ path: String) throws -> [Channel] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let scan = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = scan["results"] as? [[String: Any]]
        else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "results がありません"])
        }
        let channels: [Channel] = results.compactMap { result in
            guard result["status"] as? String == "found",
                  let channel = result["channel"] as? String
            else { return nil }
            let analysis = result["analysis"] as? [String: Any]
            let transport = analysis?["transport"] as? [String: Any]
            let services = transport?["services"] as? [[String: Any]]
            let name = services?.first?["name"] as? String ?? channel
            // 自分の TS の記述にあるリモコンの番号
            let tsid = transport?["transport_stream_id"] as? Int
            let networks = transport?["networks"] as? [[String: Any]] ?? []
            let remoteKey = networks
                .filter { $0["actual"] as? Bool == true }
                .flatMap { $0["transports"] as? [[String: Any]] ?? [] }
                .first { $0["transport_stream_id"] as? Int == tsid }?["remote_control_key_id"] as? Int
            // coax は 0 の値を省くので、無ければ 0 とみなす
            let logoInfo = services?.first?["logo"] as? [String: Any]
            let logoSource = logoInfo?["logo_transmission_type"] as? Int == 1
                ? (downloadDataID: logoInfo?["download_data_id"] as? Int ?? 0, logoID: logoInfo?["logo_id"] as? Int ?? 0)
                : nil
            let oneSeg = services?.first { $0["partial_reception"] as? Bool == true }?["service_id"] as? Int
            return Channel(channel: channel, name: name, remoteKey: remoteKey, logoSource: logoSource,
                           oneSegServiceID: oneSeg)
        }
        // リモコンの番号の順に並べる。番号の無いものは、スキャンした順のまま後ろへ
        return channels.enumerated().sorted {
            ($0.element.remoteKey ?? Int.max, $0.offset) < ($1.element.remoteKey ?? Int.max, $1.offset)
        }.map(\.element)
    }
}
