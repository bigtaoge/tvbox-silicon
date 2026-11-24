import Foundation
import Observation

/// A playlist the listener built: a name and its songs, in order. Songs are kept whole, not as
/// ids — there is no lookup by id in the catalogs, and the library's history keeps whole songs too.
public struct MusicPlaylist: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var tracks: [MusicTrack]
    public var createdAt: Date

    public init(id: UUID = UUID(), name: String, tracks: [MusicTrack] = [], createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.tracks = tracks
        self.createdAt = createdAt
    }
}

/// The listener's playlists, and the song waiting for one: kept in one file, as the library keeps
/// history and where listening stopped.
@MainActor @Observable public final class MusicPlaylistStore {
    public static let shared = MusicPlaylistStore(file: MusicLibrary.directory.appending(path: "music-playlists.json"))

    public private(set) var playlists: [MusicPlaylist] = []
    /// The song a menu offered to a playlist: set from a song's menu, cleared when the sheet closes.
    public var pickingTrack: MusicTrack?
    private let file: URL?
    private var saveTask: Task<Void, Never>?

    private struct Saved: Codable {
        var playlists: [MusicPlaylist]
    }

    public init(file: URL?) {
        self.file = file
        if let file, let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            playlists = saved.playlists
        }
    }

    @discardableResult public func create(name: String, tracks: [MusicTrack] = []) -> MusicPlaylist {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // A queue can hold the same song twice; a playlist lists it once, so the detail page's
        // ForEach (by id) never sees a duplicate.
        var seen: Set<String> = []
        let unique = tracks.filter { seen.insert($0.id).inserted }
        let playlist = MusicPlaylist(name: trimmed.isEmpty ? "未命名歌单" : trimmed, tracks: unique)
        playlists.append(playlist)
        scheduleSave()
        return playlist
    }

    public func rename(_ playlist: MusicPlaylist, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        playlists[index].name = name
        scheduleSave()
    }

    public func remove(_ playlist: MusicPlaylist) {
        playlists.removeAll { $0.id == playlist.id }
        scheduleSave()
    }

    /// Adds a song, once: a song already in the list stays where it is.
    public func add(_ track: MusicTrack, to playlist: MusicPlaylist) {
        add([track], to: playlist)
    }

    public func add(_ tracks: [MusicTrack], to playlist: MusicPlaylist) {
        guard let index = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        let fresh = tracks.filter { track in !playlists[index].tracks.contains { $0.id == track.id } }
        guard !fresh.isEmpty else { return }
        playlists[index].tracks.append(contentsOf: fresh)
        scheduleSave()
    }

    /// Takes a song out of a playlist.
    public func remove(_ track: MusicTrack, from playlist: MusicPlaylist) {
        guard let index = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        playlists[index].tracks.removeAll { $0.id == track.id }
        scheduleSave()
    }

    public func contains(_ track: MusicTrack, in playlist: MusicPlaylist) -> Bool {
        playlists.first { $0.id == playlist.id }?.tracks.contains { $0.id == track.id } ?? false
    }

    /// Writes after a short pause, so adding several songs saves once.
    private func scheduleSave() {
        guard let file, saveTask == nil else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self else { return }
            self.saveTask = nil
            self.saveNow(to: file)
        }
    }

    /// For leaving the app, when a delayed write might not happen.
    public func flush() {
        saveTask?.cancel(); saveTask = nil
        if let file { saveNow(to: file) }
    }

    private func saveNow(to file: URL) {
        guard let data = try? JSONEncoder().encode(Saved(playlists: playlists)) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}
