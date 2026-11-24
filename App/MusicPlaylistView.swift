import SwiftUI
import TVCore

/// A playlist the listener built: its songs, Play and Shuffle, and a menu to rename or delete it.
/// The list looks like an album or playlist page; the songs play as one queue from the tapped one.
struct MusicPlaylistView: View {
    let playlistID: UUID
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Bindable private var playlists = MusicPlaylistStore.shared
    @State private var showsRename = false
    @State private var newName = ""
    @State private var confirmsDelete = false

    private var playlist: MusicPlaylist? { playlists.playlists.first { $0.id == playlistID } }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: MusicLayout.rowSpacing) {
                if let playlist {
                    header(playlist).padding(.bottom, 20)
                    if playlist.tracks.isEmpty {
                        EmptyResults(symbol: "music.note.list", title: "歌单还是空的",
                                     message: "长按一首歌，选“加入歌单”，就能把它加进来。")
                    }
                    ForEach(Array(playlist.tracks.enumerated()), id: \.element.id) { index, track in
                        HStack(spacing: 10) {
                            MusicTrackRow(track: track, number: index + 1) {
                                store.music.play(MusicQueue(tracks: playlist.tracks, start: index, source: playlist.name))
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Button { playlists.remove(track, from: playlist) } label: {
                                Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("从歌单移除")
                        }
                    }
                }
            }
            .glassRowInsets()
            .pageContainer()
        }
        .screenBackdrop()
        .screenTitle(playlist?.name ?? "歌单")
        .musicPlayerInset()
        .alert("重命名歌单", isPresented: $showsRename) {
            TextField("歌单名称", text: $newName)
            Button("保存") { if let playlist { playlists.rename(playlist, to: newName) } }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog("删除这个歌单？", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("删除歌单", role: .destructive) {
                if let playlist { playlists.remove(playlist) }
                dismiss()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("歌单里的歌曲不受影响，只是这个歌单不在了。")
        }
    }

    private func header(_ playlist: MusicPlaylist) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: MusicLayout.gap * 1.4) {
                Image(systemName: "music.note.list")
                    .font(.system(size: MusicLayout.header * 0.4, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: MusicLayout.header, height: MusicLayout.header)
                    .background(Brand.accent.gradient, in: RoundedRectangle(cornerRadius: MusicLayout.header * 0.24, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.text("Playlist")).font(.caption.weight(.semibold)).foregroundStyle(Brand.accent)
                    Text(playlist.name).font(.title2.weight(.bold)).lineLimit(2)
                    Text(L10n.text("%lld songs", playlist.tracks.count)).font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 10) {
                Group {
                    Button { store.music.play(MusicQueue(tracks: playlist.tracks, source: playlist.name)) } label: {
                        Label(L10n.text("Play"), systemImage: "play.fill")
                    }
                    .controlButton(prominent: true)
                    Button { store.music.play(MusicQueue.shuffled(playlist.tracks, source: playlist.name)) } label: {
                        Label(L10n.text("Shuffle"), systemImage: "shuffle")
                    }
                    .controlButton()
                    Button { store.music.addToUpNext(playlist.tracks) } label: {
                        Label(L10n.text("Add to Up Next"), systemImage: "text.line.last.and.arrowtriangle.forward")
                    }
                    .controlButton()
                }
                .disabled(playlist.tracks.isEmpty)
                Menu {
                    Button { newName = playlist.name; showsRename = true } label: { Label("重命名", systemImage: "pencil") }
                    Button(role: .destructive) { confirmsDelete = true } label: { Label("删除歌单", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis").font(.body.weight(.bold))
                        .frame(width: 38, height: 38).glassSurface(.regular, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("更多")
            }
            .fixedSize()
            .tvFocusSection()
        }
    }
}

/// One playlist on the Music page: its name and song count; tapping it opens it.
struct MusicPlaylistRow: View {
    let playlist: MusicPlaylist

    var body: some View {
        RouteLink { MusicPlaylistView(playlistID: playlist.id) } label: {
            HStack(spacing: MusicLayout.gap) {
                Image(systemName: "music.note.list")
                    .font(.system(size: MusicLayout.art * 0.46, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: MusicLayout.art, height: MusicLayout.art)
                    .background(Brand.accent.gradient, in: RoundedRectangle(cornerRadius: MusicLayout.art * 0.3, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(playlist.name).font(.headline).lineLimit(1).foregroundStyle(.primary)
                    Text(L10n.text("%lld songs", playlist.tracks.count)).font(.subheadline).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.subheadline.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassRow()
    }
}

/// Pick a playlist for a song, or make a new one with it in: from a song's long-press menu.
struct MusicAddToPlaylistSheet: View {
    let track: MusicTrack
    @Bindable private var playlists = MusicPlaylistStore.shared
    @State private var newName = ""

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: MusicLayout.rowSpacing) {
                HStack {
                    Text("加入歌单").font(.title3.weight(.bold))
                    Spacer(minLength: 8)
                    Button { playlists.pickingTrack = nil } label: { Image(systemName: "xmark").font(.body.weight(.semibold)) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("关闭")
                }
                .padding(.bottom, 8)
                HStack(spacing: 10) {
                    TextField("新建歌单名称", text: $newName)
                        .textFieldStyle(.roundedBorder)
                    Button("新建并加入") {
                        _ = playlists.create(name: newName, tracks: [track])
                        playlists.pickingTrack = nil
                    }
                    .controlButton(prominent: true)
                    .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.bottom, 8)
                if playlists.playlists.isEmpty {
                    EmptyResults(symbol: "music.note.list", title: "还没有歌单",
                                 message: "在上面起个名字，就能新建第一个歌单。")
                }
                ForEach(playlists.playlists) { playlist in
                    Button {
                        playlists.add(track, to: playlist)
                        playlists.pickingTrack = nil
                    } label: {
                        HStack(spacing: MusicLayout.gap) {
                            Image(systemName: "music.note.list")
                                .font(.system(size: MusicLayout.art * 0.46, weight: .semibold)).foregroundStyle(.white)
                                .frame(width: MusicLayout.art, height: MusicLayout.art)
                                .background(Brand.accent.gradient, in: RoundedRectangle(cornerRadius: MusicLayout.art * 0.3, style: .continuous))
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(playlist.name).font(.headline).lineLimit(1).foregroundStyle(.primary)
                                Text(L10n.text("%lld songs", playlist.tracks.count)).font(.subheadline).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            if playlists.contains(track, in: playlist) {
                                Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Brand.accent)
                            }
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .glassRow()
                }
            }
            .glassRowInsets()
            .pageContainer()
        }
        .screenBackdrop()
        .presentationDragIndicator(.visible)
    }
}
