import Foundation
import SwiftUI

/// Independent, user-requested check of the route used for Video Intelligence's
/// native HTTPS requests. It does NOT start/stop a VPN or change network routing.
/// The result describes this request only; do not infer Tor is active forever.
enum TorRouteCheck: Equatable {
    case confirmed(exitIP: String)
    case notConfirmed(observedIP: String)
}

enum TorRoutingLinks {
    // Official Guardian Project/Orbot universal links. No custom scheme query,
    // extra app entitlement, third-party proxy, or embedded Tor runtime required.
    static let start = URL(string: "https://orbot.app/rc/start")!
    static let show = URL(string: "https://orbot.app/rc/show")!
    static let download = URL(string: "https://orbot.app/download")!
    static let check = URL(string: "https://check.torproject.org/api/ip")!
}

struct TorExitCheckResponse: Decodable, Equatable {
    let IsTor: Bool
    let IP: String
}

enum TorRouteCheckError: LocalizedError {
    case unexpectedResponse
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .unexpectedResponse:
            return "The Tor Project's network check did not respond successfully. No routing status was established."
        case .invalidResponse:
            return "The Tor Project returned an unreadable network-check response. No routing status was established."
        }
    }
}

struct TorRouteVerifier {
    static func interpret(_ data: Data) throws -> TorRouteCheck {
        guard let response = try? JSONDecoder().decode(TorExitCheckResponse.self, from: data),
              (3...64).contains(response.IP.count),
              !response.IP.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            throw TorRouteCheckError.invalidResponse
        }
        return response.IsTor
            ? .confirmed(exitIP: response.IP)
            : .notConfirmed(observedIP: response.IP)
    }

    func check() async throws -> TorRouteCheck {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 25
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: TorRoutingLinks.check)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.url?.scheme == "https", http.url?.host == "check.torproject.org" else {
            throw TorRouteCheckError.unexpectedResponse
        }
        return try Self.interpret(data)
    }
}

struct TorRoutingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var state: CheckState = .notChecked
    @State private var checkGeneration = UUID()

    private enum CheckState {
        case notChecked
        case checking
        case confirmed(String)
        case notConfirmed(String)
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Free privacy routing") {
                    Text("Orbot is a separate free, open-source app. When its Tor VPN is enabled, it can route your iPhone's network requests through Tor. Video Intelligence does not contain a VPN or choose a geographic exit region.")
                        .font(.footnote)
                    Link(destination: TorRoutingLinks.start) {
                        Label("Open Orbot and Start Tor", systemImage: "lock.shield")
                    }
                    Link(destination: TorRoutingLinks.show) {
                        Label("Open Orbot to Manage or Stop", systemImage: "gearshape")
                    }
                    Link(destination: TorRoutingLinks.download) {
                        Label("Get Orbot (free)", systemImage: "arrow.down.app")
                    }
                }
                Section("Check this app's HTTPS connection") {
                    Button {
                        checkTor()
                    } label: {
                        Label("Verify Tor routing", systemImage: "checkmark.shield")
                    }
                    .disabled(isChecking)

                    switch state {
                    case .notChecked:
                        Label("Not checked. Tor status is unknown.", systemImage: "questionmark.circle")
                            .foregroundStyle(.secondary)
                    case .checking:
                        ProgressView("Checking through the current connection…")
                    case .confirmed(let exitIP):
                        Label("Tor exit confirmed for this check", systemImage: "checkmark.shield.fill")
                            .foregroundStyle(.green)
                        LabeledContent("Observed exit IP", value: exitIP)
                    case .notConfirmed(let observedIP):
                        Label("Tor NOT detected for this request", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        LabeledContent("Observed public IP", value: observedIP)
                    case .failed(let message):
                        Text("Unable to verify: \(message)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Text("This sends one HTTPS request to check.torproject.org only when you tap Verify. It checks this app's native network route, not every webpage, playback stream, or future download. Results are not saved.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("Important") {
                    Text("Orbot routes the iPhone connection, not just Video Intelligence. Websites may block Tor exits, making YouTube or other downloads fail. Start or stop Tor in Orbot only when needed.")
                        .font(.footnote)
                    Text("Changing your IP location does not change legal residence or waive any applicable identity or age-verification requirements.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Tor Routing")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onChange(of: scenePhase) { phase in
                // Never display stale "Tor connected" after leaving to Orbot:
                // VPN state can change outside this app at any time.
                if phase != .active {
                    checkGeneration = UUID()
                    state = .notChecked
                }
            }
        }
    }

    private var isChecking: Bool {
        if case .checking = state { return true }
        return false
    }

    private func checkTor() {
        let generation = UUID()
        checkGeneration = generation
        state = .checking
        Task { @MainActor in
            do {
                let result = try await TorRouteVerifier().check()
                guard checkGeneration == generation, scenePhase == .active else { return }
                switch result {
                case .confirmed(let ip): state = .confirmed(ip)
                case .notConfirmed(let ip): state = .notConfirmed(ip)
                }
            } catch {
                guard checkGeneration == generation, scenePhase == .active else { return }
                state = .failed(error.localizedDescription)
            }
        }
    }
}
