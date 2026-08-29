import SwiftUI
import WebKit
import OSLog

@available(iOS 17.0, *)
struct LoginWebView: UIViewRepresentable {
    @ObservedObject var coordinator: LoginCoordinator

    private static let log = AppLog(subsystem: "com.leshko.freetube", category: "LoginWebView")

    private static func safeNavigationDescription(_ url: URL?) -> String {
        guard let url else { return "host=? path=?" }
        return "host=\(url.host ?? "?") path=\(url.path)"
    }

    func makeCoordinator() -> Delegate { Delegate(parent: self) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()

        // Persistent per-app storage lets Google remember accounts previously used inside FreeTube.
        // iOS still keeps this isolated from Safari, Gmail and the YouTube app.
        configuration.websiteDataStore = .default()

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true

        Task { @MainActor in
            await coordinator.prepareForLogin(in: webView)
        }

        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // No-op; the coordinator drives navigation and verification.
    }

    final class Delegate: NSObject, WKNavigationDelegate {
        let parent: LoginWebView
        init(parent: LoginWebView) { self.parent = parent }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            LoginWebView.log.debug("[webview] didStart: \(LoginWebView.safeNavigationDescription(webView.url), privacy: .public)")
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            LoginWebView.log.debug("[webview] didCommit: \(LoginWebView.safeNavigationDescription(webView.url), privacy: .public)")
            Task { @MainActor in
                parent.coordinator.handleNavigation(to: webView.url, in: webView)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            LoginWebView.log.debug("[webview] didFinish: \(LoginWebView.safeNavigationDescription(webView.url), privacy: .public)")
            Task { @MainActor in
                parent.coordinator.handleNavigation(to: webView.url, in: webView)
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            let nsError = error as NSError
            LoginWebView.log.error("[webview] didFail: domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public) \(LoginWebView.safeNavigationDescription(webView.url), privacy: .public)")
            Task { @MainActor in
                parent.coordinator.handleWebViewFailure(error)
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            let nsError = error as NSError
            LoginWebView.log.error("[webview] didFailProvisional: domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public) \(LoginWebView.safeNavigationDescription(webView.url), privacy: .public)")
            Task { @MainActor in
                parent.coordinator.handleWebViewFailure(error)
            }
        }
    }
}
