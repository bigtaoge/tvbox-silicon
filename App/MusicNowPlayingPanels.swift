#if !os(tvOS)
import SwiftUI
import TVCore

/// Lyrics on the Now Playing screen, as the big music apps show them: the cover blurred behind,
/// large lines, the line being sung big, white and bold in the middle, the rest faded. Tapping a
/// line plays from it. Without lyrics the panel says so in the same space, so nothing around it moves.
struct MusicNowPlayingLyrics: View {
    @Environment(Store.self) private var store
    @State private var scrolled: Int?
    var showsTranslation = true
    #if os(macOS)
    // A window's worth of room: larger lines.
    private let size: CGFloat = 32, translationSize: CGFloat = 18, spacing: CGFloat = 30
    #else
    private let size: CGFloat = 28, translationSize: CGFloat = 17, spacing: CGFloat = 24
    #endif

    var body: some View {
        let music = store.music
        if let lyrics = music.lyrics {
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: spacing) {
                    ForEach(Array(lyrics.lines.enumerated()), id: \.offset) { index, line in
                        let current = lyrics.synced && index == music.currentLyric
                        VStack(alignment: .leading, spacing: 4) {
                            Text(line.text.isEmpty ? "♪" : line.text).font(.system(size: current ? size + 8 : size, weight: .bold))
                            if showsTranslation, let translation = line.translation {
                                Text(translation).font(.system(size: translationSize, weight: .semibold))
                            }
                        }
                        .foregroundStyle(.white.opacity(current ? 1 : 0.32))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .animation(.easeOut(duration: 0.3), value: current)
                        .contentShape(.rect)
                        .onTapGesture { if lyrics.synced { music.seek(toLyric: line) } }
                        .id(index)
                    }
                    Text(L10n.text("Lyrics from %@", lyrics.platform.name)).font(.caption).foregroundStyle(.secondary).padding(.top, 8)
                }
                .scrollTargetLayout()
                .padding(.vertical, 28)
            }
            .scrollPosition(id: $scrolled, anchor: UnitPoint(x: 0.5, y: 0.5))
            // The lines fade in and out at the panel's edges instead of being cut.
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.07),
                                         .init(color: .black, location: 0.9), .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
            // The cover, blurred and darkened, behind the lines, as the big music apps do.
            .background {
                ZStack {
                    MusicArtwork(url: music.track?.artwork, cornerRadius: 0)
                        .blur(radius: 50)
                        .scaleEffect(1.5)
                    Color.black.opacity(0.5)
                }
            }
            .clipShape(Rectangle())
            // Once the lines are laid out: set as the panel appeared, the position was dropped, and
            // reopening the player left the lyrics at the top until the next line.
            .task { try? await Task.sleep(for: .milliseconds(60)); scrolled = music.currentLyric }
            .onChange(of: music.currentLyric) { _, index in
                guard let index else { return }
                withAnimation(.smooth(duration: 0.5)) { scrolled = index }
            }
        } else if music.lyricsLoading || music.busy {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            EmptyResults(symbol: "quote.bubble", title: L10n.text("No Lyrics"), message: L10n.text("None of the catalogs has lyrics for this song."), fills: true)
        }
    }
}

/// The songs after this one in what is playing; tapping one plays it.
struct MusicUpNext: View {
    @Environment(Store.self) private var store

    var body: some View {
        let music = store.music
        let queue = music.queue
        let upcoming = queue.map { queue in Array(queue.tracks.enumerated()).filter { $0.offset > queue.index } } ?? []
        if upcoming.isEmpty {
            EmptyResults(symbol: "list.bullet", title: L10n.text("Nothing Up Next"),
                         message: L10n.text("Play a song from search results, an album or a playlist, and the songs after it play next."), fills: true)
        } else {
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("Up Next")).font(.headline).padding(.bottom, 6)
                    ForEach(upcoming, id: \.offset) { index, track in
                        MusicUpNextRow(index: index, track: track)
                    }
                }
                .padding(.vertical, 12)
            }
        }
    }
}

