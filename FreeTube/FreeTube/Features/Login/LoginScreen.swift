import SwiftUI
import WebKit

@available(iOS 17.0, *)
struct LoginScreen: View {
    @StateObject private var coordinator = LoginCoordinator()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                LoginWebView(coordinator: coordinator)

                if case .verifying = coordinator.state {
                    Color.black.opacity(0.3).ignoresSafeArea()

                    VStack(spacing: 12) {
                        ProgressView()
                            .tint(.white)

                        Text("Finishing sign-in…")
                            .font(.headline)

                        Text("Checking YouTube session \(coordinator.verificationAttempt)/\(coordinator.maxVerificationAttempts)")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if !coordinator.missingCookieNames.isEmpty {
                            Text("Waiting for: \(coordinator.missingCookieNames.joined(separator: ", "))")
                                .font(.caption2)
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(18)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 24)
                }
            }
            .navigationTitle("Sign in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("Change account") {
                        coordinator.chooseAnotherAccount()
                    }
                }
            }
            .onChange(of: coordinator.state) { _, new in
                if case .succeeded = new { dismiss() }
            }
            .alert(
                "Sign-in failed",
                isPresented: failureBinding,
                presenting: failureMessage
            ) { _ in
                Button("Retry") {
                    coordinator.retryVerification()
                }
                Button("Change account") {
                    coordinator.chooseAnotherAccount()
                }
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
            } message: { message in
                Text(message)
            }
        }
    }

    private var failureMessage: String? {
        if case .failed(let message) = coordinator.state { return message }
        return nil
    }

    private var failureBinding: Binding<Bool> {
        Binding(
            get: {
                if case .failed = coordinator.state { return true }
                return false
            },
            set: { _ in }
        )
    }
}
