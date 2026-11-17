# 剪切板插件打开仍要 2-3s：根因复核与修复

> 状态：待批准。前序计划 `plans/clipboard-open-latency.md` 的宿主侧改造（数据持久化、推送更新、会话复用池）已随 0.0.9 发布；本计划解决剩下的一件事：**进程模型从「每会话一个 node 进程」换成「共享 node daemon」**。

## 0. 先对齐一下「慢在哪」

反馈里的理解是「宿主用观察者监听粘贴板 → 存起来 → 打开插件直接读数据」，这个链路**已经全部实现并且不慢**，需要澄清两点：

**（a）NSPasteboard 没有变更通知。** 传言的 `NSPasteboard.didChangeNotification` 在 SDK 里不存在 —— `NSPasteboard.h` 只有 `changeCount`（`.../AppKit.framework/Headers/NSPasteboard.h:165`），`grep NSPasteboardDidChange` 无匹配。macOS 从未提供粘贴板变更通知，轮询 `changeCount` 是唯一可靠手段；现有 `ClipboardHistoryMonitor.start()` 的 0.5s Timer（`ClipboardHistoryMonitor.swift:26-34`）就是标准做法（uTools 同样轮询）。

**（b）读数据确实不慢，慢的是画列表之前的 node 启动。**

| 环节 | 现状 | 耗时 |
| 监听粘贴板变化 | `ClipboardHistoryMonitor` 0.5s 轮询 `changeCount` | 可忽略 |
| 存起来 | 新记录立即 `store.append()` 写入内存 `records` 头部 | 可忽略 |
| 宿主读数据 | `PluginHostAPI.swift:257` 直接 `return .array(clipboardHistory.records.map(\.pluginValue))` | 可忽略（内存数组） |
| **画出来** | `presentation: .list` 的列表**由 JS 插件用 `leap.setList()` 推给宿主**（`PluginManifest.swift:26`、`Resources/Leap/OfficialPlugins/Clipboard/main.js:68`） | **2.5s** |

也就是说宿主手里有全部数据也没用：列表项是插件的产物，必须先把 node 跑起来、执行 `main.js`、让它把 `records` 映射成 `PluginListItem` 推回来，宿主才能渲染。这 2.5s 花在「启动一个 115.8MB 的 node 进程执行一段 JS」，不花在数据上。

**所有 JS 插件都一样**（所以本计划修的是进程模型，不只是剪贴板）：`PluginScriptExecutor.makeSession`（`PluginScriptExecutor.swift:57-70`）每建一个会话就 `spawn` 一次 `Runtimes/node-24.21.0/bin/node bootstrap.cjs <插件入口>`，会话之间不共享进程。你装的 4 个第三方插件里 3 个是 `javascript`（`FormatString.run`、`shell-runner.run`、`shutdown.run`），首次打开或池超时后打开都要等这 2 秒。Python 插件同理但轻一些（`python3.14 -c 0` 冷启 1.61s）；Shell 插件不受影响（`/bin/zsh` 系统已缓存）。

## 0.5 为什么现在的池救不了它

- `Sources/Leap/PluginSessionPool.swift:48`：`lifetime` 默认 180s（与 uTools `pluginOutTimer` 默认 3 分钟一致）。
- `Sources/Leap/PluginSessionPool.swift:118-122` `evict`：到点直接 `script.close()`，**没有任何重新预热**。
- `Sources/Leap/LauncherModel.swift:700-711` `prewarmClipboardSession()`：只在 `reloadPlugins()`（`LauncherModel.swift:199`）时触发，等价于「App 启动后 1s 预热一次」，整个进程生命周期仅此一次。

所以真实行为是：启动 1s 预热好 → 180s 后被 kill → 之后每次打开都是冷启动 → 每次 2.5s。实测你正在跑的 Leap（PID 1053，已跑 1:58）里 `pgrep -P 1053` 一个 node 子进程都没有，正是这个状态。数据量只有 3 个组 / 约 1MB，读盘不是瓶颈。

