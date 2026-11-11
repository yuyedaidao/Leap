import LeapCore
import SwiftUI

struct RemotePluginInstallView: View {
    let installation: PluginInstallationModel
    @State private var address: String

    init(installation: PluginInstallationModel) {
        self.installation = installation
        _address = State(initialValue: installation.remoteInitialAddress)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.title2.bold())
            if !isStoreInstall {
                Text("粘贴公开 GitHub 仓库中的插件目录链接，仅下载所选插件。")
                    .foregroundStyle(.secondary)
                TextField("https://github.com/owner/repo/tree/main/plugins/hello", text: $address)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("插件目录地址")
                    .accessibilityIdentifier("settings.remotePluginAddress")
                    .disabled(installation.isPreparing || installation.candidate != nil || installation.isInstalling)
                    .onSubmit { installation.downloadRemote(address: address) }
            }
            if let phase = installation.remotePhase {
                Text(phase)
                    .accessibilityIdentifier("settings.remotePluginPhase")
            }
            if installation.isPreparing {
                if let progress = installation.progress, progress.totalFiles > 0 {
                    ProgressView(value: Double(progress.completedFiles), total: Double(progress.totalFiles))
                    Text(
                        "\(progress.completedFiles) / \(progress.totalFiles) 个文件 · \(progress.downloadedBytes.formatted(.byteCount(style: .file)))"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            if let candidate = installation.candidate {
                RemotePluginCandidateView(candidate: candidate, replacementMessage: installation.replacementMessage)
            }
            if let error = installation.errorMessage {
                SettingsErrorMessage(error)
                    .accessibilityIdentifier("settings.remotePluginError")
            }
            HStack {
                Spacer()
                Button("取消", role: .cancel) {
                    installation.rejectInstallation()
                    installation.isRemotePresented = false
                }
                .keyboardShortcut(.cancelAction)
                .disabled(installation.isInstalling)
                .accessibilityIdentifier("settings.remotePluginCancel")
                if let candidate = installation.candidate {
                    let name = candidate.manifest.name
                    Button(installation.isUpdating ? "更新 \(name)" : "安装 \(name)") {
                        installation.confirmInstallation()
                    }
                        .keyboardShortcut(.defaultAction)
                        .disabled(installation.isInstalling)
                        .accessibilityIdentifier("settings.remotePluginConfirm")
                } else if !isStoreInstall {
                    Button("下载并检查") { installation.downloadRemote(address: address) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(
                            address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || installation.isPreparing
                        )
                        .accessibilityIdentifier("settings.remotePluginDownload")
                }
            }
        }
        .padding(24)
        .frame(width: 560)
        .interactiveDismissDisabled(installation.isInstalling)
        .onDisappear { installation.rejectInstallation() }
    }

    /// 商店发起的安装复用同一个弹窗：地址由索引提供，只留标题与进度/确认。
    private var isStoreInstall: Bool { installation.storeInstallName != nil }

    private var title: String {
        if let name = installation.storeInstallName {
            return installation.isUpdating ? "更新 \(name)" : "安装 \(name)"
        }
        return installation.isUpdating ? "从远程地址更新" : "从远程地址安装"
    }
}

private struct RemotePluginCandidateView: View {
    let candidate: PluginInstallCandidate
    let replacementMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(candidate.manifest.name) \(candidate.manifest.version)").font(.headline)
                Text("运行时：\(candidate.manifest.runtime.rawValue)")
                Text("命令：\(candidate.manifest.commands.map(\.title).formatted())")
                if let source = candidate.source {
                    Text("来源：\(source.directoryURL.absoluteString)")
                    Text("提交：\(source.commit)").font(.caption.monospaced())
                }
                if let replacementMessage {
                    Text(replacementMessage).foregroundStyle(.orange)
                }
                Text("插件具有本机脚本权限，可访问文件及执行本地操作。请确认你信任此来源。")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        .frame(maxHeight: 260)
    }
}
