import Foundation

public struct RemotePluginSource: Codable, Equatable, Sendable {
    public let directoryURL: URL
    public let owner: String
    public let repository: String
    public let path: String
    public let commit: String

    public init(directoryURL: URL, owner: String, repository: String, path: String, commit: String) {
        self.directoryURL = directoryURL
        self.owner = owner
        self.repository = repository
        self.path = path
        self.commit = commit
    }
}

public enum RemotePluginError: LocalizedError, Equatable {
    case invalidAddress
    case notFound
    case httpStatus(Int)
    case rateLimited(String?)
    case unsafePath
    case unsupportedFile
    case incompleteDownload
    case limitExceeded(String)
    case unsafeRedirect

    public var errorDescription: String? {
        switch self {
        case .invalidAddress:
            "请输入公开 GitHub 仓库的具体插件目录 HTTPS 链接，例如 https://github.com/owner/repo/tree/main/plugins/hello。"
        case .notFound: "无法访问插件目录或引用，请检查地址以及仓库是否公开。"
        case .httpStatus(let status): "GitHub 请求失败（HTTP \(status)），请稍后重试。"
        case .rateLimited(let reset): "GitHub 请求限流，请稍后重试。" + (reset.map { "恢复时间：\($0)。" } ?? "")
        case .unsafePath: "插件包含越界、重复或本机无法区分的文件路径。"
        case .unsupportedFile: "插件包含不支持的符号链接、子模块、Git LFS 指针或特殊文件。"
        case .incompleteDownload: "插件目录或文件下载不完整，尚未安装。"
        case .limitExceeded(let limit): "插件超过下载限制：\(limit)。"
        case .unsafeRedirect: "插件下载地址或重定向不在允许的 GitHub HTTPS 主机范围内。"
        }
    }
}

struct GitHubPluginAddress: Sendable {
    let url: URL
    let owner: String
    let repository: String
    let referenceAndPath: [String]

    init(_ input: String) throws {
        guard let parts = URLComponents(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
            parts.scheme?.lowercased() == "https", parts.host?.lowercased() == "github.com",
            parts.port == nil, parts.user == nil, parts.password == nil,
            parts.query == nil, parts.fragment == nil
        else { throw RemotePluginError.invalidAddress }
        // 在 URL 标准化之前检查原始路径，不能让编码的父级跳转被消掉。
        var encoded = parts.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
        guard encoded.first == "" else { throw RemotePluginError.invalidAddress }
        if encoded.last == "" { encoded.removeLast() }
        let components = try encoded.dropFirst().map { value -> String in
            guard let decoded = String(value).removingPercentEncoding,
                !decoded.isEmpty, decoded != ".", decoded != "..",
                !decoded.contains("/"), !decoded.contains("\\"),
                !decoded.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            else {
                throw RemotePluginError.invalidAddress
            }
            return decoded
        }
        guard components.count >= 5, components.count <= 36, components[2] == "tree",
            components[0].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }),
            components[1].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }),
            let url = parts.url
        else { throw RemotePluginError.invalidAddress }
        self.url = url
        owner = components[0]
        repository = components[1]
        referenceAndPath = Array(components.dropFirst(3))
    }
}
