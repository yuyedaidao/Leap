## Purpose

为 Leap 提供可从启动器和应用菜单访问的原生设置中心，让用户安全管理常驻行为、受管插件和仅保存在本机的数据，而不引入账号或云端依赖。

## ADDED Requirements

### Requirement: 原生设置入口
Leap SHALL 提供独立的 macOS 设置窗口，启动器齿轮和应用菜单 MUST 打开同一个设置窗口；该窗口 SHALL 包含通用、插件、数据与隐私、关于四页。

#### Scenario: 从启动器打开设置
- **WHEN** 用户点击启动器的设置入口
- **THEN** Leap SHALL 显示或前置独立设置窗口，而不是显示启动器内的临时 sheet

### Requirement: 启动器偏好
Leap SHALL 允许用户选择跟随系统、浅色或深色外观，并允许配置包含 Command、Option 或 Control 的全局快捷键。默认快捷键 MUST 为 Option-Command-L；新组合无法注册时 MUST 保留旧组合并显示错误。登录时启动默认 MUST 为关闭。

#### Scenario: 注册冲突的快捷键
- **WHEN** 用户提交无法注册的全局快捷键
- **THEN** Leap SHALL 保持此前生效的快捷键并显示可读错误

#### Scenario: 系统要求批准登录项
- **WHEN** 用户开启登录时启动且系统要求额外批准
- **THEN** Leap SHALL 显示当前状态并提供前往系统登录项设置的入口

### Requirement: 受管插件生命周期
Leap SHALL 显示仍受信任的已安装插件，并允许用户安装或更新本地插件。卸载 MUST 经二次确认后删除受管副本与信任记录，并立即令其不再参与搜索或最近使用。

#### Scenario: 卸载已安装插件
- **WHEN** 用户确认卸载一个受信任插件
- **THEN** Leap SHALL 永久删除该插件的受管副本和信任记录，并刷新启动器索引

### Requirement: 本地数据维护
Leap SHALL 允许用户确认后清除应用和插件的最近使用记录，并允许手动删除缓存后重建系统应用索引。页面 MUST 说明 Leap 宿主不收集遥测、不提供账号或云同步。

#### Scenario: 清除最近使用
- **WHEN** 用户确认清除最近使用记录
- **THEN** Leap SHALL 移除所有本地最近记录且不删除插件或其他偏好

### Requirement: 应用信息
Leap SHALL 显示应用版本和构建号；Bundle 未提供该信息时 MUST 显示开发构建。设置页 MUST NOT 提供远程检查、下载或自动安装更新。

#### Scenario: 开发构建信息
- **WHEN** 应用 Bundle 缺少版本或构建号
- **THEN** Leap SHALL 显示开发构建而非空白或错误值
