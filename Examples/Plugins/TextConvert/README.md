# 文本转换

版本：1.0.0，要求 Leap 1.1.0 或以上。

manifest.json 声明插件信息与命令；main.js 是脚本入口。Enter 进入插件后，输入文本实时得到大小写转换列表，上下键选择，Enter 执行选中项。查询 method 为 leap.query，选择为 leap.select，后者 params 增加 itemID。查询 result 是 JSON 字符串 {items:[{id,title,description}]}；选择 result 是反馈字符串。

在 Leap 设置 → 本地插件 → 安装本地插件中选择本目录并确认安装。然后在启动器搜索命令“文本转换”。

使用随包运行时，每次调用启动独立进程。标准输入发送一条 JSON-RPC 2.0 请求，params 包含 commandID/query；标准输出只返回一条同 ID 响应，result 为字符串，日志写标准错误，3秒内退出。

Escape 返回搜索，再按 Escape 收起。修改源文件后需要重新安装更新受管副本，用户数据不要放在受管目录中。
