import Foundation
import WebKit

/// Video Intelligence's lightweight WebKit-native content blocker.
/// This uses Apple's compiled WKContentRuleList APIs; it does not attempt
/// to load Firefox's uBlock Origin WebExtension into WKWebView.
///
/// Rules intentionally target third-party ad delivery and tracking hosts,
/// not media resources or all third-party iframes. Users can disable the
/// blocker immediately if a legitimate site's video fails to load.
enum NativeAdBlocker {
    static let identifier = "VideoIntelligenceBasicBlocker-v1"

    // Original conservative seed set. Future expanded EasyList/AdGuard rules
    // require a reviewed, licensed and tested converter (see research log).
    static let adHosts: [String] = [
        "doubleclick.net",
        "googlesyndication.com",
        "googleadservices.com",
        "adservice.google.com",
        "adsrvr.org",
        "adnxs.com",
        "rubiconproject.com",
        "pubmatic.com",
        "openx.net",
        "criteo.com",
        "criteo.net",
        "outbrain.com",
        "taboola.com",
        "scorecardresearch.com",
        "quantserve.com",
        "moatads.com",
        "bidswitch.net",
        "casalemedia.com",
        "yieldmo.com",
        "lijit.com"
    ]

    static var rulesJSON: String {
        let rules: [[String: Any]] = adHosts.map { host in
            // Native JSON escaper below preserves the literal backslashes
            // required by WKContentRuleList's regex engine.
            let escaped = host
                .replacingOccurrences(of: ".", with: #"\."#)
            return [
                "trigger": [
                    "url-filter": #"^https?://([^/]+\.)?"# + escaped + #"/"#,
                    "load-type": ["third-party"],
                    // Avoid blocking video and document by default.
                    "resource-type": ["script", "image", "raw", "popup"]
                ],
                "action": ["type": "block"]
            ]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return string
    }

    /// The rule list is compiled/loaded locally and attached only to this
    /// in-app WKWebView. Site login cookies are not shared externally.
    static func prepare(_ completion: @escaping (WKContentRuleList?, Error?) -> Void) {
        guard let store = WKContentRuleListStore.default() else {
            completion(nil, NSError(domain: "VideoIntelligenceAdBlocker", code: 1,
                                    userInfo: [NSLocalizedDescriptionKey: "The WebKit rule store is unavailable."]))
            return
        }
        store.lookUpContentRuleList(forIdentifier: identifier) { existing, error in
            if let existing {
                completion(existing, nil)
                return
            }
            store.compileContentRuleList(
                forIdentifier: identifier,
                encodedContentRuleList: rulesJSON
            ) { rule, compileError in
                completion(rule, compileError ?? error)
            }
        }
    }
}


/// Explicit navigation guard for video pages where tapping Play repeatedly
/// redirects the main browser to a third-party advertising site. This is OFF
/// by default, to preserve real logins and normal navigation. It never affects
/// subframe media URLs or video CDN requests.
enum VideoSiteNavigationLock {
    static func shouldBlock(currentPage: URL?, nextPage: URL?,
                            isMainFrame: Bool, enabled: Bool) -> Bool {
        guard enabled, isMainFrame,
              let sourceHost = currentPage?.host?.lowercased(),
              let nextPage,
              ["http", "https"].contains(nextPage.scheme?.lowercased() ?? ""),
              let targetHost = nextPage.host?.lowercased(),
              URLSafetyPolicy.isPublic(nextPage) else { return false }
        return sourceHost != targetHost
    }
}
