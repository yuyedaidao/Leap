# Leap 代码规范

## 构建与验证

工程由 Tuist 生成（`Leap.xcodeproj` / `Leap.xcworkspace` 不入库，改动 `Project.swift` 后需 `tuist generate`）。

- 构建：`xcodebuild build -workspace Leap.xcworkspace -scheme Leap -destination 'platform=macOS'`
- 测试：`xcodebuild test -workspace Leap.xcworkspace -scheme Leap -destination 'platform=macOS'`（可用 `-only-testing:LeapTests` 只跑单测）
- 风格检查：`swiftlint`

## Swift LSP

`sourcekit-lsp` 通过 `xcode-build-server` 获取编译参数，本机已安装并配置好。`buildServer.json` 与 `.compile` 是本地生成文件，不入库。

两侧诊断冲突时以 `xcodebuild` 为准。新增 target、改动依赖或清空 DerivedData 后重新生成：

```bash
# 仅在 buildServer.json 缺失时执行；它记录 DerivedData 路径，与编译参数无关
xcode-build-server config -workspace Leap.xcworkspace -scheme Leap
touch Sources/LeapCore/AppPaths.swift   # 强制重编，让 xcodebuild 打印 swiftc 命令行
xcodebuild build -workspace Leap.xcworkspace -scheme Leap-Workspace -destination 'platform=macOS' 2>&1 \
  | xcode-build-server parse -a -o .compile
```

## SwiftUI 与职责边界

- 优先使用 SwiftUI 原生能力构建界面；仅在 macOS 系统集成确有需要时使用 AppKit。
- `View` 只负责界面展示与用户交互；状态协调、业务规则和副作用放在独立类型中。
- 一个类型只解决一类问题，保持单一职责。

## 实现原则

- 优先可读性和直接的实现，不为未来假设进行过度抽象。
- 相同逻辑出现两处时，再评估是否提取公共组件或工具。
- 保持命名、缩进和空格一致；公开接口与边界输入必须具备必要的错误处理。

## 注释

- 为非显而易见的意图、约束、系统行为和取舍添加简洁中文注释。
- 不重复代码本身已经清楚表达的内容；注释应解释“为什么”，而非逐字描述“做什么”。
