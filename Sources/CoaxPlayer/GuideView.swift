import SwiftUI

/// 番組表。視聴画面の下半分に出す。横に局、縦に時刻を並べ、1 日（5 時から翌 5 時）ずつ見る。
/// 番組表は見ている間にだけ集めるので、まだ見ていない局の列は空になる
struct GuidePage: View {
    @ObservedObject var model: PlayerModel
    @ObservedObject var guide: ProgramGuide
    @State private var day = GuidePage.broadcastDay(of: Date())

    /// 1 分の高さ
    static let minuteHeight: CGFloat = 3
    static let columnWidth: CGFloat = 170
    static let rulerWidth: CGFloat = 36
    static let headerHeight: CGFloat = 40
    /// 映像に重ねるので半透明にする。帯、番組の枠、番組の無いところ（列の外も含む）すべて同じ濃さ
    static let opacity = 0.9

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                IconButton(symbol: "chevron.backward.2", help: "前の日", active: false) { moveDay(-1) }
                    .disabled(day <= Self.broadcastDay(of: Date()))
                Text(Self.dayLabel(day))
                    .monospacedDigit()
                    .frame(minWidth: 90)
                IconButton(symbol: "chevron.forward.2", help: "次の日", active: false) { moveDay(1) }
                    .disabled(day >= lastDay)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.panel.opacity(Self.opacity))
            if guide.events.values.allSatisfy(\.isEmpty) {
                Text("番組表はまだありません。チャンネルを見ている間に、その局の番組表を集めます（1 分ほどで 8 日分）")
                    .foregroundStyle(Color.placeholder)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                    .background(Color.black.opacity(Self.opacity))
            } else {
                timetable
                    .background(Color.black.opacity(Self.opacity))
            }
        }
    }

    private var timetable: some View {
        // 縦横を 1 つのスクロールにし、局名の行は上に留める（横には表と一緒に動く）。
        // 縦のスクロールを横の中に入れると、縦の高さが表全体に伸びて配置が崩れる
        ScrollViewReader { reader in
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        HStack(alignment: .top, spacing: 0) {
                            ruler
                            ForEach(model.channels) { channel in
                                column(channel)
                            }
                        }
                        .overlay(alignment: .topLeading) { nowLine }
                        .overlay(alignment: .topLeading) { scrollTarget }
                    } header: {
                        stationRow
                    }
                }
            }
            .onAppear { scrollToNow(reader) }
            .onChange(of: day) { _ in scrollToNow(reader) }
        }
    }

    /// 局名の行。押すとその局を選局する
    private var stationRow: some View {
        HStack(spacing: 0) {
            Color.panel.opacity(Self.opacity).frame(width: Self.rulerWidth, height: Self.headerHeight)
            ForEach(model.channels) { channel in
                HStack(spacing: 6) {
                    StationLogo(image: model.logos[channel.channel]).frame(width: 37, height: 21)
                    Text("\(channel.number) \(channel.name)").lineLimit(1).truncationMode(.tail)
                }
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 6)
                .frame(width: Self.columnWidth, height: Self.headerHeight, alignment: .leading)
                // 見ている局は色を変え、下に線を引く
                .background {
                    ZStack {
                        Color.panel.opacity(Self.opacity)
                        if model.current?.id == channel.id { Color.watching.opacity(0.35) }
                    }
                }
                .overlay(alignment: .bottom) {
                    if model.current?.id == channel.id { Rectangle().fill(Color.watching).frame(height: 3) }
                }
                .overlay(alignment: .trailing) { Rectangle().fill(Color.black).frame(width: 1) }
                // 局名を押すとその局へ切り替える
                .contentShape(Rectangle())
                .onTapGesture { model.play(channel) }
            }
        }
    }

    /// 左の時刻。1 時間ごとに区切る
    private var ruler: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { hour in
                Text("\((hour + 5) % 24)")
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    // 余白は枠の内側に取る。外側に取ると 1 時間ごとに番組の枠とずれていく
                    .padding(.top, 4)
                    .frame(width: Self.rulerWidth, height: 60 * Self.minuteHeight, alignment: .top)
                    .background(Color.panel.opacity(Self.opacity))
                    .overlay(alignment: .top) { Rectangle().fill(Color.black).frame(height: 1) }
            }
        }
    }

    private func column(_ channel: Channel) -> some View {
        let start = day, end = day.addingTimeInterval(86_400)
        let events = events(of: channel).filter { $0.end > start && $0.start < end }
        return ZStack(alignment: .topLeading) {
            Color.clear.frame(width: Self.columnWidth, height: 24 * 60 * Self.minuteHeight)
            if events.isEmpty {
                Text("未取得（見ると集めます）")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.placeholder)
                    .padding(6)
            }
            ForEach(events) { event in
                let top = max(0, event.start.timeIntervalSince(start)) / 60 * Self.minuteHeight
                let bottom = min(86_400, event.end.timeIntervalSince(start)) / 60 * Self.minuteHeight
                GuideCell(event: event, onAir: event.start <= Date() && Date() < event.end)
                    .frame(width: Self.columnWidth - 1, height: max(1, bottom - top - 1), alignment: .topLeading)
                    .offset(y: top)
            }
        }
        .frame(width: Self.columnWidth, alignment: .topLeading)
        .clipped()
        // 列を押してもその局へ切り替える。見ている局なら、選局し直して途切れないよう何もしない
        .contentShape(Rectangle())
        .onTapGesture {
            if model.current?.id != channel.id { model.play(channel) }
        }
    }

    /// 今の時刻の線。見ている日が今日のときだけ
    @ViewBuilder private var nowLine: some View {
        let offset = Date().timeIntervalSince(day)
        if offset >= 0 && offset < 86_400 {
            Rectangle().fill(Color.recording)
                .frame(height: 2)
                .offset(y: offset / 60 * Self.minuteHeight)
                .allowsHitTesting(false)
        }
    }

    /// 局の番組。最初のサービス（局名を取るもの）の番組だけ。番号が分からなければ全部
    private func events(of channel: Channel) -> [GuideEvent] {
        let all = guide.events[channel.channel] ?? []
        guard let service = channel.serviceID, all.contains(where: { $0.service == service }) else { return all }
        return all.filter { $0.service == service }
    }

    /// 見られる最後の日。番組表のある最後の番組の日
    private var lastDay: Date {
        let last = guide.events.values.compactMap { $0.last?.start }.max() ?? Date()
        return Self.broadcastDay(of: last)
    }

    private func moveDay(_ offset: Int) {
        day = day.addingTimeInterval(TimeInterval(offset) * 86_400)
    }

    /// 見ている局の列を真ん中に寄せ、今日なら今の時刻を縦の真ん中に、ほかの日は朝の 5 時を上に出す
    private func scrollToNow(_ reader: ScrollViewProxy) {
        // 表を並べ終えてから動かす
        DispatchQueue.main.async { reader.scrollTo(Self.scrollTargetID, anchor: isToday ? .center : .top) }
    }

    private static let scrollTargetID = "scrollTarget"

    private var isToday: Bool {
        let offset = Date().timeIntervalSince(day)
        return offset >= 0 && offset < 86_400
    }

    /// 開いたときに動かす先の目印。見ている局の列の、今日なら今の時刻、ほかの日は 5 時の位置に置く。
    /// offset は配置に効かず scrollTo が見ないので、余白で位置を決める
    private var scrollTarget: some View {
        let index = model.channels.firstIndex { $0.id == model.current?.id }
        let x = Self.rulerWidth + CGFloat(index ?? 0) * Self.columnWidth
        let y = isToday ? Date().timeIntervalSince(day) / 60 * Self.minuteHeight : 0
        return Color.clear
            .frame(width: Self.columnWidth, height: 1)
            // 目印は余白を付ける前の枠。余白の外に付けると、余白も含めた枠を真ん中に寄せてしまう
            .id(Self.scrollTargetID)
            .padding(.leading, x)
            .padding(.top, y)
            .allowsHitTesting(false)
    }

    /// 放送の 1 日の始まり（日本時間の 5 時）。5 時より前は前の日に入れる
    static func broadcastDay(of date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = ProgramGuide.tokyo
        return calendar.startOfDay(for: date.addingTimeInterval(-5 * 3600)).addingTimeInterval(5 * 3600)
    }

    static func dayLabel(_ day: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.timeZone = ProgramGuide.tokyo
        f.dateFormat = "M/d（E）"
        return f.string(from: day)
    }

    static func time(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = ProgramGuide.tokyo
        f.dateFormat = "H:mm"
        return f.string(from: date)
    }
}

/// 番組表の 1 枠。開始時刻、番組名、説明を入るだけ出す
struct GuideCell: View {
    let event: GuideEvent
    let onAir: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(GuidePage.time(event.start)).font(.system(size: 11)).monospacedDigit().foregroundStyle(Color.placeholder)
                Text(event.title).font(.system(size: 12, weight: .semibold))
            }
            if !event.text.isEmpty {
                Text(event.text).font(.system(size: 11)).foregroundStyle(Color.placeholder)
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background((onAir ? Color.onAir : Color.button).opacity(GuidePage.opacity))
        .clipped()
    }
}
