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

### Requirement: 启动器外壳不依赖具体功能插件
Leap SHALL 提供空搜索状态和结果容器，但在本变更中不要求实现应用搜索、剪贴板或其他实际结果来源。

#### Scenario: 无已安装插件时启动
- **WHEN** Leap 没有可运行的插件
- **THEN** 用户 SHALL 仍可通过全局快捷键打开稳定的空搜索面板
