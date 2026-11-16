# 剪切板插件打开延迟：原因与方案（含 uTools 对照）

> 状态：待批准。方向（按最新反馈）：**照搬 uTools 的实现与存储思路** —— 数据所有权搬到宿主、分组追加日志、推送更新、插件页面常驻 + 列表复用。原「迁移 SQLite/FTS5」不再采用（理由见 3.6）。

## 1. Leap 的实测与根因

同一次 App 启动内两次打开剪贴板（Debug 构建 OSLog，`subsystem BEGINSWITH "com.padding.leap"`）：

| 事件 | 第一次 | 第二次（42s 后） |
|---|---|---|
| 进入交互插件 | 58.569 | 40.441 |
| `process.run()` 起 node | +119ms | +92ms |
| 插件首个宿主调用 `getPath` | +2148ms（spawn→ready 2029ms） | +138ms（spawn→ready 46ms） |
| `dbAllDocs` 宿主耗时 | 31ms | 30ms |
| 列表出现 | 2.15s | 168ms |

- 主因：`PluginInteractionSession` 每次打开都新建 node 进程并冷启 V8（`PluginScriptExecutor.makeSession` → `PluginProcessSession.startIfNeeded`），列表要等 `enter` 走完才回。
- 次因：`dbAllDocs` 在 `@MainActor` 的 `PluginHostAPI` 里同步读盘（30ms/次），插件每敲一个字全量重跑。
- 次因：`ClipboardHistoryMonitor.capture()` 每次拷贝跑两次 `store.allDocs()`（约 60ms 主线程），且每条记录写两份（`PluginData/.../db/<id>.json` 与 `ClipboardHistory/<id>/data`）。
- 数据量：157 个 JSON / 636KB；`ClipboardHistory` 1.5MB。

## 2. uTools 是怎么做的（逆向结论）

REA 的 CLI 兜底（`npx rea-agents`）停在交互确认上被拦，所以直接解析 `app.asar` 字节头取文件表再逐个读取（同一份产物，证据是一手字节）。

- **功能归属**：`~/Library/Application Support/uTools/plugins/7eec3addfb29f07d63688641e574d26f.asar` = 官方「剪贴板」v4.3.2（`plugin.json`：`name: clipboard`，`features[].code: clipboard`，cmds `剪贴板/剪切板/Clipboard/收藏`）。
- **数据所有权在主进程**：`app.asar` 内 `dist/main.js` 的 `class kt`（`clipboardPluginId = "clipboard"`，`maxRecordNum = 1000`，`maxGroupRecordNum = 100`），目录 `<userData>/clipboard-data`。
- **存储 = 分组追加日志**：组目录按 13 位毫秒时间戳命名，每组一个 `data`，`appendFileSync(A(JSON.stringify(record)) + "\n")` 逐行追加（`A()` 加密成 hex）；满 100 条换新组；图片按 md5 命名存同组，记录 `value` 存路径。实测本机 `clipboard-data` 9.0MB、6 组、每组 100 行。去重靠 md5 + `_prevRecordItemHash` 相邻判重。
- **只读最近 11 组**：`getRecordFolderNames()` 取 `ceil(1000/100)+1` 个最新组并 `rimraf` 更老的组；`readAllRecords()` 整读每组 → `split("\n").reverse()` → 解密 JSON → 按 hash 去重，凑够 1000 条即停。
- **推送而非轮询**：新记录由主进程 `view.webContents.send("append", record)` 推给页面；preload 暴露 `readAllRecords/clearAllRecords/removeRecords/listenAppendRecord/executePaste/executeCopy/...`（`ipcRenderer.invoke("clipboard.services", ...)`）。
- **页面常驻**：插件是主窗口里的 BrowserView，隐藏只是 `hideMainWindow`；`mainHideTimingPluginAutoOut()` 用 `pluginOutTimer`（默认 3 → 180s）才 `outPlugin` 卸载。
- **渲染层不阻塞**：进 tab 时 `if (null === lh) { setState({list: []}); await this.readAllRecords() }`，先渲染空列表再填充；`lh`/`sh` 常驻内存，切 tab 不重读；搜索是内存数组过滤；列表 `slice(0, 20)`。
- **顺手确认**：收藏才走 `utools.db`（文档库 + attachment），剪贴板历史本身**没有** SQLite。

