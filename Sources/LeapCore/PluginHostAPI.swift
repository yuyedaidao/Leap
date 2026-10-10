import AppKit
import ApplicationServices
import Foundation
import ImageIO
import UniformTypeIdentifiers
import UserNotifications
import YQLogger

/// 会话提供有效性和窗口协调；系统服务不持有 View 或插件进程。
@MainActor
public final class PluginHostAPI: NSObject, UNUserNotificationCenterDelegate {
    public struct Context {
        public let pluginID: String
        public let commandIDs: Set<String>
        public let targetPID: Int32?
        public let isActive: () -> Bool
        public let setWindowHidden: (Bool) -> Void

        public init(pluginID: String, commandIDs: Set<String>, targetPID: Int32?,
                    isActive: @escaping () -> Bool, setWindowHidden: @escaping (Bool) -> Void) {
            self.pluginID = pluginID
            self.commandIDs = commandIDs
            self.targetPID = targetPID
            self.isActive = isActive
            self.setWindowHidden = setWindowHidden
        }
    }

    public static let inputMethods: Set<String> = [
        "hideMainWindowPasteText", "hideMainWindowPasteFile", "hideMainWindowPasteImage", "hideMainWindowTypeString"
    ]
    public var notificationCommand: ((String, String) -> Void)?
    private let paths: AppPaths
    private let pasteboard: NSPasteboard
    private let defaults: UserDefaults
    private let logger = YQLogger(label: "com.padding.leap/host-api")
    public private(set) var pendingCalls = 0
    private static let imageDecoder = ImageDecoder()
    private actor ImageDecoder {
        func decode(_ source: String) throws -> Data { try PluginHostAPI.imageData(source) }
    }
    private var inputInProgress = false
    var inputEnvironment = PluginInputEnvironment()

    public init(paths: AppPaths, pasteboard: NSPasteboard = .general, defaults: UserDefaults = .standard) {
        self.paths = paths
        self.pasteboard = pasteboard
        self.defaults = defaults
        super.init()
    }

    public func configureNotifications() { UNUserNotificationCenter.current().delegate = self }

    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let plugin = response.notification.request.content.userInfo["pluginID"] as? String,
              let command = response.notification.request.content.userInfo["commandID"] as? String else { return }
        await MainActor.run { self.notificationCommand?(plugin, command) }
    }

    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions { [.banner, .sound] }

    public func handle(_ method: String, params: PluginValue, context: Context) async throws -> PluginValue {
        let start = ContinuousClock.now
        pendingCalls += 1
        defer {
            pendingCalls -= 1
            logger.debug("宿主 API \(method) 完成，耗时：\(start.duration(to: .now))。")
        }
        do {
            try check(context)
            return try await execute(method, params: params, context: context)
        } catch {
            // Cocoa 错误可能带文件路径；仅记录系统错误码，业务错误本身不包含用户正文。
            let failure: any Error
            if error is CancellationError { failure = PluginSessionError.cancelled } else if
                error is PluginSessionError { failure = error } else {
                let system = error as NSError
                failure = PluginSessionError.plugin("系统操作失败（\(system.domain)，\(system.code)）。")
            }
            logger.error("宿主 API \(method) 失败：\(failure.localizedDescription)")
            throw failure
        }
    }

    private func check(_ context: Context) throws {
        try Task.checkCancellation()
        guard context.isActive() else { throw PluginSessionError.closed }
    }

    private func string(_ params: PluginValue, _ key: String) throws -> String {
        guard let value = params[key]?.string else { throw PluginSessionError.plugin("参数 \(key) 必须为字符串。") }
        return value
    }

    public nonisolated static func fileURL(_ path: String) throws -> URL {
        guard path.hasPrefix("/"), !path.contains("\0") else {
            throw PluginSessionError.plugin("请提供有效的绝对文件路径。")
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path),
            FileManager.default.isReadableFile(atPath: url.path) else {
            throw PluginSessionError.plugin("文件不存在或没有读取权限。")
        }
        return url
    }

}

extension PluginHostAPI {
    private enum Clipboard {
        case text(String), files([URL]), image(NSImage)
    }

