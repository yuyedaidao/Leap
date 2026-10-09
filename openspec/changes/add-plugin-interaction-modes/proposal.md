## Why

现有启动器不能在进入插件后持续提供参数，也没有统一的插件列表界面。通过清单声明命令交互方式，让 Enter 行为确定，并使新网页插件与输入框保持在同一面板内。

## What Changes

- 命令增加 mode、presentation、keywords、input 与文本 matches；未声明 mode 保持旧行为。
- 新增防抖、过期响应隔离的列表会话及独立查询/选择协议。
- 新网页交互命令内嵌，提供进入、输入、提交和退出事件；目录桥接继续复用。
- 更新生成器、示例、开发文档及回归测试，声明最低宿主版本。

## Capabilities

### New Capabilities

- `plugin-interaction`: 清单声明、命令匹配、输入会话、标准列表、内嵌网页及兼容性。

### Modified Capabilities

无；当前没有归档到 openspec/specs 的对应规格。

## Impact

涉及 LeapCore 清单与运行协议、Leap 启动器/网页桥接、插件生成器和测试。不添加依赖，不加入逐字流式输出、常驻进程、图片/文件/窗口匹配或分离窗口功能。
