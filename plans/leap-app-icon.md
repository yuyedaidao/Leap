# 重做 Leap 应用图标（C 方案：袋鼠剪影 + 起跳线）

## Context

现有图标（`Resources/Leap/Assets.xcassets/AppIcon.appiconset/`，1024 主图）两个实证问题：

| 项 | 现状 | macOS 26 系统图标基准 |
|---|---|---|
| 外形 | 全出血正方块，四角 alpha=255 | 透明 squircle，占画布 87.5% |
| 背景 | 纯平 `#55449F`，L=0.086，无渐变无内高光 | 纵向渐变 + 顶部内高光 |
| 主体占位 | 41% 宽 x 62% 高 | ~80% |
| 主体层次 | 橙 vs 奶油 2.43:1（同明度）→ 缩小即糊 | 靠剪影形状分层，不靠填色 |
| 16px | 约 8 行有效像素，不可辨 | 一眼一个轮廓 |

根因：**现在是「一张插画缩到 1024」，要改成「一个符号放到 1024」。** 配色深浅只是表象。

用户已选定 C 方案（袋鼠剪影 + 起跳线），并给出 Apple 风格要求：squircle 适配、Liquid Glass 材质、分层深度、边缘高光、轻微内发光、扁平正面视角、圆润几何、强剪影、主体居中占约 80% 安全区、色彩干净、渐变柔和克制。

## Approach

**用 SVG 画符号，用 `rsvg-convert` 出位图，用 `actool` 出 `.icon` / `.icns`。** 不手绘位图、不引第三方依赖——这台机器上 `rsvg-convert`、`magick`、`sips`、`iconutil`、`actool`、Icon Composer 全都已就位（已验证）。

三项与现有实现不同的关键改动：

1. **剪影化**：袋鼠做成**单色实心剪影**（无肚皮、无内耳、无眼睛），层次来自轮廓张力 + 一道同向高光。这是 16px 可读的唯一做法。
2. **主体放大到 80%**：主体 bbox 620x660（画布 61%x64%），squircle 内约 78%，与系统图标同一呼吸感；光学中心比几何中心上移 64px（向上运动的主体该略微偏高）。
3. **材质拆层**：Liquid Glass 的半透明只给**起跳线**和**背景**，绝不给主体剪影——主体一旦半透明，16px 立刻失去边缘。这条是硬约束，也是 `.icon` 必须拆两组的原因（见下）。

### 已定决策（用户确认）

| 决策 | 结论 |
|---|---|
| 主体/背景色彩 | 白/奶油剪影 `#F7F2FF` + 品牌紫亮渐变（保住旧识别色，亮度 L 0.086 → 0.16/0.075） |
| 资产格式 | 迁移到 macOS 26 `.icon` 分层格式 |
| 姿态 | 向右跳跃 + 保留起跳线 |
| 出图策略 | 先出 3 版几何候选对比，定一版后精修 |

### 对比度修正（实算 WCAG，替换先前估算）

先前的 3.7:1~7.9:1 偏乐观。`#F7F2FF` 的 L=0.905，与背景两端实测：

```
#8674F0  L=0.239  ->  3.31:1   袋鼠头部所在区域，不合格
#4F3EAE  L=0.081  ->  7.27:1
```

头部正好落在背景最亮的顶部，3.3:1 会削弱剪影。**渐变端点压深一档**，全程达标：

```
#6E5BE0  L=0.158  ->  4.59:1   达标
#43319E  L=0.075  ->  8.19:1
```

视觉上仍是「亮紫渐变」，只是明度跨度从 0.158 收到 0.083，与「渐变柔和克制」也更一致。

## 设计规格（可直接画成 SVG）

画布 1024x1024，坐标原点左上，y 向下。跳跃方向默认**向右**。

