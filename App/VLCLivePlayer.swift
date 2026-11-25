import SwiftUI
import AVFoundation
import TVCore
#if os(iOS)
import MediaPlayer
import MobileVLCKit
#endif

/// A live player session the Live page's line list can switch lines through (LiveView.swift: the
/// line tab and `measureLines` read `lines`/`line` and call `choose(line:)`). Both the AVPlayer
/// session and the VLC session satisfy it, so the line list works whichever player a channel uses.
@MainActor protocol LivePlayerSession: AnyObject {
    var lines: [Channel] { get }
    var line: Int { get }
    func choose(line index: Int)
}

extension PlaybackSession: LivePlayerSession {}

#if os(iOS)

/// The VLC live session (patch 19, step 2): one persistent VLCMediaPlayer for a playlist channel's
/// lines. Switching channels or lines only swaps the media, never the player. Only playlist channels
/// use it — platform rooms stay on PlaybackView, and a channel whose headers need anything VLC can't
/// send (Cookie, Authorization, ...) falls back to PlaybackView for that channel (LiveView.playerSection).
@MainActor @Observable final class VLCLiveSession: NSObject, VLCMediaPlayerDelegate {
    /// What the view shows while a line opens: Opening / Buffering / Playing / Paused / Error.
    /// 3.7.5 has no buffering-percentage callback, so there is no progress number, only the state.
    enum State: Equatable {
        case idle, opening, buffering, playing, paused, error
    }

    private(set) var state: State = .idle
    /// The failure to show, when the last line tried failed and none is left.
    private(set) var error: String?
    /// A one-line note, e.g. that a line didn't play and the next is being tried.
    private(set) var notice: String?
    /// The channel playing, for the title and Now Playing.
    private(set) var channel: Channel?
    /// The channel's lines, after `url`: empty when it has one line. The Live page's line list reads these.
    private(set) var lines: [Channel] = []
    /// The line playing, as an index into `lines`.
    private(set) var line = 0

    /// Whether VLC can send every header the channel and its lines need: only User-Agent and Referer
    /// map to libVLC options. Anything else falls back to the AVPlayer path for that channel.
    static func supports(channel: Channel) -> Bool {
        channel.lines.allSatisfy { supports(headers: $0.headers) }
    }
    static func supports(headers: [String: String]) -> Bool {
        headers.keys.allSatisfy { ["user-agent", "referer"].contains($0.lowercased()) }
    }

    /// Paused, for the chrome and Now Playing.
    var paused: Bool { state == .paused }
    /// The picture is up, or the error is: the page's cover can go (WatchPlayback.started).
    var started: Bool { state == .playing || error != nil }
    /// Elapsed seconds of the stream, for Now Playing. Live has no duration.
    var elapsedSeconds: Double {
        let ms = player.time.intValue
        guard ms > 0 else { return 0 }
        return Double(ms) / 1000
    }
    /// Playback speed; live plays at 1x.
    var rate: Float {
        get { player.rate }
        set { player.rate = newValue }
    }
    /// Audio volume (0–200 in libVLC; 100 is the usual level).
    var volume: Int {
        get { player.audio?.volume ?? 100 }
        set { player.audio?.volume = newValue }
    }

    /// When the line playing became ready. One that isn't ready after `lineWait` gives way to the next.
    private var lineReadyAt: ContinuousClock.Instant?
    /// A line that never became ready gives way to the next after this long (as PlaybackSession.lineWait).
    private static let lineWait: Duration = .seconds(6)
    private var triedLines: Set<Int> = []
    private var lineWatch: Task<Void, Never>?
    private var preparation: Task<Void, Never>?
    /// Bumped on every open: tasks from an earlier line bail when they see it moved.
    private var generation = UUID()
    private var baseChannel: Channel?
    private var lineChannel: Channel?
    private var playingReported = false
    private var lastNowPlayingUpdate: Date?

    /// The one persistent player: channel switches only swap its media, never the player.
    let player = VLCMediaPlayer()
    private let nowPlaying = VLCNowPlaying()
    private weak var drawableView: UIView?

    override init() {
        super.init()
        player.delegate = self
    }

    // MARK: - Playing a channel

    /// Starts a channel: its lines, the last line that played, then the first open.
    func start(_ channel: Channel) {
        baseChannel = channel
        self.channel = channel
        lines = channel.alternates.isEmpty ? [] : channel.lines
        line = 0; triedLines = [0]
        // A live channel starts on the line that played last time (as PlaybackSession.start).
        if lines.count > 1,
           let cached = LiveLineCache.lastLine(for: channel), lines.indices.contains(cached) {
            line = cached; triedLines = [cached]
        }
        open(lines.isEmpty ? channel : lines[line])
    }