只要「回收一次 = 再付一次 2.5s」这个等式不打破，调 TTL 只是把 2.5s 往后推。**spawn 这个进程本身才是要改的东西。**

## 0.6 uTools 7.8.0 的对照（REA 实测，仅供参考）

uTools 不是 Electron 之外另有巧思，而是它从来不给插件开进程：插件跑在 `BrowserView` 里（`assemblyPlugin` → `runningPluginPool[name].view`），「退出」默认只 `setBrowserView(null)`，只有 `pluginIsOutKill` 为真才 `webContents.destroy()`（outKill 默认关，`outkillplugin` doc `data: []`）。缺点是需要拉起整个 Electron（主进程 176MB + GPU 58MB + utility 41MB + 2 个 Renderer 87/71MB）。

Leap 不需要换宿主层，也能拿到同样的效果：**一个常驻 node daemon 里用 `Worker` 装所有插件**。

## 1. 先回答「不校验签名是不是就快了」

是，但**不可行**。

实测（本机 /tmp 下对同一份 `/Applications/Leap.app/Contents/Resources/Runtimes/node-24.21.0/bin/node` 反复验证）：

| 操作 | real |
| 冷状态执行签名后的 node | 2.14s / 2.48s / 2.63s（重复复现） |
| 同文件第二次、第三次 | 0.02–0.03s |
| `cp` 一份新副本后首次执行 | 2.5s 级别（每次新 inode 都付一次） |
| `codesign --remove-signature` 后首次执行 | 0.00s（但进程被内核 `SIGKILL`，exit=137；无签名在 Apple Silicon 上本来就跑不起来） |
| `/bin/echo`（99KB，有签名）新副本首次执行 | 0.00s |

结论：这 2 秒是 **115.8MB 大二进制首次被加载 + 校验**的固定开销，去掉签名进程直接被杀，方案不存在。daemon 方案正好把它变成「每次 App 生命周期只付一次」。

## 2. 方案：共享 node daemon + 每插件一个 Worker

### 2.1 结构

```
Leap.app
 ├─ NSHost 进程（SwiftUI）
 │   └─ PluginDaemon（新增，一个）── stdin/stdout ──┐
 └────────────────────────────────────────────────┐│
                                                   ▼│
                                    node daemon.cjs（常驻，一个进程）
                                     ├─ Worker ← bootstrap.cjs + clipboard/main.js
                                     ├─ Worker ← bootstrap.cjs + FormatString/main.js
                                     └─ Worker ← bootstrap.cjs + ...
```

- **daemon 进程全程常驻**：App 启动预热时拉起，一直到 App 退出。那 2.5s 只付一次（而且是启动预热时付，用户看不见）。
- **每个插件会话 = 一个 `Worker`**：不需要在同一个 JS 全局里跑多个插件，`worker_threads` 天然给出独立模块缓存、独立全局、独立事件循环。
- **`bootstrap.cjs` 一行不改**：Worker 里由一个新写的 shim 造出 `process.stdin`（`defineProperty` 换成 `PassThrough`）+ 接管 `process.stdout.write` 转发到 `parentPort`，然后 `require('bootstrap.cjs')`。**插件代码完全不用改，现有插件零迁移**。

### 2.2 原型已验证（不是设计推演）

我已经在 `/tmp/dproto` 用真实文件（未改动的 `bootstrap.cjs`、`host-api.js`、`OfficialPlugins/Clipboard/main.js`）跑通了端到端：

