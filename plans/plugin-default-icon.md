# 生成插件的默认 icon 换成独立的通用图标（Figma 设计）

## Context

「创建插件模板」勾选「包含图标」时，生成的 `icon.png` 直接复制的是**生成器插件自己的图标**：

```js
// Resources/Leap/OfficialPlugins/TemplateGenerator/templates.js:154
if (data.includeIcon) files['icon.png'] = readFileSync(path.join(__dirname, 'default-icon.png'));
```

也就是说，所有新建插件的图标都和「插件模板生成器」长得一样，无法区分谁是谁。用户希望通过 Figma 设计一张**通用**的插件图标，作为生成结果的默认图标。

现状细节：

- `default-icon.png` 为 1024×1024 RGB + alpha，同一个文件既作为生成器插件自己的 `manifest.icon`（`manifest.json:6`），又作为生成结果的 `icon.png`。
- 展示处都是等比缩放后加圆角：启动器命令图标 28×28（`Sources/Leap/LauncherView.swift:404-421`，圆角 9）、设置页插件图标（`Sources/Leap/PluginSettingsPage.swift:374-390`，圆角 7）。因此设计要在 28pt 下仍可辨识，且不要依赖方形底色的圆角（会被二次裁切）。
- 生成器 README 已写「可替换 icon.png 为自己的 PNG 图标」，新图标只是更好的默认值。

## Approach

### 1. Figma 里画一张通用图标

已确认：新建专用 Figma 文件；图形用**模块拼块**；配色用**系统蓝主色**；导出 1024×1024 透明 PNG。

Figma 文件：<https://www.figma.com/design/yaE8p1bs9kKBf2SBoo2QMG>（`Leap Plugin Generic Icon`，`Leap Plugin Icon` frame = 1:2）

设计规格（已按 Apple 系统图标风格修订）：

- 画布：1024×1024 frame，透明背景。
- 底色：满幅 1024×1024 连续曲率圆角矩（cornerRadius 224，cornerSmoothing 1），自上而下蓝色渐变 `#58A6FF` → `#0060DF`，与系统蓝 `#007AFF` 同色相。
- 字形：2×2 白色圆角块，240×240、cornerRadius 60、间距 48；右下块整体向右下偏移（脱离网格），表达「可插拔的一块」。
- 右下脱离块用左上→右下的 45° 对角渐变（白 100% → 白 40%），形成飞出去的层次；其余三块纯白。
- 不放文字；底色自身已带圆角，宿主再叠 7–9pt 圆角裁切也不会出现双重边框。

导出：`rsvg-convert` 把 Figma SVG 导成 PNG（RGB + alpha，1024×1024，文件名 `plugin-icon.png`）。不用 `download_assets`/`exportAsync` 直接取 PNG：前者把透明区压成画布灰底，后者 PNG 体量超 MCP 返回上限。

### 2. 落到仓库

- 新增 `Resources/Leap/OfficialPlugins/TemplateGenerator/plugin-icon.png`（生成结果用的默认图标）。
- `templates.js:154` 改为复制 `plugin-icon.png`；生成器自身 `manifest.json` 的 `icon` 仍指向 `default-icon.png`（生成器自己的身份不变）。
- 检查 Tuist 资源声明是否需要补文件（`Resources/Leap` 目前应整目录打包，需确认 `Project.swift` 是否逐文件列举）。

### 3. 文档同步

- 生成器 `README.md` 中「可选生成默认 icon.png」的说明保持不变；如图标配色与品牌相关，可在 `Docs/PluginDevelopment.md` 的图标相关段落补一句默认图标来源。

## Files to modify

- `Resources/Leap/OfficialPlugins/TemplateGenerator/plugin-icon.png`（新增，Figma 导出）
- `Resources/Leap/OfficialPlugins/TemplateGenerator/templates.js`（`:154` 图标来源）
- `Tests/PluginTemplateGenerator/*.test.js`（图标字节断言）
- `Project.swift` 无需改：`Resources/Leap/OfficialPlugins` 是 `.folderReference`（`Project.swift:45`），新增文件自动随 app 打包。

## Reuse

- 图标规格、导出尺寸以现有 `Resources/Leap/OfficialPlugins/TemplateGenerator/default-icon.png`、`Clipboard/default-icon.png` 为基准（1024×1024，透明）。
- 生成与复制链路不变：`filesFor()` 直接读文件字节写入生成目录（`templates.js:149-156`）。

## Steps

- [x] 确认图标方向与配色（已确认：模块拼块 + 系统蓝 #007AFF）。
- [x] 在 Figma 新建专用文件，按规格绘制 1024×1024 图标，导出透明 PNG，把文件链接记入本计划。
- [x] 把导出文件加入 `Resources/Leap/OfficialPlugins/TemplateGenerator/plugin-icon.png`。
- [x] `templates.js` 的 `includeIcon` 分支改用 `plugin-icon.png`。
- [x] 生成器 `manifest.json` 的 `icon` 保持 `default-icon.png`，确认生成器自身外观不变。
- [x] 生成器测试补断言：勾选图标时生成的 `icon.png` 与 `plugin-icon.png` 字节一致，且与 `default-icon.png` 不同。

## Verification

```bash
Resources/Leap/Runtimes/node-24.21.0/bin/node --test Tests/PluginTemplateGenerator/*.test.js
```

手测：用「创建插件模板」勾选「包含默认图标」生成一个插件，检查目录内 `icon.png`，在设置页与启动器里确认显示为新图标（不是生成器图标）。