```
              +------------------------+  y=64
              |      squircle           |
              |   +----------------+    |  y=118  主体顶
              |   |    __          |    |
              |   |   /  \__       |    |
              |   |  |  .   \__    |    |
              |   |  |       .  \   |    |
              |   |  \__        )  |    |  y=778 主体底
              |   +----------------+    |
              |   ===================   |  y=800 起跳线
              +------------------------+  y=960
```

| 元素 | 几何 | 填充 |
|---|---|---|
| squircle | App 图标 87.5%（64→960）；`.icon` 路径由系统遮罩生成，SVG 里不自己圆角 | 背景渐变 |
| 背景 | 全出血 rect，(0,0)-(1024,1024)，被系统 squircle 裁切 | 纵向渐变 `#6E5BE0`(y=64) → `#43319E`(y=960)；顶部再叠一条 2% 白、向下羽化 96px 的内高光 |
| 袋鼠剪影 | bbox (200,118)-(820,778)，620x660 | `#F7F2FF`，100% 不透明 |
| ├ 躯干 | 豆形，髋 (470,640) → 肩 (400,380)，最大宽 200 | 同上 |
| ├ 头+吻 | 楔形圆角，头心 (560,330)，朝右，耳后倾 30° | 同上 |
| ├ 前臂 ×2 | 胸部下方两根粗短锥形，(500,400)→(600,500) | 同上 |
| ├ 后腿+脚 | 髋 (450,600) → 踝 (700,690)，腿粗 70→40；脚掌水平延伸 120 | 同上 |
| └ 尾巴 | 髋 (430,640) 弧形向左下扫到 (180,700)，粗 90→45，圆头 | 同上 |
| 起跳线 | 圆头胶囊 (200,800)-(760,800)，粗 44 | 白 42% alpha |
| 主高光 | 沿剪影左上轮廓 1 条 18px 宽描边，仅覆盖左上半周 | `#F7F2FF` 30% |
| 输出基线 | 白剪影 + 紫渐变底：对比 4.59:1（顶）~8.19:1（底） | — |

已知取舍与护栏：

- **不做眼睛/内耳等细节**：16px 下是噪点，不是细节。
- **主体不允许半透明**：硬约束。`.icon` 的 `translucency` 是**按 group 生效**的，整图一组会把剪影一起变透——所以必须拆两组，见下节。
- 渐变明度跨度控制在 0.083（`#6E5BE0`→`#43319E`），与「柔和克制」一致且全程对比达标。
- 剪影若真要「一点温度」，允许在胸口加 1 条 24px 宽的奶油色细带作为唯一装饰，其余一律留空。

## 3 版几何候选

同一坐标系、同一配色，只改几何。每版输出 1024 / 32 / 16 三联图并排对比。

| | V1 弧线主导 | V2 体块主导 | V3 拉伸主导 |
|---|---|---|---|
| 主张 | 一条连续的跃起曲线 | 敦实的一团，最像「剪影」 | 强调速度与位移 |
| 尾巴 | 长，左扫到 x=150，粗 90→40 | 短粗，到 x=250，粗 100→70 | 中长，到 x=190，尾尖上翘 |
| 躯干最大宽 | 190 | 230 | 175 |
| 头部 | 小且圆，头心 (540,340) | 大且方，头心 (580,320) | 中等略长，头心 (600,350) |
| 后腿 | 弯曲蓄力，踝 (680,700) | 粗壮，踝 (700,680) | 直且向后蹬，踝 (760,720) |
| 整体 bbox | (150,118)-(800,778) | (200,110)-(820,790) | (170,130)-(880,760) |
| 起跳线 | (200,800)-(760,800) 粗 44 | (190,810)-(790,810) 粗 52 | (240,790)-(700,790) 粗 38 |
| 16px 预判 | 尾巴在缩小后退化成一抹，靠身体+线 | 最稳，一团+一条线最清晰 | 横向过宽，16px 可能被压扁 |

挑选标准（顺序不可换）：16px 可辨，然后 32px 姿态可读，最后才是 1024 的美感。

## `.icon` 结构（必须拆两组，否则剪影变透）