    private func prepareClipboard(_ method: String, params: PluginValue) async throws -> Clipboard {
        if method.hasSuffix("Text") { return .text(try string(params, "text")) }
        if method.hasSuffix("File") {
            let values: [String]
            if let single = params["filePath"]?.string { values = [single] } else if
                case let .array(array) = params["filePath"], array.allSatisfy({ $0.string != nil }) {
                values = array.compactMap(\.string)
            } else { throw PluginSessionError.plugin("文件路径必须为字符串或路径数组。") }
            guard !values.isEmpty else { throw PluginSessionError.plugin("文件路径数组不能为空。") }
            return .files(try values.map(Self.fileURL))
        }
        let source = try string(params, "image")
        let decoder = Self.imageDecoder
        let worker = Task.detached { try await decoder.decode(source) }
        let data = try await PluginCancellableOperation.value(of: worker)
        try Task.checkCancellation()
        guard let image = NSImage(data: data) else { throw PluginSessionError.plugin("无法读取图片。") }
        return .image(image)
    }

    /// 解码前限制源数据及像素数，避免压缩很小但尺寸巨大的图片耗尽内存。
    private nonisolated static func imageData(_ source: String) throws -> Data {
        let maximum = 16 * 1024 * 1024
        let data: Data
        if source.hasPrefix("data:") {
            guard let comma = source.firstIndex(of: ","), source[..<comma].hasSuffix(";base64"),
                  let decoded = Data(base64Encoded: String(source[source.index(after: comma)...])),
                  !decoded.isEmpty, decoded.count <= maximum else {
                throw PluginSessionError.plugin("图片 Data URL 无效或超过 16MB。")
            }
            data = decoded
        } else {
            let url = try fileURL(source)
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0, size <= maximum else { throw PluginSessionError.plugin("图片必须为 1 字节至 16MB。") }
            data = try Data(contentsOf: url)
        }
        try Task.checkCancellation()
        guard data.count <= maximum,
              let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 64_000_000 / height,
              let image = CGImageSourceCreateImageAtIndex(imageSource, 0,
                  [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { throw PluginSessionError.plugin("图片格式无效或像素数超过 6400 万。") }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1,
            nil) else {
            throw PluginSessionError.plugin("无法转换图片。")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw PluginSessionError.plugin("无法编码图片。") }
        try Task.checkCancellation()
        return output as Data
    }

    private func write(_ contents: Clipboard) throws {
        pasteboard.clearContents()
        let succeeded: Bool
        switch contents {
        case let .text(text): succeeded = pasteboard.setString(text, forType: .string)
        case let .files(urls): succeeded = pasteboard.writeObjects(urls as [NSURL])
        case let .image(image): succeeded = pasteboard.writeObjects([image])
        }
        guard succeeded else { throw PluginSessionError.plugin("写入剪贴板失败。") }
    }

    // 分派表的独立 case 不构成组合业务分支，按 API 分组保留可读性。
    // swiftlint:disable:next cyclomatic_complexity
    private func execute(_ method: String, params: PluginValue, context: Context) async throws -> PluginValue {
        switch method {
        case "copyText", "copyFile", "copyImage":
            let clipboard = try await prepareClipboard(method, params: params)
            try check(context)
            try write(clipboard)
        case "getCopyedFiles":
            return copiedFiles()
        case let name where Self.inputMethods.contains(name):
            try await input(name, params: params, context: context)
        case "simulateKeyboardTap":
            guard case let .array(array) = params["modifiers"], array.allSatisfy({ $0.string != nil }) else {
                throw PluginSessionError.plugin("修饰键必须为字符串数组。")
            }
            let (key, flags) = try PluginKeyboard.decode(string(params, "key"), modifiers: array.compactMap(\.string))
            try PluginKeyboard.requirePermission()
            try check(context)
            try PluginKeyboard.tap(key, flags: flags)
        case "shellOpenPath", "shellTrashItem", "shellShowItemInFolder":
            try fileOperation(method, params: params, context: context)
        case "shellOpenExternal":
            let value = try string(params, "url")
            guard let url = URL(string: value), let scheme = url.scheme, !scheme.isEmpty,
                  !url.isFileURL, !["javascript", "data"].contains(scheme.lowercased()) else {
                throw PluginSessionError.plugin("请提供可由系统打开的绝对 URL；本地文件请使用 shellOpenPath。")
            }
            guard NSWorkspace.shared.open(url) else { throw PluginSessionError.plugin("系统无法打开该 URL。") }
        case "shellBeep": NSSound.beep()
        case "getNativeId":
            if let value = defaults.string(forKey: "pluginNativeID"),
                UUID(uuidString: value) != nil { return .string(value) }
            let value = UUID().uuidString
            defaults.set(value, forKey: "pluginNativeID")
            return .string(value)
        case "getAppName": return .string("Leap")
        case "getAppVersion":
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            return .string(version ?? PluginManifest.hostVersion)
        case "getPath": return .string(try path(string(params, "name")))
        case "getFileIcon": return .string(try fileIcon(string(params, "filePath")))
        case "isMacOS": return .bool(true)
        case "isDev", "isWindows", "isLinux": return .bool(false)
        case "readCurrentFolderPath", "readCurrentBrowserUrl":
            return .string(try await readTarget(method, context: context))
        case "showNotification": try await notify(params, context: context)
        case "outPlugin", "hideMainWindow": break
        default: throw PluginSessionError.plugin("未知宿主接口。")
        }
        return .bool(true)
    }

}

extension PluginHostAPI {
    private func copiedFiles() -> PluginValue {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return .array(urls.map { url in
            var directory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &directory)
            return .object(["path": .string(url.path), "name": .string(url.lastPathComponent),
                            "isFile": .bool(exists && !directory.boolValue),
                            "isDiractory": .bool(exists && directory.boolValue)])
        })
    }

