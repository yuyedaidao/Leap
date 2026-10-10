# Leap SDK 验证记录

日期：2026-10-09。环境：Apple M3 Pro / arm64、macOS 26、Xcode macOS 26.5 SDK、Swift 6；随包 Node.js 24.21.0 / Python 3.14.7。应用版本为 1.2.0。

## 功能验证

- `LeapTests`：54 项测试、12 个套件全部通过，包含真实进程和管道、会话复用、取消、业务错误恢复、超时、消息上限、忽略 SIGTERM 的强制退出、列表最终快照及模板生成。
- Node 测试：38 项全部通过，覆盖 JS/Python SDK、数字枚举、网页桥接、生成器校验与全部模板组合。
- 数字枚举：长整数逐字符计算；`123` 生成标题 0 至标题 5，`19` 为空；拒绝非整数及超过 1000 位的输入。
- 四个 JS 示例的 `leap.d.ts` 与宿主 SDK 类型声明逐字一致；活动代码、官方插件和示例已无旧 JSON-RPC 调用通道。
- `swiftlint lint --quiet --no-cache Sources Tests Project.swift` 返回成功，没有 error；仍有文件长度、类型长度、复杂度与排版等 warning。
- `git diff --check` 通过。

UI 测试目标已编译，但运行器初始化失败，未执行 UI 断言：`com.apple.LocalAuthentication Code=-4 / System authentication is running / 认证已取消`。因此复制、退出、隐藏等实际窗口行为仍需在可运行 UI 测试的桌面环境复验，不能把这次运行记录为通过。

## 性能

每组 100 次测量。Node 基准使用文本转换插件；旧基线从迁移前提交 `2757829` 读取实际入口，仅写入临时目录，测量后删除。代码没有保留旧协议实现。

| 测量链路 | p50 | p95 |
| --- | ---: | ---: |
| 原实现每次输入启动进程并获得响应 | 34.006ms | 35.618ms |
| 新 SDK 暖态管道请求到响应 | 0.045ms | 0.141ms |
| 数字枚举：输入协调器到主线程完成发布 | 22.543ms | 26.029ms |

SDK 冷启动首次响应为 31.658ms；原生输入协调器冷态为 73.958ms。每个交互会话只启动一次进程，退出不保留空闲池。

管道基准不含输入合并或界面刷新；原生链路包含默认 16ms 输入合并、真实随包运行时、业务计算、通信以及主线程列表与加载状态发布，不含 SwiftUI 渲染和屏幕合成。两组插件及测量范围不同，不能直接相减或视为完整视觉延迟。原生测试要求本机暖态 p95 小于 50ms，本次达到；不同机器和业务负载需要重新测量。

暖态处理后静置 1 秒，`ps` 记录插件进程累计 CPU 时间前后均为 `0:00.04`。这只能说明该时间分辨率下未观察到增长，不能证明绝对零 CPU 开销。

复现命令（仓库根目录）：

```sh
Resources/Leap/Runtimes/node-24.21.0/bin/node --test Tests/PluginSDK/*.test.js Tests/NumberEnumeration/*.test.js Tests/PluginTemplateGenerator/*.test.js
Resources/Leap/Runtimes/node-24.21.0/bin/node Tests/PluginSDK/benchmark.cjs
xcodebuild test -workspace Leap.xcworkspace -scheme Leap -destination 'platform=macOS' -only-testing:LeapTests
swiftlint lint --quiet --no-cache Sources Tests Project.swift
```

基准读取子进程 CPU 时间需要本机允许 `ps`。开发阶段移除了旧通信协议，旧开发插件必须迁移入口并重新安装；详见 [开发指南](PluginDevelopment.md)。

## 系统 API 回归验证

日期：2026-10-10。

- Node/Python/网页/模板及数字枚举：45 项全部通过；Swift：64 项、13 个套件全部通过。
- macOS 应用构建通过；SwiftLint 返回成功、无 error，仍有文件长度等 warning；`git diff --check` 通过。
- Node/Python/网页桥接：`Resources/Leap/Runtimes/node-24.21.0/bin/node --test Tests/PluginSDK/*.test.js Tests/PluginTemplateGenerator/*.test.js`。
- Swift：`xcodebuild test -workspace Leap.xcworkspace -scheme Leap -destination 'platform=macOS' -only-testing:LeapTests`。
- 新增测试使用独立 NSPasteboard、临时文件及模拟输入环境，不向用户前台窗口发送键盘事件。
- 覆盖结构化结果、图片字节/Data URL、16MB图片和24MB帧边界、权限错误、焦点失败及取消、宿主等待不占业务额度、等待上限、UUID与路径映射。
- 实机验收：安装 HostAPI 示例，从 TextEdit 放置光标后唤起插件，验证中文/Emoji输入及粘贴；Finder 目录与文件粘贴；Safari/Chrome/Arc URL读取；系统授权拒绝后重试；通知点击有效命令、插件卸载后不激活。
- 废纸篓验收只使用新建临时文件，验证原文件已移动，不执行永久删除。自动测试未覆盖系统授权弹窗及第三方应用接受事件的行为。
- 本次废纸篓临时文件自动测试通过。UI 操作在退出旧 Leap 并重新定位进程时返回 `procNotFound`，未能安装新示例；TextEdit、Finder、Safari/Chrome/Arc、系统授权弹窗及通知点击的实机验收尚未完成，以上项目是待验收步骤。

## 原生列表标题与快捷键回归

日期：2026-10-10。Swift 单测 69 项、13 个套件通过；Node/Python、网页、模板及示例测试 49 项通过。

macOS 构建通过；SwiftLint 返回成功、无 error，仍有现有长度和排版 warning；差异空白检查通过。

- 覆盖 ⌘1–⌘9/⌘0 的映射、越界、自动重复、加载和执行期间的保护；旧数组及动态标题快照兼容、标题清空、最终快照和过期批次隔离。
- 真实进程测试确认标题及 `description` 子标题从 SDK 同步到宿主；数字枚举示例展示动态标题和子标题。
- 新增 UI 测试验证默认搜索快捷执行、参数框聚焦时执行第十项、长标题/子标题布局和两种旋转控件的位置。实际运行均停在 `Launch → Terminate com.padding.leap`，150 秒后结束等待，尚未执行界面断言，不能记录为通过。
- UI 复验：`xcodebuild test -workspace Leap.xcworkspace -scheme Leap -destination 'platform=macOS' -only-testing:LeapUITests/PluginInteractionUITests/testNumericShortcutsTitleSubtitlesAndCenteredProgress -only-testing:LeapUITests/PluginInteractionUITests/testDefaultSearchNumericShortcutEntersPlugin`。另需手动确认中文组合输入、弹窗及网页插件不会被数字快捷键干扰。
