import SwiftUI

/// 首次启动引导。只在本机说明权限与隐私，不收集任何信息。
enum OnboardingState {
    private static let hasSeenKey = "hasSeenOnboarding"

    static var hasSeenOnboarding: Bool {
        UserDefaults.standard.bool(forKey: hasSeenKey)
    }

    static func markSeen() {
        UserDefaults.standard.set(true, forKey: hasSeenKey)
    }
}

struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0

    private let pages = OnboardingPage.all

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                ForEach(Array(pages.enumerated()), id: \.offset) { index, item in
                    OnboardingPageView(item: item)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .automatic))
            .indexViewStyle(.page(backgroundDisplayMode: .interactive))

            VStack(spacing: 12) {
                if page < pages.count - 1 {
                    Button {
                        withAnimation { page += 1 }
                    } label: {
                        Text("下一步")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                } else {
                    Button {
                        OnboardingState.markSeen()
                        dismiss()
                    } label: {
                        Text("开始使用")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }

                Button("跳过") {
                    OnboardingState.markSeen()
                    dismiss()
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            .padding(24)
        }
        .background(Color(uiColor: .systemBackground))
        .interactiveDismissDisabled()
    }
}

private struct OnboardingPage {
    let symbol: String
    let title: String
    let detail: String
    let tint: Color

    static let all: [OnboardingPage] = [
        OnboardingPage(symbol: "figure.walk.motion",
                       title: "记录你的生活轨迹",
                       detail: "LifeTrack 记录运动、地点、停留与旅行，帮你回顾每天去了哪里、做了什么。",
                       tint: .indigo),
        OnboardingPage(symbol: "lock.shield.fill",
                       title: "数据只保存在本机",
                       detail: "没有账号、没有服务器、不上传定位或照片。所有轨迹与照片分析都在你的 iPhone 上完成。",
                       tint: .teal),
        OnboardingPage(symbol: "location.fill",
                       title: "定位权限",
                       detail: "开始记录轨迹需要“使用 App 时”定位；若想锁屏后继续记录，可在记录时升级为“始终允许”。",
                       tint: .blue),
        OnboardingPage(symbol: "photo.on.rectangle",
                       title: "照片与隐私",
                       detail: "照片只读取小尺寸缩略图做本地分类，绝不把原图交给分析器。蜂窝网络下默认不下载 iCloud 缩略图。",
                       tint: .purple)
    ]
}

private struct OnboardingPageView: View {
    let item: OnboardingPage

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: item.symbol)
                .font(.system(size: 64, weight: .semibold))
                .foregroundStyle(item.tint)
                .padding(28)
                .background(item.tint.opacity(0.12), in: Circle())

            Text(item.title)
                .font(.title2.weight(.bold))

            Text(item.detail)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 28)
            Spacer()
        }
        .padding(.top, 40)
    }
}