/// One song after this one: cover, title, artist, length; tapping it plays it. The Queue page
/// reuses the same row and adds a × to take the song out.
struct MusicUpNextRow: View {
    @Environment(Store.self) private var store
    let index: Int
    let track: MusicTrack
    var onRemove: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 12) {
            Button { store.music.jump(to: index) } label: {
                HStack(spacing: 12) {
                    MusicArtwork(url: track.artwork, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title).font(.body.weight(.medium)).lineLimit(1)
                        Text(track.artistLine).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if let duration = track.duration {
                        Text(MusicTime.text(duration)).font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("从队列移除")
            }
        }
    }
}

/// The playing queue as its own page: the song now, and what comes after it. From the Music
/// page's Now Playing card and the mini player's list button; the full player's Up Next panel
/// stays as it is.
struct MusicQueuePage: View {
    @Environment(Store.self) private var store
    @Bindable private var playlists = MusicPlaylistStore.shared
    @State private var justSaved = false

    var body: some View {
        let music = store.music
        ScrollView {
            LazyVStack(alignment: .leading, spacing: MusicLayout.rowSpacing) {
                if let track = music.track {
                    nowPlaying(track, music: music).padding(.bottom, 20)
                }
                if let queue = music.queue {
                    let upcoming = Array(queue.tracks.enumerated()).filter { $0.offset > queue.index }
                    HStack {
                        SectionHeader(title: L10n.text("Up Next"))
                        Spacer()
                        Button("清空") { music.clearUpNext() }
                            .controlButton()
                            .disabled(upcoming.isEmpty)
                    }
                    .padding(.bottom, 8)
                    .tvFocusSection()
                    if upcoming.isEmpty {
                        EmptyResults(symbol: "list.bullet", title: "队列里没有下一首",
                                     message: "播完这首就停了。去搜一首歌，或打开一张歌单接着播。")
                    }
                    ForEach(upcoming, id: \.offset) { index, track in
                        MusicUpNextRow(index: index, track: track) { music.removeFromQueue(at: index) }
                    }
                    Button {
                        let tracks = Array(queue.tracks[queue.index...])
                        _ = playlists.create(name: queue.source ?? "播放列表", tracks: tracks)
                        justSaved = true
                    } label: {
                        Label(justSaved ? "已存为歌单" : "存为歌单", systemImage: justSaved ? "checkmark" : "music.note.list")
                    }
                    .controlButton()
                    .padding(.top, 12)
                    .task(id: justSaved) {
                        guard justSaved else { return }
                        try? await Task.sleep(for: .seconds(2))
                        justSaved = false
                    }
                } else {
                    EmptyResults(symbol: "list.bullet", title: "没有正在播放的队列",
                                 message: "去搜一首歌，或打开一张歌单，播起来再看。")
                }
            }
            .glassRowInsets()
            .pageContainer()
        }
        .screenBackdrop()
        .screenTitle("播放列表")
        // No musicPlayerInset here: the strip's list button would push this page again, and the
        // page itself is the player — the song above has its own play control.
    }

    /// The song playing now: cover, title, artist, and a play/pause button; tapping the song
    /// itself opens the full player.
    private func nowPlaying(_ track: MusicTrack, music: MusicPlaybackSession) -> some View {
        HStack(spacing: MusicLayout.gap) {
            Button { music.presentsPlayer = true } label: {
                HStack(spacing: MusicLayout.gap) {
                    MusicArtwork(url: track.artwork, size: MusicLayout.art * 1.4)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.text("Now Playing")).font(.caption.weight(.semibold)).foregroundStyle(Brand.accent)
                        Text(track.title).font(.headline).lineLimit(1)
                        Text(track.artistLine).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer(minLength: 8)
            Button { music.toggle() } label: {
                Image(systemName: music.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
                    .frame(width: 44, height: 44).contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.text(music.isPlaying ? "Pause" : "Play"))
        }
        .padding(14)
        .contentPanel(cornerRadius: 20)
        .contentShape(Rectangle())
    }
}
#endif
