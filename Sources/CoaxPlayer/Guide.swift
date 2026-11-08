import Foundation

/// 番組表の 1 番組。基本情報（番組名と説明）と拡張情報（詳しい説明の項目）をまとめたもの
struct GuideEvent: Identifiable, Equatable {
    let service: Int
    let eventID: Int
    let start: Date
    /// 長さ（秒）。分からなければ nil
    let duration: Int?
    let title: String
    let text: String
    let items: [GuideSection.Item]

    var id: String { "\(service)/\(eventID)" }
    /// 終わり。長さが分からなければ、開始から 1 時間とみなす（画面に置くため）
    var end: Date { start.addingTimeInterval(TimeInterval(duration ?? 3600)) }
}

/// `coax tune --schedule` の 1 行（EIT のスケジュールの 1 セクション）。保存にもこの形を使う
struct GuideSection: Codable {
    let network: Int
    let transport: Int
    let service: Int
    let table: Int
    let section: Int
    let version: Int
    let events: [Event]

    struct Event: Codable {
        let id: Int
        /// 放送の時刻（日本時間）。時差は付いていない
        let start: String?
        let duration: Int?
        let title: String?
        let text: String?
        let items: [Item]?
    }

    struct Item: Codable, Equatable {
        let heading: String
        let value: String
    }

    /// 同じセクションの別の版を置き換えるためのキー
    var key: String { "\(network)/\(transport)/\(service)/\(table)/\(section)" }
    /// テーブル ID 0x58 以降は拡張情報（詳しい説明だけ）
    var extended: Bool { table & 0x0f >= 8 }
}

/// 視聴中に集めた番組表。物理チャンネルごとに、届いたセクションの最新の版を持ち、ファイルに残す
@MainActor
final class ProgramGuide: ObservableObject {
    /// 物理チャンネルごとの番組。開始の順
    @Published private(set) var events: [String: [GuideEvent]] = [:]
    /// 物理チャンネル → セクションのキー → セクション
    private var sections: [String: [String: GuideSection]] = [:]
    private var dirty = false
    private let url: URL

    nonisolated static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/CoaxPlayer/guide.json")

    init(url: URL = ProgramGuide.defaultURL) {
        self.url = url
        if let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode([String: [String: GuideSection]].self, from: data) {
            sections = saved
            dropPast()
            for channel in sections.keys { rebuild(channel) }
        }
    }

    /// coax の `schedule` の行の JSON を足す。同じ版なら何もしない
    func add(channel: String, json: String) {
        guard let section = try? JSONDecoder().decode(GuideSection.self, from: Data(json.utf8)) else { return }
        if sections[channel]?[section.key]?.version == section.version { return }
        sections[channel, default: [:]][section.key] = section
        dirty = true
        scheduleRebuild(channel)
    }

    /// 書き換えがあればファイルに残す
    func save() {
        guard dirty else { return }
        dropPast()
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(sections).write(to: url, options: .atomic)
            dirty = false
        } catch {
            FileHandle.standardError.write(Data("番組表を保存できません: \(error.localizedDescription)\n".utf8))
        }
    }

    /// セクションは 1 分ほどの間に続けて届くので、並べ直しはまとめて行う
    private var pendingRebuild: Set<String> = []
    private func scheduleRebuild(_ channel: String) {
        guard pendingRebuild.insert(channel).inserted, pendingRebuild.count == 1 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            let channels = self.pendingRebuild
            self.pendingRebuild = []
            for channel in channels { self.rebuild(channel) }
        }
    }

    /// セクションから番組の一覧を作る。基本情報と拡張情報を番組 ID でまとめる
    private func rebuild(_ channel: String) {
        var basics: [String: (Int, GuideSection.Event)] = [:]
        var details: [String: [GuideSection.Item]] = [:]
        for section in (sections[channel] ?? [:]).values {
            for event in section.events {
                let id = "\(section.service)/\(event.id)"
                if section.extended {
                    if let items = event.items { details[id] = items }
                } else {
                    basics[id] = (section.service, event)
                }
            }
        }
        events[channel] = basics.compactMap { id, pair in
            let (service, event) = pair
            guard let start = event.start.flatMap(Self.parse) else { return nil }
            return GuideEvent(service: service, eventID: event.id, start: start, duration: event.duration,
                              title: event.title ?? "", text: event.text ?? "",
                              items: details[id] ?? event.items ?? [])
        }
        .sorted { ($0.start, $0.service) < ($1.start, $1.service) }
    }

    /// 番組がすべて終わって 1 日たったセクションを捨てる。ファイルが大きくなり続けないように
    private func dropPast() {
        let limit = Date().addingTimeInterval(-86_400)
        for (channel, byKey) in sections {
            sections[channel] = byKey.filter { _, section in
                section.events.contains { event in
                    guard let start = event.start.flatMap(Self.parse) else { return true }
                    return start.addingTimeInterval(TimeInterval(event.duration ?? 3600)) > limit
                }
            }
        }
    }

    static let tokyo = TimeZone(identifier: "Asia/Tokyo")!

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tokyo
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()

    static func parse(_ text: String) -> Date? { formatter.date(from: text) }
}
