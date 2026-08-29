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

                        Text("正在完成登录…")
                            .font(.headline)

                        Text("正在检查 YouTube 登录状态 \(coordinator.verificationAttempt)/\(coordinator.maxVerificationAttempts)")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if !coordinator.missingCookieNames.isEmpty {
                            Text("正在等待：\(coordinator.missingCookieNames.joined(separator: ", "))")
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
            .navigationTitle("登录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("切换账号") {
                        coordinator.chooseAnotherAccount()
                    }
                }
            }
            .onChange(of: coordinator.state) { _, new in
                if case .succeeded = new { dismiss() }
            }
            .alert(
                "登录失败",
                isPresented: failureBinding,
                presenting: failureMessage
            ) { _ in
                Button("重试") {
                    coordinator.retryVerification()
                }
                Button("切换账号") {
                    coordinator.chooseAnotherAccount()
                }
                Button("取消", role: .cancel) {
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