| 验证项 | 结果 |
|---|---|
| shim 里替换 `process.stdin` | `stdinIsFake=true`，写入 `{"a":1}\n` 后 Worker 正常 `RECV:` |
| 接管 `process.stdout.write` | 正常，帧不落到真 stdout（不污染 daemon 协议） |
| 原样 `require` 未改的 bootstrap.cjs | 正常 `ready` |
| 真实 Clipboard 插件在 Worker 里 | `ready` 45ms；`input` 事件后正确回 `{"items":[],"title":"剪切板历史"}` |
| 同时两个会话 | 分别在 45ms / 137ms ready，互不干扰 |
| Worker 内 `process.exit()` | 只结束该 Worker，daemon 存活 |
| Worker 内 `process.abort()` | 报 `ERR_WORKER_UNSUPPORTED_OPERATION`，daemon 存活（不会带崩宿主） |
| Worker 内 `process.chdir()` | 不支持（`ERR_WORKER_UNSUPPORTED_OPERATION`）；`Object.defineProperty(process,'cwd',...)` 可生效 |
| daemon 基线 RSS | 43MB；加载 1 个 Worker 后 59MB（当前单个 node 会话实测 47MB，同量级） |

启动成本实测：1 个 Worker `online` 14ms、5 个 37ms、8 个 21ms。**也就是说 evict 一次之后再拉起只要 ~15ms，不再是 2.5s。** 池的 180s TTL 原样保留都没关系。

### 2.3 Swift 侧改动（尽量贴住现有结构）

不新写一个会话类。`PluginProcessSession` 现有状态机（`pending`、`hostTasks`、超时/取消/loading 与 `receive(message)` 分派）全部复用，只把**传输层**变成可切换：

```swift
// PluginProcessSession.swift
enum Transport {
    case process                 // 现状：自己持有 Process + 三个 Pipe
    case daemon(PluginDaemon, sessionID: String)
}
```

只有 4 个分支点要改，其余一行不动：

| 位置 | 现在 | daemon 模式 |
|---|---|---|
| `startIfNeeded()`（`:188`） | 建 Pipe、`process.run()` | 向 daemon 发 `{op:"spawn", session, entry}`，等 `<session>/ready` 帧 |
| `send(_:)`（`:244`） | 写自己的 `input` Pipe | `daemon.write(sessionID, message)` |
| `receive(_ data:)`（`:257`） | 切自己 Pipe 的帧 | 不用；daemon 分发器已经解析好，直接调 `receive(message)` |
| `finishClose()`（`:382`） | `terminate()` + 250ms 后 `SIGKILL` | `daemon.close(sessionID)`（daemon 给 Worker 发 `exit` 事件，宽限后 `worker.terminate()`） |
| `processIdentifier`（`:165`） | 自己的 pid | 返回 daemon 的 pid（现有测试断言「同一会话 pid 不变」，仍然成立） |

新增一个 `PluginDaemon`（`Sources/LeapCore/PluginDaemon.swift`）：拥有那一个 `Process`、一个帧循环、一个 `[sessionID: PluginProcessSession]` 注册表；负责 `spawn`/`write`/`close`/崩溃后重启。`PluginScriptExecutor.makeSession` 里按 `manifest.runtime` 选 transport：`.javascript` → daemon，`.python`/`.shell` → 现有 process 路径（Python 跑不进 `worker_threads`，不在本次范围）。

`PluginSessionPool` / `PluginInteractionSession` / `LauncherModel` / `PluginScriptSession` **都不用动**（`PluginScriptSession` 只依赖 `PluginProcessSession` 的方法）。

### 2.4 协议与隔离要点

- **会话分帧**：daemon 的 stdin/stdout 仍是「一行一个 JSON」，每条加 `session` 字段。Worker → daemon 的帧由 shim 加上 `session` 再 `postMessage`；daemon → Worker 的帧先去掉 `session` 再投给对应 Worker。
- **id 必须按会话命名空间**：现有 `request` 的 id 是 `sessionID + "/" + UUID()`（天然唯一），但**插件发起宿主调用的 id 是 `host-<n>`（`bootstrap.cjs:53`），跨 Worker 会撞**。daemon 在出口把 `host-N` 改写成 `<session>/host-N`，回程再改回。`ready` 帧（id 字面量 `"ready"`）同理改成 `<session>/ready`。
- **24MB 帧上限、超时、取消、hostCancel 全部沿用**：它们都在 `bootstrap.cjs` / `PluginProcessSession` 里，daemon 只做搬运，不碰语义。

### 2.5 失败与降级

