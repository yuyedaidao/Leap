# 导入 App 图标（直接放 appiconset）

## Context

用户提供了两张 1024×1024 全出血成品图：

| 文件 | 底色 |
| --- | --- |
| `~/Downloads/Untitled/AppIcon-Light_512x512@2x.png` | `#F4F5F8`（浅） |
| `~/Downloads/Untitled/AppIcon-Dark_512x512@2x.png` | `#23262D`（深） |

要求：把它作为 App 图标导入，**只导入、不改图、不搞花活**。用户已明确：**只用浅色（Light）那一张**，深色/暗色模式交给系统自动处理。

上一轮我犯的错：给 `icon.json` 加了蓝色渐变/阴影/translucency；又绕去用 `.icon` + `Project.swift` 独立输入。用户反馈：没必要用 actool，直接放到合适的位置，顶多生成不同尺寸。

## 现状（工作区未提交，本轮要清掉）

- `Project.swift` 被我加了 `.folderReference(path: "Resources/Leap/AppIcon.icon")` + 注释 —— **回退**，恢复成只有 `.glob(pattern: "Resources/Leap/Assets.xcassets")`。
- `Resources/Leap/AppIcon.icon/`（`icon.json` + `Assets/AppIcon.png`）—— **整个删除**。
- `Resources/Leap/Assets.xcassets/` 现有 `AppIcon.backup.appiconset`（旧图标 10 个尺寸，仅作参考模板）、`LauncherSettingsIcon.imageset`、`Contents.json`。
- `ASSETCATALOG_COMPILER_APPICON_NAME: "AppIcon"`（`Project.swift:57`）已就位，只要目录名为 `AppIcon.appiconset` 就会被 Xcode 自动当作 App 图标。

## Approach

在 `Resources/Leap/Assets.xcassets/` 下新增 `AppIcon.appiconset/`，用 `sips` 从 **`AppIcon-Light_512x512@2x.png`** 这一张 1024 源图逐档降采样出 10 个 PNG，`Contents.json` 照抄 `AppIcon.backup.appiconset/Contents.json` 的 10 项结构（`16/16@2x/32/32@2x/128/128@2x/256/256@2x/512/512@2x`，`idiom: "mac"`）。

不写 `.icon`、不改 `Project.swift`、不套任何装饰、不放深色图。

## Files to modify

- 新增 `Resources/Leap/Assets.xcassets/AppIcon.appiconset/`（10 个 PNG + `Contents.json`）
- 回退 `Project.swift` 到 HEAD（`git checkout -- Project.swift`）
- 删除 `Resources/Leap/AppIcon.icon/`（整个目录）

## Steps

- [x] `git checkout -- Project.swift`；删除 `Resources/Leap/AppIcon.icon/`
- [x] 用 `sips -Z <px>` 从 `AppIcon-Light_512x512@2x.png` 生成 10 档 PNG 到 `AppIcon.appiconset/`
- [x] 复制 `AppIcon.backup.appiconset/Contents.json` 到新目录（内容与本任务一致，无需改）
- [x] `xcodebuild build -workspace Leap.xcworkspace -scheme Leap -destination 'platform=macOS'`
- [x] 核对产物：`AppIcon.icns` 存在、`Info.plist` 的 `CFBundleIconName == AppIcon`、icns 内档位齐全
- [ ] 按 `~/.codex/skills/git-auto-commit/SKILL.md` 风格 `type(scope): 中文标题` 提交并 `git push origin main`

## Reuse

- `Resources/Leap/Assets.xcassets/AppIcon.backup.appiconset/Contents.json` — 10 项结构可直接复用，只换 filename 引用（文件名本来就同名，可原样拷贝）。
- `Project.swift:57` 的 `ASSETCATALOG_COMPILER_APPICON_NAME: "AppIcon"` — 无需改动。
- `Sources/Leap/DataSettingsPage.swift:87` 用 `NSWorkspace.shared.icon(forFile:)` 读图标，图标生效后自动跟随，无需改。

## Verification

```bash
xcodebuild build -workspace Leap.xcworkspace -scheme Leap -destination 'platform=macOS'
APP="$(xcodebuild -workspace Leap.xcworkspace -scheme Leap -destination 'platform=macOS' -showBuildSettings | awk '/ BUILT_PRODUCTS_DIR/{print $3}')/Leap.app"
ls -l "$APP/Contents/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' "$APP/Contents/Info.plist"
sips -s format png -Z 256 "$APP/Contents/Resources/AppIcon.icns" --out build/icon-check/256.png   # 肉眼看图
```

- 构建零 icon 相关 warning
- 产物 icns 里 16/32/128/256/512 档齐全
- 图标视图里不显方、不显小
