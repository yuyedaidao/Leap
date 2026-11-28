# README 接入 54 秒演示视频

## Context

`~/Work/Project/2026/LeapVideo` 产出了新片 `out/leap-54s.mp4`（1920×1080@30 / 1623 帧 / 54.1s / 3.7MB / 无音轨 / moov 已前置），用户认可内容，要放进 Leap 仓库 README。

顺带核出的 README 与当前产品不一致之处（本次一并处理，均已确认）：

| 位置 | 问题 | 结论 |
|---|---|---|
| `Docs/media/icon.png` | 平均色 `#815a85`（紫）＝**旧图标**，README 顶部 96px 就是它 | 换成当前图标（平均色 `#d0def8`，白底+蓝） |
| `Docs/media/launcher-screenshot.png` | 1600×1184 旧截图，演的「输 `a` 出列表」 | 删除，位置让给视频封面 |
| `Docs/media/lunch-plugin-demo.gif` | 185K，没有任何 md 引用（孤儿） | 删除 |
| 「首次使用」例子 | 写「输入『备忘录』或 `bwl`」，与视频主角场景不符 | 改成视频里的 `jsq` / `shizhong` / `clock` / `gj` |

用户已拍板的选项：**静止封面 + 点击看片**；**直接放 1080p 原片**；**保持无声**；顺带清掉旧图标 / 静态截图 / 孤儿 GIF。

## Approach

1. 视频产物落 `Docs/media/leap-demo.mp4`（原名稳定，后续可原地替换），封面落 `Docs/media/leap-demo-poster.png`（1920×1080 截帧）。
2. README 用 `<a><img></a>` 包住封面，链接指向 **raw 地址**（`raw.githubusercontent.com/yuyedaidao/Leap/main/...`）——浏览器会以 `video/mp4` 内联播放并支持拖动进度条；仓库内相对路径的 mp4 在 GitHub 的 `<video>` 标签下放不出来（CSP 只放行 `user-attachments` CDN），而相对链接点开是 blob 页（只有下载按钮），所以走 raw。`origin` = `github.com/yuyedaidao/Leap`，默认分支 `main`，已确认。
3. 封面帧选 **成片 38.6s**（`随机密码` 插件刚跑出 3 条 16 位密码、字幕还没起），它同时承载「插件」与「AI 写插件」两个卖点。备选：7.9s（`jsq`→计算器，突出搜索）、22.0s（`gj`→关机插件列表）。
4. 图标从 `Resources/Leap/Assets.xcassets/AppIcon.appiconset/AppIcon-512@2x.png`（1024×1024）缩到 192×192 另存 —— README 只显示 96px，没必要塞 400K 的原图。

## Files to modify

- `README.md` — 新增视频块；更新首次使用示例；卖点行与视频对齐（见下，可拒）
- `Docs/media/leap-demo.mp4`（新增，3.7MB）
- `Docs/media/leap-demo-poster.png`（新增，约 1–2MB）
- `Docs/media/icon.png`（替换为新图标 192×192）
- `Docs/media/launcher-screenshot.png`（`git rm`）
- `Docs/media/lunch-plugin-demo.gif`（`git rm`）

## README 改动草案

头部到按钮一段改成：

```md
<p align="center"><img src="Docs/media/icon.png" width="96" alt="Leap 图标"></p>

# Leap

**把你的想法变成 Mac 上的一条命令。**

Leap 是一个可以自由添加插件的开源 macOS 启动器。把常用脚本做成命令，或用你熟悉的 AI 编程工具创建插件。装到本机后，按 `⌥⌘L` 就能搜索并运行。

**无需注册 Leap 账号 · 不设插件安装数量上限 · 官方商店与本地插件都能装**

[下载 Leap](https://github.com/yuyedaidao/Leap/releases/latest) · [浏览现成插件](https://github.com/yuyedaidao/LeapPlugins)

<p align="center">
  <a href="https://raw.githubusercontent.com/yuyedaidao/Leap/main/Docs/media/leap-demo.mp4">
    <img src="Docs/media/leap-demo-poster.png" width="800" alt="Leap 演示视频：搜索应用、用插件定时关机、让 AI 写一个随机密码插件">
  </a>
</p>
<p align="center"><sub>▶ 54 秒演示：搜索任意 App · 插件即命令 · 用 AI 写插件</sub></p>
```

「首次使用」改成（删掉备忘录/bwl 的旧例子）：

```md
### 首次使用

按 `⌥⌘L` 呼出搜索框，应用和插件命令在同一个框里搜：

- 应用：`jsq`（拼音首字母）、`shizhong`（全拼）、`clock`（英文名）都能命中同一个 App
- 插件命令：已安装的插件就是一条命令，输入 `gj` 直接跑关机插件
```

## Steps

- [x] `cp out/leap-54s.mp4 Docs/media/leap-demo.mp4`（已验证 moov 在 mdat 前，不需要重封装）
- [x] `Docs/media/leap-demo-poster.png`：从成片 38.6s 抽一帧，`sips` 压一档体积
- [x] `Docs/media/icon.png`：AppIcon-512@2x → 192×192 → 覆盖旧图
- [x] `git rm Docs/media/launcher-screenshot.png Docs/media/lunch-plugin-demo.gif`
- [x] 改 `README.md`：视频块 + 首次使用示例 + 卖点行第三句（`插件保存在本机` → `官方商店与本地插件都能装`，与成片 S5a 一致，可拒）
- [x] 全仓搜残留引用：`launcher-screenshot`、`lunch-plugin-demo`
- [x] **不 commit**（AGENTS.md：视觉改动等用户看过再提交）；把封面图与 README diff 交给用户过目

## Verification

- `ffprobe` 确认入口文件仍是 1920×1080 / 1623 帧 / 54.1s；`xxd -l 48` 确认 `moov` 在前
- 封面用 `swift tools/ocr.swift` 核对：能看到「随机密码 / 16 位随机密码」与三条密码
- 新图标平均色用 `ffmpeg -vf scale=1:1` 采样，应为 `#d0def8`（不再是紫色）
- `grep -rn "launcher-screenshot\|lunch-plugin-demo" --include=*.md .` 无输出
- `open Docs/media/leap-demo.mp4` 本地能播；push 后 `curl -I` 检查 raw 地址返回 `content-type: video/mp4`

## Risks

- raw 链接写死了 `yuyedaidao/Leap@main`：仓库改名或大改目录结构会失效（改回相对链接即可降级为「下载」）。
- `Docs/media` 从 540K 涨到约 5MB；`Docs/media` 是文档素材目录，不进 App 包，可接受。
- 封面里已经有成片字幕，图上再叠一行 `<sub>` 会重复一次信息，觉得啰嗦就删掉那一行。
