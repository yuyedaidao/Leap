import LeapCore
import SwiftUI

/// 商店里未安装的插件只有索引字段：不为了看详情去下载插件，也不展示本机安装路径。
struct PluginStoreDetailsView: View {
    let entry: PluginStoreEntry
    let state: PluginStoreEntry.State
    let isBusy: Bool
    let requestInstall: () -> Void

    var body: some View {
        List {
            Section {
                header
            }
            if !entry.commands.isEmpty {
                Section("命令") {
                    ForEach(entry.commands, id: \.self) { title in
                        Text(title)
                    }
                }
            }
            Section("插件信息") {
                PluginDetailField(title: "插件 ID", value: entry.id, identifier: "settings.pluginStoreDetails.id")
                if let runtime = entry.runtime {
                    PluginDetailField(title: "运行时", value: runtime)
                }
                if let minimumHostVersion = entry.minimumHostVersion {
                    PluginDetailField(title: "最低宿主版本", value: minimumHostVersion)
                }
                PluginDetailField(title: "来源", value: sourceDescription)
                if let summary = entry.summary, !summary.isEmpty {
                    PluginDetailField(title: "简介", value: summary)
                }
            }
        }
        .listStyle(.inset)
        .accessibilityIdentifier("settings.pluginStoreDetails.list")
    }

    private var header: some View {
        HStack(spacing: 12) {
            PluginStoreIcon(entry: entry, installed: nil)
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.headline)
                Text("版本 \(entry.version) · \(entry.commands.count) 个命令")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            action
        }
    }

    @ViewBuilder
    private var action: some View {
        switch state {
        case .notInstalled:
            if entry.isCompatibleWithHost() {
                Button("安装", action: requestInstall)
                    .disabled(isBusy)
                    .accessibilityIdentifier("settings.pluginStoreDetailsInstall.\(entry.id)")
            } else {
                Text("需要 Leap \(entry.minimumHostVersion ?? "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .installed, .updatable:
            Text("已安装")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var sourceDescription: String {
        let source = PluginStoreSource.official
        return "\(source.owner)/\(source.repository)/\(entry.path)"
    }
}
