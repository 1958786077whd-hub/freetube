import Foundation
import OSLog

/// Loads the persisted cookie header on launch and pushes it to YouTubeKit. Reacts to expiration by
/// clearing cookies and flipping `AuthState.shared.status = .loggedOut`.
@available(iOS 17.0, *)
@MainActor
final class SessionManager {
    static let shared = SessionManager()

    private struct CandidateSession {
        var header: String
        let previousHeader: String
        let previousStatus: AuthState.Status
    }

    private let store = CookieStore.shared
    private let client = YouTubeKitClient.shared
    private let log = AppLog(subsystem: "com.leshko.freetube", category: "SessionManager")
    private var candidateSession: CandidateSession?

    private init() {}

    /// Call exactly once during `FreeTubeApp.init` or `RootView.onAppear`.
    func bootstrap() async {
        if let header = store.loadHeader(), !header.isEmpty {
            client.applyCookies(header)
            AuthState.shared.status = .loggedIn(displayName: nil)
            log.info("[session] bootstrap: header found in keychain (length=\(header.count, privacy: .public)) → applied to client, status=.loggedIn")
        } else {
            AuthState.shared.status = .loggedOut
            log.info("[session] bootstrap: no cookies on disk — status=.loggedOut")
        }
        // Visitor data is needed even for anonymous video requests. See YouTubeKitClient.ensureVisitorData().
        await client.ensureVisitorData()
        log.info("[session] bootstrap: visitor data ensured")
    }

    /// Applies a newly captured header only to the in-memory YouTubeKit models. Keychain and the
    /// global authenticated state remain untouched until server verification succeeds.
    func applyCandidateCookies(_ header: String) {
        if var candidateSession {
            candidateSession.header = header
            self.candidateSession = candidateSession
        } else {
            self.candidateSession = CandidateSession(
                header: header,
                previousHeader: client.cookies,
                previousStatus: AuthState.shared.status
            )
        }

        client.applyCookies(header)
        log.info("[session] candidate cookies applied in memory; persistent session unchanged")
    }

    /// Commits the candidate only after an authenticated YouTube response has been received.
    func commitAuthenticatedSession(displayName: String?) {
        guard let candidateSession else {
            log.error("[session] commit requested without an in-memory candidate")
            return
        }

        store.storeHeader(candidateSession.header)
        client.applyCookies(candidateSession.header)
        AuthState.shared.status = .loggedIn(displayName: displayName)
        self.candidateSession = nil
        log.info("[session] verified candidate committed → status=.loggedIn")
    }

    /// Restores the session that was active before candidate validation. This protects a valid
    /// Keychain login when a new candidate is rejected, cancelled or abandoned with the sheet.
    func discardCandidateCookies() {
        guard let candidateSession else { return }

        client.applyCookies(candidateSession.previousHeader)
        AuthState.shared.status = candidateSession.previousStatus
        self.candidateSession = nil
        log.info("[session] candidate discarded; previous in-memory session restored")
    }

    func signOut() async {
        log.info("[session] signOut called")
        candidateSession = nil
        store.clear()
        client.applyCookies("")
        // Drop the visitor token too — if cookies were stale, the token they were paired with may
        // also be invalid. `ensureVisitorData` below seeds a fresh one for the anonymous session.
        client.clearVisitorData()
        await client.ensureVisitorData()
        // Wipe the local subscriptions cache so the next signed-in user doesn't see the previous
        // account's channels marked as "subscribed".
        SubscriptionRegistry.shared.clear()
        AuthState.shared.status = .loggedOut
        log.info("[session] signOut complete → status=.loggedOut")
    }

    /// Called by error-handling layer when 401-equivalent or `cookieExpired` is observed.
    func handleExpiredSession() async {
        log.error("[session] expired — clearing cookies and routing to login")
        await signOut()
    }
}
