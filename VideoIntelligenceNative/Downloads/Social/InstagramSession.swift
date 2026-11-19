import Combine
import Foundation
import WebKit

/// Optional, user-authorized Instagram session. WebKit persists its own cookies
/// on-device; extraction receives a short-lived, 0600 Netscape cookie file.
@MainActor
final class InstagramSession: ObservableObject {
    static let shared = InstagramSession()
    let dataStore: WKWebsiteDataStore = .default()
    @Published private(set) var hasSession = false

    private init() {}

    static func matchesInstagram(_ domain: String) -> Bool {
        let clean = domain.lowercased().hasPrefix(".") ? String(domain.lowercased().dropFirst()) : domain.lowercased()
        return clean == "instagram.com" || clean.hasSuffix(".instagram.com")
    }

    func refresh() async {
        let cookies = await dataStore.httpCookieStore.allCookies()
        hasSession = cookies.contains { cookie in
            Self.matchesInstagram(cookie.domain)
                && cookie.name == "sessionid"
                && (cookie.expiresDate.map { $0 > Date() } ?? true)
        }
    }

    func signOut() async {
        let store = dataStore.httpCookieStore
        let cookies = await store.allCookies()
        for cookie in cookies where Self.matchesInstagram(cookie.domain) {
            await store.deleteCookie(cookie)
        }
        hasSession = false
    }

    /// Returns nil for no opted-in session; never sends Instagram cookies to
    /// YouTube, TikTok, or unrelated URL hosts.
    func temporaryCookieFile(for url: URL) async throws -> URL? {
        guard let host = url.host, Self.matchesInstagram(host) else { return nil }
        let all = await dataStore.httpCookieStore.allCookies()
        let cookies = all.filter {
            Self.matchesInstagram($0.domain) &&
            ($0.expiresDate.map { $0 > Date() } ?? true)
        }
        guard cookies.contains(where: { $0.name == "sessionid" }) else {
            hasSession = false
            return nil
        }
        hasSession = true
        var content = "# Netscape HTTP Cookie File\n"
        for c in cookies {
            let fields = [
                c.domain, c.domain.hasPrefix(".") ? "TRUE" : "FALSE",
                c.path.isEmpty ? "/" : c.path, c.isSecure ? "TRUE" : "FALSE",
                String(Int(c.expiresDate?.timeIntervalSince1970 ?? 0)),
                c.name, c.value
            ]
            guard !fields.contains(where: { $0.contains("\n") || $0.contains("\r") || $0.contains("\t") }) else { continue }
            content += fields.joined(separator: "\t") + "\n"
        }
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("instagram-session-\(UUID().uuidString).txt")
        try Data(content.utf8).write(to: file, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return file
    }
}
