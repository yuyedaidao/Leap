## Purpose

提供可长期驻留的 Leap 原生启动器外壳，以验证 macOS 上全局唤起和即时可输入的搜索面板能够稳定作为后续插件平台的入口。

## ADDED Requirements

### Requirement: 全局快捷键唤起启动器
Leap SHALL 在启动后注册 `Option + Space` 作为全局快捷键，并在该快捷键触发时显示启动器搜索面板。

#### Scenario: 快捷键显示面板
- **WHEN** Leap 已在后台运行且用户按下 `Option + Space`
- **THEN** Leap SHALL 在 200ms 内显示搜索面板并将输入焦点置于搜索框

#### Scenario: 反复唤起
- **WHEN** 搜索面板已显示且用户再次按下 `Option + Space`
- **THEN** Leap SHALL 保持可用的单一搜索面板且不创建重复窗口

### Requirement: 启动器首页只呈现搜索与最近使用
Leap SHALL 提供固定 800×420 的启动器面板。查询为空时，首页 MUST 只呈现搜索栏、设置入口和最近成功执行的受管插件命令；首页 MUST NOT 呈现“市场精选”“已安装插件”或其他插件浏览分区。

#### Scenario: 没有最近使用记录
- **WHEN** Leap 没有最近成功执行的有效命令
- **THEN** Leap SHALL 隐藏整个“最近使用”区块并显示简短引导

#### Scenario: 显示最近使用记录
- **WHEN** 用户此前成功执行过仍然有效的受管插件命令
- **THEN** Leap SHALL 按最近使用顺序显示至多 8 个命令卡片

### Requirement: 已确认插件命令可搜索但不构成首页分区
Leap SHALL 从受管且与信任记录匹配的插件副本索引命令。用户输入查询时，Leap SHALL 按插件名、命令标题和命令 ID 显示匹配项；失效、篡改或未信任的副本 MUST NOT 出现在搜索或最近使用中。

#### Scenario: 搜索受管插件命令
- **WHEN** 用户输入能匹配已确认插件命令的信息
- **THEN** Leap SHALL 显示匹配命令，并允许用户执行该命令
