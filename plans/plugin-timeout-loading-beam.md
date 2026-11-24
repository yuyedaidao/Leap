# 插件执行期限与加载光带调整

## Context

- `LoadingTest` 在 `onInputChange` 中等待超过 3 秒后，宿主判定超时并关闭整个插件会话；普通网络请求也很容易超过这一期限。
- 3 秒期限目前同时承担“防止同步死循环拖死会话”和“限制异步业务耗时”两种职责，需要保留失控插件的兜底，但不能把正常网络 I/O 当作卡死。
- 当前加载状态由 `PluginLoadingRing` 在 28×28 图标外绘制约 32×32 圆环；非圆形图标时视觉效果不协调。
- 用户建议改为 `PluginHeaderTag` 整个胶囊标签的 BorderBeam 动画。工程已接入 `BorderBeam`，搜索头部已有可复用用法。

## Approach

- **已确认：**将 `PluginProcessSession.request` 的默认业务期限从 3 秒延长到 **60 秒**，继续以同一个超时兜底同步死循环和长期不完成的异步任务。保留 `timeout` 参数，测试仍可用短显式期限快速覆盖超时路径。
- 保持每个事件累计 60 秒的宿主调用等待额度及“宿主等待期间暂停业务计时”规则不变；网络请求应在插件内使用 `AbortSignal` 响应输入取消。
- **已确认：**删除图标外圈的 `PluginLoadingRing`，复用现有 `BorderBeam` 依赖，在 `PluginHeaderTag` 的 40pt 高、20pt 圆角胶囊边界持续循环播放，直到加载状态结束。
- 光带复用搜索头部当前的 `.line`、`.rightToLeft`、`BeamPalette.colorful` 和 `intensity: 0.5`，形状使用与背景一致的 `.rounded(20)`；加载状态只由现有 `showsLoading` 驱动 `active`，不添加第二套计时器。
- 保持 `leap.showLoading()` / `leap.hideLoading()`、查询/选择状态归属、取消和结束清理逻辑不变，仅替换视觉呈现。
- 将加载状态的无障碍说明附着在现有 28×28 图标上：加载时提供“正在查询/正在执行”和原有标识，非加载时继续隐藏装饰图标；遵循系统“减弱动态效果”设置。
- **已确认：**本次计划不启用独立审核。

## Files to modify

- `Sources/LeapCore/PluginProcessSession.swift`：仅把请求默认业务期限从 3 秒改为 60 秒，复用现有超时收尾。
- `Sources/Leap/PluginInteractionView.swift`：引入 BorderBeam，移除圆形加载环，为 `PluginHeaderTag` 增加加载外观并迁移无障碍状态。
- `Tests/LeapTests/PluginInteractionProcessTests.swift`：更新期限、超时及会话关闭测试。
- `Tests/LeapUITests/PluginInteractionUITests.swift`：更新加载状态的界面验收。
- `Docs/PluginDevelopment.md`：同步全部默认期限文案，以及“图标外圆弧”改为“整个插件标签光带”的加载动画说明。

## Reuse

- `Sources/LeapCore/PluginProcessSession.swift`：现有 `Pending` 计时、宿主调用等待额度、取消及 `fail` 收尾机制。
- `Sources/LeapCore/PluginListSession.swift`：现有 `isLoadingVisible` 和按取消令牌隔离旧回调的状态管理。
- `Sources/Leap/PluginInteractionView.swift`：`PluginHeaderTag`、`PluginInteractionTag` 及加载状态无障碍标识。
- `Sources/Leap/LauncherView.swift`：工程现有 `BorderBeam` 引入及 `.borderBeam(shape:style:direction:active:colors:intensity:)` 配置。
- `Tuist/Package.swift`、`Project.swift`：BorderBeam 已配置，无需新增依赖。

## Steps

- [x] 确认默认业务期限 60 秒、保留失控保护、加载光带持续循环；不启用独立审核。
- [x] 将默认业务期限改为 60 秒，增加一个使用默认期限且超过原 3 秒仍能成功的真实 SDK 测试；保留短显式期限的超时测试。
- [x] 用 `PluginHeaderTag` 的持续 BorderBeam 替换图标圆环，把加载无障碍状态移到现有图标；头部保持 40pt 高、图标保持 28×28，并验证 Reduce Motion 下库的行为，必要时显式降级。
- [x] 将 UI 测试的 `assertLoadingRing` 改为固定 28×28 图标的加载状态断言，继续验证查询/选择期间列表面板尺寸稳定及加载结束清理。
- [x] 更新插件开发文档和 LoadingTest 的验收方式，不修改 LoadingTest 插件源码。
- [x] 构建、运行相关单测/UI 测试，并提供实际视觉效果预览；用户确认前不提交。

## Verification

- 运行 `xcodebuild build -workspace Leap.xcworkspace -scheme Leap -destination 'platform=macOS'`。
- 运行相关 `LeapTests`：用真实 JavaScript SDK 的 `setTimeout` 模拟约 3.2 秒异步任务，验证默认期限下成功且会话可继续复用，不依赖外部网络；现有 `timeout: 0.1` 等显式期限用例继续验证超时和关闭后的错误行为，并覆盖取消。
- 运行相关 `LeapUITests`，确认查询与选择均能显示和清除加载状态。
- 用现有 `LoadingTest` 输入 `4` 或 `9`，实测超过原 3 秒期限仍能完成、光带持续显示后消失、连续输入取消和退出重进。
- 分别使用圆形、方形和不规则插件图标检查整个标签光带；检查 Reduce Motion、浅色/深色外观及长插件名布局。
