import ProjectDescription

let project = Project(
    name: "Leap",
    settings: .settings(
        base: [
            "MACOSX_DEPLOYMENT_TARGET": "26.0",
            "SWIFT_STRICT_CONCURRENCY": "complete",
            "SWIFT_VERSION": "6.0",
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
                "CFBundleShortVersionString": "1.2.0",
                "CFBundleVersion": "3",
            ]),
            sources: ["Sources/Leap/**"],
            resources: [
                .folderReference(path: "Resources/Leap/Runtimes"),
                .folderReference(path: "Resources/Leap/OfficialPlugins"),
                .folderReference(path: "Resources/Leap/PluginSDK"),
                .glob(pattern: "Resources/Leap/Assets.xcassets"),
            ],
            dependencies: [
                .target(name: "LeapCore"),
                .external(name: "YQLogger"),
            ],
            settings: .settings(base: [
                "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
            ])
        ),
        .target(
            name: "LeapTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "com.padding.leap.tests",
            infoPlist: .default,
            sources: ["Tests/LeapTests/**"],
            dependencies: [.target(name: "LeapCore")],
            settings: .settings(base: [
                "BUNDLE_LOADER": "",
                "TEST_HOST": "",
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
        ),
    ]
)
