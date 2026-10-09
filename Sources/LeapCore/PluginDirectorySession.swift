import Foundation

/// 授权只属于当前网页实例；选择目录不会给其他插件授予打开任意路径的能力。
@MainActor
public final class PluginDirectorySession {
    public enum DirectoryError: LocalizedError {
        case selectionInProgress
        case invalidDirectory
        case outsideSelection
        case openFailed

        public var errorDescription: String? {
            switch self {
            case .selectionInProgress: "目录选择窗口已经打开。"
            case .invalidDirectory: "目录不存在或路径无效。"
            case .outsideSelection: "只能打开当前页面选择的目录及其子目录。"
            case .openFailed: "无法用 Finder 打开目录，请重试。"
            }
        }
    }

    private let choose: @MainActor () async -> URL?
    private let open: (URL) -> Bool
    private var selectedDirectory: URL?
    private var isChoosing = false

    public init(choose: @escaping @MainActor () async -> URL?, open: @escaping (URL) -> Bool) {
        self.choose = choose
        self.open = open
    }

    public nonisolated static func isAllowedPage(_ source: URL?, mainFrame: Bool, expectedPage: URL) -> Bool {
        guard mainFrame, let source, source.isFileURL else { return false }
        return source.resolvingSymlinksInPath().standardizedFileURL ==
            expectedPage.resolvingSymlinksInPath().standardizedFileURL
    }

    public func chooseDirectory() async throws -> String? {
        guard !isChoosing else { throw DirectoryError.selectionInProgress }
        isChoosing = true
        defer { isChoosing = false }
        guard let directory = await choose() else { return nil }
        let resolved = directory.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.isFileURL, (try? resolved.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw DirectoryError.invalidDirectory
        }
        selectedDirectory = resolved
        return resolved.path
    }

    public func openDirectory(path: String) throws {
        guard path.hasPrefix("/"), !path.contains("\0") else { throw DirectoryError.invalidDirectory }
        let directory = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        guard let selectedDirectory else { throw DirectoryError.outsideSelection }
        // 按路径组件比较，拒绝同名前缀目录和指向授权目录外的符号链接。
        let parentComponents = selectedDirectory.pathComponents
        guard directory.pathComponents.starts(with: parentComponents) else { throw DirectoryError.outsideSelection }
        guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw DirectoryError.invalidDirectory
        }
        guard open(directory) else { throw DirectoryError.openFailed }
    }
}
