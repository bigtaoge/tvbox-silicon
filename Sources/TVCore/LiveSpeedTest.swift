import Foundation

/// The latency of a live channel's lines, measured by asking each line's address for its head
/// (patch 14, B8). Only when the viewer opens the line list: nothing is measured in the background.
/// Results live 10 minutes in memory. The milliseconds are a probe latency, not playback speed.
public enum LiveSpeedTest {
    /// Each line gets this long to answer.
    public static let timeout: TimeInterval = 2
    /// How long a measurement stands before the line list measures again.
    public static let cacheLifetime: TimeInterval = 600

    // Every access goes through `lock`, so the storage is marked `nonisolated(unsafe)` for Swift 6
    // (the lock, not the compiler, guards it).
    private static nonisolated(unsafe) var cache: [String: (ms: Int, at: Date)] = [:]
    private static let lock = NSLock()

    /// The cached latency of a line's address, when measured in the last 10 minutes.
    public static func cachedMs(for url: URL) -> Int? {
        lock.withLock {
            guard let entry = cache[url.absoluteString], Date().timeIntervalSince(entry.at) < cacheLifetime else { return nil }
            return entry.ms
        }
    }

    /// The best (lowest) cached latency of the channel's lines, if any line was measured.
    public static func cachedMs(for channel: Channel) -> Int? {
        ([channel.url] + channel.alternates.map(\.url)).compactMap { cachedMs(for: $0) }.min()
    }

    /// Measures every line in parallel (2 s each) and returns the milliseconds by address.
    /// Lines with a fresh cached result are not measured again, unless `force`.
    public static func measure(_ lines: [Channel], force: Bool = false) async -> [String: Int] {
        var results: [String: Int] = [:]
        await withTaskGroup(of: (String, Int?).self) { group in
            for line in lines {
                group.addTask {
                    let key = line.url.absoluteString
                    if !force, let cached = cachedMs(for: line.url) { return (key, cached) }
                    return (key, await probe(line.url, headers: line.headers))
                }
            }
            for await (key, ms) in group {
                if let ms {
                    results[key] = ms
                    lock.withLock { cache[key] = (ms, Date()) }
                }
            }
        }
        return results
    }

    /// One line's latency, capped at `timeout` whatever the server does: a HEAD, else the first byte
    /// of a ranged GET, so a live FLV's endless body can't hang the probe.
    private static func probe(_ url: URL, headers: [String: String]) async -> Int? {
        await withTaskGroup(of: Int?.self) { group in
            group.addTask { await timedProbe(url, headers: headers) }
            group.addTask { try? await Task.sleep(for: .seconds(timeout)); return nil }
            defer { group.cancelAll() }
            return await group.next() ?? nil
        }
    }

    private static func timedProbe(_ url: URL, headers: [String: String]) async -> Int? {
        let began = Date()
        if let ms = await head(url, headers: headers, began: began) { return ms }
        return await firstByte(url, headers: headers, began: began)
    }

    private static func head(_ url: URL, headers: [String: String], began: Date) async -> Int? {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "HEAD"
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode) else { return nil }
        return Int(Date().timeIntervalSince(began) * 1000)
    }

    private static func firstByte(_ url: URL, headers: [String: String], began: Date) async -> Int? {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        guard let (bytes, _) = try? await URLSession.shared.bytes(for: request) else { return nil }
        var iterator = bytes.makeAsyncIterator()
        guard (try? await iterator.next()) != nil else { return nil }
        return Int(Date().timeIntervalSince(began) * 1000)
    }
}