```jsonc
{
  "fill": { "automatic-gradient": "extended-srgb:0.431,0.357,0.878,1" },  // #6E5BE0 兜底
  "groups": [
    {
      // 第 1 组：背景渐变 + 起跳线 + 高光 —— 允许液态玻璃感
      "layers": [{ "image-name": "bg.png", "name": "bg" }],
      "translucency": { "enabled": true, "value": 0.35 }
    },
    {
      // 第 2 组：袋鼠剪影 —— 关闭 translucency，保证 16px 边缘锐利
      "layers": [{ "image-name": "subject.png", "name": "subject" }],
      "translucency": { "enabled": false, "value": 0 },
      "shadow": { "kind": "neutral", "opacity": 0.35 }
    }
  ],
  "supported-platforms": { "squares": "shared", "circles": ["watchOS"] }
}
```

- `bg.png` 与 `subject.png` 都是 1024x1024 全出血透明 PNG，由同一个 SVG 分两次导出（隐藏另一层）。
- 系统负责 squircle 遮罩、圆角、阴影、深色/着色三态渲染 —— SVG 里**不要**画圆角。
- 若 actool 拒绝 `bucket` 内双组结构，回退方案：合并成单图单组、`translucency` 关闭（放弃液态玻璃感，保住剪影，其余设计不变）。

## 图标管线

```
Resources/Leap/IconCandidates/AppIcon.svg          <- 唯一真源（新增）
        |
        | rsvg-convert -w 1024 -h 1024
        v
   AppIcon-1024.png  (透明底含 squircle? 否 -> 见下)
        |
        +--> AppIcon.icon/Assets/AppIcon.png + icon.json   (推荐)
        |        |
        |        +-> actool --app-icon AppIcon ... -> Assets.car + AppIcon.icns
        |             (squircle / 阴影 / translucency / dark / tinted 全由系统生成)
        |
        +--> AppIcon.appiconset/AppIcon-{16,32,128,256,512}[@2x].png  (回退路径)
        |        rsvg-convert 逐档降采样，不用 sips（避免 libvips 锐化过冲）
        |
        +--> Docs/media/icon.png (256) 与 LauncherSettingsIcon.imageset (1024/2048)
```

关键点：

- **推荐 `.icon` 而非经典 appiconset**：实测经典 `AppIcon.appiconset` 在 Contents.json 里加 `appearances: luminosity/dark` 与 tinted 会被 `actool` 忽略（报 "2 unassigned children"），且不会生成 dark/tinted rendition。要深色/着色三态，只能走 `.icon`。`.icon` 的 squircle、内阴影、translucency 都由 Apple 套，不用手画（已用 `ping_icon.icon` 验证：产物 icns 的 squircle bbox (9,10)-(119,120)、四角 alpha=0）。
- 命名保持一致：`.icon` 也命名为 `AppIcon`，`ASSETCATALOG_COMPILER_APPICON_NAME: "AppIcon"`（`Project.swift:55`）无需改动。
- SVG 里**不要**画方块背景和圆角——只画 squircle 内的内容（渐变由 `icon.json` 的 `fill.automatic-gradient` 或 SVG 自带 rect 承担，二选一，见下条待定项）。
- 起跳线必须是矢量圆头，不要用 filter 模糊：小尺寸要锐。

## 待定项（需用户定，决定后才动手画）

全部已定，无剩余阻塞项。仅一个执行期待验证：actool 是否接受 catalog 内的 `.icon` 双组结构（`iconutil` 回解产物可确认）。

## Files to modify

