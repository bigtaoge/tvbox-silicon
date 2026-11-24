import SwiftUI
import TVCore

/// The program guide of a live playlist (#802): what's on each channel now and next. An XMLTV file loads once for the
/// whole playlist; a per-channel address (DIYP) is asked for each channel as it shows on screen.
@MainActor @Observable final class LiveGuide {
    let address: GuideAddress
    private(set) var guide: ProgramGuide?
    private(set) var perChannel: [String: [Programme]] = [:]
    /// Per-channel programmes by channel and day ("name|2026-11-24"), for the programme page (patch 15).
    private(set) var perChannelByDay: [String: [Programme]] = [:]
    @ObservationIgnored private var asked = Set<String>()
    @ObservationIgnored private var askedDays = Set<String>()

    init(address: GuideAddress) { self.address = address }

    /// The start of `date`'s day in China's time zone, for the programme page's date strip (patch 15).
    static func startOfDay(_ date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = ProgramGuide.chinaTime
        return calendar.startOfDay(for: date)
    }

    static func dayKey(_ name: String, on day: Date) -> String {
        name + "|" + ProgramGuide.dayString(day)
    }

    /// The guide a playlist uses: the address the viewer typed in for it, else its subscription entry's `epg`, else
    /// the `x-tvg-url` its M3U header names.
    static func address(for source: LiveSource, playlist: String?, in store: Store) -> GuideAddress? {
        let typed = store.guideAddresses[source.url.absoluteString]
        for text in [typed, source.guide, playlist].compactMap({ $0 }) {
            if let address = GuideAddress(text, relativeTo: source.url) { return address }
        }
        return nil
    }

    func schedule(for channel: Channel) -> [Programme]? {
        switch address {
        case .xmltv: guide?.schedule(for: channel)
        case .perChannel: perChannel[channel.name]
        }
    }

    /// The channel's programmes on `day` (China time zone), for the programme page (patch 15): the loaded
    /// XMLTV guide filtered to the day, or the per-channel address asked for that day. Nil when the guide
    /// has nothing for the channel at all.
    func schedule(for channel: Channel, on day: Date) -> [Programme]? {
        switch address {
        case .xmltv: guide?.schedule(for: channel)?.on(day)
        case .perChannel: perChannelByDay[Self.dayKey(channel.name, on: day)]
        }
    }

    /// Loads an XMLTV guide for the playlist's channels.
    func load(_ channels: [Channel]) async {
        guard case let .xmltv(url) = address else { return }
        do { guide = try await ProgramGuides.shared.guide(url, for: channels) }
        catch {
            guard !(error is CancellationError) else { return }
            Diagnostics.shared.record(.warning, "live", "guide not loaded host=\(url.host() ?? "-"): \(error.localizedDescription)")
        }
    }

    /// Asks a per-channel guide for the channel's programmes today, once.
    func fetch(_ channel: Channel) async {
        guard case .perChannel = address, asked.insert(channel.name).inserted else { return }
        if let programmes = await ProgramGuides.shared.schedule(address, name: channel.name) {
            if !programmes.isEmpty { perChannel[channel.name] = programmes }
        } else {
            asked.remove(channel.name)
        }
    }

    /// Asks a per-channel guide for the channel's programmes on `day`, once per channel and day (patch 15,
    /// programme page). An XMLTV guide already holds the whole week, so nothing is asked for it. The answer
    /// is kept even when empty, so the page can tell "no programmes that day" from "still asking".
    func fetch(_ channel: Channel, on day: Date) async {
        guard case .perChannel = address else { return }
        let key = Self.dayKey(channel.name, on: day)
        guard askedDays.insert(key).inserted else { return }
        if let programmes = await ProgramGuides.shared.schedule(address, name: channel.name, on: day) {
            perChannelByDay[key] = programmes
        } else {
            askedDays.remove(key)
        }
    }
}

/// Redraws a programme line when a programme ends, and at no other time.
struct ProgrammeTimes: TimelineSchedule {
    let ends: [Date]
    init(_ schedule: [Programme]) { ends = schedule.map(\.end) }
    func entries(from start: Date, mode: TimelineScheduleMode) -> [Date] { [start] + ends.filter { $0 > start } }
}

/// What's on the channel now, as a line under its name; `otherwise` (or nothing) without a guide or a programme.
struct NowOnText: View {
    let channel: Channel
    var otherwise: String? = nil
    @Environment(LiveGuide.self) private var guide: LiveGuide?
    var body: some View {
        let schedule = guide?.schedule(for: channel) ?? []
        Group {
            if schedule.isEmpty {
                if let otherwise { Text(otherwise) }
            } else {
                TimelineView(ProgrammeTimes(schedule)) { context in
                    if let now = schedule.now(at: context.date) { Text(now.title) } else if let otherwise { Text(otherwise) }
                }
            }
        }
        .task(id: channel.name) { await guide?.fetch(channel) }
    }
}

/// The programme on now, with its times and how far in it is, and the one after: for the Apple TV guide's highlighted
/// channel. Nothing without a guide.
struct NowAndNext: View {
    let channel: Channel
    @Environment(LiveGuide.self) private var guide: LiveGuide?
    var body: some View {
        let schedule = guide?.schedule(for: channel) ?? []
        Group {
            if !schedule.isEmpty {
                TimelineView(.everyMinute) { context in
                    let date = context.date
                    VStack(alignment: .leading, spacing: 10) {
                        if let now = schedule.now(at: date) {
                            line(L10n.text("Now On"), now, emphasis: true)
                            ProgressView(value: date.timeIntervalSince(now.start), total: now.end.timeIntervalSince(now.start))
                                .frame(maxWidth: 420)
                        }
                        if let next = schedule.next(after: date) { line(L10n.text("Coming Up"), next, emphasis: false) }
                    }
                }
            }
        }
        .task(id: channel.name) { await guide?.fetch(channel) }
    }

    private func line(_ label: String, _ programme: Programme, emphasis: Bool) -> some View {
        HStack(spacing: 14) {
            Text(label).foregroundStyle(.secondary)
            Text(programme.start, format: .dateTime.hour().minute()).monospacedDigit().foregroundStyle(.secondary)
            Text(programme.title).fontWeight(emphasis ? .semibold : .regular).lineLimit(1)
        }
    }
}

/// Asks for the address of a playlist's guide, or for none to use the playlist's own.
struct GuideAddressAlert: ViewModifier {
    @Binding var isPresented: Bool
    let source: LiveSource
    /// The address the playlist gives itself, shown as the field's placeholder.
    let automatic: String?
    let saved: () -> Void
    @Environment(Store.self) private var store
    @State private var text = ""

    func body(content: Content) -> some View {
        content
            .alert(L10n.text("Program Guide"), isPresented: $isPresented) {
                TextField(automatic ?? "https://…/epg.xml.gz", text: $text)
                    .autocorrectionDisabled()
                    #if !os(macOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                Button(L10n.text("Save")) {
                    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    store.guideAddresses[source.url.absoluteString] = value.isEmpty ? nil : value
                    saved()
                }
                Button(L10n.text("Cancel"), role: .cancel) {}
            } message: {
                Text(L10n.text("An XMLTV file (.xml or .xml.gz), or an address with {name} for each channel. Leave it empty to use the playlist's own guide."))
            }
            .onChange(of: isPresented) { _, shown in if shown { text = store.guideAddresses[source.url.absoluteString] ?? "" } }
    }
}