| 维度 | uTools | Leap（现状） |
|---|---|---|
| 谁读盘 | 主进程，一次读最近 11 个组文件 | 插件进程逐文件读+解码，且在 MainActor |
| 新记录怎么进列表 | 主进程 `append` 推送 | 无通道，每次输入全量重读 |
| 打开成本 | 页面常驻，隐藏 180s 后才卸载 | 每次新建 node 进程，冷启 ~2s |
| 磁盘格式 | 分组 JSON-lines + md5 图片 | 每条一个 JSON + 每条一个 `data` 副本 |

## 3. 按 uTools 思路改造

### 3.1 数据所有权搬到宿主：`ClipboardHistoryStore`（新类型）

`Sources/LeapCore/ClipboardHistoryStore.swift`，`@MainActor`，替代 `ClipboardHistoryMonitor` 里对 `PluginDocumentStore` 的依赖：

- 目录 `<AppPaths.applicationSupportDirectory>/clipboard-data/<13 位毫秒>/`，每组一个 `data`，**每行一条 JSON 记录**，组满 100 条换组；图片按 md5 存组内 `<hash>.png`，记录里 `imagePath` 存组内文件名。
- 内存持有最近 1000 条（`records`，新→旧），启动时 `loadRecent()` 只读最近 11 组的 `data`，反向解析并按 hash 去重。
- `append(record)`：相邻 hash 判重 → 追加到当前组（必要时换组）→ 插入内存头部 → 超过 1000 条淘汰最老组（连同组内图片）→ 通知观察者（推送用）。
- `search(query, type, limit)`：内存过滤，语义对齐 uTools：空查询返回最近记录；含空格时按 uTools 的多词匹配处理；`type` 过滤 `text/image/files`；出结果前 `slice(limit)`。
- `remove(ids)` / `clearAll()`：重写相关组文件（uTools 同款做法），图片一并删除。
- 与现状一致的安全边界保留：图片 ≤16MB 且 ≤6400 万像素、`pngData` 校验不变；**新增文本上限 200KB**（超限不收录，避免 1000 条文本撑爆内存），加一行注释说明取值理由。

### 3.2 迁移旧数据（一次性）

首次启动检测 `<PluginData>/com.padding.leap.clipboard/db/*.json`：按 `timestamp` 升序导入新结构（图片从旧 `ClipboardHistory/<id>/<hash>.png` 复制到新组目录），写入 `meta` 标记；旧目录**保留不删**，失败则下次重试。

### 3.3 插件只负责展示

- 宿主 API 新增：`leap.clipboard.history({limit})`、`leap.clipboard.search(query, {type, limit})`、`leap.clipboard.remove(ids)`、`leap.clipboard.clear()`、`leap.clipboard.onAppend(cb)`；粘贴继续用现有 `hideMainWindowPaste*`。
- `Resources/Leap/OfficialPlugins/Clipboard/main.js` 改为：进入时 `records = await leap.clipboard.history({limit: 1000})` 装进内存 → `leap.clipboard.onAppend(record => { records.unshift(record); refresh() })` → 输入变化只在内存里过滤 → `setList(前 100 条)`（bootstrap 现有上限就是 100）→ `onSelect` 直接命中内存记录，不再 `leap.db.get`。
- 索引型 `leap.db` 不再被剪贴板使用；`PluginDocumentStore` 与 `leap.db` 保持原样，其他插件不受影响。

### 3.4 推送通道（唯一需要动 SDK 的地方）

- `bootstrap.cjs` 已支持 `{type: "event", method, params}` 的主机→插件通道，新增一个 `method: "notify"`：`params.name` + `params.payload` 分发给 `leap.onHostEvent(name, cb)` 注册的处理器（与现有 `handlers` 同款单处理器约束）。
- 宿主侧 `PluginScriptSession` 增加 `notify(_ name:payload:)`，`ClipboardHistoryStore` 的观察者 → `PluginInteractionSession` → 推 `clipboard.append`。
- 旧插件不注册处理器即无影响。

### 3.5 打开路径：会话保活 + 列表复用（对齐 uTools 的 180s TTL）

- 新增 `Sources/Leap/PluginSessionPool.swift`：`borrow/recycle/evictExpired/prewarm`，TTL 180s（= uTools `pluginOutTimer` 默认值）。
- `PluginInteractionSession` 拆出 `suspend()`（停输入等待，保留进程与列表快照），`close()` 才杀进程；`LauncherModel.activate` 走池，`exitInteraction()` 回收，`prepareForPresentation()`（用户要主窗口）立即释放。
- `PluginListSession` 增加 `initialSnapshot`：命中池时立刻发布上次列表（`isLoading = false`），回包后替换 —— 对应 uTools「先渲染空/旧列表再填充」。

