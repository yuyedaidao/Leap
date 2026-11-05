# 创建 deepseek-reviewer 子代理

## Context

用户需要一个独立的代码审核子代理：用 DeepSeek V4 Pro 模型（与主会话模型隔离）审核本次任务的代码改动，基于 pi-subagents 的 agent 机制实现。

## 关键事实（已查证）

- pi-subagents 用户级 agent 路径：`~/.pi/agent/agents/**/*.md`（YAML frontmatter + 系统提示词），当前该目录不存在，需新建。
- DeepSeek 模型已在 `~/.pi/agent/models.json` 注册，frontmatter 中写 `model: deepseek/deepseek-v4-pro` 即可。
- 后台（async）子代理会加载 ambient 扩展，因此 codegraph 扩展（`~/.pi/agent/extensions/codegraph.ts`）注册的 `codegraph_*` 工具在子代理中可用；pi-rtk-optimizer 同为 ambient 扩展，会自动改写 bash 命令为 rtk 等价命令，无需在 agent 里做特殊配置。
- 前台（foreground）子代理不加载 ambient 扩展，因此该 agent 应默认 `async: true`。

## Approach

创建单个文件 `~/.pi/agent/agents/deepseek-reviewer.md`：

```yaml
---
name: deepseek-reviewer
description: 使用独立 DeepSeek 模型审核本次任务的代码改动
model: deepseek/deepseek-v4-pro
tools: read, grep, find, ls, bash, codegraph_status, codegraph_query, codegraph_explore, codegraph_node, codegraph_callers, codegraph_files
async: true
acceptanceRole: read-only
inheritProjectContext: true
---
```

- `tools`：用户指定的 5 个基础工具 + 6 个 codegraph 工具（后台子代理加载 ambient 扩展后可用；若加载失败 pi-subagents 会在启动前明确报缺失，不会静默降级）。
- `inheritProjectContext: true`：让审核员看到仓库的 `AGENTS.md`（Leap 代码规范），审核时能对照项目规则。
- bash 命令使用上，提示词中允许 `git status/diff/log` 等只读 git 命令和 `codegraph status/query/node/callers/files/explore` CLI；pi-rtk-optimizer 会自动将符合条件的命令改写为 rtk 形式，无需 agent 感知。
- 系统提示词正文：沿用用户提供的审核方法、返回格式原文，补充一段「可用工具命令」说明（git 只读命令、codegraph CLI/工具、rtk 改写透明生效）。

## Files to modify

- 新建：`~/.pi/agent/agents/deepseek-reviewer.md`

## Reuse

- 用户提供的审核提示词原文（审核方法 1–6、返回格式）原样保留，仅追加工具命令说明。

## Steps

- [x] 创建 `~/.pi/agent/agents/` 目录
- [x] 写入 `deepseek-reviewer.md`（frontmatter + 用户提示词 + 工具命令说明）
- [x] 用 `subagent({ action: "guide", ... })` 或重启会话确认 agent 被发现（也可用 `subagent` 工具列出 agent 名验证）

## Verification

- 在 pi 会话中发起一次轻量调用：`subagent({ agent: "deepseek-reviewer", task: "审核当前仓库最近一次提交的改动", cwd: 本仓库 })`，确认：
  1. agent 名可解析（不报 unknown agent）；
  2. 模型解析为 deepseek/deepseek-v4-pro；
  3. 返回格式符合「结论 / 审核范围 / 问题 / 验证缺口」结构。
