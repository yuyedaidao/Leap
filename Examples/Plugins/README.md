# Leap 插件示例

完整的创建、清单、运行协议、网页 UI、宿主桥接、安装更新与调试说明见 [插件开发指南](../../Docs/PluginDevelopment.md)。

## 选择示例

| 示例 | 类型 | 适合了解 |
| --- | --- | --- |
| [TemplateGenerator](../../Resources/Leap/OfficialPlugins/TemplateGenerator/README.md) | JavaScript + 网页 UI | 官方内置；创建七种组合及多命令模板，支持搜索匹配、输入配置、Shell 后台和默认图标 |
| [TextConvert](TextConvert/README.md) | JavaScript + 宿主列表 | 持续输入、文本内容匹配与结果选择 |
| [Hello](Hello/README.md) | Shell | 最小安装流程与前台 `hello` 输出 |
| [JavaScriptEcho](JavaScriptEcho) | JavaScript | 单次 JSON-RPC 请求与字符串响应 |
| [PythonEcho](PythonEcho) | Python | 标准输入输出上的 JSON-RPC |
| [WebEcho](WebEcho) | JavaScript + 网页 UI | `window.leap.invoke` 的最小网页调用 |
| [ShellCommands](ShellCommands) | Shell | 同一入口分派多个命令，以及前台/后台模式 |

Echo 示例用于展示协议，业务输入校验和错误处理请参考指南中的完整入口示例。

## 安装与开发

在 Leap 设置 → 本地插件 → 安装本地插件中选择示例的整个目录，而不是此 `Plugins` 父目录或某个文件。首次安装按界面确认，再到启动器搜索清单中的命令标题。

建议从 TemplateGenerator 创建自己的插件，再修改生成文件。修改源目录后需要重新安装更新受管副本；生成的插件不会自动安装。目录桥接限制不是脚本文件系统沙箱，安装前应检查脚本内容。
