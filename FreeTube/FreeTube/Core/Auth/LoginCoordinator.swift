import Foundation
import Combine
import WebKit
import OSLog

/// Drives the `WKWebView`-based login flow.
///
/// The login web view uses a persistent per-app website data store so Google accounts that were
/// previously used inside FreeTube can appear in Google's account chooser on later sign-ins.
/// Safari / Google-app cookies are still isolated by iOS and cannot be read by this app.
@available(iOS 17.0, *)
@MainActor
final class LoginCoordinator: NSObject, ObservableObject {
    enum State: Equatable {
        case idle
        case loading
        case awaitingCredentials
        case verifying
        case succeeded
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var missingCookieNames: [String] = []
    @Published private(set) var verificationAttempt: Int = 0

    let maxVerificationAttempts = 8

    private let log = AppLog(subsystem: "com.leshko.freetube", category: "LoginCoordinator")
    private let session = SessionManager.shared
    private let accountService = AccountService()
    private weak var activeWebView: WKWebView?
    private var verificationTask: Task<Void, Never>?

    func resetState() {
        verificationTask?.cancel()
        verificationTask = nil
        missingCookieNames = []
        verificationAttempt = 0
        state = .idle
    }

    static let startURL: URL = {
        var components = URLComponents(string: "https://accounts.google.com/AccountChooser")!
        components.queryItems = [
            URLQueryItem(name: "service", value: "youtube"),
            URLQueryItem(name: "continue", value: "https://www.youtube.com/signin?action_handle_signin=true&next=/")
        ]
        return components.url!
    }()

    static let signedInHostFragment = "youtube.com"
    static let youTubeLandingURL = URL(string: "https://www.youtube.com/")!

    func prepareForLogin(in webView: WKWebView) async {
        activeWebView = webView
        verificationTask?.cancel()
        verificationTask = nil
        missingCookieNames = []
        verificationAttempt = 0
        state = .loading

        await clearYouTubeCookies(from: webView)

        state = .awaitingCredentials
        webView.load(URLRequest(url: Self.startURL))
    }

    func handleNavigation(to url: URL?, in webView: WKWebView) {
        activeWebView = webView
        guard let url else {
            log.debug("[login] handleNavigation called with nil url")
            return
        }

        log.info("[login] nav → host=\(url.host ?? "?", privacy: .public) path=\(url.path, privacy: .public)")

        if url.host?.contains(Self.signedInHostFragment) == true {
            if state != .succeeded {
                beginVerification(in: webView)
            }
            return
        }

        if isPostSignInGoogleURL(url) {
            log.info("[login] detected post-sign-in Google URL — bouncing to youtube.com to mint YT cookies")
            state = .loading
            webView.load(URLRequest(url: Self.youTubeLandingURL))
            return
        }

        if url.host?.contains("accounts.google.com") == true, state != .loading {
            state = .awaitingCredentials
        }
    }

    func handleWebViewFailure(_ error: Error) {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            return
        }

        verificationTask?.cancel()
        verificationTask = nil
        log.error("[login] web view navigation failed: \(error.localizedDescription, privacy: .public)")
        state = .failed("Google 登录页面加载失败：\(error.localizedDescription)\n\n请检查网络后重试。")
    }

    func retryVerification() {
        guard let webView = activeWebView else {
            state = .failed("登录页面已经失效，请关闭当前窗口后重新登录。")
            return
        }

        verificationTask?.cancel()
        verificationTask = nil
        missingCookieNames = []
        verificationAttempt = 0
        state = .loading
        webView.load(URLRequest(url: Self.youTubeLandingURL))
    }

    func chooseAnotherAccount() {
        guard let webView = activeWebView else {
            state = .failed("登录页面已经失效，请关闭当前窗口后重新登录。")
            return
        }

        verificationTask?.cancel()
        verificationTask = nil
        missingCookieNames = []
        verificationAttempt = 0
        state = .loading

        Task { [weak self, weak webView] in
            guard let self, let webView else { return }
            await self.clearYouTubeCookies(from: webView)
            guard self.state != .succeeded else { return }
            self.state = .awaitingCredentials
            webView.load(URLRequest(url: Self.startURL))
        }
    }

    private func beginVerification(in webView: WKWebView) {
        verificationTask?.cancel()
        missingCookieNames = []
        verificationAttempt = 0
        state = .verifying

        verificationTask = Task { [weak self, weak webView] in
            guard let self, let webView else { return }

            for attempt in 1...self.maxVerificationAttempts {
                guard !Task.isCancelled else { return }
                self.verificationAttempt = attempt

                if await self.captureCookies(from: webView) {
                    self.verificationTask = nil
                    return
                }

                if attempt < self.maxVerificationAttempts {
                    try? await Task.sleep(for: .milliseconds(1500))
                }
            }

            guard !Task.isCancelled else { return }
            let missing = self.missingCookieNames.isEmpty
                ? "未知会话 Cookie"
                : self.missingCookieNames.joined(separator: ", ")

            self.verificationTask = nil
            self.state = .failed(
                "Google 登录已经完成，但 FreeTube 没有获取到完整的 YouTube 登录 Cookie。\n\n缺少：\(missing)\n\n你可以重试检测，或者切换另一个 Google 账号。"
            )
        }
    }

