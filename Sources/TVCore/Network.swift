import Foundation

public struct HTTPClient: Sendable {
    public static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
    // Subscription hosts often send a landing page to browser user agents.
    public static let subscriptionUserAgent = "okhttp/3.12.13"
    public let session: URLSession
    let mirrors: GitHubMirrors
    public init(session: URLSession = .shared) { self.init(session: session, mirrors: .shared) }
    init(session: URLSession, mirrors: GitHubMirrors) { self.session = session; self.mirrors = mirrors }
    /// Most downloads stop at 20 MB; a subscription address can also be a book source list, and complete Legado lists
    /// run past 20 MB (one with 3907 sources is 21 MB).
    public static let subscriptionLimit = 64_000_000
    /// `fresh` asks the server again instead of taking a copy from this device's HTTP cache. `limit` is the most bytes
    /// accepted.
    public func get(_ url: URL, headers: [String: String] = [:], fresh: Bool = false, limit: Int = 20_000_000) async throws -> (Data, URL) {
        if let data = try ImportedFiles.data(at: url) { return (data, url) }
        // A source whose subscription needs a sign-in (Xiaoya with forced login on) keeps
        // needing it after the import: its CMS API, posters and play links all live on the
        // same host, and the spider's own requests go through this same client on the Swift
        // side. Add the saved Basic header for that host only, and only when the caller did
        // not already supply one. Looked up on the original URL, and only sent when the
        // address actually fetched is that same host — never to a GitHub mirror.
        let savedAuthorization: String? = headers.keys.contains(where: { $0.lowercased() == "authorization" }) ? nil
            : SubscriptionCredentials.shared.authorizationHeader(for: url)
        return try await mirrors.fetch(url, timeout: 25) { [session] address, timeout in
            var request = URLRequest(url: address, timeoutInterval: timeout)
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            if fresh { request.cachePolicy = .reloadIgnoringLocalCacheData }
            for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
            if address.host()?.lowercased() == url.host()?.lowercased(), let savedAuthorization {
                request.setValue(savedAuthorization, forHTTPHeaderField: "Authorization")
            }
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw TVError.invalidConfiguration }
            guard (200..<300).contains(http.statusCode) else { throw TVError.http(http.statusCode) }
            guard data.count <= limit else {
                throw TVError.unsupported(limit == 20_000_000 ? L10n.text("The playlist exceeds 20 MB. Use a smaller subscription.")
                                          : L10n.text("The file is larger than %lld MB.", limit / 1_000_000))
            }
            // A mirror's address isn't the file's origin: relative paths resolve against the original.
            return (data, address == url ? response.url ?? url : url)
        }
    }
    public func subscription(_ url: URL, credential: SubscriptionCredential? = nil) async throws -> Subscription {
        if let credential { SubscriptionCredentials.shared.remember(credential, for: url) }
        let (data, finalURL) = try await get(url, headers: ["User-Agent": Self.subscriptionUserAgent].merging(credential?.headers ?? [:]) { $1 })
        if let bundle = CatPawOpen.bundle(data, at: finalURL) { return try await CatPawOpen.subscription(bundle: bundle, origin: finalURL, http: self) }
        return try await Subscription.parse(data, origin: finalURL).sniffingScripts(http: self, credential: credential)
    }
    public func channels(_ source: LiveSource) async throws -> [Channel] { try await playlist(source).channels }
    /// A live source's channels, and the XMLTV guide its M3U header names, if any (#802).
    public func playlist(_ source: LiveSource) async throws -> (channels: [Channel], guide: String?) {
        if let platform = source.platform { return (try await LiveCatalog.channels(platform), nil) }
        let (data, finalURL) = try await get(source.url, headers: source.headers)
        guard let text = String(data: data, encoding: .utf8) else { throw TVError.unsupported(L10n.text("Live playlists must use UTF-8 encoding.")) }
        let guide = Playlist.guideAddress(in: text).flatMap { try? WebAddress.resolve($0, relativeTo: finalURL).absoluteString }
        return (try Playlist.parse(text, origin: finalURL, headers: source.headers), guide)
    }
}
