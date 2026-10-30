import Foundation

/// `coax scan` の結果のうち、受信できたチャンネル。
struct Channel: Identifiable {
    /// `coax tune --ch` に渡す名前
    let channel: String
    let name: String

    var id: String { channel }
}

/// スキャンで選べる範囲。pattern は `coax scan --include` に渡すチャンネル名の条件（coax-gpui と同じ）
struct ScanRange {
    let label: String
    let pattern: String

    static let all = [
        ScanRange(label: "地上 UHF 13〜62", pattern: "1[3-9]|[2-5][0-9]|6[0-2]"),
        ScanRange(label: "地上 VHF 1〜12", pattern: "[1-9]|1[0-2]"),
        ScanRange(label: "ケーブル C13〜C63", pattern: "C(?:1[3-9]|[2-5][0-9]|6[0-3])"),
    ]
}

enum ScanFile {
    /// scan.json の既定の場所。Finder から開くと作業ディレクトリが / なので、ユーザーの領域に置く（coax-gpui と共通）
    static var defaultPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/coax-player/scan.json").path
    }

    /// `coax scan` の結果から、受信できたチャンネルだけを並べる
    static func load(_ path: String) throws -> [Channel] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let scan = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = scan["results"] as? [[String: Any]]
        else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "results がありません"])
        }
        return results.compactMap { result in
            guard result["status"] as? String == "found",
                  let channel = result["channel"] as? String
            else { return nil }
            let analysis = result["analysis"] as? [String: Any]
            let transport = analysis?["transport"] as? [String: Any]
            let services = transport?["services"] as? [[String: Any]]
            let name = services?.first?["name"] as? String ?? channel
            return Channel(channel: channel, name: name)
        }
    }
}
