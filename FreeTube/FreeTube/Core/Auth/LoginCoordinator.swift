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
    enum Failure: Equatable {
        case cookieTimeout
        case rejected
        case network(String)
        case webView(String)
        case unavailable

        var title: String {
            switch self {
            case .cookieTimeout:
                return "仍未获取 YouTube 登录 Cookie"
            case .rejected:
                return "YouTube 明确拒绝此登录会话"
            case .network:
                return "网络原因导致无法验证"
            case .webView:
                return "登录页面加载失败"
            case .unavailable:
                return "登录页面已经失效"
            }
        }

        var message: String {
            switch self {
            case .cookieTimeout:
                return "仍在等待 YouTube 登录 Cookie。\n\nGoogle 登录已经完成，但 WKWebView 在 20 秒内没有写入可用于验证的认证候选 Cookie。请点“重试”再次检测，或者切换账号。"
            case .rejected:
                return "YouTube 明确拒绝此登录会话。\n\nFreeTube 已把捕获到的 Cookie 交给 YouTube 服务端验证，但服务端仍返回未登录。请重试，或者切换另一个 Google 账号。"
            case .network(let detail):
                return "账号 Cookie 已获取，但暂时无法连接 YouTube 验证，请检查网络后重试。\n\n\(detail)"
            case .webView(let detail):
                return "Google 登录页面加载失败：\n\n\(detail)\n\n请检查网络后重试。"
            case .unavailable:
                return "登录页面已经失效，请关闭当前窗口后重新登录。"
            }
        }
    }

    enum State: Equatable {
        case idle
        case loading
        case awaitingCredentials
        case waitingForCookies
        case verifying
        case succeeded
        case failed(Failure)
    }

    private enum ValidationOutcome {
        case authenticated(AccountInfo)
        case rejected
        case network(String)
        case cancelled
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var candidateCookieNames: [String] = []
    @Published private(set) var verificationAttempt: Int = 0

    /// One immediate check plus 19 one-second waits keeps cookie polling active for about 20s.
    let maxVerificationAttempts = 20

    private let log = AppLog(subsystem: "com.leshko.freetube", category: "LoginCoordinator")
    private let cookieStore = CookieStore.shared
    private let session = SessionManager.shared
    private let accountService = AccountService()
    private weak var activeWebView: WKWebView?
    private var verificationTask: Task<Void, Never>?
    private var candidateHeader: String?
    private var candidateCookieCount = 0
    private var flowGeneration = 0
    private var isRedirectingToYouTube = false
    private var lastCookieInventorySignature = ""

    static let youTubeLandingURL: URL = {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.youtube.com"
        components.path = "/"
        guard let url = components.url else {
            preconditionFailure("Invalid static YouTube login URL")
        }
        return url
    }()

    /// Mirrors the working Google → YouTube hand-off used by the reference project. Starting at
    /// `ServiceLogin` with `service=youtube` makes Google finish at YouTube's sign-in endpoint so
    /// YouTube, rather than only Google AccountChooser, mints the final `.youtube.com` cookies.
    static let startURL: URL = {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "accounts.google.com"
        components.path = "/ServiceLogin"
        components.queryItems = [
            URLQueryItem(name: "service", value: "youtube"),
            URLQueryItem(name: "uilel", value: "3"),
            URLQueryItem(name: "passive", value: "true"),
            URLQueryItem(name: "continue", value: "https://www.youtube.com/signin?action_handle_signin=true&next=/")
        ]
        guard let url = components.url else {
            preconditionFailure("Invalid static Google YouTube sign-in URL")
        }
        return url
    }()

    /// Switching accounts deliberately returns to AccountChooser while preserving Google's
    /// persistent account list. Only YouTube-domain cookies are cleared before this URL is loaded.
    static let accountChooserURL: URL = {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "accounts.google.com"
        components.path = "/AccountChooser"
        components.queryItems = [
            URLQueryItem(name: "service", value: "youtube"),
            URLQueryItem(name: "continue", value: "https://www.youtube.com/signin?action_handle_signin=true&next=/")
        ]
        guard let url = components.url else {
            preconditionFailure("Invalid static Google account chooser URL")
        }
        return url
    }()

    func resetState() {
        invalidateCurrentFlow()
        state = .idle
    }

    func cancel() {
        invalidateCurrentFlow()
        activeWebView = nil
        state = .idle
    }

    func prepareForLogin(in webView: WKWebView) async {
        activeWebView = webView
        invalidateCurrentFlow()
        activeWebView = webView
        state = .loading
        let generation = flowGeneration

        await clearYouTubeCookies(from: webView)

        guard isCurrent(generation), !Task.isCancelled else { return }
        state = .awaitingCredentials
        webView.load(URLRequest(url: Self.startURL))
    }

    func handleNavigation(to url: URL?, in webView: WKWebView) {
        activeWebView = webView
        guard let url else {
            log.debug("[login] handleNavigation called with nil URL")
            return
        }

        let host = url.host?.lowercased() ?? "?"
        log.info("[login] navigation host=\(host, privacy: .public) path=\(url.path, privacy: .public)")

        if Self.host(host, belongsTo: "youtube.com") {
            isRedirectingToYouTube = false
            switch state {
            case .succeeded, .failed(_):
                return
            default:
                beginVerification(in: webView)
                return
            }
        }

        if isPostSignInGoogleURL(url) {
            guard !isRedirectingToYouTube else { return }
            switch state {
            case .succeeded, .failed(_):
                return
            default:
                isRedirectingToYouTube = true
                log.info("[login] post-sign-in Google page detected; loading youtube.com to mint YouTube cookies")
                state = .loading
                webView.load(URLRequest(url: Self.youTubeLandingURL))
                return
            }
        }

        if Self.host(host, belongsTo: "accounts.google.com"), state != .loading {
            switch state {
            case .succeeded, .failed(_), .verifying, .waitingForCookies:
                break
            default:
                state = .awaitingCredentials
            }
        }
    }

    func handleWebViewFailure(_ error: Error) {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            return
        }

        log.error("[login] web view navigation failed: domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public)")

        // A YouTube service verification already in flight is authoritative. A late WebKit
        // callback must not cancel it or replace its result with a generic page-load failure.
        guard verificationTask == nil else {
            log.notice("[login] ignored WebKit failure while cookie/server verification is active")
            return
        }
        switch state {
        case .succeeded, .failed(_):
            return
        default:
            state = .failed(.webView(error.localizedDescription))
        }
    }

    func retryVerification() {
        guard verificationTask == nil else { return }
        guard let webView = activeWebView else {
            state = .failed(.unavailable)
            return
        }

        let previousState = state
        if case .failed(.network(_)) = previousState, let candidateHeader {
            startCandidateRetry(candidateHeader)
            return
        }

        candidateHeader = nil
        candidateCookieCount = 0
        candidateCookieNames = []
        verificationAttempt = 0
        lastCookieInventorySignature = ""
        isRedirectingToYouTube = true
        state = .loading

        if case .failed(.webView(_)) = previousState, let currentURL = webView.url {
            webView.load(URLRequest(url: currentURL))
        } else {
            webView.load(URLRequest(url: Self.youTubeLandingURL))
        }
    }

    func chooseAnotherAccount() {
        guard let webView = activeWebView else {
            state = .failed(.unavailable)
            return
        }

        invalidateCurrentFlow()
        activeWebView = webView
        state = .loading
        let generation = flowGeneration

        Task { [weak self, weak webView] in
            guard let self, let webView else { return }
            await self.clearYouTubeCookies(from: webView)
            guard self.isCurrent(generation), !Task.isCancelled else { return }
            self.state = .awaitingCredentials
            webView.load(URLRequest(url: Self.accountChooserURL))
        }
    }

    private func beginVerification(in webView: WKWebView) {
        // `didCommit` and `didFinish` both arrive for the same navigation. There is exactly one
        // task for the full cookie-polling + server-verification lifecycle.
        guard verificationTask == nil else {
            log.debug("[login] navigation callback ignored; verification task already active")
            return
        }

        candidateCookieNames = []
        verificationAttempt = 0
        state = .waitingForCookies
        let generation = flowGeneration

        verificationTask = Task { [weak self, weak webView] in
            guard let self, let webView else { return }
            await self.pollForCookiesAndVerify(in: webView, generation: generation)
        }
    }

    private func pollForCookiesAndVerify(in webView: WKWebView, generation: Int) async {
        var lastRejectedHeader: String?
        var receivedExplicitRejection = false

        for attempt in 1...maxVerificationAttempts {
            guard isCurrent(generation), !Task.isCancelled else { return }
            verificationAttempt = attempt

            let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
            guard isCurrent(generation), !Task.isCancelled else { return }

            logCookieInventoryIfChanged(cookies)

            guard let candidate = cookieStore.makeHeaderCandidate(from: cookies) else {
                candidateCookieNames = cookieStore.authenticationCandidateNames(in: cookies)
                state = .waitingForCookies
                await waitBeforeNextCookieCheck(attempt: attempt)
                continue
            }

            candidateCookieCount = candidate.cookieCount
            candidateCookieNames = candidate.authenticationCookieNames

            // A rejected header is retried only if WebKit has actually written a different
            // candidate. This gives asynchronous cookie writes the full polling window without
            // hammering the account endpoint with an identical rejected request every second.
            guard candidate.header != lastRejectedHeader else {
                state = .waitingForCookies
                await waitBeforeNextCookieCheck(attempt: attempt)
                continue
            }

            candidateHeader = candidate.header
            let outcome = await validate(candidate, generation: generation)
            guard isCurrent(generation), !Task.isCancelled else { return }

            switch outcome {
            case .authenticated(let accountInfo):
                commit(accountInfo, generation: generation)
                return

            case .rejected:
                receivedExplicitRejection = true
                lastRejectedHeader = candidate.header
                candidateHeader = nil
                candidateCookieCount = 0
                session.discardCandidateCookies()
                log.notice("[login] server result: isDisconnected=true; waiting for any later WebKit cookie update")
                state = .waitingForCookies

            case .network(let detail):
                // Keep both the in-memory candidate and the coordinator's private copy so Retry
                // can repeat only the server validation without asking for the Google password.
                state = .failed(.network(detail))
                finishVerificationTask(generation: generation)
                return

            case .cancelled:
                return
            }

            await waitBeforeNextCookieCheck(attempt: attempt)
        }

        guard isCurrent(generation), !Task.isCancelled else { return }
        candidateHeader = nil
        candidateCookieCount = 0
        session.discardCandidateCookies()
        state = .failed(receivedExplicitRejection ? .rejected : .cookieTimeout)
        finishVerificationTask(generation: generation)
    }

    private func validate(
        _ candidate: CookieStore.HeaderCandidate,
        generation: Int
    ) async -> ValidationOutcome {
        guard isCurrent(generation), !Task.isCancelled else { return .cancelled }

        state = .verifying
        session.applyCandidateCookies(candidate.header)
        log.info("[login] validating candidate with YouTube: cookies=\(candidate.cookieCount, privacy: .public) authNames=[\(candidate.authenticationCookieNames.joined(separator: ","), privacy: .public)]")

        do {
            let accountInfo = try await accountService.fetchAccountInfo()
            guard isCurrent(generation), !Task.isCancelled else { return .cancelled }
            log.info("[login] server result: authenticated=true isDisconnected=false")
            return .authenticated(accountInfo)
        } catch is CancellationError {
            return .cancelled
        } catch YouTubeServiceError.notAuthenticated {
            guard isCurrent(generation), !Task.isCancelled else { return .cancelled }
            log.notice("[login] server result: authenticated=false isDisconnected=true")
            return .rejected
        } catch {
            guard isCurrent(generation), !Task.isCancelled else { return .cancelled }
            log.error("[login] server validation unavailable: \(String(describing: error), privacy: .public)")
            return .network(error.localizedDescription)
        }
    }

    private func startCandidateRetry(_ header: String) {
        guard verificationTask == nil else { return }
        let generation = flowGeneration
        state = .verifying

        verificationTask = Task { [weak self] in
            guard let self else { return }
            let candidate = CookieStore.HeaderCandidate(
                header: header,
                authenticationCookieNames: self.candidateCookieNames,
                cookieCount: self.candidateCookieCount
            )
            let outcome = await self.validate(candidate, generation: generation)
            guard self.isCurrent(generation), !Task.isCancelled else { return }

            switch outcome {
            case .authenticated(let accountInfo):
                self.commit(accountInfo, generation: generation)

            case .rejected:
                self.candidateHeader = nil
                self.candidateCookieCount = 0
                self.session.discardCandidateCookies()
                self.state = .failed(.rejected)
                self.finishVerificationTask(generation: generation)

            case .network(let detail):
                self.state = .failed(.network(detail))
                self.finishVerificationTask(generation: generation)

            case .cancelled:
                break
            }
        }
    }

    private func commit(_ accountInfo: AccountInfo, generation: Int) {
        guard isCurrent(generation) else { return }
        let trimmedName = accountInfo.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        session.commitAuthenticatedSession(displayName: trimmedName.isEmpty ? nil : trimmedName)
        candidateHeader = nil
        candidateCookieCount = 0
        state = .succeeded
        log.info("[login] verified candidate committed; state=succeeded")
        finishVerificationTask(generation: generation)
    }

    private func waitBeforeNextCookieCheck(attempt: Int) async {
        guard attempt < maxVerificationAttempts else { return }
        try? await Task.sleep(for: .seconds(1))
    }

    private func finishVerificationTask(generation: Int) {
        guard isCurrent(generation) else { return }
        verificationTask = nil
    }

    private func invalidateCurrentFlow() {
        flowGeneration += 1
        verificationTask?.cancel()
        verificationTask = nil
        session.discardCandidateCookies()
        candidateHeader = nil
        candidateCookieCount = 0
        candidateCookieNames = []
        verificationAttempt = 0
        isRedirectingToYouTube = false
        lastCookieInventorySignature = ""
    }

    private func isCurrent(_ generation: Int) -> Bool {
        flowGeneration == generation
    }

    private func logCookieInventoryIfChanged(_ cookies: [HTTPCookie]) {
        let relevant = cookieStore.relevantCookies(from: cookies).sorted {
            if $0.name != $1.name { return $0.name < $1.name }
            if $0.domain != $1.domain { return $0.domain < $1.domain }
            return $0.path < $1.path
        }
        let candidateNames = cookieStore.authenticationCandidateNames(in: relevant)
        let signature = relevant.map {
            "\($0.name)|\($0.domain)|\($0.path)|\($0.isSecure)|\($0.isHTTPOnly)|\($0.value.count)"
        }.joined(separator: ";")

        guard signature != lastCookieInventorySignature else { return }
        lastCookieInventorySignature = signature

        log.info("[login] cookie inventory changed: all=\(cookies.count, privacy: .public) relevant=\(relevant.count, privacy: .public) authNames=[\(candidateNames.joined(separator: ","), privacy: .public)]")
        for cookie in relevant {
            log.info("[login] cookie name=\(cookie.name, privacy: .public) domain=\(cookie.domain, privacy: .public) path=\(cookie.path, privacy: .public) secure=\(cookie.isSecure, privacy: .public) httpOnly=\(cookie.isHTTPOnly, privacy: .public) valueLength=\(cookie.value.count, privacy: .public)")
        }
    }

    private func isPostSignInGoogleURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if host == "myaccount.google.com" { return true }
        if host == "accounts.google.com" {
            let path = url.path.lowercased()
            return path.contains("manageaccount")
                || path.contains("checkcookie")
                || path.contains("/b/")
        }
        return false
    }

    private func clearYouTubeCookies(from webView: WKWebView) async {
        let store = webView.configuration.websiteDataStore.httpCookieStore
        let cookies = await store.allCookies()
        let staleYouTubeCookies = cookies.filter {
            Self.host($0.domain, belongsTo: "youtube.com")
        }

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
        for cookie in cookies where host(cookie.domain, belongsTo: "youtube.com") {
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

    private static func host(_ host: String, belongsTo baseDomain: String) -> Bool {
        let normalized = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return normalized == baseDomain || normalized.hasSuffix(".\(baseDomain)")
    }
}
