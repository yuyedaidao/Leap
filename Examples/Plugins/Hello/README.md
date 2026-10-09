# Leap Hello 插件

这是供 Leap 安装的本地 Shell 插件。唯一命令“输出 hello”以 foreground 模式执行，在 Leap 的脚本输出界面显示 `hello`。

## 安装与使用

1. 打开 Leap 设置中的“本地插件”页面，点击“安装本地插件”。
2. 选择 `/Users/wyq/Work/Project/2026/Leap/Examples/Plugins/Hello` 目录（选择整个目录，不是 manifest.json 文件）。
3. 确认安装 Hello。
4. 回到 Leap 启动器，搜索“输出 hello”，选择该命令并执行。

Leap 会复制插件到受管目录；安装后移动源目录不影响已安装副本。修改源脚本后，需在 Leap 中重新选择此目录更新插件。

## 直接验证

```sh
/bin/zsh /Users/wyq/Work/Project/2026/Leap/Examples/Plugins/Hello/main.zsh
```

预期输出只有 `hello` 和一个换行，退出状态为 0。脚本不依赖第三方运行时，也不需要可执行权限，Leap 会直接通过 zsh 调用入口。
