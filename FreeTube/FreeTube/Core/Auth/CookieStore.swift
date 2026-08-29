import Foundation
import OSLog

/// Persists the YouTube cookie header string in the Keychain. Per CLAUDE.md §2 cookies must
/// never touch disk, `UserDefaults`, plist, or logs — only Keychain in-memory access at runtime.
final class CookieStore {
    static let shared = CookieStore()

    static let keychainKey = "com.leshko.freetube.cookies"

    /// Cookie names that indicate the web login has produced a plausible authenticated session.
    /// This is deliberately a candidate list, not a required set: Google changes which members
    /// are issued based on account, region and web client. YouTube's authenticated endpoint is the
    /// authority that decides whether the resulting header is actually signed in.
    static let authenticationCandidateCookieNames: Set<String> = [
        "SAPISID",
        "__Secure-3PAPISID",
        "__Secure-1PAPISID",
        "__Secure-3PSID",
        "__Secure-1PSID",
        "SID",
        "APISID"
    ]

    struct HeaderCandidate {
        let header: String
        let authenticationCookieNames: [String]
        let cookieCount: Int
    }

    private let log = AppLog(subsystem: "com.leshko.freetube", category: "CookieStore")

    private init() {}

    func storeHeader(_ header: String) {
        do {
            try KeychainHelper.set(header, for: Self.keychainKey)
            log.info("[cookies] keychain write OK (length=\(header.count, privacy: .public))")
        } catch {
            log.error("[cookies] keychain write FAILED: \(String(describing: error), privacy: .public)")
        }
    }

    func loadHeader() -> String? {
        let header = KeychainHelper.string(for: Self.keychainKey)
        if let header {
            log.info("[cookies] keychain read hit (length=\(header.count, privacy: .public))")
        } else {
            log.info("[cookies] keychain read miss")
        }
        return header
    }

    func clear() {
        KeychainHelper.delete(Self.keychainKey)
        log.info("[cookies] keychain cleared")
    }

    /// Builds a `Cookie:` header string from a list of `HTTPCookie` values. Missing members of a
    /// historical fixed cookie list never block header creation. The only local gate is that at
    /// least one modern authentication-candidate cookie exists; the YouTube service validates the
    /// complete header afterwards.
    ///
    /// Why the dedupe matters: when the WKWebView's redirect chain visits
    /// `accounts.google.com → m.youtube.com → www.youtube.com`, YouTube sets multiple cookies
    /// with the same name but different domain attributes — e.g. one `SID` scoped to
    /// `m.youtube.com` and another scoped to `.youtube.com`. Concatenating both into a single
    /// `Cookie:` header sends `SID=mobile; SID=cross-domain;`, and YouTube's server picks one
    /// (often the first) which can be the mobile-only value that fails to validate at
    /// `www.youtube.com/youtubei/v1/...`. Picking the broadest-domain variant per name fixes
    /// the resulting "logged out despite valid cookies" symptom.
    func makeHeader(from cookies: [HTTPCookie]) -> String? {
        makeHeaderCandidate(from: cookies)?.header
    }

