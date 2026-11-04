// swift-tools-version: 5.10

import PackageDescription

#if TUIST
import ProjectDescription

// Xcode 27 不再支持依赖声明的 macOS 10.x 部署目标，统一与应用保持一致。
let packageSettings = PackageSettings(
    targetSettings: [
        "YQLogger": ["MACOSX_DEPLOYMENT_TARGET": "26.0"],
        "Logging": ["MACOSX_DEPLOYMENT_TARGET": "26.0"]
    ]
)
#endif

let package = Package(
    name: "Leap",
    dependencies: [
        .package(url: "https://github.com/yuyedaidao/YQLogger.git", branch: "main"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", exact: "2.10.1")
    ]
)
