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
                    "url-filter": #"^https?://([^/]+\.)?"# + escaped + #"([/:?#]|$)"#,
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
        let store = WKContentRuleListStore.default()
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
