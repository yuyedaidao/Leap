# 深色模式下打开 web 插件先白闪一下

## Context

深色模式下打开 `presentation: web` 的插件（如 JSON 格式化），会先闪一帧白底再变成深色。

原因不在插件页面写错了 —— `index.html` 已经有 `color-scheme: light dark` 和 `color: inherit`，是**宿主 WebView 自己的底色**问题：

1. `PluginWebView.makeNSView` 只设了 `WKWebViewConfiguration` 和脚本，没有设任何底色。`WKWebView` 默认 `drawsBackground = true`、`underPageBackgroundColor` 是白色，且 WebKit 的进程/渲染层在首帧内容准备好之前先呈现这层白底。
2. 插件页面首帧还没解析完 CSS 时，`body` 没有背景，露出的就是上面那层白底。
3. 首帧之后两件事才发生：WebKit 根据 `color-scheme`/`prefers-color-scheme` 把默认 canvas 变深，插件 CSS 生效 —— 也就是用户看到的"白一下然后变深"。

若把 `NSApp.appearance` 设为 `darkAqua`（`AppDelegate.swift:135`，来自设置里的"外观"），宿主已经是深色，但 `WKWebView` 的页面底色并不由 `NSApp.appearance` 决定，所以仍然白闪。

## 关于「先提交当前修改」

你上一条要求先提交剪切板插件修复。当前是计划模式，我不能执行 git 提交（属于改动仓库）。计划批准后我会先按主题拆提交那批改动，再实现本计划；如果你希望两者合成一个提交，告诉我。

## Approach

三层一起改，任何一层单独改都不够（首帧之前 WebKit 不跑页面 CSS，页面 CSS 生效前最后一帧仍是宿主底色）：

**① 宿主 WebView 不画自己的底色**

`PluginPageWebView` 初始化时 `setValue(false, forKey: "drawsBackground")`。这是 `WKWebView` 的私有 key，但只有它能让 WebKit 完全不绘制那层白色。

**关于「能不能直接设透明」**：技术上能 —— 上面的 `drawsBackground=false` 之后，WebView 本身就是透明的，露出的会是启动器面板的 Liquid Glass（`LauncherView.swift:67` `.glassEffect(.regular, ...)`）。但插件页面（如 JSON 格式化）是一块代码编辑区，需要不透光的可读表面；透明会让壁纸颜色透上来，文本对比度随时变，不可接受。所以透明只作为“不画白”的手段，页面仍需自己/由宿主涂上不透明底色，就是第③ 步。

**② 按当前外观给 WebView 设 `appearance`**

WKWebView 据此给页面 `prefers-color-scheme`，也影响它自己的合成底色。

- `NSApp.appearance` 已经是 `darkAqua`/`aqua` 时，`webView.appearance` 留 `nil` 继承即可。
- `NSApp.appearance == nil`（“跟随系统”）时，取 `NSApp.effectiveAppearance` 显式赋给 webView —— 这一条是关键：让 WebView 不必自己等系统外观同步，减少它先按亮色起一帧的机会。

**③ 注入首帧底色，早于任何页面脚本**

新增一个 `WKUserScript(injectionTime: .atDocumentStart)`，把宿主算出的底色写成：

```css
html{background:#1e1e1e;color-scheme:dark}
```

底色取 `NSColor.textBackgroundColor`（已与你确认，深色下为文字区近黑色，与周边原生内容区一致），在当前 `effectiveAppearance` 下转 sRGB 后拼 `#rrggbb`；`color-scheme` 由 `effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])` 决定，把两者写在一起才能让 WebKit 的默认 canvas 色同步变深。

插到现有 SDK 脚本之前（`WKUserContentController` 按添加顺序执行）。这样文档一建立就是深色，不会在 CSS 解析前露出白底。深色与浅色走同一路径，值不同。

## Files to modify

- `Sources/Leap/PluginWebView.swift`
  - `makeNSView`：创建 `PluginPageWebView` 后设 `drawsBackground=false`、`appearance`、并把首帧底色 `WKUserScript` 插到 `userContentController` 最前面。
  - `PluginPageWebView`（文件末尾）：可加一个 `configure(for:)` 方法承载上述三件，避免 `makeNSView` 继续膨胀。
  - 首帧底色的取值需要一个小的 `NSColor` → CSS 转换（`usingColorSpace(.sRGB)` 后拼 `#rrggbb`）。