    /// Plays line `index` of the live channel, as the viewer chose: the others are there to fall back on again.
    func choose(line index: Int) {
        guard lines.indices.contains(index), index != line else { return }
        Diagnostics.shared.record(.info, "player", "vlc line \(index + 1)/\(lines.count) chosen")
        line = index; triedLines = [index]
        open(lines[index])
    }

    /// The channel's next line not tried since it was chosen, when this one failed or hasn't started;
    /// false when there is none left. A line that played a while before it dropped leaves every line
    /// to try again.
    func tryNextLine() -> Bool {
        guard lines.count > 1 else { return false }
        if let readyAt = lineReadyAt, readyAt.duration(to: .now) > .seconds(60) { triedLines = [line] }
        guard let next = (1..<lines.count).map({ (line + $0) % lines.count }).first(where: { !triedLines.contains($0) }) else { return false }
        Diagnostics.shared.record(.warning, "player", "vlc line \(line + 1)/\(lines.count) not ready; trying line \(next + 1)")
        let failed = line
        line = next; triedLines.insert(next)
        open(lines[next])
        notice = L10n.text("Line %@ didn't play. Trying line %@.", "\(failed + 1)", "\(next + 1)")
        return true
    }

    /// Plays the current line again (the error overlay's Retry).
    func retryCurrentLine() {
        guard let lineChannel else { return }
        error = nil; notice = nil
        open(lineChannel)
    }

    func pause() { player.pause() }
    func resume() { player.play() }
    func togglePlayback() {
        if player.isPlaying { player.pause() } else { player.play() }
    }

    /// Stops playback and drops the session's tasks; the player is kept for the next channel.
    func stop() {
        generation = UUID()
        lineWatch?.cancel(); lineWatch = nil
        preparation?.cancel(); preparation = nil
        player.stop()
        state = .idle; error = nil; notice = nil
        nowPlaying.stop()
    }

    /// The canvas's view for VLC to draw into; set again only when the view changes.
    func attachDrawable(_ view: UIView) {
        guard drawableView !== view else { return }
        drawableView = view
        player.drawable = view
    }

    // MARK: - Opening a line

    private func open(_ channel: Channel) {
        generation = UUID()
        let activeGeneration = generation
        lineWatch?.cancel(); lineWatch = nil
        preparation?.cancel(); preparation = nil
        lineReadyAt = nil; playingReported = false
        error = nil; notice = nil
        state = .opening
        lineChannel = channel
        configureAudioSession()
        if lines.count > 1 {
            lineWatch = Task { [weak self] in
                try? await Task.sleep(for: Self.lineWait)
                guard let self, !Task.isCancelled, self.generation == activeGeneration, self.lineReadyAt == nil, self.error == nil else { return }
                _ = self.tryNextLine()
            }
        }
        Diagnostics.shared.record(.info, "player", "vlc switch start name=\(channel.name) url=\(channel.url.absoluteString) headers=\(channel.headers.keys.sorted().joined(separator: ","))")
        preparation = Task { [weak self] in
            guard let self else { return }
            // A playlist's FLV relay resolves to HLS: play the remembered address first, and refresh
            // the resolution behind it (as PlaybackSession.open). VLC could play FLV itself, but the
            // relay also carries the platform's address, so the resolution stays.
            var channel = channel
            if let cached = LiveLineCache.resolvedURL(for: channel.url), !LiveCatalog.isRoom(cached) {
                let original = channel
                channel = Channel(name: channel.name, group: channel.group, url: cached, logo: channel.logo,
                                  headers: channel.headers, skipScope: channel.skipScope,
                                  historyContext: channel.historyContext, resumePosition: channel.resumePosition)
                Task {
                    let fresh = await LiveCatalog.playable(original)
                    if fresh.url != original.url { LiveLineCache.store(resolved: fresh.url, for: original.url) }
                }
            } else {
                let original = channel.url
                channel = await LiveCatalog.playable(channel)
                if channel.url != original { LiveLineCache.store(resolved: channel.url, for: original) }
            }
            guard self.generation == activeGeneration, !Task.isCancelled else { return }
            self.play(channel: channel)
        }
    }

    /// Hands the resolved address to VLC: the media options carry the cache and the headers libVLC
    /// can send. The player is reused; the old channel keeps playing until the new media replaces it.
    private func play(channel: Channel) {
        let media = VLCMedia(url: channel.url)
        var options: [String: Any] = ["network-caching": 1000, "http-reconnect": true]
        if let agent = channel.headers.first(where: { $0.key.lowercased() == "user-agent" })?.value, !agent.isEmpty {
            options["http-user-agent"] = agent
        }
        if let referrer = channel.headers.first(where: { $0.key.lowercased() == "referer" })?.value, !referrer.isEmpty {
            options["http-referrer"] = referrer
        }
        media.addOptions(options)
        player.media = media
        player.play()
    }

