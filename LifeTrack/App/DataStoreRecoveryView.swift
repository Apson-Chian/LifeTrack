import SwiftUI

struct DataStoreRecoveryView: View {
    let errorMessage: String
    let storeName: String
    let retry: () -> Void
    let createEmptyStore: () -> Void
    @State private var confirmsNewStore = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Image(systemName: "externaldrive.badge.exclamationmark")
                        .font(.system(size: 48))
                        .foregroundStyle(.orange)

                    Text("数据库加载失败")
                        .font(.title2.bold())

                    Text("LifeTrack 无法安全打开当前数据库。旧数据库不会被自动删除或覆盖。")

                    GroupBox("错误信息") {
                        Text(errorMessage)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Text("当前数据库：\(storeName).store")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Text("你可以先重试。若仍失败，可以创建一个使用不同文件名的空数据库，再从 LifeTrack 备份文件恢复数据。原数据库文件会继续保留在设备上。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Button("重新尝试打开", action: retry)
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: .infinity)

                    Button("创建新的空数据库", role: .destructive) {
                        confirmsNewStore = true
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                }
                .padding(24)
            }
            .navigationTitle("数据恢复")
            .alert("确认创建空数据库？", isPresented: $confirmsNewStore) {
                Button("取消", role: .cancel) { }
                Button("创建", role: .destructive, action: createEmptyStore)
            } message: {
                Text("这不会删除旧数据库，但 LifeTrack 将改用新的空数据库。之后可在设置中从备份恢复。")
            }
        }
    }
}
