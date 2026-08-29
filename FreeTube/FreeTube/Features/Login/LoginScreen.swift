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

                if showsVerificationProgress {
                    Color.black.opacity(0.3).ignoresSafeArea()

                    VStack(spacing: 12) {
                        ProgressView()
                            .tint(.white)

                        Text(progressTitle)
                            .font(.headline)

                        Text(progressDetail)
                            .font(.caption)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)

                        if !coordinator.candidateCookieNames.isEmpty {
                            Text("已检测到：\(coordinator.candidateCookieNames.joined(separator: ", "))")
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
                    Button("取消") {
                        coordinator.cancel()
                        dismiss()
                    }
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
            .onDisappear {
                coordinator.cancel()
            }
            .alert(
                failure?.title ?? "登录失败",
                isPresented: failureBinding,
                presenting: failure
            ) { _ in
                Button("重试") {
                    coordinator.retryVerification()
                }
                Button("切换账号") {
                    coordinator.chooseAnotherAccount()
                }
                Button("取消", role: .cancel) {
                    coordinator.cancel()
                    dismiss()
                }
            } message: { failure in
                Text(failure.message)
            }
        }
    }

    private var showsVerificationProgress: Bool {
        switch coordinator.state {
        case .waitingForCookies, .verifying:
            return true
        default:
            return false
        }
    }

    private var progressTitle: String {
        switch coordinator.state {
        case .waitingForCookies:
            return "仍在等待 YouTube 登录 Cookie"
        case .verifying:
            return "已获取登录 Cookie，正在验证账号"
        default:
            return "正在完成登录…"
        }
    }

    private var progressDetail: String {
        switch coordinator.state {
        case .waitingForCookies:
            return "Google/WKWebView 正在写入 Cookie（\(coordinator.verificationAttempt)/\(coordinator.maxVerificationAttempts)）"
        case .verifying:
            return "正在通过 YouTube 服务端确认此会话是否已登录"
        default:
            return ""
        }
    }

    private var failure: LoginCoordinator.Failure? {
        if case .failed(let failure) = coordinator.state { return failure }
        return nil
    }

    private var failureBinding: Binding<Bool> {
        Binding(
            get: {
                if case .failed(_) = coordinator.state { return true }
                return false
            },
            set: { _ in }
        )
    }
}
