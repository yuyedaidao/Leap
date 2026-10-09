## Purpose

为插件开发者提供明确的命令交互声明，让用户通过统一输入框进入工具、持续提供参数并查看列表或网页结果，同时保持既有一次执行命令和旧网页插件的兼容性。

## ADDED Requirements

### Requirement: 清单决定命令行为
宿主 SHALL 按每个命令的 mode 分派 action 或 interactive，校验展示方式、参数输入、运行时与最低版本的合法组合；未声明 mode SHALL 保持旧行为。

#### Scenario: 直接动作与网页共存
- **WHEN** 含 webEntry 的插件选择显式 action 命令
- **THEN** 脚本只执行一次，不打开网页或接管输入框

#### Scenario: 非法配置
- **WHEN** Shell 声明 interactive 或 interactive 缺少 presentation
- **THEN** 安装被拒绝并给出错误

### Requirement: 插件输入会话
宿主 SHALL 在 interactive 进入后锁定命令，关键词进入清空参数，内容匹配进入保留原文本，返回恢复全局搜索。中文输入组合过程 SHALL 不触发查询。

#### Scenario: 持续输入与返回
- **WHEN** 用户进入列表插件、修改参数并按返回
- **THEN** 参数只交给当前插件，返回后恢复进入前搜索文本

### Requirement: 列表查询与选择
插件 SHALL 用 leap.query 返回字符串编码的列表结果，用 leap.select 接收明确选择的条目标识。宿主 SHALL 防抖、限制并发、忽略过期响应、显示加载/空/错误状态并防止重复选择动作。

#### Scenario: 旧请求晚到
- **WHEN** 参数连续变化且旧结果最后返回
- **THEN** 旧结果不覆盖最新列表

#### Scenario: 无效结果
- **WHEN** 列表含重复标识或超过100项
- **THEN** 显示可恢复错误，不执行条目动作

### Requirement: 内嵌网页生命周期
宿主 SHALL 将新web命令挂载在输入框下方，并提供进入、输入变化、提交与退出事件；禁用顶部参数输入的网页仍可使用自己的表单。目录授权 SHALL 属于本次网页实例。

#### Scenario: 原生目录选择
- **WHEN** 内嵌网页调用目录选择并取消
- **THEN** 面板和表单保持可用，取消不触发生成

#### Scenario: 退出释放
- **WHEN** 返回全局搜索或隐藏启动器
- **THEN** 会话停止接收输入，网页退出且目录授权不跨会话保留

### Requirement: 文本命令匹配
宿主 SHALL 支持关键词、正则文本与任意文本匹配，匹配候选不执行插件脚本，并按声明长度限制过滤文本。

#### Scenario: 内容作为初始参数
- **WHEN** 用户输入文本并选择通过内容匹配出现的命令
- **THEN** 原文本成为插件初始参数而不是被清空

### Requirement: 开发入口完整
生成器和开发文档 SHALL 覆盖action、interactive/list与interactive/web，并提供最小可运行入口及错误处理示例。

#### Scenario: 生成后安装
- **WHEN** 开发者创建列表模板并安装
- **THEN** 进入后输入参数可得到列表，选择条目得到执行反馈
