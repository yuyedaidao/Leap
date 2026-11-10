---
name: leap-plugin-development
description: 创建、修改或排查 macOS 启动器 Leap 的插件。适用于插件清单、JavaScript 或 Python 动作、原生列表、网页、Shell 命令，以及本地安装与验证。
---

# 开发 Leap 插件

## 确认目标与查阅资料

根据用户使用的 Leap 版本选择参考资料。优先使用匹配版本的本地源码，否则到官方仓库 `https://github.com/yuyedaidao/Leap` 读取同一个 Git tag 或提交的以下路径。未指定版本时以 `v0.0.2` 为首版参考，在交付时注明。开发版使用对应提交。资料不可用时，列出未能核对的接口及其验收方法。

- `Docs/PluginDevelopment.md`：清单、运行方式、宿主 API、权限及调试。
- `Resources/Leap/PluginSDK/leap.d.ts`：脚本端和网页端的 JavaScript 接口及回调类型。
- `Examples/Plugins/README.md`：示例索引。只读取与任务相符的示例目录中的清单和入口。

先选交互方式，再选运行时。JavaScript 可作为默认，已有 Python 代码或明确偏好时使用 Python。

| 需求 | 从这里开始 |
| --- | --- |
| 一次执行并返回反馈 | `JavaScriptEcho` 或 `PythonEcho` |
| 根据输入显示和选择结果 | `NumberEnumeration` 或 `TextConvert`，由宿主绘制原生列表 |
| 启动器内嵌网页 | `WebEcho` |
| 独立网页窗口 | `StandaloneWindow` |
| 执行系统命令 | `Hello` 或 `ShellCommands` |
| 剪贴板、Finder 或其他系统能力 | 先确定交互方式，再查阅 `HostAPI` 和指南中的系统 API |

## 创建或修改目录

- 从最接近的官方示例或 Leap 设置中的「插件模板生成器」起步。交付目录根部的 `manifest.json`、脚本入口和交互需要的资源。检查 `entry`、`webEntry`、图标等路径指向目录内现有文件，命令 ID 唯一且与脚本及网页调用一致。更新已有插件时保留插件 ID。
- 复用示例时核对 `minimumHostVersion`。部分 `v0.0.2` 示例仍声明 `1.2.0`，直接复制会导致旧版宿主拒绝安装。仅在最低兼容版本有依据时声明该字段。
- 脚本入口由宿主注入 `leap`。JavaScript 入口采用 CommonJS，`leap.d.ts` 仅用于编辑器类型检查。脚本使用 `leap.log` 或 `console` 调试，标准输出留给宿主协议。Shell 使用系统 zsh 和 `LEAP_COMMAND_ID`，只提供命令执行。
- 原生列表在 `onInputChange` 回调内使用 `setList`。异步查询应返回 Promise 并传递取消信号，选择后的操作放在 `onSelect`。Python 回调接收字典，取消信号用 `is_set()` 检查。
- 网页运行在 WKWebView，通过 `window.leap.invoke` 调用清单中声明的命令，入口脚本用 `leap.onInvoke` 处理。网页自身负责绘制并反馈调用失败。根据指南区分内嵌和独立窗口的清单写法。
- 跨插件启动使用 `runPlugin(pluginID, commandID, query?)`；调用成功后当前插件会话结束并由目标命令接管，不返回目标数据。
- 涉及文件、系统权限或网络时，校验业务输入并处理拒绝、取消与失败。Node.js 和 Python 入口具有本地权限，持久数据应放在受管插件目录以外。

## 验证与交付

1. 检查 JSON、清单规则和入口文件。根据运行时使用 `node --check`、Python 语法编译或 `zsh -n`，并验证关键业务行为及相关错误分支。
2. 在 Leap 的插件设置中选择「安装插件 → 从本地目录安装」，选择整个插件目录。确认信任后，在启动器搜索清单中的命令标题。每次修改源目录后重新安装，以更新受管副本。
3. 按实际交互验收动作结果、列表输入与选择、网页调用或 Shell 退出行为。排查脚本错误可查看 `com.padding.leap` 的 `plugin-session` 日志。
4. 交付时注明插件目录、参考的 Leap 版本、如何触发命令，并分别报告静态检查和 Leap 内实测结果。