    private func isPostSignInGoogleURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if host == "myaccount.google.com" { return true }
        if host == "accounts.google.com" {
            let path = url.path.lowercased()
            return path.contains("manageaccount") || path.contains("checkcookie") || path.contains("/b/")
        }
        return false
    }

    /// Returns true when verification should stop: either YouTube confirmed the account or a
    /// definitive validation error was shown to the user.
    private func captureCookies(from webView: WKWebView) async -> Bool {
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        let ytCookies = cookies.filter {
            $0.domain.hasSuffix("youtube.com") || $0.domain.hasSuffix("google.com")
        }
        let presentNames = Set(ytCookies.map(\.name))
        let missingNames = CookieStore.requiredCookieNames.subtracting(presentNames).sorted()
        missingCookieNames = missingNames
        let missing = missingNames.joined(separator: ",")

        let byName = Dictionary(grouping: ytCookies, by: \.name)
        let duplicateNames = byName.filter { $0.value.count > 1 }
        let duplicateSummary = duplicateNames
            .map { "\($0.key)×\($0.value.count)" }
            .sorted()
            .joined(separator: ",")
        let domainSet = Set(ytCookies.map(\.domain)).sorted().joined(separator: ",")

        log.info("[login] captureCookies: total=\(cookies.count, privacy: .public) ytScoped=\(ytCookies.count, privacy: .public) presentRequired=\(CookieStore.requiredCookieNames.intersection(presentNames).count, privacy: .public)/\(CookieStore.requiredCookieNames.count, privacy: .public) missing=[\(missing, privacy: .public)] uniqueNames=\(byName.count, privacy: .public)")
        log.info("[login] captureCookies domains: [\(domainSet, privacy: .public)]")
        if !duplicateNames.isEmpty {
            log.info("[login] captureCookies duplicates (will be deduped): [\(duplicateSummary, privacy: .public)]")
        }

        guard let header = CookieStore.shared.makeHeader(from: cookies) else {
            log.notice("[login] required cookie set incomplete — retrying automatically")
            return false
        }

        log.info("[login] required cookies present, applying session and validating with YouTube")
        await session.signIn(with: header)
        missingCookieNames = []

        do {
            _ = try await accountService.fetchAccountInfo()
            state = .succeeded
            log.info("[login] account validation succeeded — state=.succeeded")
            return true
        } catch YouTubeServiceError.notAuthenticated {
            log.notice("[login] cookie names were complete but YouTube rejected the session")
            await session.signOut()
            state = .failed("Cookie 已获取完整，但 YouTube 没有接受这个登录会话。\n\n请点“切换账号”重新登录。")
            return true
        } catch {
            log.error("[login] account validation request failed: \(String(describing: error), privacy: .public)")
            state = .failed("登录 Cookie 已获取，但验证账号时网络请求失败：\n\n\(error.localizedDescription)\n\n请检查网络后点“重试”。")
            return true
        }
    }

    private func clearYouTubeCookies(from webView: WKWebView) async {
        let store = webView.configuration.websiteDataStore.httpCookieStore
        let cookies = await store.allCookies()
        let staleYouTubeCookies = cookies.filter { $0.domain.hasSuffix("youtube.com") }

        guard !staleYouTubeCookies.isEmpty else {
            log.info("[login] no stale YouTube cookies to clear before sign-in")
            return
        }

        for cookie in staleYouTubeCookies {
            await store.delete(cookie)
        }
        log.info("[login] cleared \(staleYouTubeCookies.count, privacy: .public) stale YouTube cookies; preserved Google account sessions")
    }

    static func clearYouTubeWebSession() async {
        let store = WKWebsiteDataStore.default().httpCookieStore
        let cookies = await store.allCookies()
        for cookie in cookies where cookie.domain.hasSuffix("youtube.com") {
            await store.delete(cookie)
        }
    }

    static func clearWebData() async {
        let types: Set<String> = [
            WKWebsiteDataTypeCookies,
            WKWebsiteDataTypeLocalStorage,
            WKWebsiteDataTypeSessionStorage,
            WKWebsiteDataTypeIndexedDBDatabases,
            WKWebsiteDataTypeWebSQLDatabases
        ]
        await WKWebsiteDataStore.default()
            .removeData(ofTypes: types, modifiedSince: .distantPast)
    }
}
