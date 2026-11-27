#if os(iOS)
import Combine
import MediaPlayer
import PlayerEngineKit
import SwiftUI
import TVCore
import UIKit

/// The AetherEngine live session: one shared engine for a playlist channel's lines.
/// Switching channels or lines only loads a new URL into the same engine, never
/// creates a new one (an app has one engine; PlayerEngine.shared).
/// Only playlist channels use it — platform rooms stay on PlaybackView, and the
/// engine is created lazily by PlayerEngine.shared the first time live TV opens.
/// This is the verified AetherEngine 7.76.0 path (2026-11-28): the engine is created
/// after the JVM is already running without crashing, the [FFmpeg] line is the
/// FFmpegBuild version, and a 山东移动 CCTV1 stream plays with picture, MP2 sound
/// and smooth playback. It replaces VLCLiveSession, whose player init cannot run
/// once the JVM is up (fix-3–fix-7); the VLC files stay in the repo untouched as
/// the fallback, they are just no longer called by the live page.
@MainActor @Observable final class AetherLiveSession {
    /// What the view shows while a line opens: Opening / Buffering / Playing / Paused / Error.
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
    /// Seconds from load() starting to the first frame, when it has played; nil before.
    /// Recorded to Diagnostics with the audio codecs when the line becomes ready.
    private(set) var firstFrameSeconds: Double?
    /// The audio tracks the engine found (MP2 shows as codec "mp2"). The live page
    /// doesn't display them; they are here so the session carries what the test page
    /// shows, and Diagnostics logs their codecs on first frame.
    var audioTracks: [PlayerAudioTrack] { player.audioTracks }

    /// The engine sends whatever headers a channel carries (LoadOptions.httpHeaders rides
    /// onto the playlist, every segment and every AES key — AetherEngine #119, including
    /// Authorization), so every playlist channel can play here. Only platform rooms stay
    /// on AVPlayer, and LiveView routes those by LiveCatalog.isRoom, not by this gate.
    static func supports(channel: Channel) -> Bool { true }

    /// Paused, for the chrome and Now Playing.
    var paused: Bool { state == .paused }
    /// The picture is up, or the error is: the page's cover can go (WatchPlayback.started).
    var started: Bool { state == .playing || error != nil }
    /// Elapsed seconds of the stream, for Now Playing. Live has no duration.
    var elapsedSeconds: Double { player.currentTime }

    /// When the line playing became ready. One that isn't ready after `lineWait` gives way to the next.
    private var lineReadyAt: ContinuousClock.Instant?
    /// A line that loaded but shows no picture gives way to the next after this long.
    /// The watch only starts once load() has returned, so the engine's probe
    /// (first load measured 5.8 s) doesn't eat the budget — 6 s is the VLC/AVPlayer value.
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
    /// The clock is only trusted as "frames render" once a load has returned (clockArmed):
    /// before that, currentTime may still hold the previous stream's value, and the
    /// session must not call that a first frame.
    private var clockArmed = false
    /// The last clock seen: the clock advancing is the ground truth that frames render
    /// (as VLC fix 2 — a player can report buffering while the picture is already up).
    private var lastCurrentTime: Double = 0

    /// The one shared engine: channel switches only load a new URL, never a new engine.
    /// Accessing .shared creates the engine (after the JVM is already running, which
    /// is the order the verification passed in).
    let player = PlayerEngine.shared
    private let nowPlaying = AetherNowPlaying()
    private var cancellables: Set<AnyCancellable> = []

    init() {
        observeEngine()
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
        Diagnostics.shared.record(.info, "player", "aether line \(index + 1)/\(lines.count) chosen")
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
        Diagnostics.shared.record(.warning, "player", "aether line \(line + 1)/\(lines.count) not ready; trying line \(next + 1)")
        let failed = line
        line = next; triedLines.insert(next)
        open(lines[next])
        notice = L10n.text("Line %@ didn't play. Trying line %@.", "\(failed + 1)", "\(next + 1)")
        return true
    }

    /// The current line failed: try the next, else show the failure.
    private func failCurrentLine() {
        if !tryNextLine() {
            state = .error
            error = L10n.text("This channel isn't playing right now.")
            nowPlaying.update(title: nil, session: self)
        }
    }

    /// Plays the current line again (the error overlay's Retry).
    func retryCurrentLine() {
        guard let lineChannel else { return }
        error = nil; notice = nil
        open(lineChannel)
    }

    func pause() {
        player.pause()
        state = .paused
        nowPlaying.update(title: nil, session: self)
    }
    func resume() {
        player.resume()
        state = .playing
        nowPlaying.update(title: channel?.name, session: self)
    }
    func togglePlayback() {
        if paused { resume() } else { pause() }
    }

    /// Stops playback and drops the session's tasks; the engine is kept for the next channel.
    func stop() {
        generation = UUID()
        lineWatch?.cancel(); lineWatch = nil
        preparation?.cancel(); preparation = nil
        player.stop()
        state = .idle; error = nil; notice = nil
        nowPlaying.stop()
    }

    // MARK: - Opening a line