- 可能需要 `Sources/Leap/PluginInteractionView.swift`（`:16` 调用点）传一个 `NSAppearance` 或直接什么都不传（WebView 内取 `NSApp.effectiveAppearance` 更简单，倾向后者，零调用点改动）。

## Reuse

- `AppearancePreference.appKitAppearance`（`Sources/Leap/SettingsCoordinator.swift:23-36`）：已有的三档外观映射，不重复实现。
- `AppDelegate.applyAppearancePreference`（`Sources/Leap/AppDelegate.swift:132-137`）：外观唯一的设置点，`NSApp.appearance` 已在那里落好，WebView 只需读取。
- `PluginPageWebView`（`PluginWebView.swift` 文件末尾，已存在的 `WKWebView` 子类）：加配置方法比新建子类省事。
- 现有 SDK 注入模式（`makeNSView` 里的 `WKUserScript(source: context.coordinator.sdkSource, injectionTime: .atDocumentStart)`）：首帧底色脚本照同一写法复用该通道。

## Steps

- [x] `PluginPageWebView` 加 `configure()`：`setValue(false, forKey: "drawsBackground")`；`appearance = NSApp.appearance ?? NSApp.effectiveAppearance`。
- [x] 写 `firstPaintCSS()`：取 `NSColor.textBackgroundColor` 在当前 `effectiveAppearance` 下的 sRGB 值，拼 `html{background:#rrggbb;color-scheme:dark|light}`；`color-scheme` 由 `effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])` 决定。
- [x] `makeNSView` 里把这个 CSS 包成 `WKUserScript(injectionTime: .atDocumentStart, forMainFrameOnly: true)`，**插到 `addUserScript(sdkSource)` 之前**（`WKUserContentController` 按添加顺序执行）。
- [x] `dismantleNSView` 无需改动（用户脚本随 WebView 一起销毁）。
- [x] 不新增外观设置项、不改 `AppearancePreference`、不动插件侧任何代码（`json-formatter/index.html` 已有 `color-scheme: light dark`，`color: inherit` 会跟宿主 WalkView 的 canvas 色）。

## Verification

- [x] `xcodebuild build -workspace Leap.xcworkspace -scheme Leap -destination 'platform=macOS'`；`xcodebuild test ... -only-testing:LeapTests`；`swiftlint`。
- [x] 手工 A（深色 + 主题深色）：设置 → 外观 → 深色；反复开关 JSON 格式化插件 10 次，不应出现白帧。
- [x] 手工 B（深色 + 主题跟随系统）：同上，系统为深色时无白帧。
- [x] 手工 C（浅色）：确认浅色下不会反过来闪黑，插件文字仍可读。
- [x] 手工 D（运行中切主题）：设置里深 ↔ 浅切换后重新打开插件，首帧颜色应与新主题一致（已知限制：已打开的页面需要重进才变色）。
- [x] 手工 E：`webWindow` 独立窗口（`PluginWebWindowController.swift:36` 的 `PluginWebContent`）打开 web 插件；它和嵌入页共用 `PluginWebView`，应自动跟着修好，验证一遍即可。

## 已知限制

- `drawsBackground` 是 `WKWebView` 的私有 key（`setValue(_:forKey:)`）。它在 macOS 26 上仍可用，但不是公开 API，系统大版本升级后需要回归一次。备选是公开的 `underPageBackgroundColor`，但它在 WebKit 内部仍有绘制，单靠它无法消除首帧白底——这也是不选它作为主方案的原因。
- 透明不是目标：WebView 变透明后会露出面板的 Liquid Glass，插件代码区会因壁纸透色而难读，所以第③ 步仍要涂不透明底色。
- 只覆盖 `presentation: web` 的内嵌页面与独立窗口；JS 列表插件不走 WKWebView，不受影响。
- 若插件页面自身把 `html`/`body` 背景写死为白（如 `background: #fff`），首帧之后仍会变白——那是插件的问题，本计划不改插件。
