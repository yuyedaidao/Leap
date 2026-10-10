import AppKit
import LeapCore
import SwiftUI
import WebKit
import YQLogger

struct PluginWebContent: View {
    let command: PluginCommandDescriptor
    let session: PluginInteractionSession

    var body: some View {
        VStack(spacing: 0) {
            if let webEntry = command.manifest.webEntry {
                PluginWebView(
                    pageURL: command.pluginDirectory.appendingPathComponent(webEntry),
                    readAccessDirectory: command.pluginDirectory,
                    invoke: { await session.invoke(commandID: $0, query: $1) }, interaction: session
                )
            } else {
                ContentUnavailableView("网页入口不可用", systemImage: "exclamationmark.triangle")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct PluginWebView: NSViewRepresentable {
    let pageURL: URL
    let readAccessDirectory: URL
    let invoke: (String, String) async -> LauncherModel.InvocationResponse
    var interaction: PluginInteractionSession?
    // 在 SwiftUI body 中传入值快照，让参数变化独立于输入栏布局触发网页更新。
    var committedInput: String?
    var submitID = 0

    func makeCoordinator() -> Coordinator {
        Coordinator(
            pageURL: pageURL, readAccessDirectory: readAccessDirectory, invoke: invoke, interaction: interaction
        )
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let controller = configuration.userContentController
        controller.addUserScript(WKUserScript(
            source: context.coordinator.sdkSource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        controller.addScriptMessageHandler(context.coordinator, contentWorld: .page, name: "leapInvoke")
        controller.addScriptMessageHandler(context.coordinator, contentWorld: .page, name: "leapDirectory")
        controller.addScriptMessageHandler(context.coordinator, contentWorld: .page, name: "leapHost")

        let webView = PluginPageWebView(frame: .zero, configuration: configuration)
        webView.focusesOnAttach = interaction?.configuration.inputEnabled == false
        webView.navigationDelegate = context.coordinator
        webView.loadFileURL(pageURL, allowingReadAccessTo: readAccessDirectory)
        interaction?.exitWebPage = { [weak webView] in
            webView?.evaluateJavaScript("window.__leapDispatch('exit', null)", completionHandler: nil)
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.update(webView, interaction: interaction, query: committedInput, submitID: submitID)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        let controller = webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: "leapInvoke", contentWorld: .page)
        controller.removeScriptMessageHandler(forName: "leapDirectory", contentWorld: .page)
        controller.removeScriptMessageHandler(forName: "leapHost", contentWorld: .page)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandlerWithReply {
        private let readAccessDirectory: URL
        private let pageURL: URL
        private let invoke: (String, String) async -> LauncherModel.InvocationResponse
        private weak var directoryWindow: NSWindow?
        let initialContext: String
        private weak var interaction: PluginInteractionSession?
        var sdkSource: String {
            guard let url = Bundle.main.url(forResource: "web", withExtension: "js", subdirectory: "PluginSDK"),
                  let source = try? String(contentsOf: url, encoding: .utf8) else {
                return "throw new Error(\"Leap SDK 资源不可用。\");"
            }
            guard let hostURL = Bundle.main.url(forResource: "host-api", withExtension: "js", subdirectory: "PluginSDK"),
                  let hostSource = try? String(contentsOf: hostURL, encoding: .utf8) else {
                return "throw new Error(\"Leap 宿主 SDK 资源不可用。\");"
            }
            return "window.__leapContext = \(initialContext);\n" + hostSource + "\n" + source
        }
        private var lastQuery: String?
        private var latestQuery: String?
        private var lastSubmitID = 0
        private var pendingSubmit: String?
        private var isLoaded = false
        private lazy var directories = PluginDirectorySession(
            choose: { @MainActor [weak self] in
                guard let window = self?.directoryWindow, window.isVisible else { return nil }
                let panel = NSOpenPanel()
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                // 允许用户在选择保存位置时直接创建新的父目录。
                panel.canCreateDirectories = true
                panel.allowsMultipleSelection = false
                panel.prompt = "选择目录"
                // 附在实际插件窗口上，取消后焦点返回网页，不切换到此前的前台应用。
                return await withCheckedContinuation { continuation in
                    panel.beginSheetModal(for: window) { response in
                        continuation.resume(returning: response == .OK ? panel.url : nil)
                    }
                }
            },
            open: { NSWorkspace.shared.open($0) }
        )

        init(
            pageURL: URL,
            readAccessDirectory: URL,
            invoke: @escaping (String, String) async -> LauncherModel.InvocationResponse,
            interaction: PluginInteractionSession?
        ) {
            self.pageURL = pageURL.resolvingSymlinksInPath().standardizedFileURL
            self.readAccessDirectory = readAccessDirectory.standardizedFileURL
            self.invoke = invoke
            self.interaction = interaction
            if let interaction {
                let data = try? JSONSerialization.data(withJSONObject: [
                    "commandID": interaction.command.commandID, "query": interaction.committedInput
                ])
                initialContext = data.map { String(decoding: $0, as: UTF8.self) } ?? "null"
                lastQuery = interaction.committedInput
                latestQuery = lastQuery
            } else {
                initialContext = "null"
            }
        }

        func update(_ webView: WKWebView, interaction: PluginInteractionSession?, query: String?, submitID: Int) {
            guard let interaction, interaction.isActive else { return }
            latestQuery = query
            if lastSubmitID != submitID {
                lastSubmitID = submitID
                pendingSubmit = query
            }
            guard isLoaded else { return }
            if lastQuery != latestQuery {
                lastQuery = latestQuery
                dispatch(webView, event: "input", value: query ?? "")
            }
            flushSubmit(webView)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoaded = true
            if lastQuery != latestQuery, let latestQuery {
                lastQuery = latestQuery
                dispatch(webView, event: "input", value: latestQuery)
            }
            flushSubmit(webView)
        }

        private func flushSubmit(_ webView: WKWebView) {
            guard let value = pendingSubmit else { return }
            pendingSubmit = nil
            dispatch(webView, event: "submit", value: value)
        }

        private func dispatch(_ webView: WKWebView, event: String, value: String) {
            // callAsyncJavaScript 用参数传值，用户文本不会拼入可执行脚本。
            webView.callAsyncJavaScript(
                "window.__leapDispatch(event, value)", arguments: ["event": event, "value": value],
                in: nil, in: .page, completionHandler: nil
            )
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url,
                  url.isFileURL,
                  url.standardizedFileURL.path.hasPrefix(readAccessDirectory.path + "/") else {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage,
            replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
        ) {
            guard PluginDirectorySession.isAllowedPage(
                message.frameInfo.request.url, mainFrame: message.frameInfo.isMainFrame, expectedPage: pageURL
            ), interaction?.isActive == true else {
                replyHandler(nil, "接口只允许当前插件主页面调用。"); return
            }
            if message.name == "leapHost" {
                guard let body = message.body as? [String: Any], let method = body["method"] as? String,
                      let params = body["params"], JSONSerialization.isValidJSONObject(params),
                      let data = try? JSONSerialization.data(withJSONObject: params), data.count <= 24 * 1024 * 1024,
                      let value = try? JSONDecoder().decode(PluginValue.self, from: data), let interaction else {
                    replyHandler(nil, "宿主接口参数无效。"); return
                }
                if method == "__cancelHostCall", let callID = value["callID"]?.string {
                    interaction.cancelWebHostCall(callID)
                    replyHandler(true, nil)
                    return
                }
                guard let callID = body["callID"] as? String, callID.hasPrefix("web-host-"), callID.count <= 64 else {
                    replyHandler(nil, "宿主调用标识无效。")
                    return
                }
                let hostTask: Task<PluginValue, any Error>
                do { hostTask = try interaction.startWebHostCall(method, params: value, callID: callID) }
                catch { replyHandler(nil, error.localizedDescription); return }
                Task { @MainActor in
                    let deadline = Task {
                        try await Task.sleep(for: .seconds(60))
                        hostTask.cancel()
                    }
                    defer { deadline.cancel(); interaction.finishWebHostCall(callID) }
                    do {
                        let result = try await hostTask.value
                        let encoded = try JSONEncoder().encode(result)
                        guard encoded.count <= 24 * 1024 * 1024 else { throw PluginSessionError.messageTooLarge }
                        let object = try JSONSerialization.jsonObject(with: encoded, options: .fragmentsAllowed)
                        replyHandler(object, nil)
                        // 回复已提交给 WebKit 后才关闭页面，避免调用者永远等不到确认。
                        Task { @MainActor [weak interaction] in
                            guard let interaction, interaction.isActive else { return }
                            interaction.hostAction?(method)
                        }
                    } catch { replyHandler(nil, error.localizedDescription) }
                }
                return
            }
            if message.name == "leapDirectory" {
                handleDirectoryMessage(message, replyHandler: replyHandler)
                return
            }
            guard let body = message.body as? [String: Any],
                  let commandID = body["commandID"] as? String,
                  let query = body["query"] as? String else {
                replyHandler(nil, "网页调用参数无效。")
                return
            }
            Task { [invoke] in
                switch await invoke(commandID, query) {
                case let .success(response):
                    replyHandler(response, nil)
                case let .failure(message):
                    replyHandler(nil, message)
                }
            }
        }

        private func handleDirectoryMessage(
            _ message: WKScriptMessage,
            replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
        ) {
            guard PluginDirectorySession.isAllowedPage(
                message.frameInfo.request.url, mainFrame: message.frameInfo.isMainFrame, expectedPage: pageURL
            ),
                  let body = message.body as? [String: Any],
                  let action = body["action"] as? String else {
                replyHandler(nil, "目录接口只允许当前插件主页面调用。")
                return
            }
            directoryWindow = message.webView?.window
            Task {
                do {
                    switch action {
                    case "choose":
                        let path = try await directories.chooseDirectory()
                        replyHandler(path.map { $0 as Any } ?? NSNull(), nil)
                    case "open":
                        guard let path = body["path"] as? String else {
                            replyHandler(nil, "目录路径无效。")
                            return
                        }
                        try directories.openDirectory(path: path)
                        replyHandler(true, nil)
                    default:
                        replyHandler(nil, "未知目录操作。")
                    }
                } catch {
                    YQLogger(label: "com.padding.leap/plugin-directory")
                        .error("插件目录操作失败：\(error.localizedDescription)。")
                    replyHandler(nil, error.localizedDescription)
                }
            }
        }
    }
}

/// 无顶部参数框的内嵌页面仍需接过旧搜索框的焦点，避免非激活面板被误判为失焦。
private final class PluginPageWebView: WKWebView {
    var focusesOnAttach = false
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard focusesOnAttach else { return }
        Task { @MainActor [weak self] in
            guard let self, let window = self.window, window.isVisible else { return }
            window.makeKey()
            window.makeFirstResponder(self)
        }
    }
}
