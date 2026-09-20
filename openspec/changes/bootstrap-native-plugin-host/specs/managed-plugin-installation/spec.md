## Purpose

建立可验证、可追踪的本地插件安装边界，使 Leap 只从用户确认过的受管副本加载插件，并为以后扩展插件 SDK 保留稳定的信任模型。

## ADDED Requirements

### Requirement: 本地插件清单验证
Leap SHALL 仅安装包含 `manifest.json` 的插件目录。清单 MUST 包含唯一的插件 ID、名称、版本、运行时类型、逻辑入口和至少一个命令；运行时类型 MUST 为 `python` 或 `javascript`。清单 MAY 声明图标相对路径；图标 MUST 是插件目录内的 PNG、JPEG 或 ICNS 文件。

#### Scenario: 安装有效插件
- **WHEN** 用户选择包含有效清单及对应逻辑入口的插件目录
- **THEN** Leap SHALL 展示插件名称、版本、命令和运行时类型以供确认

#### Scenario: 拒绝无效插件
- **WHEN** 用户选择缺少必填字段、使用不支持的运行时、具有重复 ID 或缺少逻辑入口的插件目录
- **THEN** Leap SHALL 拒绝安装并显示具体校验失败原因

#### Scenario: 图标不安全或不存在
- **WHEN** 插件声明的图标不是允许的目录内相对路径，或该文件不存在
- **THEN** Leap SHALL 拒绝安装并显示图标校验失败原因

### Requirement: 受管安装与信任确认
Leap SHALL 在用户确认后将插件复制到其应用支持目录，并仅从该受管副本运行插件。相同插件 ID 的版本或内容变化 MUST 再次请求用户确认。

#### Scenario: 首次安装插件
- **WHEN** 用户确认安装一个此前未信任的有效插件
- **THEN** Leap SHALL 保存受管副本和该版本的信任记录

#### Scenario: 更新已安装插件
- **WHEN** 用户安装具有相同插件 ID 但不同版本或内容的插件
- **THEN** Leap SHALL 在替换受管副本前重新展示变更后的插件信息并要求确认

#### Scenario: 从设置安装插件
- **WHEN** 用户在 Leap 设置中选择本地插件目录
- **THEN** Leap SHALL 先展示候选插件的名称、版本、运行时和命令，再按信任状态决定是否要求确认

### Requirement: 插件依赖保持自包含
Leap SHALL 不在安装或运行插件时自动执行 `pip`、`npm` 或其他依赖下载命令。

#### Scenario: 包含自带依赖的插件
- **WHEN** 用户安装包含自身脚本依赖的插件目录
- **THEN** Leap SHALL 复制该目录但不尝试修改、下载或更新其依赖