### 3.6 刻意不做（点名）

- **不迁移 SQLite/FTS5**：uTools 也没用数据库；数据搬回宿主后插件不再读盘、宿主侧只是内存过滤，FTS 的收益场景（几千条 + 查询下沉）在这套结构里不存在。迁移还会牵动 `PluginDocumentStore` 全体调用方。
- **不做记录加密**：uTools 用 `A()` 加密 `data` 行，但图片本来就是明文文件，Leap 现状同样明文；加密要引入密钥管理与迁移，收益不足以进本轮。
- **不做** uTools 的收藏、悬浮中转、合并复制、MCP 工具等附加功能。

## 4. Steps

1. `ClipboardHistoryStore`：分组读写、去重、1000 条淘汰、搜索、删除/清空 + 单测。
2. 旧数据迁移（`db/*.json` + `ClipboardHistory/`）与标记。
3. `ClipboardHistoryMonitor` 改用新 store（拷贝路径不再 `allDocs`，JSON 不再写两份）。
4. 宿主 API `leap.clipboard.*` + `bootstrap.cjs`/`host-api.js` 的 `notify`/`onHostEvent` + `PluginScriptSession.notify`。
5. 剪贴板 `main.js` 重写为内存列表 + 推送追加 + 内存过滤。
6. `PluginSessionPool` + `PluginInteractionSession.suspend()` + `PluginListSession.initialSnapshot` + `LauncherModel` 接入。
7. 补测试与基准（见 6）。

## 5. 风险与兼容

- `remove/clear` 需要整组重写（uTools 同款），组内 100 条，成本可忽略但要避免并发写：写操作统一在 `ClipboardHistoryStore` 内串行。
- 文本 200KB 上限会改变「超长文本也能进历史」的现状，需要你确认可接受（超限仅跳过记录，不影响粘贴）。
- 图片路径约定从 `ClipboardHistory/<id>/<hash>.png` 变为 `clipboard-data/<ts>/<hash>.png`，旧记录靠迁移转换；迁移失败的旧记录要能继续读（插件按 `imagePath` 是否含 `/` 判断新旧）。
- 推送通道改 wire protocol：只新增 `notify` 方法与 `onHostEvent`，旧插件无感；但 SDK 与宿主必须同版本发布。
- 会话保活常驻约 40MB，180s 后释放；`prepareForPresentation` 立刻回收。
- 插件内存持 1000 条记录（文本为主，图片只存路径），列表只渲染前 100 条。

## 6. Verification

- `xcodebuild test -workspace Leap.xcworkspace -scheme Leap -destination 'platform=macOS' -only-testing:LeapTests`
- 新增 `ClipboardHistoryStoreTests`：100 条换组、1000 条淘汰最老组并删图片、相邻/历史 hash 去重、搜索语义（空查询/多词/类型过滤）、删除重写组文件、旧结构迁移后条数与图片可读。
- `ClipboardHistoryMonitorTests` 更新为新存储；`Tests/ClipboardPlugin/history.test.js` 改为内存过滤语义。
- `PluginPerformanceTests`：`history()` 1000 条 p95 < 20ms；复用会话 `enter` p95 < 200ms。
- 手工：冷启动 → 第一次打开剪贴板，`log show --predicate 'subsystem BEGINSWITH "com.padding.leap"' --info --debug --style compact` 对比 enter → 首帧，目标 <200ms；复制 5 次后列表即时出现（无需重开）；主线程无 30ms 以上卡顿。
- `swiftlint`

## 7. 执行结果（实测）

- 全量测试：`-only-testing:LeapTests` 152 tests / 27 suites 通过，`swiftlint` 改动文件无 error。
- 迁移：真实旧数据 157 条 → `clipboard-data/1794281925777`（100 行 + 6 图）、`clipboard-data/1794536252202`（57 行 + 2 图），旧 `ClipboardHistory/` 保留。
- 预热：Leap 启动后 1.2s 拉起插件 Node 进程（日志 `plugin-session : 已启动插件会话进程`）。
- 首次打开：`enter → 首个 clipboardHistory 返回` **87ms**（改造前 2029ms + 30ms ≈ 2.15s）；第 2、3 次打开无新建进程、无宿主调用。
- 独立审核（deepseek-reviewer）三轮：首轮 7 项、次轮 2 项全部修复；末轮仅剩一处有界资源泄漏，已按建议在 `recycle` 覆盖前关闭旧 entry。
