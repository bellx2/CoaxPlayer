import Foundation

/// PIX-DT295 を pix-userland（https://github.com/Khronos31/pix-userland）の pixd と pix-ts で使う。
/// 利用者が用意したフォルダー（配布アーカイブを展開したもの）に pixd・pix-ts・firmware/dt295.bin がある。
/// ファームウェアはメーカー由来で再配布が制限されるので、.app には同梱しない
struct PixUserland {
    let folder: URL

    var pixd: URL { folder.appendingPathComponent("pixd") }
    var pixTS: URL { folder.appendingPathComponent("pix-ts") }
    var firmware: URL { folder.appendingPathComponent("firmware/dt295.bin") }

    /// pixd の名前。前回アプリが落ちて残った pixd を探すのにも使う
    static let instance = "coaxplayer"
    /// pixd のソケットを置く場所。ソケットのパスの長さに上限（macOS は 103 バイト）があるので、一時ディレクトリの浅いところにする
    static let runtimeDir = FileManager.default.temporaryDirectory.appendingPathComponent("CoaxPlayer-pix")
    /// pixd を受け持つ CoaxPlayer が flock をかけておくファイル。CoaxPlayer を 2 つ起動したとき、
    /// あとのものが先のものの pixd を「落ちて残ったもの」と取り違えて止めないようにする
    static let lockPath = FileManager.default.temporaryDirectory.appendingPathComponent("CoaxPlayer-pix.lock").path

    /// 足りないものがあれば、その説明
    var problem: String? {
        let fm = FileManager.default
        for url in [pixd, pixTS] where !fm.isExecutableFile(atPath: url.path) {
            return "\(url.lastPathComponent) がありません"
        }
        if !fm.fileExists(atPath: firmware.path) { return "firmware/dt295.bin がありません" }
        return nil
    }

    /// pixd を起動する引数。port は `pixd --list-json` の USB の位置（"3-1.1" など）
    func daemonArguments(port: String) -> [String] {
        ["--device", "usb:\(port)", "--firmware", firmware.path,
         "--instance", Self.instance, "--runtime-dir", Self.runtimeDir.path]
    }

    /// 選局して TS を stdout に出し続ける pix-ts の引数。地上波（13〜62ch）だけを受ける
    func tuneArguments(channel: String) -> [String]? {
        guard let number = Int(channel), (13...62).contains(number) else { return nil }
        return ["--runtime-dir", Self.runtimeDir.path, "--instance", Self.instance,
                "--receiver", "0", "-c", "T\(number)", "-t", "-", "-o", "-"]
    }

    /// `coax scan --tune-command` に渡すコマンド。coax が {ch} を物理チャンネルに置き換えて、チャンネルごとに起動する。
    /// coax は空白で語に分けるので、各語を ' で囲む（パスに空白があってもよいように）
    var scanCommand: String {
        let words = [pixTS.path, "--runtime-dir", Self.runtimeDir.path, "--instance", Self.instance,
                     "--receiver", "0", "-c", "T{ch}", "-t", "-", "-o", "-"]
        return words.map { "'\($0)'" }.joined(separator: " ")
    }

    /// `pixd --list-json` の出力から DT295 の USB の位置を取る。取れなければ理由を返す
    static func port(listJSON data: Data) -> Result<String, PixError> {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .failure(PixError("pixd --list-json を読めません"))
        }
        // 型番は筐体（enclosures）に、USB の位置はその devices にある
        let enclosures = (root["enclosures"] as? [[String: Any]] ?? []).filter { $0["model"] as? String == "PIX-DT295" }
        let devices = enclosures.flatMap { $0["devices"] as? [[String: Any]] ?? [] }
        if let port = devices.lazy.compactMap({ $0["port"] as? String }).first {
            return .success(port)
        }
        // macOS で USB の位置を読めない差し込み口がある（バス 0 として見え、pixd が選べない）
        let ungrouped = root["ungrouped_usb_devices"] as? [[String: Any]] ?? []
        if ungrouped.contains(where: { $0["model"] as? String == "PIX-DT295" }) {
            return .failure(PixError("PIX-DT295 の USB の位置を読めません。別の差し込み口に挿し直してください"))
        }
        return .failure(PixError("PIX-DT295 が見つかりません"))
    }
}

struct PixError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}
