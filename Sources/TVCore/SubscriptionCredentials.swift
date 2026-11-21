import Foundation
import Security

/// HTTP Basic Auth for one subscription host, e.g. Xiaoya with forced login on:
/// user name `dav`, password from `/etc/xiaoya/guestpass.txt`.

/// The password lives in the Keychain and in memory, never in the subscription list
/// (UserDefaults), in a file, or in logs.
public struct SubscriptionCredential: Codable, Hashable, Sendable {
    public var username: String
    public var password: String
    public init(username: String, password: String) { self.username = username; self.password = password }
    /// `Authorization: Basic base64(username:password)`, nil when either half is missing.
    public var authorizationHeader: String? {
        guard !username.isEmpty, !password.isEmpty else { return nil }
        return "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
    }
    public var headers: [String: String] {
        guard let value = authorizationHeader else { return [:] }
        return ["Authorization": value]
    }
}

/// A subscription host's sign-in, kept in the Keychain (one item per host) and in memory
/// for the plugin downloads that follow an import: a subscription JSON and the jar it
/// names live on the same host, so both need the same header. Modeled on
/// `KeychainSubtitleCredentials`: same service pattern, same accessibility.
public final class SubscriptionCredentials: @unchecked Sendable {
    public static let shared = SubscriptionCredentials()
    private let service = "com.jo32.yingxia.subscription-credentials"
    private let lock = NSLock()
    private var memory: [String: SubscriptionCredential] = [:]

    /// The sign-in for an address's host: memory first, else the Keychain. Nil when none was saved.
    public func credential(for url: URL) -> SubscriptionCredential? {
        guard let host = url.host()?.lowercased() else { return nil }
        lock.lock(); defer { lock.unlock() }
        if let saved = memory[host] { return saved }
        var query = base(host)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
              let credential = try? JSONDecoder().decode(SubscriptionCredential.self, from: data) else { return nil }
        memory[host] = credential
        return credential
    }

    /// The `Authorization` header for a download from this address's host, if one was saved.
    public func authorizationHeader(for url: URL) -> String? { credential(for: url)?.authorizationHeader }

    /// Remembers a sign-in for this session only (a subscription import does this so the
    /// jar download right after it sends the same header). The Keychain is untouched.
    public func remember(_ credential: SubscriptionCredential, for url: URL) {
        guard let host = url.host()?.lowercased() else { return }
        lock.lock(); defer { lock.unlock() }
        memory[host] = credential
    }

    /// Saves a sign-in to the Keychain (nil clears it from the Keychain and memory).
    public func save(_ credential: SubscriptionCredential?, for url: URL) {
        guard let host = url.host()?.lowercased() else { return }
        lock.lock(); defer { lock.unlock() }
        SecItemDelete(base(host) as CFDictionary)
        if let credential {
            memory[host] = credential
            guard let data = try? JSONEncoder().encode(credential) else { return }
            var item = base(host)
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let status = SecItemAdd(item as CFDictionary, nil)
            if status != errSecSuccess { Diagnostics.shared.record(.warning, "subscription", "keychain save failed status=\(status)") }
        } else {
            memory[host] = nil
        }
    }

    private func base(_ host: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: host]
    }
}