- Worker 抛未捕获异常或被 `process.exit` → daemon 发 `{session, type:"fatal"}`；对应 `PluginProcessSession` 走现有 `fail()`，**同时**把这个 entry 从池里摘掉（顺手修掉一个现存缺陷：池里会留下已死的会话）。
- Worker 在 `ready` 之前就因为 shim 级原因失败 → 该插件**降级回现有 per-process 路径**跑一次（每次启动只试一次，不循环），保证第三方插件不会被新机制卡死。
- daemon 进程意外退出 → 所有会话按 `fail()` 收尾；下一次按需重启 daemon 并懒拉起 Worker。

### 2.6 明确不做

- 不把插件宿主换成 Electron/WebView 共享渲染进程。
- 不让 Python 插件进 daemon（`worker_threads` 只跑 JS；Python 冷启 1.61s 仍在，另立项）。
- 不改 `bootstrap.cjs` / `host-api.js` / `bootstrap.py` 的协议语义；不改 `clipboard-data` 存储与推送。
- 不改池的 TTL 策略（daemon 让 evict 变得便宜，不需要靠延长 TTL 兜）。
- 不缩小 node 二进制（`--with-intl=small-icu`、裁掉 64MB `include` 等），收益与风险另议。

## 3. 涉及文件

新增：

- `Resources/Leap/PluginSDK/daemon.cjs` —— daemon 主循环：会话表、`spawn`/`write`/`close`、Worker 生命周期、帧路由与 id 命名空间。
- `Resources/Leap/PluginSDK/worker-shim.cjs` —— Worker 内伪造 `process.stdin` / 接管 `process.stdout.write` / 修 `process.cwd`，然后 `require(resolve(__dirname,'bootstrap.cjs'))`。
- `Sources/LeapCore/PluginDaemon.swift` —— 单例传输层：启停、写帧、读帧分发、崩溃重启。
- `Tests/LeapTests/PluginDaemonTests.swift`。

修改：

- `Sources/LeapCore/PluginProcessSession.swift` —— 加 `Transport` 枚举与上表 4+1 个分支点。
- `Sources/LeapCore/PluginScriptExecutor.swift` —— `makeSession` 按 runtime 选 transport；`.javascript` 走 daemon。
- `Sources/Leap/LauncherModel.swift` —— 启动预热提前到 `ensureDaemonStarted()` + 现有 `prewarmClipboardSession()` 保留（现在预热的是 Worker，15ms）。
- `Sources/Leap/AppDelegate.swift:127` —— 退出时除 `PluginProcessSession.terminateAll()` 外关掉 daemon。
- `Project.swift` 无需改（`Resources/Leap/PluginSDK` 已是 folder reference，新文件自动进包）。

## 4. 复用

- `PluginProcessSession` 的整台状态机（超时、取消、hostCall 双向、loading、`refreshDeadline`）—— 一行不重写。
- `PluginScriptSession` / `PluginSessionPool` / `PluginInteractionSession` —— 完全不动。
- `prewarmClipboardSession()`（`LauncherModel.swift:700`）—— 预热入口保留，只是现在预热的是 Worker。
- `Resources/Leap/PluginSDK/bootstrap.cjs`（226 行）—— 原样复用，不改一行。
- 现有 `Tests/LeapTests/PluginInteractionProcessTests.swift` —— 继续覆盖 per-process 路径（Python/Shell 仍用），不改。

## 5. 步骤

