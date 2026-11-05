import AppKit
import SwiftUI

struct DataSettingsPage: View {
    let coordinator: SettingsCoordinator

    @State private var isClearHistoryConfirmationPresented = false

    var body: some View {
        Form {
            LocalDataSection(
                coordinator: coordinator,
                requestClearHistory: { isClearHistoryConfirmationPresented = true }
            )
            PrivacySection()
            if let message = coordinator.dataMessage {
                Label(message, systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "清除最近使用？",
            isPresented: $isClearHistoryConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("清除", role: .destructive, action: coordinator.clearRecentItems)
            Button("取消", role: .cancel) {}
        } message: {
            Text("这会删除应用和插件的全部最近使用记录。")
        }
    }
}

private struct LocalDataSection: View {
    let coordinator: SettingsCoordinator
    let requestClearHistory: () -> Void

    var body: some View {
        Section("本地数据") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Leap 的最近使用记录和系统应用索引仅保存在本机。清除最近记录不会删除插件或其他偏好。")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("清除最近使用", role: .destructive, action: requestClearHistory)
                        .accessibilityIdentifier("settings.clearRecentButton")
                    Spacer()
                    Button("重建系统应用索引", action: coordinator.rebuildApplicationIndex)
                        .disabled(!coordinator.canRebuildApplicationIndex || coordinator.isRebuildingApplicationIndex)
                }
                if coordinator.isRebuildingApplicationIndex {
                    ProgressView("正在重建系统应用索引…")
                }
            }
            .padding(.vertical, 4)
        }
    }
}

private struct PrivacySection: View {
    var body: some View {
        Section("隐私") {
            Text("Leap 宿主不会收集遥测，也不提供账号或云同步。已确认插件按其自身逻辑运行，请只安装可信来源的插件。")
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
        }
    }
}

struct AboutSettingsPage: View {
    let updates: AppUpdateController
    private var versionDescription: String {
        guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              !version.isEmpty,
              !build.isEmpty else {
            return "开发构建"
        }
        return "版本 \(version)（构建 \(build)）"
    }

    var body: some View {
        HStack(content: {
            Spacer()
            VStack(alignment: .leading, spacing: 18) {
                Spacer()
                // AppIcon 是应用图标集，通过系统接口读取打包后的图标。
                Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
                    .resizable()
                    .scaledToFit()
                    .frame(width: 48, height: 48)
                    .accessibilityLabel("Leap 应用图标")
                    .accessibilityIdentifier("settings.about.appIcon")
                Text("Leap")
                    .font(.largeTitle.bold())
                Text(versionDescription)
                    .foregroundStyle(.secondary)
                Button("检查更新", action: updates.checkForUpdates)
                    .disabled(!updates.canCheckForUpdates)
                    .accessibilityIdentifier("settings.checkForUpdatesButton")
                if let error = updates.errorMessage {
                    Text(error).foregroundStyle(.red)
                }
                Text("从 GitHub 正式发行版下载更新，确认后安装并重启。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            Spacer()
        })
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(32)
    }
}