    private func open(_ channel: Channel) {
        generation = UUID()
        let activeGeneration = generation
        lineWatch?.cancel(); lineWatch = nil
        preparation?.cancel(); preparation = nil
        lineReadyAt = nil; playingReported = false; clockArmed = false; lastCurrentTime = 0
        firstFrameSeconds = nil
        error = nil; notice = nil
        state = .opening
        lineChannel = channel
        Diagnostics.shared.record(.info, "player", "aether switch start name=\(channel.name) url=\(channel.url.absoluteString) headers=\(channel.headers.keys.sorted().joined(separator: ","))")
        preparation = Task { [weak self] in
            guard let self else { return }
            // The shared engine failed to create (creationError set): show the failure
            // instead of hanging on the waiting overlay.
            guard self.player.creationError == nil else {
                guard self.generation == activeGeneration, !Task.isCancelled else { return }
                self.state = .error
                self.error = L10n.text("Live playback isn't available right now.")
                return
            }
            // A playlist's FLV relay resolves to HLS: play the remembered address first, and refresh
            // the resolution behind it (as VLCLiveSession.open). The engine could play FLV itself, but the
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
            // Load it into the shared engine, with the channel's headers (LoadOptions.httpHeaders).
            // A newer load supersedes this one: PlayerEngine returns false for the superseded
            // load (CancellationError), and the generation check below drops it silently.
            let ok = await self.player.load(urlString: channel.url.absoluteString, headers: channel.headers)
            guard self.generation == activeGeneration, !Task.isCancelled else { return }
            if ok {
                // load() returned: the session is up. The first frame (or the moving clock)
                // flips it to playing; a line that loads but shows no picture gives way
                // to the next after lineWait.
                if self.state == .opening { self.state = .buffering }
                self.clockArmed = true
                self.lastCurrentTime = self.player.currentTime
                self.lineWatch = Task { [weak self] in
                    try? await Task.sleep(for: Self.lineWait)
                    guard let self, !Task.isCancelled, self.generation == activeGeneration, self.lineReadyAt == nil, self.error == nil else { return }
                    self.failCurrentLine()
                }
            } else {
                self.failCurrentLine()
            }
        }
    }

    // MARK: - Engine signals
    //
    // The engine's Combine publishers drive the session's state; the session never parses
    // the engine's state string (it is a debug description, not a contract). load()
    // returning, the first frame, and the moving clock are the signals.

    private func observeEngine() {
        player.$hasFirstFrame
            .sink { [weak self] ready in
                guard let self, ready, self.state == .opening || self.state == .buffering else { return }
                self.markPlaying()
            }
            .store(in: &cancellables)
        player.$errorText
            .sink { [weak self] text in
                guard let self, !text.isEmpty, self.state == .playing else { return }
                Diagnostics.shared.record(.warning, "player", "aether error while playing: \(text)")
                self.failCurrentLine()
            }
            .store(in: &cancellables)
        player.$currentTime
            .sink { [weak self] time in
                guard let self else { return }
                defer { self.lastCurrentTime = max(self.lastCurrentTime, time) }
                guard self.clockArmed, self.state == .opening || self.state == .buffering,
                      time > self.lastCurrentTime else { return }
                self.markPlaying()
            }
            .store(in: &cancellables)
    }

    /// The playing bookkeeping, shared by the first-frame signal and the clock signal:
    /// the line is ready, the line is remembered, Now Playing starts. First-frame seconds
    /// and the audio codecs go to Diagnostics, so the switch time and the MP2 track are
    /// measurable in Diagnostic Logs.
    private func markPlaying() {
        state = .playing
        error = nil
        if lineReadyAt == nil {
            lineReadyAt = .now
            if let start = player.loadStartedAt {
                firstFrameSeconds = Date().timeIntervalSince(start)
            }
            // The line played: remember it, so the next play starts there (as PlaybackSession.watch).
            if lines.count > 1, let base = baseChannel { LiveLineCache.record(line: line, for: base) }
            Diagnostics.shared.record(.info, "player", "aether playing name=\(channel?.name ?? "-") firstFrame=\(firstFrameSeconds.map { String(format: "%.1f", $0) } ?? "-")s tracks=\(player.audioTracks.map(\.codec).joined(separator: ","))")
        }
        if !playingReported {
            playingReported = true
            nowPlaying.start(session: self)
        }
        nowPlaying.update(title: channel?.name, session: self)
    }
}

extension AetherLiveSession: LivePlayerSession {}

/// The channel on the Lock Screen, in Control Center and on headphones: play, pause and toggle.
/// The engine doesn't publish these for a host-owned session, so they are filled in by hand
/// (as VLCNowPlaying). Live has no timeline, so there is no seek or skip.
@MainActor final class AetherNowPlaying {
    private var targets: [(MPRemoteCommand, Any)] = []
    private var title = ""

    func start(session: AetherLiveSession) {
        guard targets.isEmpty else { return }
        let commands = MPRemoteCommandCenter.shared()
        func on(_ command: MPRemoteCommand, _ action: @escaping @MainActor (AetherLiveSession) -> Void) {
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
    func update(title: String?, session: AetherLiveSession) {
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

/// The AetherEngine player at the top of the Live page: the engine's picture, a waiting overlay driven by the
/// session's state, an error overlay with Retry / Try another line, and a tap-to-show chrome with
/// the channel name and the Full Screen button. No danmaku, subtitles or episode controls: playlist
/// live has none of those (as VLCLivePlaybackView).
struct AetherLivePlaybackView: View {
    let channel: Channel
    var watch: WatchPlayback
    var opened: (AetherLiveSession) -> Void = { _ in }
    @State private var session = AetherLiveSession()
    @State private var showsChrome = true
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.black
            PlayerEngineSurface(player: session.player)
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
            // AVPlayer keeps the screen awake while it plays; the engine needs the same by hand.
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
    /// "transcoding" step any more — the engine decodes as it downloads.
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

#endif
