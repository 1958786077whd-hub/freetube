import SwiftUI
import WebKit
import OSLog

@available(iOS 17.0, *)
struct LoginWebView: UIViewRepresentable {
    @ObservedObject var coordinator: LoginCoordinator

    private static let log = AppLog(subsystem: "com.leshko.freetube", category: "LoginWebView")

    func makeCoordinator() -> Delegate { Delegate(parent: self) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()

        // Use the persistent per-app website data store. This does NOT give FreeTube access to
        // Safari, Gmail, or the YouTube app's cookies (iOS sandboxing prevents that), but it does
        // let Google remember accounts that the user has already signed into inside FreeTube so
        // later sign-ins can show Google's account chooser instead of requiring credentials again.
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
            LoginWebView.log.debug("[webview] didStart: \(webView.url?.absoluteString ?? "?", privacy: .public)")
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            LoginWebView.log.debug("[webview] didCommit: \(webView.url?.absoluteString ?? "?", privacy: .public)")
            Task { @MainActor in
                parent.coordinator.handleNavigation(to: webView.url, in: webView)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            LoginWebView.log.debug("[webview] didFinish: \(webView.url?.absoluteString ?? "?", privacy: .public)")
            Task { @MainActor in
                parent.coordinator.handleNavigation(to: webView.url, in: webView)
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            LoginWebView.log.error("[webview] didFail: \(error.localizedDescription, privacy: .public) url=\(webView.url?.absoluteString ?? "?", privacy: .public)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            LoginWebView.log.error("[webview] didFailProvisional: \(error.localizedDescription, privacy: .public) url=\(webView.url?.absoluteString ?? "?", privacy: .public)")
        }
    }
}
