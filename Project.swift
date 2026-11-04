import ProjectDescription

let project = Project(
    name: "Leap",
    settings: .settings(
        base: [
            "MACOSX_DEPLOYMENT_TARGET": "26.0",
            "SWIFT_STRICT_CONCURRENCY": "complete",
            "SWIFT_VERSION": "6.0"
        ]
    ),
    targets: [
        .target(
            name: "LeapCore",
            destinations: .macOS,
            product: .staticFramework,
            bundleId: "com.padding.leap.core",
            deploymentTargets: .macOS("26.0"),
            infoPlist: .default,
            sources: ["Sources/LeapCore/**"],
            dependencies: [.external(name: "YQLogger")]
        ),
        .target(
            name: "Leap",
            destinations: .macOS,
            product: .app,
            bundleId: "com.padding.leap",
            deploymentTargets: .macOS("26.0"),
            infoPlist: .extendingDefault(with: [
                "CFBundleDisplayName": "Leap",
                "CFBundleShortVersionString": "0.0.2",
                "CFBundleVersion": "2",
                "SUFeedURL": "https://github.com/yuyedaidao/Leap/releases/latest/download/appcast.xml",
                "SUPublicEDKey": "rall1vVcaEkME3Mpr8GMWjJ0teBItxcALE+u9IeymwA=",
                "SUEnableAutomaticChecks": false,
                "SUAutomaticallyUpdate": false,
                "SUAllowsAutomaticUpdates": false,
                "SUEnableSystemProfiling": false,
                "SUVerifyUpdateBeforeExtraction": true,
                "NSAppleEventsUsageDescription": "Leap 插件可在你调用时读取 Finder 目录或浏览器当前标签页。"
            ]),
            sources: ["Sources/Leap/**"],
            resources: [
                .folderReference(path: "Resources/Leap/Runtimes"),
                .folderReference(path: "Resources/Leap/OfficialPlugins"),
                .folderReference(path: "Resources/Leap/PluginSDK"),
                .glob(pattern: "Resources/Leap/Assets.xcassets")
            ],
            dependencies: [
                .target(name: "LeapCore"),
                .external(name: "YQLogger"),
                .external(name: "Sparkle")
            ],
            settings: .settings(base: [
                "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon"
            ])
        ),
        .target(
            name: "LeapTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "com.padding.leap.tests",
            infoPlist: .default,
            // 协调模型直接参与单测编译；更新器注入替身，不启动真实下载安装。
            sources: [
                "Tests/LeapTests/**", "Sources/Leap/PluginInstallationModel.swift",
                "Sources/Leap/AppUpdateController.swift"
            ],
            dependencies: [.target(name: "LeapCore"), .external(name: "Sparkle"), .external(name: "YQLogger")],
            settings: .settings(base: [
                "BUNDLE_LOADER": "",
                "TEST_HOST": ""
            ])
        ),
        .target(
            name: "LeapUITests",
            destinations: .macOS,
            product: .uiTests,
            bundleId: "com.padding.leap.uitests",
            infoPlist: .default,
            sources: ["Tests/LeapUITests/**"],
            dependencies: [.target(name: "Leap")]
        )
    ],
    // 资源由 SwiftUI 按名称读取，禁用旧版 Tuist 不兼容 Swift 6 的未使用资源包装类型。
    resourceSynthesizers: []
)