- [x] 写 `worker-shim.cjs`：`defineProperty(process,'stdin',{value:new PassThrough()})`；覆盖 `process.stdout.write` 转发 `parentPort`；`parentPort.on('message')` 写入假 stdin；`Object.defineProperty(process,'cwd',{value:()=>pluginDir})`；末尾 `require(resolve(__dirname,'bootstrap.cjs'))`（入口走 `process.argv[2]`，与现在一致）。
- [x] 写 `daemon.cjs`：stdin 按行解析 `{op}`；`spawn` 建 Worker（`argv:[entry]`）、`write` 投帧、`close` 发 `exit` 事件后宽限 `worker.terminate()`；Worker 出帧加 `session` 并改写 `host-N`/`ready` 的 id；`error`/`exit` 上报 `fatal`。
- [x] 写 `PluginDaemon.swift`：`start()`（spawn `node daemon.cjs`，stdin/stdout 分帧读写）、`spawn(session:entry:directory:)`、`write(_:session:)`、`close(session:)`、`[String: PluginProcessSession]` 注册表、退出码非 0 时清理并按需重启；`terminateAll()` 对齐现有静态 registry。
- [x] 改 `PluginProcessSession`：加 `Transport`，按 2.3 表格改 5 处；`init(executable:arguments:directory:hostCall:onHostReply:hostWaitTimeout:)` 之外增加 daemon 初始化入口，不动现有初始化。
- [x] 改 `PluginScriptExecutor.makeSession`：`.javascript` 走 daemon。
- [x] 接 `PluginSessionPool` 的失败回池：会话 `fatal` 时报给池，池删除对应 entry（顺手修 2.5 提到的死会话残留）。
- [x] 降级路径：Worker 在 `ready` 前失败 → 该插件本次改走 per-process，并在 `logger.notice` 记一条，方便后续定位。
- [x] 单测 `PluginDaemonTests`：
  - 两个 JS 会话共存于同一 daemon（断言 `processIdentifier` 相同、两边都能 `enter`/`input`）；
  - 一个会话里 `process.exit(0)`，另一个会话后续请求仍正常（隔离）；
  - 两个会话同时发起宿主调用，`host-N` 不串台；
  - 会话 `close()` 后 daemon 仍存活，再 `spawn` 能立刻拿到新会话（断言耗时在毫秒量级，不设严格上限）；
  - 未改动的 `bootstrap.cjs` 在 Worker 里可正常 `ready`。
- [x] 手工验证：App 启动后等 5 分钟再打开剪切板；`pgrep -P <leap-pid>` 应始终只有一个 node（daemon），且打开后列表立即出现。

## 6. 验证

```bash
xcodebuild build -workspace Leap.xcworkspace -scheme Leap -destination 'platform=macOS'
xcodebuild test -workspace Leap.xcworkspace -scheme Leap -destination 'platform=macOS' -only-testing:LeapTests
swiftlint
```

手工：

1. 冷启动 Leap → 立刻打开剪切板（预热可能未完成，允许一次慢）；再退出插件，隔 5 分钟再打开 → 应 ~15ms 内出列表。
2. `pgrep -P $(pgrep -x Leap) -l` → 只有 1 个 node（daemon）。
3. 打开 js-formatter（`presentation: web`）与 FormatString（`presentation: list`），确认都正常工作。
4. 打开一个 Python 插件（TemplateGenerator），确认仍走原路径、行为不变。
5. 活动监视器看 daemon 内存：空载 ~43MB，每多一个活跃插件 +~16MB。

## 7. 风险与已知限制

- **daemon 是单点**：它崩了整个 JS 插件层一起失败，靠「重启 + 懒拉起」恢复。这是集中式模型的固有代价。
- **同进程内 CPU 抢占**：一个插件里跑死循环会拖慢其它插件的响应（Worker 是同级线程，`resourceLimits` 只能限内存，不限 CPU）。
- **`process.chdir` 不可用**：Worker 里不支持，shim 用 Patched `process.cwd` 兜住「插件想知道自己在哪」。若有第三方插件依赖真正的相对路径 `fs` 操作，会受影响 → 2.5 的降级路径保底。`shortcut: 只 patch cwd 不 patch fs，出现相对路径插件时改为在 shim 里包一层 fs`。
- **单插件崩溃的观测变了**：以前是「整个 node 进程没了」，现在是「一个 Worker 没了、daemon 还在」，日志里要能区分。
- **不要在 daemon 里跑不可信的重活**：Worker 共享同一个 V8 进程，堆隔离不等于安全隔离（插件本来就只按 App 权限跑，本次不降低也不提升隔离级别）。