    /// The audio session, as PlaybackSession.configure sets it: libVLC's audio output goes through
    /// the same AVAudioSession.
    private func configureAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            if audioSession.category != .playback || audioSession.mode != .moviePlayback {
                try audioSession.setCategory(.playback, mode: .moviePlayback)
            }
            try audioSession.setActive(true)
        } catch { Diagnostics.shared.failure("player", "audio session", error) }
    }

    // MARK: - VLCMediaPlayerDelegate

    // libVLC calls these on its own threads, never the main one: each hops back to the MainActor
    // before touching state (assessment §7.4).

    @objc nonisolated func mediaPlayerStateChanged(_ aNotification: Notification) {
        Task { @MainActor [weak self] in self?.syncStateFromPlayer() }
    }

    @objc nonisolated func mediaPlayerTimeChanged(_ aNotification: Notification) {
        Task { @MainActor [weak self] in self?.refreshNowPlayingTime() }
    }

    /// The player's state, read back on the MainActor: drives the waiting UI, the line fallback,
    /// and Now Playing. Notifications that arrive after stop() are ignored (state is .idle then).
    /// The state is read fresh from the player, not from the notification, so a stale notification
    /// for a line already left just re-syncs the current one.
    private func syncStateFromPlayer() {
        guard state != .idle else { return }
        switch player.state {
        case .opening:
            state = .opening
        case .buffering:
            state = .buffering
        case .playing:
            state = .playing
            error = nil
            if lineReadyAt == nil {
                lineReadyAt = .now
                // The line played: remember it, so the next play starts there (as PlaybackSession.watch).
                if lines.count > 1, let base = baseChannel { LiveLineCache.record(line: line, for: base) }
            }
            if !playingReported {
                playingReported = true
                Diagnostics.shared.record(.info, "player", "vlc playing name=\(channel?.name ?? "-")")
                nowPlaying.start(session: self)
            }
            nowPlaying.update(title: channel?.name, session: self)
        case .paused:
            state = .paused
            nowPlaying.update(title: nil, session: self)
        case .error:
            // The line failed: try the next, else show the failure.
            if !tryNextLine() {
                state = .error
                error = L10n.text("This channel isn't playing right now.")
                nowPlaying.update(title: nil, session: self)
            }
        case .stopped, .ended:
            // A stop that arrives while a new line is opening belongs to the media change, not a
            // failure; one that arrives after the stream was up is the stream dying.
            if state == .playing || state == .buffering, !tryNextLine() {
                state = .error
                error = L10n.text("This channel isn't playing right now.")
                nowPlaying.update(title: nil, session: self)
            }
        case .esAdded:
            break
        @unknown default:
            break
        }
    }

    /// Now Playing's elapsed time, at most once every 5 seconds: timeChanged fires far more often.
    private func refreshNowPlayingTime() {
        guard state == .playing else { return }
        let now = Date()
        if let last = lastNowPlayingUpdate, now.timeIntervalSince(last) < 5 { return }
        lastNowPlayingUpdate = now
        nowPlaying.update(title: nil, session: self)
    }
}

extension VLCLiveSession: LivePlayerSession {}

/// The channel on the Lock Screen, in Control Center and on headphones: play, pause and toggle.
/// AVKit published these by itself for the AVPlayer path; VLC needs them filled in by hand
/// (assessment §6). Live has no timeline, so there is no seek or skip.
@MainActor final class VLCNowPlaying {
    private var targets: [(MPRemoteCommand, Any)] = []
    private var title = ""

    func start(session: VLCLiveSession) {
        guard targets.isEmpty else { return }
        let commands = MPRemoteCommandCenter.shared()
        func on(_ command: MPRemoteCommand, _ action: @escaping @MainActor (VLCLiveSession) -> Void) {
            command.isEnabled = true
            let target = command.addTarget { [weak self, weak session] _ in
                MainActor.assumeIsolated {
                    guard let session else { return .noActionableNowPlayingItem }
                    action(session)
                    self?.update(title: nil, session: session)
                    return .success
                }
            }
            targets.append((command, target))
        }
        on(commands.playCommand) { session in session.resume() }
        on(commands.pauseCommand) { session in session.pause() }
        on(commands.togglePlayPauseCommand) { session in session.togglePlayback() }
    }

    /// `title` nil keeps the one shown.
    func update(title: String?, session: VLCLiveSession) {
        guard !targets.isEmpty else { return }
        if let title { self.title = title }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: self.title,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyPlaybackRate: session.paused ? 0.0 : 1.0,
        ]
        let elapsed = session.elapsedSeconds
        if elapsed.isFinite, elapsed > 0 { info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = session.paused ? .paused : .playing
    }

