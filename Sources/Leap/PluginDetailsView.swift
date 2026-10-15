import LeapCore
import SwiftUI

struct PluginDetailsView: View {
    let plugin: InstalledPluginDescriptor
    let requestUpdate: () -> Void
    let requestUninstall: () -> Void

    var body: some View {
        List {
            Section {
                PluginDetailsHeader(plugin: plugin, requestUpdate: requestUpdate, requestUninstall: requestUninstall)
            } header: {
                Text("插件信息")
            } footer: {
                Text("关键字用于搜索命令；命令标题、插件名称和命令 ID 也可用于搜索。匹配后需选中命令才会运行。")
            }
            ForEach(plugin.manifest.commands, id: \.id) { command in
                PluginCommandDetails(command: command, manifest: plugin.manifest)
            }
            Section {
                PluginTechnicalInformation(plugin: plugin)
            }
        }
        .listStyle(.inset)
        .accessibilityIdentifier("settings.pluginDetails.list")
    }
}

private struct PluginDetailsHeader: View {
    let plugin: InstalledPluginDescriptor
    let requestUpdate: () -> Void
    let requestUninstall: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            PluginIcon(plugin: plugin)
                .frame(width: 40, height: 40)
            Text("版本 \(plugin.manifest.version) · \(plugin.manifest.commands.count) 个命令")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("settings.pluginDetails.version")
                .textSelection(.enabled)
            Spacer()
            PluginManagementActions(
                origin: plugin.origin, requestUpdate: requestUpdate, requestUninstall: requestUninstall
            )
            if plugin.origin == .local {
                Text("本地安装")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct PluginCommandDetails: View {
    let command: PluginManifest.Command
    let manifest: PluginManifest

    var body: some View {
        Section {
            PluginDetailField(
                title: "运行方式",
                value: PluginCommandSummary(command: command, manifest: manifest).behavior,
                identifier: "settings.pluginCommand.\(command.id).behavior"
            )
            PluginDetailField(
                title: "关键字",
                value: command.keywords?.isEmpty == false
                    ? (command.keywords ?? []).joined(separator: "、") : "未声明额外关键字",
                identifier: "settings.pluginCommand.\(command.id).keywords"
            )
            PluginContentRules(rules: command.matches ?? [], commandID: command.id)
            if command.mode == .interactive {
                PluginDetailField(title: "参数输入", value: command.inputEnabled ? "已启用" : "已关闭")
                if let placeholder = command.input?.placeholder, command.inputEnabled, !placeholder.isEmpty {
                    PluginDetailField(title: "输入提示", value: placeholder)
                }
            }
        } header: {
            Text(command.title)
                .accessibilityIdentifier("settings.pluginCommand.\(command.id).title")
        } footer: {
            if command.matches?.isEmpty == false {
                Text("满足任意一条内容规则即可在搜索中匹配此命令。")
            }
        }
    }
}

/// 展示宿主实际采用的运行方式，尤其不能把旧版网页清单的缺省模式当作普通动作。
private struct PluginCommandSummary {
    let command: PluginManifest.Command
    let manifest: PluginManifest

    var behavior: String {
        if command.mode == .interactive {
            switch command.presentation {
            case .list: return "内嵌列表交互"
            case .web: return "内嵌网页交互"
            case nil: return "交互模式"
            }
        }
        if command.mode == nil, manifest.webEntry != nil, manifest.runtime != .shell {
            return "独立网页窗口"
        }
        return command.resolvedExecutionMode == .background ? "动作 · 后台执行" : "动作 · 等待完成"
    }
}

private struct PluginContentRules: View {
    let rules: [PluginManifest.Command.Match]
    let commandID: String

    var body: some View {
        Group {
            if rules.isEmpty {
                PluginDetailField(title: "内容匹配规则", value: "未声明内容匹配规则")
            } else {
                // 规则没有独立 ID，按清单顺序保持列表行身份，允许相同规则重复声明。
                ForEach(Array(rules.enumerated()), id: \.offset) { index, rule in
                    LabeledContent("内容匹配规则") {
                        PluginContentRule(rule: rule)
                            .accessibilityIdentifier("settings.pluginCommand.\(commandID).rule.\(index)")
                    }
                    .textSelection(.enabled)
                }
            }
        }
    }
}

private struct PluginContentRule: View {
    let rule: PluginManifest.Command.Match

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // 与 PluginCommandMatcher 一致：省略长度时采用 1…1000 个字符。
            Text("\(rule.type == .text ? "文本匹配" : "正则匹配") · \(rule.minLength ?? 1)–\(rule.maxLength ?? 1000) 个字符")
            if rule.type == .regex {
                Text(rule.pattern ?? "未声明表达式")
                    .font(.system(.callout, design: .monospaced))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct PluginTechnicalInformation: View {
    let plugin: InstalledPluginDescriptor
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            PluginTechnicalFields(plugin: plugin)
        } label: {
            // 标识只放在标题上，避免传播到子字段并覆盖各行自己的标识。
            Text("技术信息")
                .accessibilityIdentifier("settings.pluginDetails.technical")
        }
    }
}

private struct PluginTechnicalFields: View {
    let plugin: InstalledPluginDescriptor

    var body: some View {
        Group {
            PluginDetailField(title: "插件 ID", value: plugin.id, identifier: "settings.pluginDetails.id")
            PluginDetailField(title: "运行时", value: plugin.manifest.runtime.rawValue)
            PluginDetailField(title: "入口文件", value: plugin.manifest.entry)
            if let webEntry = plugin.manifest.webEntry {
                PluginDetailField(title: "网页入口", value: webEntry)
            }
            PluginDetailField(
                title: "安装目录", value: plugin.pluginDirectory.path,
                identifier: "settings.pluginDetails.directory"
            )
            PluginDetailField(title: "最低宿主版本", value: plugin.manifest.minimumHostVersion ?? "未声明")
            ForEach(plugin.manifest.commands, id: \.id) { command in
                PluginDetailField(title: "\(command.title) · 命令 ID", value: command.id)
            }
        }
        .textSelection(.enabled)
    }
}

private struct PluginDetailField: View {
    let title: String
    let value: String
    var identifier = ""

    var body: some View {
        LabeledContent(title) {
            Text(value)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(identifier)
        }
        .textSelection(.enabled)
    }
}
