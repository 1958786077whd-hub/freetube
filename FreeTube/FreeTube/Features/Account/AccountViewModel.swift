import Foundation
import Observation

@available(iOS 17.0, *)
@Observable
@MainActor
final class AccountViewModel {
    private(set) var info: AccountInfo?
    private(set) var isLoading: Bool = false
    var errorState: ErrorState?

    private let service: any AccountServicing
    private let session: SessionManager

    init(
        service: any AccountServicing = AccountService(),
        session: SessionManager = .shared
    ) {
        self.service = service
        self.session = session
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            info = try await service.fetchAccountInfo()
        } catch YouTubeServiceError.notAuthenticated {
            info = nil
            // Keep the global auth state in sync with what YouTube actually reported. Without this,
            // one screen can show "signed out" while other screens still believe cookies are valid.
            await session.handleExpiredSession()
        } catch {
            errorState = ErrorState(from: error)
        }
    }

    func signOut() async {
        await session.signOut()
        // Remove the active YouTube web session but keep Google's account-chooser cookies so
        // accounts previously used inside FreeTube remain available for quick re-login.
        await LoginCoordinator.clearYouTubeWebSession()
        info = nil
    }
}
