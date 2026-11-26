import SwiftUI
import AVFoundation
import TVCore
#if os(iOS)
import MediaPlayer
import Darwin
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

// MARK: - Lazy loading (patch 19, lazy load, 2026-11-26)
//
// MobileVLCKit must not be linked into the app: dyld would load it at launch, and its
// presence in the process breaks the embedded runtimes (the JVM that runs jar plugins,
// QuickJS for music scripts) — pulling a subscription or playing a VOD then crashes,
// even though no VLC code ever runs. So the app never imports MobileVLCKit and the
// build strips the link flag (Podfile post_install); the framework is still embedded
// in the app bundle, and VLCRuntime dlopens it the first time live TV opens.
// The player itself is reached only through the ObjC runtime (VLCPlayerBridge).

/// Loads MobileVLCKit on demand. The heavy parts (JVM pre-warm, dlopen) run off the
/// main thread; the lock only guards the once-only load.
private enum VLCRuntime {
    private static let lock = NSLock()
    // Guarded by `lock`; the compiler cannot see that, so the unsafe marker is the
    // honest annotation (patch-verification skill: shared mutable state).
    nonisolated(unsafe) private static var handle: UnsafeMutableRawPointer?
    nonisolated(unsafe) private static var loaded = false

    /// The framework binary inside the app bundle. It is embedded by the
    /// "[CP] Embed Pods Frameworks" phase; the Podfile strips only the link flag.
    static var frameworkPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Frameworks/MobileVLCKit.framework/MobileVLCKit").path
    }

    /// dlopens the framework (once) and checks the two classes the player needs.
    /// RTLD_GLOBAL (not RTLD_LOCAL): libVLC loads its decoder/demuxer plugins
    /// itself, and they resolve their symbols through the global scope — with
    /// RTLD_LOCAL the plugins cannot load, libvlc fails to start, and the player
    /// init below returns nil (live TV crashed on tap, no picture, 2026-11-27).
    /// The app's own FFmpeg is statically linked, so its calls are already bound
    /// to its own copy; making VLC's symbols global does not rebind them.
    /// Fast; call it off the main thread anyway, because the JVM pre-warm it runs
    /// after can take a second.
    static func load() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if loaded { return true }
        guard let handle = dlopen(frameworkPath, RTLD_NOW | RTLD_GLOBAL) else {
            let reason = dlerror().map { String(cString: $0) } ?? "unknown error"
            Diagnostics.shared.record(.error, "player", "vlc dlopen failed: \(reason)")
            return false
        }
        self.handle = handle
        guard NSClassFromString("VLCMediaPlayer") != nil, NSClassFromString("VLCMedia") != nil else {
            Diagnostics.shared.record(.error, "player", "vlc classes missing after dlopen")
            return false
        }
        loaded = true
        return true
    }

    /// Starts the embedded JVM now, if the host is bundled, so its heap is reserved
    /// BEFORE VLC's framework is mapped in. The JVM starts lazily on first plugin
    /// use (AppleRuntime.m: TVAppleRuntimeRequest); if live TV opened first and the
    /// JVM started after VLC, its 384 MB–1 GB contiguous heap might not fit any more.
    /// The "trim" command releases idle runtimes — a no-op on a fresh JVM — and the
    /// JVM starts before the command is dispatched, which is the point here.
    /// Runs on the calling thread: call it off the main thread (TVAppleRuntimeRequest
    /// is documented to run on plugin worker threads, never the UI thread).
    /// Gated on EmbeddedJarHost.available: without the host in the bundle the call
    /// would set the runtime's sticky `failed` flag and break plugins for the session.
    static func prewarmJVM() {
        guard EmbeddedJarHost.available, let resources = Bundle.main.resourcePath else { return }
        resources.withCString { res in
            "{\"command\":\"trim\"}".withCString { req in
                if let out = tvAppleRuntimeRequest(res, req) { free(out) }
            }
        }
    }
}

