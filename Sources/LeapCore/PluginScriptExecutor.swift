import Foundation

public struct BundledRuntimeLocator: Sendable {
    public enum RuntimeError: LocalizedError, Equatable {
        case missingRuntime(PluginManifest.Runtime)

        public var errorDescription: String? {
            switch self {
            case .missingRuntime(.python): "Leap 随包 Python 运行时不可用。"
            case .missingRuntime(.javascript): "Leap 随包 Node.js 运行时不可用。"
            }
        }
    }

    public let paths: AppPaths

    public init(paths: AppPaths) {
        self.paths = paths
    }

    public func executable(for runtime: PluginManifest.Runtime, fileManager: FileManager = .default) throws -> URL {
        let executable: URL
        switch runtime {
        case .python:
            executable = paths.runtimesDirectory
                .appendingPathComponent("python-3.14.7/Versions/3.14/bin/python3.14")
        case .javascript:
            executable = paths.runtimesDirectory
                .appendingPathComponent("node-24.21.0/bin/node")
        }
        guard fileManager.isExecutableFile(atPath: executable.path) else {
            throw RuntimeError.missingRuntime(runtime)
        }
        return executable
    }
}

public struct PluginScriptExecutor: Sendable {
    let runtimeLocator: BundledRuntimeLocator
    private let processRunner = JSONRPCProcessRunner()

    public init(runtimeLocator: BundledRuntimeLocator) {
        self.runtimeLocator = runtimeLocator
    }

    public func invoke(
        manifest: PluginManifest,
        pluginDirectory: URL,
        commandID: String,
        query: String
    ) throws -> String {
        let entryURL = pluginDirectory.appendingPathComponent(manifest.entry).standardizedFileURL
        guard entryURL.path.hasPrefix(pluginDirectory.standardizedFileURL.path + "/") else {
            throw PluginManifestValidator.ValidationError.invalidEntry
        }
        let runtime = try runtimeLocator.executable(for: manifest.runtime)
        return try processRunner.invoke(
            executable: runtime,
            arguments: [entryURL.path],
            commandID: commandID,
            query: query
        )
    }
}
