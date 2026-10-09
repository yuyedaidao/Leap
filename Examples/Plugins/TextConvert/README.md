# 文本转换

要求 Leap 1.2.0。安装本目录后搜索“文本转换”或 convert，Enter 进入原生列表。输入文字实时得到大小写转换候选，上下键选择，Enter 返回选中结果，Escape 返回搜索。

入口直接使用宿主注入的 leap.onInputChange 和 leap.onSelect，不处理通信协议。会话内复用同一 Node.js 进程，退出即释放。修改源文件后需重新安装更新受管副本。

完整 API、异步取消和类型提示见[开发指南](../../../Docs/PluginDevelopment.md)。