/// The C entry point that starts the embedded JVM (AppleRuntime.m). EmbeddedJarHost
/// declares the same symbol for its own calls; this is the same function, referenced
/// directly so the pre-warm does not go through the plugin worker.
@_silgen_name("TVAppleRuntimeRequest")
private func tvAppleRuntimeRequest(_ resources: UnsafePointer<CChar>, _ request: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?

/// The player's state. Raw values copied from VLCMediaPlayerState (VLCMediaPlayer.h,
/// MobileVLCKit 3.7.5): Stopped 0, Opening 1, Buffering 2, Ended 3, Error 4,
/// Playing 5, Paused 6, ESAdded 7.
private enum VLCPlayerState: Int {
    case stopped = 0, opening = 1, buffering = 2, ended = 3, error = 4, playing = 5, paused = 6, esAdded = 7
}

/// The VLCMediaPlayer, reached only through the ObjC runtime: the app never links
/// MobileVLCKit, so there is no compile-time type for it. Properties go through KVC,
/// void methods through performSelector; the selectors and keys are the ones the 3.7.5
/// headers declare (VLCMediaPlayer.h, VLCMedia.h, VLCAudio.h, VLCTime.h):
/// state, time.intValue, rate, audio.volume, playing (getter isPlaying), drawable,
/// media, delegate, play/pause/stop, initWithURL:, addOptions:. There is no
/// compile-time check that they are right — a wrong one fails at runtime, not at
/// build time — so they are listed here, not scattered. A missing player is a no-op
/// that reports safe defaults, so a failed load degrades to an error overlay.
@MainActor private final class VLCPlayerBridge: NSObject {
    private var rawPlayer: NSObject?

    /// Whether the player exists (the framework loaded and the player was created).
    var isReady: Bool { rawPlayer != nil }

    /// Loads the framework and creates the one persistent player, with `delegate` as
    /// its delegate. The heavy part (JVM pre-warm + dlopen) runs off the main thread;
    /// the player itself is created here, on the MainActor. Returns false when VLC
    /// is unavailable — the session then shows an error instead of playing.
    func prepare(delegate: VLCLiveSession) async -> Bool {
        if rawPlayer != nil { return true }
        let loaded = await Task.detached(priority: .userInitiated) {
            VLCRuntime.prewarmJVM()
            return VLCRuntime.load()
        }.value
        guard loaded else { return false }
        guard let playerClass = NSClassFromString("VLCMediaPlayer") as? NSObject.Type else { return false }
        // Build the player as [[VLCMediaPlayer alloc] init] through performSelector:
        // a plain playerClass.init() traps (crashes) if the ObjC init returns nil
        // (libvlc failed to start), while perform returns nil and degrades to an
        // error overlay instead. This was the live-TV tap crash (2026-11-27).
        guard let allocated = (playerClass as AnyObject).perform(NSSelectorFromString("alloc"))?.takeRetainedValue() else { return false }
        guard let player = allocated.perform(NSSelectorFromString("init"))?.takeRetainedValue() as? NSObject else { return false }
        player.setValue(delegate, forKey: "delegate")
        rawPlayer = player
        return true
    }

    /// The player's state, or .stopped when there is no player.
    var state: VLCPlayerState {
        guard let raw = rawPlayer?.value(forKey: "state") as? NSNumber,
              let state = VLCPlayerState(rawValue: raw.intValue) else { return .stopped }
        return state
    }

    /// Elapsed milliseconds (VLCTime.intValue), or 0.
    var timeMs: Int32 {
        (rawPlayer?.value(forKeyPath: "time.intValue") as? NSNumber)?.int32Value ?? 0
    }

    /// Playback speed; live plays at 1x.
    var rate: Float {
        get { (rawPlayer?.value(forKey: "rate") as? NSNumber)?.floatValue ?? 1 }
        set { rawPlayer?.setValue(NSNumber(value: newValue), forKey: "rate") }
    }

    /// Audio volume 0–200 (VLCAudio.volume, ObjC int), 100 when unavailable.
    var volume: Int {
        get { (rawPlayer?.value(forKeyPath: "audio.volume") as? NSNumber)?.intValue ?? 100 }
        set { rawPlayer?.setValue(NSNumber(value: newValue), forKeyPath: "audio.volume") }
    }

    /// Whether the stream is playing (the `playing` property, getter isPlaying).
    var isPlaying: Bool {
        (rawPlayer?.value(forKey: "playing") as? NSNumber)?.boolValue ?? false
    }

    /// The view VLC draws into.
    var drawable: UIView? {
        get { rawPlayer?.value(forKey: "drawable") as? UIView }
        set { rawPlayer?.setValue(newValue, forKey: "drawable") }
    }

    func play() { rawPlayer?.perform(NSSelectorFromString("play")) }
    func pause() { rawPlayer?.perform(NSSelectorFromString("pause")) }
    func stop() { rawPlayer?.perform(NSSelectorFromString("stop")) }

    /// Hands a resolved address to VLC: builds the media, adds the cache and header
    /// options, and sets it as the player's media. Returns false when the media
    /// could not be built (the framework did not load).
    func setMedia(url: URL, options: [String: Any]) -> Bool {
        guard let mediaClass = NSClassFromString("VLCMedia") as? NSObject.Type,
              let rawPlayer else { return false }
        // NSObject.alloc is unavailable in Swift, so ask for it through performSelector:
        // the class object answers it like any NSObject. The +1 from alloc is handed to
        // initWithURL: below, as in [[VLCMedia alloc] initWithURL:].
        guard let allocated = (mediaClass as AnyObject).perform(NSSelectorFromString("alloc"))?.takeRetainedValue() else { return false }
        guard let media = allocated.perform(NSSelectorFromString("initWithURL:"), with: url)?.takeRetainedValue() as? NSObject else { return false }
        media.perform(NSSelectorFromString("addOptions:"), with: options as NSDictionary)
        rawPlayer.setValue(media, forKey: "media")
        return true
    }
}

/// The VLC live session (patch 19, step 2 + lazy load): one persistent VLCMediaPlayer for a playlist channel's
/// lines. Switching channels or lines only swaps the media, never the player. Only playlist channels
/// use it — platform rooms stay on PlaybackView, and a channel whose headers need anything VLC can't
/// send (Cookie, Authorization, ...) falls back to PlaybackView for that channel (LiveView.playerSection).
/// The player is created on demand by VLCPlayerBridge (dlopen); the session itself never
/// touches a VLCKit type, so the framework stays out of the process until live TV opens.
@MainActor @Observable final class VLCLiveSession: NSObject {
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
        let ms = player.timeMs
        guard ms > 0 else { return 0 }
        return Double(ms) / 1000
    }
    /// Playback speed; live plays at 1x.
    var rate: Float {
        get { player.rate }
        set { player.rate = newValue }
    }
    /// Audio volume (0–200 in libVLC; 100 is the usual level). The bridge converts
    /// at the boundary: VLCAudio.volume is ObjC `int`, which Swift imports as `Int32`.
    var volume: Int {
        get { player.volume }
        set { player.volume = newValue }
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
    /// The last playback clock seen from timeChanged: the clock advancing is the ground truth
    /// that frames render. libVLC can keep a live HLS stream in the buffering state while it
    /// plays, which would leave the waiting overlay up forever (fix 2, 2026-11-25).
    private var lastTimeMs: Int32 = 0

    /// The one persistent player: channel switches only swap its media, never the player.
    /// The bridge creates the real VLCMediaPlayer on demand (dlopen); until then it is
    /// a no-op, so nothing here can touch VLC before live TV opens.
    private let player = VLCPlayerBridge()
    private let nowPlaying = VLCNowPlaying()
    private weak var drawableView: UIView?

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
        lineReadyAt = nil; playingReported = false; lastTimeMs = 0
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
            // Load VLC before playing: the framework is dlopened on demand (see
            // VLCRuntime), and the JVM is pre-warmed first so its heap is reserved
            // before VLC's framework is mapped in. Already-loaded is a no-op.
            if !self.player.isReady {
                guard await self.player.prepare(delegate: self) else {
                    guard self.generation == activeGeneration, !Task.isCancelled else { return }
                    self.state = .error
                    self.error = L10n.text("Live playback isn't available right now.")
                    return
                }
            }
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
        var options: [String: Any] = ["network-caching": 1000, "http-reconnect": true]
        if let agent = channel.headers.first(where: { $0.key.lowercased() == "user-agent" })?.value, !agent.isEmpty {
            options["http-user-agent"] = agent
        }
        if let referrer = channel.headers.first(where: { $0.key.lowercased() == "referer" })?.value, !referrer.isEmpty {
            options["http-referrer"] = referrer
        }
        guard player.setMedia(url: channel.url, options: options) else {
            // VLC did not load (framework missing or classes gone): show the failure
            // instead of hanging on the waiting overlay.
            state = .error
            error = L10n.text("This channel isn't playing right now.")
            return
        }
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

    // MARK: - Player callbacks (VLCMediaPlayerDelegate)
    //
    // The session does not conform to VLCMediaPlayerDelegate at compile time — the app
    // never imports MobileVLCKit — but these @objc methods are the delegate callbacks:
    // libVLC calls them on the delegate when it responds to the selector, and the
    // bridge sets this session as the player's delegate. The signatures must stay
    // exactly as the protocol declares them (mediaPlayerStateChanged: /
    // mediaPlayerTimeChanged: taking a Notification).

    // libVLC calls these on its own threads, never the main one: each hops back to the MainActor
    // before touching state (assessment §7.4).

    @objc nonisolated func mediaPlayerStateChanged(_ aNotification: Notification) {
        Task { @MainActor [weak self] in self?.syncStateFromPlayer() }
    }

    @objc nonisolated func mediaPlayerTimeChanged(_ aNotification: Notification) {
        Task { @MainActor [weak self] in self?.refreshNowPlayingTime() }
    }

    /// The playing bookkeeping, shared by the state callback and the clock callback:
    /// the line is ready, the line is remembered, Now Playing starts.
    private func markPlaying() {
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
            markPlaying()
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
    /// The clock advancing is also the ground truth that the stream is playing: libVLC can keep
    /// a live HLS stream in the buffering state while frames render, which left the waiting
    /// overlay up forever. Once the clock moves, mark it playing (fix 2, 2026-11-25).
    private func refreshNowPlayingTime() {
        let ms = player.timeMs
        if (state == .opening || state == .buffering), ms > lastTimeMs {
            markPlaying()
        }
        lastTimeMs = max(lastTimeMs, ms)
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
