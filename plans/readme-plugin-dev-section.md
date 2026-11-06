# README「开发」章节扩写：用官方 Skill 做自己的插件

## Context

README 已删掉原先的「用 AI 创建第一个插件」和「为什么用 Leap」两节，现在的「开发」只是一个三条链接的列表：

```
## 开发
- [插件开发指南](Docs/PluginDevelopment.md)
- [官方 Skill](skills/leap-plugin-development/)
- [构建与发版说明](Docs/Development.md)
```

问题：普通用户（不是仓库开发者）看完不知道「怎么用 AI 做一个插件」。需要在不重新堆砌长文的前提下，补上两件具体的事：

1. 怎么安装官方 Skill（`skills/leap-plugin-development/`）。
2. 装好之后该对 AI 说什么（可直接复制的提示词模板），以及插件做好后怎么装进 Leap。

## Approach

把「开发」拆成两层：面向普通用户的「做自己的插件」（主体），和原来那三条给贡献者的链接收尾。

- `### 安装官方 Skill`：一句说明 Skill 是什么 + `npx skills add ...` 命令 + 没装 `npx` 的替代做法（复制 `skills/leap-plugin-development/` 到所用工具的 Skills 目录）。
- `### 用 Skill 创建插件`：一段提示词模板（代码块可直接复制，方括号处让用户替换），以及做完后的安装路径（设置 → 插件 → 安装插件 → 从本地目录安装 → 信任后 `⌥⌘L` 搜索）。
- `### 参与项目`：保留原来的三条链接。

提示词模板不绑定具体插件题材，用占位符让用户填（避免再写一段具体的「午饭吃什么」示例）。

## Files to modify

- `README.md`：只改「## 开发」一节，其余章节不动。

## Reuse

- Skill 安装命令：`npx skills add https://github.com/yuyedaidao/Leap/tree/main/skills/leap-plugin-development`（原文已在 `Docs/Development.md:89` 内联，可直接引用同一条）。
- Skill 内容与用法：`skills/leap-plugin-development/SKILL.md`（它会引导 AI 按交互方式选示例、核对 `minimumHostVersion`、交付后本地安装验证）。
- 本地安装与验证：`Docs/PluginDevelopment.md:247` 「安装、更新与安全」已有完整说明（远程安装、本地目录安装、信任确认、改动后重新安装），README 直接链过去。
- `Examples/Plugins/README.md`：示例索引，README 只给链接。

## 拟写内容（README 替换「## 开发」整节）

```markdown
## 开发

### 安装官方 Skill

Leap 提供了官方 Skill `leap-plugin-development`。装进常用的 AI 编程工具（Codex、Claude Code、Cursor 等）后，AI 就能按 Leap 的插件规范写清单、脚本和网页。

```sh
npx skills add https://github.com/yuyedaidao/Leap/tree/main/skills/leap-plugin-development
```

命令默认装进当前项目，按提示选择工具；加 `--global` 后同一工具的其他项目也能用。没有 `npx` 时，把 [skills/leap-plugin-development/](skills/leap-plugin-development/) 目录复制到所用工具的 Skills 目录。

### 用 Skill 创建插件

装好后直接说想要什么，并指定用这个 Skill：

> 用 `leap-plugin-development` 帮我做一个 Leap 插件：[插件名称]。在 Leap 里搜索 [命令标题] 就能触发，[触发后做什么、结果怎么展示]。做好后告诉我插件目录的绝对路径。

例：把 Downloads 里最新的截图移动到指定文件夹，打开后在列表里显示结果。

做好的插件怎么装进 Leap，见[插件开发指南 · 安装、更新与安全](Docs/PluginDevelopment.md#安装更新与安全)。

### 更多资料

- [插件开发指南](Docs/PluginDevelopment.md)：清单字段、宿主 API、安装与调试
- [官方示例](Examples/Plugins/README.md)：可直接参考的插件目录
- [构建与发版说明](Docs/Development.md)
```

## Steps

- [x] 按上面的拟写内容替换 README「## 开发」整节：三个 `###` 小节（安装官方 Skill、用 Skill 创建插件、更多资料）。
- [x] 提示词只给 blockquote 模板（方括号占位符）+ 一行具体示例，不再写“说清三件事”之类的展开。
- [x] 「安装到 Leap」不再在 README 展开，一句链接指向 `Docs/PluginDevelopment.md` 已有的「安装、更新与安全」（L247）；不改 Docs 正文。
- [x] 细节（清单字段、API、调试、示例）只给链接，不在 README 里重复展开。
- [x] 校对锚点/链接有效，行文与上文（安装章节的 `###` 风格）一致。

## Verification

- 通读 README：普通用户能从「装 Skill → 说需求 → 装插件 → 搜索运行」一条线走通。
- 检查所有相对链接可点（`Docs/PluginDevelopment.md`、`skills/leap-plugin-development/`、`Docs/Development.md`、`Examples/Plugins/README.md`）。
- 命令可复制执行：`npx skills add ...` 与仓库内 skill 目录路径一致。
