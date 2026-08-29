import Foundation
import OSLog
import YouTubeKit

/// Reads the server's authentication signals without inheriting YouTubeKit's current
/// `isDisconnected = true` default when `mainAppWebResponseContext.loggedOut` is omitted.
/// The account-menu endpoint is still a real authenticated YouTube endpoint; this decoder only
/// distinguishes an explicit rejection from a changed-but-authenticated response shape.
private struct AuthenticationProbeResponse: YouTubeResponse {
    enum Verdict: Sendable {
        case authenticated
        case rejected
        case indeterminate
    }

    static let headersType: HeaderTypes = .userAccountHeaders
    static let parametersValidationList: ValidationList = [:]

    let verdict: Verdict
    let displayName: String?
    let channelHandle: String?

    static func decodeJSON(json: JSON) -> AuthenticationProbeResponse {
        let loggedOut = json[
            "responseContext",
            "mainAppWebResponseContext",
            "loggedOut"
        ].bool

        if loggedOut == true {
            return AuthenticationProbeResponse(
                verdict: .rejected,
                displayName: nil,
                channelHandle: nil
            )
        }

        for action in json["actions"].arrayValue {
            let accountHeader = action[
                "openPopupAction",
                "popup",
                "multiPageMenuRenderer",
                "header",
                "activeAccountHeaderRenderer"
            ]
            guard accountHeader.exists() else { continue }

            return AuthenticationProbeResponse(
                verdict: .authenticated,
                displayName: accountHeader["accountName", "simpleText"].string,
                channelHandle: accountHeader["channelHandle", "simpleText"].string
            )
        }

        if loggedOut == false {
            return AuthenticationProbeResponse(
                verdict: .authenticated,
                displayName: nil,
                channelHandle: nil
            )
        }

        return AuthenticationProbeResponse(
            verdict: .indeterminate,
            displayName: nil,
            channelHandle: nil
        )
    }
}

private struct AuthenticationProbeIndeterminateError: LocalizedError, Sendable {
    var errorDescription: String? {
        "YouTube 返回了无法识别的登录验证响应，请稍后重试。"
    }
}

struct AccountInfo: Sendable {
    let displayName: String
    let handle: String?
    let avatarURL: URL?
    let channelID: String?
}

struct AccountLibrary: Sendable {
    let history: [Video]
    let historyCount: Int?
    let watchLater: [Video]
    let watchLaterCount: Int?
    let likedVideos: [Video]
    let likedCount: Int?
    let playlists: [Playlist]
    /// Best-effort channel ID for the signed-in user, harvested from one of the user's owned
    /// playlists in the library response (`YTPlaylist.channel?.channelId`). YouTubeKit's
    /// `AccountInfosResponse` doesn't expose this directly. Used by the Library screen's
    /// "Your videos" row.
    let userChannelID: String?
}

protocol AccountServicing: Sendable {
    func fetchAccountInfo() async throws -> AccountInfo
    func fetchLibrary() async throws -> AccountLibrary
    func fetchPlaylists() async throws -> [Playlist]
}

/// Wraps YouTubeKit's authenticated `Account*Response` types. All three require cookies on
/// `YouTubeModel`; `SessionManager.bootstrap` / `applyCandidateCookies` is responsible for applying them.
/// Authenticated methods throw `YouTubeServiceError.notAuthenticated` only after a definitive
/// server-side logged-out result so the UI can route to the login screen without parser false
/// negatives.
final class AccountService: AccountServicing {
    private let client: YouTubeKitClient
    private let log = AppLog(subsystem: "com.leshko.freetube", category: "AccountService")

    nonisolated init(client: YouTubeKitClient = .shared) {
        self.client = client
    }