    func stop() {
        for (command, target) in targets { command.removeTarget(target) }
        targets = []
        // Music may already have taken Now Playing back as the player closed.
        let center = MPNowPlayingInfoCenter.default()
        if center.nowPlayingInfo?[MPNowPlayingInfoPropertyMediaType] as? UInt == MPNowPlayingInfoMediaType.video.rawValue {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
        }
    }
}

/// The VLC player at the top of the Live page: the VLC picture, a waiting overlay driven by the
/// player's state, an error overlay with Retry / Try another line, and a tap-to-show chrome with
/// the channel name and the Full Screen button. No danmaku, subtitles or episode controls: playlist
/// live has none of those (assessment §4.3).
struct VLCLivePlaybackView: View {
    let channel: Channel
    var watch: WatchPlayback
    var opened: (VLCLiveSession) -> Void = { _ in }
    @State private var session = VLCLiveSession()
    @State private var showsChrome = true
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.black
            VLCCanvas(session: session)
            if session.state == .opening || session.state == .buffering {
                waitingOverlay
            } else if let error = session.error {
                errorOverlay(error)
            }
            if showsChrome {
                chromeOverlay
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { toggleChrome() }
        .environment(\.colorScheme, .dark)
        .onAppear {
            // AVPlayer keeps the screen awake while it plays; VLC needs the same by hand.
            UIApplication.shared.isIdleTimerDisabled = true
            session.start(channel)
            opened(session)
        }
        .onChange(of: channel) { _, channel in session.start(channel) }
        .onChange(of: session.started, initial: true) { _, started in watch.started(started) }
        .onChange(of: session.state) { _, state in
            if state == .playing { scheduleHide() } else { hideTask?.cancel(); showsChrome = true }
        }
        .onDisappear {
            hideTask?.cancel()
            UIApplication.shared.isIdleTimerDisabled = false
            session.stop()
        }
    }

    /// Opening or buffering: the channel name and what the player is doing. There is no
    /// "transcoding" step any more — VLC decodes as it downloads.
    private var waitingOverlay: some View {
        VStack(spacing: 10) {
            ProgressView().tint(.white)
            Text(session.channel?.name ?? channel.name)
                .font(.headline).foregroundStyle(.white).lineLimit(1)
            Text(session.state == .buffering ? L10n.text("Buffering…") : L10n.text("Connecting…"))
                .font(.subheadline).foregroundStyle(.white.opacity(0.7))
            if let notice = session.notice {
                Text(notice).font(.caption).foregroundStyle(.white.opacity(0.6))
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.45))
    }

    private func errorOverlay(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle").font(.title2).foregroundStyle(.white.opacity(0.8))
            Text(message).font(.subheadline).foregroundStyle(.white.opacity(0.85)).multilineTextAlignment(.center)
            if let notice = session.notice {
                Text(notice).font(.caption).foregroundStyle(.white.opacity(0.6))
            }
            HStack(spacing: 12) {
                Button(L10n.text("Retry")) { session.retryCurrentLine() }
                    .buttonStyle(.bordered).tint(.white)
                if session.lines.count > 1 {
                    Button(L10n.text("Try another line")) { _ = session.tryNextLine() }
                        .buttonStyle(.bordered).tint(.white)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.55))
    }

    private var chromeOverlay: some View {
        VStack {
            HStack {
                Text(channel.name)
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                    .lineLimit(1)
                Spacer()
                Button { watch.toggleFullScreen(true) } label: {
                    Image(systemName: watch.fullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .font(.headline).foregroundStyle(.white)
                        .padding(10)
                        .background(.black.opacity(0.45), in: Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Spacer()
        }
    }

    /// A tap on the picture shows the controls, or hides them at once. Only while playing: the
    /// waiting and error overlays keep the chrome up by themselves.
    private func toggleChrome() {
        guard session.state == .playing || session.state == .paused else { return }
        showsChrome.toggle()
        if showsChrome { scheduleHide() } else { hideTask?.cancel() }
    }

    /// The controls leave about three seconds into playback (as PlaybackView.scheduleHide).
    private func scheduleHide() {
        hideTask?.cancel()
        guard !session.paused, !UIAccessibility.isVoiceOverRunning else { return }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { withAnimation(.smooth(duration: 0.3)) { showsChrome = false } }
        }
    }
}

/// The VLC picture: a plain UIView VLC draws into (its drawable), replacing PlayerLayerView.
private struct VLCCanvas: UIViewRepresentable {
    let session: VLCLiveSession

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        session.attachDrawable(view)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        session.attachDrawable(view)
    }
}

#endif
