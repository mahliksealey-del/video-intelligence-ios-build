import SwiftUI
import WebKit

/// On-device, explicit Instagram sign-in; credentials go only to Instagram in
/// the site's own WebKit page. Session cookies are never displayed or logged.
struct InstagramSignInView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var session: InstagramSession
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let errorText {
                    Text(errorText).font(.footnote).foregroundStyle(.red).padding(8)
                }
                InstagramLoginWebView(dataStore: session.dataStore, errorText: $errorText)
            }
            .navigationTitle("Instagram Sign-In")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        Task {
                            await session.refresh()
                            dismiss()
                        }
                    }
                }
            }
        }
    }
}

private struct InstagramLoginWebView: UIViewRepresentable {
    let dataStore: WKWebsiteDataStore
    @Binding var errorText: String?

    func makeCoordinator() -> Coordinator { Coordinator(errorText: $errorText) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        if let url = URL(string: "https://www.instagram.com/accounts/login/") {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let errorText: Binding<String?>
        init(errorText: Binding<String?>) { self.errorText = errorText }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if (error as NSError).code != NSURLErrorCancelled {
                errorText.wrappedValue = error.localizedDescription
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            errorText.wrappedValue = nil
        }
    }
}