    func fetchAccountInfo() async throws -> AccountInfo {
        log.info("[account] fetchAccountInfo — model.cookies length=\(self.client.model.cookies.count, privacy: .public) alwaysUseCookies=\(self.client.model.alwaysUseCookies, privacy: .public)")
        let response: AccountInfosResponse
        do {
            response = try await AccountInfosResponse.sendThrowingRequest(
                youtubeModel: client.model,
                data: [:]
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            log.error("[account] AccountInfosResponse failed: \(String(describing: error), privacy: .public)")
            throw YouTubeServiceError.network(error)
        }

        if !response.isDisconnected {
            // This is the primary success condition. Do not require a parsed account name or
            // handle: accounts without a YouTube channel can legitimately omit those fields.
            log.info("[account] AccountInfosResponse isDisconnected=false; authenticated session confirmed")
            return makeAccountInfo(
                displayName: response.name,
                handle: response.channelHandle,
                avatarURL: Mappers.bestThumbnailURL(response.avatar)
            )
        }

        log.notice("[account] AccountInfosResponse isDisconnected=true; checking raw account-menu authentication signals")
        return try await confirmAuthenticationWithRawAccountProbe()
    }

    /// `AccountInfosResponse` currently defaults `isDisconnected` to true when YouTube omits the
    /// exact `mainAppWebResponseContext.loggedOut` field. A second YouTube account-menu request is
    /// decoded without that default, so only an explicit `loggedOut=true` becomes rejection. A
    /// returned active-account header or `loggedOut=false` is a server-confirmed success; an
    /// unfamiliar response remains retryable instead of being mislabeled as bad credentials.
    private func confirmAuthenticationWithRawAccountProbe() async throws -> AccountInfo {
        let probe: AuthenticationProbeResponse
        do {
            probe = try await AuthenticationProbeResponse.sendThrowingRequest(
                youtubeModel: client.model,
                data: [:],
                useCookies: true
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            log.error("[account] raw authentication probe failed: \(String(describing: error), privacy: .public)")
            throw YouTubeServiceError.network(error)
        }

        switch probe.verdict {
        case .authenticated:
            log.info("[account] raw account-menu probe confirmed authenticated session")
            return makeAccountInfo(
                displayName: probe.displayName,
                handle: probe.channelHandle,
                avatarURL: nil
            )

        case .rejected:
            log.notice("[account] raw account-menu probe returned explicit loggedOut=true")
            throw YouTubeServiceError.notAuthenticated

        case .indeterminate:
            log.notice("[account] raw account-menu probe was indeterminate; keeping verification retryable")
            throw YouTubeServiceError.network(AuthenticationProbeIndeterminateError())
        }
    }

    private func makeAccountInfo(
        displayName: String?,
        handle: String?,
        avatarURL: URL?
    ) -> AccountInfo {
        log.info("[account] account metadata presence: name=\(displayName != nil, privacy: .public) handle=\(handle != nil, privacy: .public) avatar=\(avatarURL != nil, privacy: .public)")
        return AccountInfo(
            displayName: displayName ?? "",
            handle: handle,
            avatarURL: avatarURL,
            // AccountInfosResponse doesn't expose channelID directly; the library response does.
            // Callers that need it should `fetchLibrary` and read `userChannelID` from there.
            channelID: nil
        )
    }

    func fetchLibrary() async throws -> AccountLibrary {
        log.info("Fetching account library")
        let response: AccountLibraryResponse
        do {
            response = try await AccountLibraryResponse.sendThrowingRequest(
                youtubeModel: client.model,
                data: [:]
            )
        } catch {
            log.error("AccountLibraryResponse failed: \(String(describing: error), privacy: .public)")
            throw YouTubeServiceError.network(error)
        }
        guard !response.isDisconnected else {
            throw YouTubeServiceError.notAuthenticated
        }
        let playlists = response.playlists.map(Mappers.playlist(from:))
        let liked = (response.likes?.frontVideos ?? []).map(Mappers.video(from:))
        let later = (response.watchLater?.frontVideos ?? []).map(Mappers.video(from:))
        let history = (response.history?.frontVideos ?? []).map(Mappers.video(from:))
        // Counts come from YTPlaylist.videoCount which is a human-readable string like "1,234"
        // or "1.2K videos". `Mappers.parseAbbreviatedCount` already handles both forms (built
        // for subscriber counts) so we reuse it here.
        //
        // **Why we fall back to `frontVideos.count` when the parse returns nil:**
        // The library response's `history` block typically carries an annotation like
        // "Last viewed today" (a date string, not a number) instead of "N videos" — so
        // `parseAbbreviatedCount` correctly produces nil there. Same can happen with
        // `likes`/`watchLater` if YouTube's locale-specific annotation doesn't include digits.
        // Falling back to `frontVideos.count` lets the Library menu always show a meaningful
        // number (the count of preview items YouTube returned). It's a lower bound, not a
        // grand total — so we surface it with a `+` suffix in the UI when the response had
        // more pages to fetch via `HistoryResponse` / `PlaylistInfosResponse`.
        let likedCount = Mappers.parseAbbreviatedCount(response.likes?.videoCount) ?? (liked.isEmpty ? nil : liked.count)
        let watchLaterCount = Mappers.parseAbbreviatedCount(response.watchLater?.videoCount) ?? (later.isEmpty ? nil : later.count)
        let historyCount = Mappers.parseAbbreviatedCount(response.history?.videoCount) ?? (history.isEmpty ? nil : history.count)
        // Trace the raw → parsed mapping so we can debug "— shown instead of count" reports
        // without round-tripping through a debugger.
        log.info("[account] library counts — likes raw=\"\(response.likes?.videoCount ?? "nil", privacy: .public)\" preview=\(liked.count, privacy: .public) → \(likedCount.map(String.init) ?? "nil", privacy: .public), watchLater raw=\"\(response.watchLater?.videoCount ?? "nil", privacy: .public)\" preview=\(later.count, privacy: .public) → \(watchLaterCount.map(String.init) ?? "nil", privacy: .public), history raw=\"\(response.history?.videoCount ?? "nil", privacy: .public)\" preview=\(history.count, privacy: .public) → \(historyCount.map(String.init) ?? "nil", privacy: .public)")
        // Pull the user's channel ID off any owned playlist. Every playlist in
        // `AccountLibraryResponse.playlists` is owned by the signed-in user.
        let userChannelID = response.playlists.compactMap { $0.channel?.channelId }.first
        return AccountLibrary(
            history: history,
            historyCount: historyCount,
            watchLater: later,
            watchLaterCount: watchLaterCount,
            likedVideos: liked,
            likedCount: likedCount,
            playlists: playlists,
            userChannelID: userChannelID
        )
    }

    func fetchPlaylists() async throws -> [Playlist] {
        log.info("Fetching account playlists")
        let response: AccountPlaylistsResponse
        do {
            response = try await AccountPlaylistsResponse.sendThrowingRequest(
                youtubeModel: client.model,
                data: [:]
            )
        } catch {
            log.error("AccountPlaylistsResponse failed: \(String(describing: error), privacy: .public)")
            throw YouTubeServiceError.network(error)
        }
        guard !response.isDisconnected else {
            throw YouTubeServiceError.notAuthenticated
        }
        return response.results.map(Mappers.playlist(from:))
    }
}
