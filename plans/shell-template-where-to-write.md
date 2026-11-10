# Shell 插件模板：让用户一眼看到「在哪写自己的脚本」

## Context

用户在 JProject 插件里写 Shell 脚本时卡在最基本的问题上：模板生成的 `main.zsh` 把真正的脚本内容藏在 `case` 分支的 `printf '%s\n' 'hello'` 里，不知道自己的逻辑该写在哪里；也问过 `LEAP_COMMAND_ID` 到底是干什么的。

现状（`Resources/Leap/OfficialPlugins/TemplateGenerator/templates.js:6-16`）：

```zsh
#!/bin/zsh
set -eu
# 所有命令共用入口，未知 ID 必须失败，避免误执行业务动作。
case "${LEAP_COMMAND_ID:-}" in
  'id.a'|'id.b') printf '%s\n' 'hello' ;;
  *) printf '%s\n' '未知命令。' >&2; exit 1 ;;
esac
```

三个问题：

1. **单命令也强制写 `case`**，用户看不出 `hello` 那行才是可替换的业务代码。
2. **多命令共用同一个分支**（ID 用 `|` 拼成一条 pattern），用户没法给不同命令写不同逻辑——模板本身是误导。
3. 生成的 `README.md` 只说「按命令 ID 分派请求」，没有告诉用户改哪个文件、改哪一行。

目标：生成的 `main.zsh` 让第一次写插件的用户 10 秒内找到落笔处，同时不破坏「多命令共用一个入口」的模型。

## Approach

已与用户确认：单命令免 case、多命令逐条分支；模板生成器 + 文档 + 示例三处同步；占位输出保留 `hello`。

### 单命令：不生成 `case`

```zsh
#!/bin/zsh
set -eu

# ↓ 在这里写你的脚本；标准输出会显示在启动器里。
printf '%s\n' 'hello'
```

理由：只有一条命令时 `case` 是纯噪声，`LEAP_COMMAND_ID` 分派没有意义。首行注释直接指向落笔处。

### 多命令：一条命令一个分支，分支内标注落笔处

```zsh
#!/bin/zsh
set -eu

# 一个 case 分支对应清单里的一条命令；改下面的内容就是改这条命令的脚本。
# 命令标题从清单 manifest.json 的 commands[].title 查看。
case "${LEAP_COMMAND_ID:-}" in
  # 输出 hello
  'shell.foreground')
    # ↓ 在这里写这条命令的脚本
    printf '%s\n' 'hello'
    ;;
  # 后台运行
  'shell.background')
    # ↓ 在这里写这条命令的脚本
    printf '%s\n' 'hello'
    ;;
  *) printf '%s\n' '未知命令。' >&2; exit 1 ;;
esac
```

`command.title` 可能含换行，写进注释前压平空白（`title.replace(/[\r\n]+/g, ' ')`）；`#` 出现在注释里无害，不需要转义。

两条命令以上才生成 `case`；`${LEAP_COMMAND_ID:-}` 与未知 ID 分支保持不变（测试依赖未知 ID 退出码 1）。占位输出统一保留 `'hello'`，测试断言 `stdout === 'hello\n'` 因此无需改动。

不采用「每个命令生成一个函数再分派」的方案：`command.id` 常含 `.`（如 `com.leap.plugin.JProject.run`），不能直接做函数名，需要重命名映射，反而增加理解成本。

### 同步文档与示例

- `Docs/PluginDevelopment.md` 的 Shell 一节（`232-247`）改成同样形态，并补一句「`LEAP_COMMAND_ID` 是宿主注入的命令 ID，单命令时不需要分派」。
- `Examples/Plugins/ShellCommands/main.zsh` 作为「同入口分派多命令」的示例，改成每条命令独立分支（它的两条命令都是 `print` 中文，不涉及 `hello`）。
- 生成器自带 `README.md`（`templates.js:124` 附近）补一句「`main.zsh` 的每个 case 分支就是一条命令的脚本」。

## Files to modify

- `Resources/Leap/OfficialPlugins/TemplateGenerator/templates.js` — `scriptFor()` 的 shell 分支（`:6-16`）；`filesFor()` 里生成的 README 文案（`:118-127`）。
- `Docs/PluginDevelopment.md` — Shell 一节示例与说明。
- `Examples/Plugins/ShellCommands/main.zsh` — 示例同步。
- `Tests/PluginTemplateGenerator/generator.test.js`、`Tests/PluginTemplateGenerator/comprehensive.test.js` — 现有断言依赖 `stdout === 'hello\n'`、`unknown` 退出码 1；模板结构变化后需复核。

## Reuse

- 模板生成链路已存在：`templates.js:scriptFor()` 按 runtime 分派，`filesFor()` 组装 `manifest.json` / 入口 / README，无需新增文件或新机制。
- 测试直接 `spawnSync('/bin/zsh', ...)` 跑生成结果（`generator.test.js:32`、`comprehensive.test.js:59`），改模板后自动覆盖真实执行。

## Steps

- [x] `scriptFor()` shell 分支：`commands.length === 1` 时输出无 `case` 的简体；多命令按命令逐条生成分支，每条带标题注释与落笔处注释。
- [x] 标题写进注释前压平换行。
- [x] 生成 README 文案补充「`main.zsh` 的每个 case 分支就是一条命令的脚本」。
- [x] 同步 `Docs/PluginDevelopment.md` Shell 一节。
- [x] 同步 `Examples/Plugins/ShellCommands/main.zsh`。
- [x] 补充生成器测试：单命令生成结果不含 `case`；多命令分支各自可执行；未知 ID 仍退出 1。现有 `stdout === 'hello\n'` 断言应保持通过。

## Verification

```bash
Resources/Leap/Runtimes/node-24.21.0/bin/node --test Tests/PluginTemplateGenerator/*.test.js
```

手测：用「创建插件模板」生成单命令与多命令的 Shell 插件，安装后各跑一次，确认输出正确、未知 ID 失败；再 `zsh -n main.zsh` 校验语法。