- 新增 `Resources/Leap/IconCandidates/AppIcon.svg`（唯一真源）
- 新增 `Resources/Leap/IconCandidates/redesign/`（3 版候选的 1024/32/16 三联图 + 对比 contact sheet，定版后删除）
- 新增 `Resources/Leap/Assets.xcassets/AppIcon.icon/`（`icon.json` + `Assets/AppIcon.png`）
- 删除 `Resources/Leap/Assets.xcassets/AppIcon.appiconset/`（若走 `.icon`；否则改写其中 10 张 PNG + Contents.json）
- `Resources/Leap/Assets.xcassets/LauncherSettingsIcon.imageset/LauncherSettingsIcon{,@2x}.png`（同步新图）
- `Docs/media/icon.png`（README 展示图，256）
- `Resources/Leap/IconCandidates/**` 15 张历史候选（1254x1254 全出血、无 alpha、`git ls-files` 显示已入库）：体积大且与最终风格无关，建议一并删除
- `Project.swift`：预计不改（`.glob` 已覆盖 xcassets）

## Reuse

- `Scripts/package-release.py` / `publish-release.py` 不碰 icns（图标由 `xcodebuild` 调 actool 生成）——无需改动，但发版前需确认 `.app` 内 `Contents/Resources/AppIcon.icns` 存在且含 512/1024 档（现产物只有 16/32/128/256 四档）。
- `Sources/Leap/LauncherView.swift:213-232` 的设置按钮用 `Image("LauncherSettingsIcon").scaledToFill()` + `clipShape(Circle())`，放大后裁掉留白——新图换进去要重算 `iWidth`（现为 `ceil(sqrt(radius*radius*2))*2 = 58`）。
- `Docs/media/icon.png` 由 README:1 引用，尺寸 256 已够。

## Steps

- [x] 定配色（白剪影 + `#6E5BE0`→`#43319E` 紫渐变）、格式（`.icon`）、朝向（向右 + 起跳线）、策略（3 版候选）
- [x] 写一个参数化 SVG 模板（尾巴端点/躯干宽度/头部位置/起跳线为可替换参数），避免手抄三份坐标
- [ ] 出 V1/V2/V3 的 1024 + 32 + 16 三联图，拼 contact sheet，交用户选版
- [ ] 选定版后精修：二值化确认剪影仍是一个「一团 + 一条线」；与系统 App 并排比对
- [ ] 拆两组导出 `bg.png` + `subject.png`，搭 `AppIcon.icon/icon.json`（按上节 schema）
- [ ] `tuist generate` → `xcodebuild build` → 确认无 "unassigned children" / 尺寸警告
- [ ] `iconutil -c iconset` 解产物 icns，确认 squircle 四角 alpha=0、含 512/1024 档
- [ ] 同步 `LauncherSettingsIcon.imageset` 与 `Docs/media/icon.png`
- [ ] 删历史候选 PNG（`Resources/Leap/IconCandidates/**`，确认 `git rm`）
- [ ] `swiftlint`（无 Swift 改动，跑一次确认不引入告警）

## Verification

```bash
# 1. 资产编译（必须零 icon 相关警告）
tuist generate
xcodebuild build -workspace Leap.xcworkspace -scheme Leap -destination 'platform=macOS' 2>&1 | grep -i "icon\|actool"

# 2. 产物自检：squircle 透明、尺寸齐全
iconutil -c iconset "$(find ~/Library/Developer/Xcode/DerivedData -path '*Leap.app/Contents/Resources/AppIcon.icns' | head -1)" -o /tmp/iconcheck
sips -g pixelWidth -g hasAlpha /tmp/iconcheck/*.png

# 3. 小尺寸可读性：16/32px 二值化后人工确认轮廓仍在
magick /tmp/iconcheck/icon_16x16.png -colorspace gray -threshold 50% -scale 800% /tmp/iconcheck/16-bin.png
```

肉眼验收清单：Dock 里与系统图标并排不显方、不显小；Finder 图标视图 32px 能读出「袋鼠在跳」；深色模式（若走 `.icon`）不糊；菜单栏/关于面板同图一致。

> 已知限制：`.icon` 在 Tuist + Asset Catalog 内的行为需实测一次；若 actool 拒绝，回退到经典 appiconset（放弃深色/着色两态，其余设计不变）。
