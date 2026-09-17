## Purpose

验证 Leap 可以以统一协议运行受管 Python、JavaScript 与可选 Web 页面插件，并在插件失败时保持宿主应用可用。

## ADDED Requirements

### Requirement: 运行两种脚本插件
Leap SHALL 使用随应用分发的 Python 和 JavaScript 运行时启动已确认的受管插件，并将被触发的命令 ID 与后续查询文本传递给插件。

#### Scenario: 运行 Python 示例插件
- **WHEN** 用户触发一个 Python 插件声明的命令并输入查询文本
- **THEN** Leap SHALL 使用内置 Python 运行时执行该插件并显示其文本响应

#### Scenario: 运行 JavaScript 示例插件
- **WHEN** 用户触发一个 JavaScript 插件声明的命令并输入查询文本
- **THEN** Leap SHALL 使用内置 JavaScript 运行时执行该插件并显示其文本响应

### Requirement: 脚本通信使用可验证请求响应
Leap SHALL 通过 JSON-RPC 请求向插件发送命令 ID 和查询文本，并仅接受能关联到该请求的有效响应。

#### Scenario: 插件返回有效响应
- **WHEN** 插件返回与当前请求关联的有效 JSON-RPC 文本响应
- **THEN** Leap SHALL 在搜索面板中展示该响应

#### Scenario: 插件返回无效响应或失败
- **WHEN** 插件进程退出、超时或返回无效 JSON-RPC
- **THEN** Leap SHALL 显示可读错误且继续保持搜索面板与其他插件可用

### Requirement: Web 页面可调用宿主桥接
Leap SHALL 在插件声明 Web 页面时从其受管目录加载该页面，并向页面提供可调用的 `window.leap.invoke` 桥接入口。

#### Scenario: Web 页面调用插件逻辑
- **WHEN** 用户在已加载的插件 Web 页面中调用 `window.leap.invoke` 并提供命令与参数
- **THEN** Leap SHALL 将调用路由至该插件的脚本逻辑并把响应返回页面

#### Scenario: Web 页面缺失或不可加载
- **WHEN** 已安装插件声明的 Web 页面不存在或无法加载
- **THEN** Leap SHALL 显示该插件的加载错误且不影响宿主或其他插件