    private func fileOperation(_ method: String, params: PluginValue, context: Context) throws {
        let url = try Self.fileURL(string(params, "fullPath"))
        try check(context)
        if method == "shellOpenPath" {
            guard NSWorkspace.shared.open(url) else { throw PluginSessionError.plugin("系统无法打开该路径。") }
        } else if method == "shellTrashItem" {
            guard FileManager.default.isWritableFile(atPath: url.deletingLastPathComponent().path) else {
                throw PluginSessionError.plugin("没有移动文件到废纸篓的权限。")
            }
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } else { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    public func path(_ name: String) throws -> String {
        let manager = FileManager.default
        switch name {
        case "home": return manager.homeDirectoryForCurrentUser.path
        case "userData": return paths.applicationSupportDirectory.path
        case "temp": return manager.temporaryDirectory.path
        case "exe":
            guard let executable = Bundle.main.executableURL else { throw PluginSessionError.plugin("应用可执行路径不可用。") }
            return executable.path
        case "logs": return manager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Leap").path
        default:
            let directories: [String: FileManager.SearchPathDirectory] = [
                "appData": .applicationSupportDirectory, "desktop": .desktopDirectory, "documents": .documentDirectory,
                "downloads": .downloadsDirectory, "music": .musicDirectory, "pictures": .picturesDirectory,
                "videos": .moviesDirectory
            ]
            guard let directory = directories[name], let url = manager.urls(for: directory,
                in: .userDomainMask).first else {
                throw PluginSessionError.plugin("不支持的系统路径名称。")
            }
            return url.path
        }
    }

    private func fileIcon(_ value: String) throws -> String {
        let icon: NSImage
        if value == "folder" { icon = NSWorkspace.shared.icon(for: .folder) } else if
            value.hasPrefix("."), value.count > 1, !value.contains("/") {
            icon = NSWorkspace.shared.icon(for: UTType(filenameExtension: String(value.dropFirst())) ?? .data)
        } else { icon = NSWorkspace.shared.icon(forFile: try Self.fileURL(value).path) }
        guard let tiff = icon.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw PluginSessionError.plugin("无法读取文件图标。")
        }
        return "data:image/png;base64," + png.base64EncodedString()
    }

    private func target(_ context: Context, preferCurrent: Bool) throws -> NSRunningApplication {
        if preferCurrent, let current = NSWorkspace.shared.frontmostApplication,
           current.processIdentifier != ProcessInfo.processInfo.processIdentifier { return current }
        guard let pid = context.targetPID, pid != ProcessInfo.processInfo.processIdentifier,
              let application = NSRunningApplication(processIdentifier: pid), !application.isTerminated else {
            throw PluginSessionError.plugin("唤起 Leap 前的应用已退出或不可用。")
        }
        return application
    }

    private func input(_ method: String, params: PluginValue, context: Context) async throws {
        guard !inputInProgress else { throw PluginSessionError.plugin("另一个外部输入正在执行，请稍后重试。") }
        inputInProgress = true
        defer { inputInProgress = false }
        let text = method == "hideMainWindowTypeString" ? try string(params, "text") : nil
        let clipboard = text == nil ? try await prepareClipboard(method, params: params) : nil
        guard let pid = context.targetPID, pid != ProcessInfo.processInfo.processIdentifier,
              inputEnvironment.isAlive(pid) else { throw PluginSessionError.plugin("唤起 Leap 前的应用已退出或不可用。") }
        try inputEnvironment.requirePermission()
        try check(context)
        if let clipboard { try write(clipboard) }
        context.setWindowHidden(true)
        do {
            try await restoreFocus(pid, context: context)
            for chunk in text.map(PluginKeyboard.unicodeChunks) ?? [[]] {
                try check(context)
                guard inputEnvironment.frontmostPID() == pid else {
                    throw PluginSessionError.plugin("目标焦点已改变，已停止输入。")
                }
                if text != nil { try inputEnvironment.type(chunk) } else { try inputEnvironment.paste() }
                if text != nil { try await Task.sleep(for: .milliseconds(2)) }
            }
        } catch {
            if context.isActive() { context.setWindowHidden(false) }
            throw error
        }
    }

    private func restoreFocus(_ pid: Int32, context: Context) async throws {
        guard inputEnvironment.activate(pid) else { throw PluginSessionError.plugin("无法恢复目标应用焦点。") }
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while inputEnvironment.frontmostPID() != pid {
            try check(context)
            guard ContinuousClock.now < deadline, inputEnvironment.isAlive(pid) else {
                throw PluginSessionError.plugin("恢复应用焦点超时。")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        // 激活通知先于键盘焦点交接；留一个事件周期，并在发送前再次核对目标。
        try await Task.sleep(for: .milliseconds(50))
    }

    private func readTarget(_ method: String, context: Context) async throws -> String {
        let application = try target(context, preferCurrent: true)
        let script: String
        switch (method, application.bundleIdentifier) {
        case ("readCurrentFolderPath", "com.apple.finder"):
            script = "tell application id \"com.apple.finder\""
                + " to get POSIX path of (target of front Finder window as alias)"
        case ("readCurrentBrowserUrl", "com.apple.Safari"):
            script = "tell application id \"com.apple.Safari\" to get URL of current tab of front window"
        case ("readCurrentBrowserUrl", "com.google.Chrome"):
            script = "tell application id \"com.google.Chrome\" to get URL of active tab of front window"
        case ("readCurrentBrowserUrl", "company.thebrowser.Browser"):
            script = "tell application id \"company.thebrowser.Browser\" to get URL of active tab of front window"
        default: throw PluginSessionError.plugin("目标不是 Finder 或受支持的 Safari、Chrome、Arc 浏览器。")
        }
        let worker = Task.detached {
            try Task.checkCancellation()
            var error: NSDictionary?
            let source = "with timeout of 60 seconds\n" + script + "\nend timeout"
            guard let appleScript = NSAppleScript(source: source) else {
                throw PluginSessionError.plugin("无法创建系统查询。")
            }
            let result = appleScript.executeAndReturnError(&error)
            guard error == nil, let value = result.stringValue, !value.isEmpty else {
                throw PluginSessionError.plugin("无法读取当前窗口；请检查窗口是否存在及系统设置中的自动化授权。")
            }
            return value
        }
        let value = try await PluginCancellableOperation.value(of: worker)
        try check(context)
        return value
    }

    private func notify(_ params: PluginValue, context: Context) async throws {
        let body = try string(params, "body")
        guard !body.isEmpty else { throw PluginSessionError.plugin("通知正文不能为空。") }
        let command = params["clickFeatureCode"]
        if let command {
            guard let id = command.string, context.commandIDs.contains(id) else {
                throw PluginSessionError.plugin("通知点击命令未在当前插件清单中声明。")
            }
        }
        let center = UNUserNotificationCenter.current()
        let authorization = Task { try await center.requestAuthorization(options: [.alert, .sound]) }
        guard try await PluginCancellableOperation.value(of: authorization) else {
            throw PluginSessionError.plugin("通知权限未授权，请在系统设置中允许 Leap 通知。")
        }
        try check(context)
        let content = UNMutableNotificationContent()
        content.title = "Leap"
        content.body = body
        content.sound = .default
        if let command = command?.string { content.userInfo = ["pluginID": context.pluginID, "commandID": command] }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        let posting = Task {
            try Task.checkCancellation()
            try await center.add(request)
        }
        try await PluginCancellableOperation.value(of: posting)
    }
}
