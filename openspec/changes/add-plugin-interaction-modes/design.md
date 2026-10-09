## Context

见 proposal.md。现有命令由 runtime/webEntry 隐式决定进入行为；JSON-RPC 每次启动独立进程，result 为字符串；旧网页使用独立窗口。

## Goals / Non-Goals

**Goals:** 清单决定 Enter 行为，列表与网页共用启动器会话，旧插件兼容。

**Non-Goals:** 常驻运行时、流式结果、系统 UI 自动化、图片/文件匹配、窗口分离。

## Decisions

- commands 增加 mode(action/interactive)、presentation(list/web)、keywords、input(enabled/placeholder)、matches(type=text/regex、pattern、minLength/maxLength)。关键词匹配优先，内容匹配保留原输入，关键词进入清空参数。
- 新清单声明 minimumHostVersion=1.1.0，应用版本同步；缺省 mode 使用旧分派，不把 webEntry 推断改为新模式。显式 action 忽略共享 webEntry。
- list 强制启用参数输入，interactive 禁止 shell/background；action 禁止 presentation/input。最低版本及正则在安装时校验。
- 继续用字符串 result，新增 leap.query(params.commandID/query) 返回 JSON 字符串 {items:[{id,title,description?}]}；leap.select 增加 itemID，返回字符串反馈。结果最多100项，标识非空唯一。
- 列表会话独立于 View，200ms 防抖，最新输入版本号隔离旧响应，取消令牌终止过期进程；执行选择时禁止重复动作。中文组合输入结束才提交查询。
- 网页在原主页面注入 onEnter/onInputChange/onSubmit/onExit，订阅返回移除监听函数；进入上下文含 commandID/query，迟订阅能取得初始上下文。宿主按输入版本发送事件，输入为只读的宿主状态。
- 内嵌网页宽度跟随800点宿主，内容高度由webWindow.height减宿主操作栏约束并按屏幕裁剪；旧webWindow规则仍用于独立窗口。
- 失焦隐藏前结束会话；sheet期间不隐藏。返回/Escape清理会话与授权并恢复搜索，重新快捷键唤起默认全局搜索。不以关闭视图承诺业务回滚。
- 示例使用文本转换列表，不使用eval计算器；生成器可生成直接动作/列表/网页三种方式，缺省兼容现有withUI参数。

## Risks / Trade-offs

- [进程启动成本] → 防抖、过期取消和有界结果，测量响应时间后再考虑常驻进程。
- [第三方旧宿主忽略字段] → 文档与模板声明1.1.0最低版本；不能承诺修改旧宿主的安装器。
- [正则复杂度] → 限制匹配文本长度，预编译正则并在安装时拒绝无效模式；插件仍为受信任代码。
- [网页焦点/目录sheet] → 在实际挂载面板处理Escape与sheet失焦，并以真实UI测试验证。

## Migration Plan

旧插件不改；模板生成器自身迁移为interactive/web。新模板明确mode及最低版本。失败时返回全局搜索，源目录与用户数据不迁移。回滚可使用旧清单恢复旧行为，但新交互插件不能在旧宿主完整运行。
