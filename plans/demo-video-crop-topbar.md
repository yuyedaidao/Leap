# 宣传片：裁掉录屏镜头顶部残留的菜单栏与底图工具栏

## Context

宣传片里所有「操作 Leap」的录屏镜头，画面顶部都有一条不会动的横条：上面是 macOS 菜单栏的残边（预览 / 文件 / 编辑…），下面是录制底图窗口 `bg.png` 的工具栏（含「搜索」框）。

原因是录屏是整屏采集，而 `src/components/Footage.tsx` 的裁切窗口从源图 `y = 60` 像素开始——实测各次录制的分层是：

| 源图 y（3456×2234，2x） | 内容 |
|---|---|
| 0 – 66 px | macOS 菜单栏（亮灰，luma 0.248） |
| 68 – 172 px | Preview 底图窗口工具栏（暗，含 `bg.png` 标题与「搜索」框） |
| 176 px 起 | 真正的底图渐变，可安全取景 |

`crop.y = 60` 正好落在菜单栏下沿，于是每条录屏镜头顶固定挂着「6px 菜单栏残边 + 一整条 Preview 工具栏」。合成的动效镜头（S1 / S4a / S5）是 Remotion 画的，没有这个问题——抽帧对比可证：t=33s、t=45s 顶部全平，t=12s、t=20s 有横条。

## Approach

把取景窗口的 `y` 从 `60` 提到 `180`（工具栏底边实测 172–176 px，留 4–8 px 余量），并同步修正注释和过期的时长说明。

同一个常量现在在 `src/Main.tsx` 和 `src/Root.tsx` 里各写了一份（后者供单镜预览 Composition 使用），两处必然会漂移——这次要改的就是「常量与实际画面不符」，所以顺手把它挪到已有 `Crop` 类型的 `components/Footage.tsx` 里导出，两个文件改为 import。

取景范围只下移、不缩放（用户已定）：构图、字幕位置、面板大小全部不变，画面内容整体上移约 90 px（输出像素）。

裁切是等比推导的：`w = 2560`（源像素）→ 输出 1920 宽，缩放 0.75，可视高度 = `1080 / 0.75 = 1440` 源像素（720 pt）。y 提到 180 后画面覆盖源图 180–1620 px（90–810 pt），启动器顶边在 285 pt、最高插件列表底部约 611 pt，仍在框内；底部多出 60 px 无内容渐变，不影响字幕安全区。

## Files to modify

- `~/Work/Project/2026/LeapVideo/src/components/Footage.tsx`：新增并导出 `PANEL_CROP = { x: 448, y: 180, w: 2560 }`，注释写清「从菜单栏与底图工具栏下沿开始取景」
- `~/Work/Project/2026/LeapVideo/src/Main.tsx`：删掉本地的 `PANEL`，改用 `PANEL_CROP`；镜头表上方注释里的「总长 1800 帧 = 60 秒」已过期（实际 1623 帧 = 54.1 秒，见 `SCRIPT.md` v3），一并改成 1623 / 54.1 秒
- `~/Work/Project/2026/LeapVideo/src/Root.tsx`：同样删掉本地 `PANEL`，改用 `PANEL_CROP`
- `~/Work/Project/2026/LeapVideo/out/leap-54s.mp4`（重渲染产物）
- `~/Work/Project/2026/Leap/Docs/media/leap-demo.mp4`、`leap-demo-poster.png`（README 引用的素材，重渲染后同步覆盖，README 继续用 1080p 母版，用户已定）

## Reuse

- 裁切逻辑已是现成的：`Footage.tsx` 用 `crop.{x,y,w}` + 自动 16:9，只要动取值，8 条录屏镜头（s2a/s2b/s2c/s2d/s3a/s3b/s4b1/s4c）全部生效，无需改任何镜头组件。
- 时长由 `SHOTS` 的 `len` 求和得到（`TOTAL_FRAMES`），渲染命令不变。

## Steps

- [x] `Footage.tsx` 导出 `PANEL_CROP`（y=180），`Main.tsx` / `Root.tsx` 改用导入，修正帧数注释
- [x] `npx remotion render Main out/leap-54s.mp4` 重出成片（1920×1080 / 30fps / H.264）
- [x] 抽帧自检：`t = 8 / 12 / 20 / 30 / 45 s` 各取一帧，断言画面顶部 0–90 px 既没有高亮横条也没有可 OCR 的文字（不应再出现「预览」「文件」「bg.png」「搜索」）
- [ ] 确认启动器面板与字幕都没被裁到：OCR 应仍读到搜索词与字幕原文
- [x] 从新成片取一帧（与原海报同时间点）覆盖 `Docs/media/leap-demo-poster.png`（1920×1080），并覆盖 `Docs/media/leap-demo.mp4`
- [ ] 提交 LeapVideo 仓库的取景改动；在 Leap 仓库提交新素材（`docs(readme): 重剪辑裁掉录屏顶部的菜单栏与工具栏`）并推送

## Verification

- `ffprobe` 时长仍为 54.1 s、分辨率 1920×1080、30 fps。
- 抽帧脚本判据：顶部 90 px 的行亮度均值与相邻行一致、行内最大值不超过画面常规亮度（无文字高光）。
- 逐镜人工过一遍（Remotion Studio 或导出帧）：S2 三镜、S3 两镜、S4 两镜的启动器面板完整，字幕不被遮挡。
- README 里的 raw 链接仍返回 200。

## 已知取舍

- 只下移取景：面板上方仍留约 190 pt 底图空白（约占画面高度 27%）。保留这份留白是为了不动现有构图与字幕位置（用户已确认接受）；若以后再想更聚焦，收紧 `w` 是独立的一次改动。
- 不重录：`bg.png` 底图窗口的工具栏仍在源素材里，只是被裁出画外。下次录屏若想彻底避免，可把底图改成全屏（菜单栏自动隐藏 + 无边框窗口）。
