import Foundation

/// The last line that played, and the direct address a playlist's FLV relay resolved to, remembered
/// across launches so the next play starts there instead of resolving again (patch 14, B5).
/// Only playlist addresses are kept: a platform room's address expires, so rooms are never cached.
/// A cached address that fails is dropped and the channel resolves again (`PlaybackSession`).
public enum LiveLineCache {
    private static let key = "live.lineCache"
    /// Entries older than this are dropped when read.
    private static let lifetime: TimeInterval = 30 * 86400
    private static let cap = 200

    private struct Stored: Codable {
        var lines: [String: Line] = [:]
        var urls: [String: Resolved] = [:]
        struct Line: Codable { var line: Int; var at: Date }
        struct Resolved: Codable { var url: String; var at: Date }
    }

    private static var stored: Stored {
        get {
            guard let data = UserDefaults.standard.data(forKey: key),
                  var value = try? JSONDecoder().decode(Stored.self, from: data) else { return Stored() }
            let cutoff = Date().addingTimeInterval(-lifetime)
            value.lines = value.lines.filter { $0.value.at > cutoff }
            value.urls = value.urls.filter { $0.value.at > cutoff }
            return value
        }
        set {
            var value = newValue
            if value.lines.count > cap {
                value.lines = Dictionary(value.lines.sorted { $0.value.at > $1.value.at }.prefix(cap).map { ($0.key, $0.value) },
                                         uniquingKeysWith: { $1 })
            }
            if value.urls.count > cap {
                value.urls = Dictionary(value.urls.sorted { $0.value.at > $1.value.at }.prefix(cap).map { ($0.key, $0.value) },
                                        uniquingKeysWith: { $1 })
            }
            UserDefaults.standard.set(try? JSONEncoder().encode(value), forKey: key)
        }
    }

    /// The line of `channel` (its first line's id) that played last, if it is still one of its lines.
    public static func lastLine(for channel: Channel) -> Int? {
        stored.lines[channel.id]?.line
    }

    /// Remembers that `line` of `channel` played (the channel's first line is the key).
    public static func record(line: Int, for channel: Channel) {
        var value = stored
        value.lines[channel.id] = Stored.Line(line: line, at: Date())
        stored = value
    }

    /// The direct address `url` resolved to last time, if it was remembered.
    public static func resolvedURL(for url: URL) -> URL? {
        stored.urls[url.absoluteString].flatMap { URL(string: $0.url) }
    }

    /// Remembers that a playlist address resolved to `url`. Room addresses are never kept.
    public static func store(resolved url: URL, for original: URL) {
        guard url != original, !LiveCatalog.isRoom(original), !LiveCatalog.isRoom(url) else { return }
        var value = stored
        value.urls[original.absoluteString] = Stored.Resolved(url: url.absoluteString, at: Date())
        stored = value
    }

    /// Drops the remembered address for `url`, so the next play resolves it again.
    public static func clear(for url: URL) {
        var value = stored
        value.urls.removeValue(forKey: url.absoluteString)
        stored = value
    }
}
