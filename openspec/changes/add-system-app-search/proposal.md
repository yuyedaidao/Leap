## Why

Leap 当前只能搜索插件命令，无法承担系统应用启动器这一基础职责。为了让主搜索框覆盖用户最常见的启动场景，需要建立无需额外隐私权限、可持续更新且支持中文拼音的本地应用索引。

## What Changes

- 建立基于标准应用目录扫描和 FSEvents 监听的本地应用索引，并持久化轻量缓存以缩短冷启动等待。
- 支持按本地化名称、拼音、拼音首字母和 Bundle ID 搜索应用，并使用启动历史辅助同等级结果排序。
- 将系统应用与插件命令合并为统一搜索结果和统一最近使用记录。
- 为搜索结果和横向最近使用列表提供键盘选择与回车执行。
- 使用 NSWorkspace 启动或激活应用，成功后隐藏 Leap，失败时保留面板并展示错误。
- 保留现有插件搜索、插件执行和 200ms 热唤起目标。

## Capabilities

### New Capabilities

- `system-application-search`: 发现、索引、搜索、启动和持续更新本机标准目录中的 macOS 应用。

### Modified Capabilities

无。

## Impact

- 新增 macOS 应用索引、文件系统监听、搜索归一化和启动服务。
- 调整 LauncherModel、搜索结果视图及最近使用持久化格式。
- 使用 Foundation、CoreServices/FSEvents 和 AppKit 原生能力，不新增第三方依赖或系统隐私权限。
- 增加索引、排序、历史迁移和统一启动器交互测试。
