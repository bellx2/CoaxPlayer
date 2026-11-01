import AppKit

/// 新しい版があるかを GitHub の最新の Release で確かめ、Homebrew で入れていれば brew で更新する。
/// 確かめるのは 1 日 1 回まで。失敗したら何も出さず、次の機会に試す
@MainActor
final class Updater: ObservableObject {
    enum State: Equatable {
        case idle
        /// 新しい版がある
        case available(String)
        case updating
        /// 更新に失敗した。理由を添える
        case failed(String)
    }

    @Published private(set) var state = State.idle

    static let releasesURL = URL(string: "https://github.com/bellx2/CoaxPlayer/releases/latest")!
    private static let latestAPI = URL(string: "https://api.github.com/repos/bellx2/CoaxPlayer/releases/latest")!
    nonisolated private static let brew = "/opt/homebrew/bin/brew"
    /// Homebrew で入れたときにできる場所
    private static let caskroom = "/opt/homebrew/Caskroom/coaxplayer"
    private static let interval: TimeInterval = 24 * 60 * 60

    /// この .app の版。swift run などで版が無いときは確かめない
    private let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

    /// 前に見つけた最新の版を出し、1 日たっていれば確かめ直す
    func check() {
        guard current != nil else { return }
        let defaults = UserDefaults.standard
        if let latest = defaults.string(forKey: "latestVersion") { show(latest) }
        let last = defaults.object(forKey: "lastUpdateCheck") as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) >= Self.interval else { return }

        var request = URLRequest(url: Self.latestAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { data, response, _ in
            guard (response as? HTTPURLResponse)?.statusCode == 200, let data,
                  let release = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = release["tag_name"] as? String
            else { return }
            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            DispatchQueue.main.async {
                UserDefaults.standard.set(Date(), forKey: "lastUpdateCheck")
                UserDefaults.standard.set(latest, forKey: "latestVersion")
                self.show(latest)
            }
        }.resume()
    }

    /// 更新中や失敗の表示は残し、それ以外は確かめた結果に合わせる
    private func show(_ latest: String) {
        guard let current else { return }
        switch state {
        case .idle, .available:
            state = Self.isNewer(latest, than: current) ? .available(latest) : .idle
        case .updating, .failed:
            break
        }
    }

    /// "1.0.10" と "1.0.9" のように、点で区切った数で比べる
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) where (i < x.count ? x[i] : 0) != (i < y.count ? y[i] : 0) {
            return (i < x.count ? x[i] : 0) > (i < y.count ? y[i] : 0)
        }
        return false
    }

    /// Homebrew で入れていれば brew で更新して起動し直す。そうでなければ Release のページを開く
    func update() {
        guard FileManager.default.fileExists(atPath: Self.caskroom),
              FileManager.default.isExecutableFile(atPath: Self.brew)
        else {
            NSWorkspace.shared.open(Self.releasesURL)
            return
        }
        state = .updating
        let app = Bundle.main.bundlePath
        DispatchQueue.global().async {
            // tap が古いと新しい版を知らないので、先に brew update をする
            let result = Self.run(["update", "--quiet"]) ?? Self.run(["upgrade", "--cask", "coaxplayer"])
            DispatchQueue.main.async {
                if let error = result {
                    self.state = .failed(error)
                } else {
                    Self.relaunch(app)
                }
            }
        }
    }

    /// brew を動かし、失敗したら最後の出力の行を返す
    nonisolated private static func run(_ arguments: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: brew)
        p.arguments = arguments
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return "brew: \(error.localizedDescription)" }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        guard p.terminationStatus != 0 else { return nil }
        let last = output.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
        return "brew \(arguments[0]) が失敗しました（\(p.terminationStatus)）: \(last)"
    }

    /// 終わるのを待って新しい .app を開く小さなシェルを残し、アプリを終える
    private static func relaunch(_ app: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; open \"$0\"", app]
        try? p.run()
        NSApp.terminate(nil)
    }
}
