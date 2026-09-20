## Why

Leap 的长期目标依赖于可靠的原生插件宿主，但目前仓库尚未验证 SwiftUI 宿主、捆绑的 Python/JavaScript 运行时和 Web 插件页面能否形成可分发的最小闭环。先完成这条闭环，可在实现应用启动、剪贴板和完整插件 SDK 前降低架构与发布风险。

## What Changes

- 新建 macOS 26 SwiftUI 宿主，提供常驻的全局快捷键、固定尺寸搜索面板与仅含“最近使用”的首页；本阶段不展示市场或已安装插件分区。
- 建立本地插件安装流程：校验清单、复制到 Leap 受管目录，并在首次安装或升级时要求用户确认信任。
- 捆绑并验证 Python 与 JavaScript 运行时；各运行一个最小插件，并通过 JSON-RPC 接收命令和查询文本。
- 支持插件可选 Web 页面，由 WKWebView 加载并通过受限桥接 API 调用宿主能力。
- 建立构建、测试与 Developer ID/公证发布配置骨架，但不执行真实签名或公证。

## Capabilities

### New Capabilities

- `native-launcher-shell`: 常驻 macOS 启动器窗口、全局唤起与基础搜索面板。
- `managed-plugin-installation`: 本地插件清单验证、受管安装和用户信任确认。
- `plugin-runtime-bridge`: Python、JavaScript 与 Web 插件页面到原生宿主的最小通信闭环。

### Modified Capabilities

无。

## Impact

- 新增 SwiftUI macOS 应用工程、测试目标和示例插件资源。
- 使用 AppKit、WebKit、捆绑 Python 与 Node.js 运行时。
- 新增插件清单和 JSON-RPC 协议；它们是后续插件 SDK 的内部预览接口，尚不承诺兼容性。
- 新增本地构建与发布检查脚本，真实 Developer ID 证书与公证凭据不进入仓库。