    func makeHeaderCandidate(from cookies: [HTTPCookie]) -> HeaderCandidate? {
        let scoped = relevantCookies(from: cookies)

        // Domain inventory — quick way to confirm we have cookies from `.youtube.com` (cross-
        // subdomain) and not just `m.youtube.com` or `www.youtube.com` scoped variants.
        let domainSummary = Dictionary(grouping: scoped, by: \.domain)
            .map { "\($0.key)=\($0.value.count)" }
            .sorted()
            .joined(separator: ", ")
        log.info("[cookies] makeHeader: incoming \(cookies.count, privacy: .public) total / \(scoped.count, privacy: .public) yt+google-scoped — domains: [\(domainSummary, privacy: .public)]")

        let grouped = Dictionary(grouping: scoped, by: \.name)
        var chosen: [HTTPCookie] = []
        for (name, duplicates) in grouped {
            guard let best = duplicates.min(by: { cookieRank($0) < cookieRank($1) }) else {
                continue
            }
            if duplicates.count > 1 {
                let droppedDomains = duplicates
                    .filter { $0 !== best }
                    .map(\.domain)
                    .sorted()
                    .joined(separator: ",")
                log.info("[cookies] dedupe \(name, privacy: .public): chose domain=\(best.domain, privacy: .public), dropped=[\(droppedDomains, privacy: .public)]")
            }
            chosen.append(best)
        }

        let candidateNames = Set(chosen.map(\.name))
            .intersection(Self.authenticationCandidateCookieNames)
            .sorted()
        guard !candidateNames.isEmpty else {
            log.notice("[cookies] makeHeader: waiting — no authentication-candidate cookie yet")
            return nil
        }

        let dropped = scoped.count - chosen.count
        let sortedCookies = chosen.sorted {
            if $0.name != $1.name { return $0.name < $1.name }
            if $0.domain != $1.domain { return $0.domain < $1.domain }
            return $0.path < $1.path
        }
        let header = sortedCookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")

        // Cookie values and the assembled header are intentionally never logged. The coordinator
        // logs value lengths and flags only when the safe cookie inventory actually changes.
        log.info("[cookies] makeHeader: built — kept=\(chosen.count, privacy: .public) dropped=\(dropped, privacy: .public) duplicates candidates=[\(candidateNames.joined(separator: ","), privacy: .public)]")
        return HeaderCandidate(
            header: header,
            authenticationCookieNames: candidateNames,
            cookieCount: chosen.count
        )
    }

    func relevantCookies(from cookies: [HTTPCookie]) -> [HTTPCookie] {
        let now = Date()
        return cookies.filter { cookie in
            guard !cookie.name.isEmpty, !cookie.value.isEmpty else { return false }
            if let expiresDate = cookie.expiresDate, expiresDate <= now { return false }
            return Self.domain(cookie.domain, belongsTo: "youtube.com")
                || Self.domain(cookie.domain, belongsTo: "google.com")
        }
    }

    func authenticationCandidateNames(in cookies: [HTTPCookie]) -> [String] {
        Set(relevantCookies(from: cookies).map(\.name))
            .intersection(Self.authenticationCandidateCookieNames)
            .sorted()
    }

    /// Ranking is based on whether a browser could send the cookie to the exact API host first.
    /// A Google-domain cookie is retained when it is the only value for a name, but it can never
    /// displace a YouTube-domain value that is valid for `www.youtube.com`.
    private func cookieRank(_ cookie: HTTPCookie) -> (Int, Int, Int, Int) {
        let normalizedDomain = Self.normalizedDomain(cookie.domain)
        let scopeRank: Int
        if Self.cookie(cookie, canBeSentTo: "www.youtube.com") {
            scopeRank = 0
        } else if Self.domain(cookie.domain, belongsTo: "youtube.com") {
            scopeRank = 1
        } else {
            scopeRank = 2
        }

        let broadDomainRank = normalizedDomain == "youtube.com" || normalizedDomain == "google.com" ? 0 : 1
        let broadPathRank = cookie.path == "/" ? 0 : 1
        return (scopeRank, broadDomainRank, broadPathRank, normalizedDomain.count)
    }

    private static func cookie(_ cookie: HTTPCookie, canBeSentTo host: String) -> Bool {
        let normalizedHost = normalizedDomain(host)
        let normalizedCookieDomain = normalizedDomain(cookie.domain)
        return normalizedHost == normalizedCookieDomain
            || normalizedHost.hasSuffix(".\(normalizedCookieDomain)")
    }

    private static func domain(_ domain: String, belongsTo baseDomain: String) -> Bool {
        let normalized = normalizedDomain(domain)
        return normalized == baseDomain || normalized.hasSuffix(".\(baseDomain)")
    }

    private static func normalizedDomain(_ domain: String) -> String {
        domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }
}
