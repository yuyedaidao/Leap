import LeapCore
import SwiftUI
import WebKit

struct PluginWebSheet: View {
    let command: PluginCommandDescriptor
    let invoke: (String, String) async -> LauncherModel.InvocationResponse
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(command.title)
                    .font(.headline)
                Spacer()
                Button("关闭", action: dismiss)
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            if let webEntry = command.manifest.webEntry {
                PluginWebView(
                    pageURL: command.pluginDirectory.appendingPathComponent(webEntry),
                    readAccessDirectory: command.pluginDirectory,
                    invoke: invoke
                )
            } else {
                ContentUnavailableView("网页入口不可用", systemImage: "exclamationmark.triangle")
            }
        }
        .frame(minWidth: 560, minHeight: 360)
    }
}

struct PluginWebView: NSViewRepresentable {
    let pageURL: URL
    let readAccessDirectory: URL
    let invoke: (String, String) async -> LauncherModel.InvocationResponse

    func makeCoordinator() -> Coordinator {
        Coordinator(readAccessDirectory: readAccessDirectory, invoke: invoke)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let controller = configuration.userContentController
        controller.addUserScript(WKUserScript(
            source: "window.leap = Object.freeze({ invoke: (commandID, query = '') => window.webkit.messageHandlers.leapInvoke.postMessage({ commandID, query }) });",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        controller.addScriptMessageHandler(context.coordinator, contentWorld: .page, name: "leapInvoke")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.loadFileURL(pageURL, allowingReadAccessTo: readAccessDirectory)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "leapInvoke", contentWorld: .page)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandlerWithReply {
        private let readAccessDirectory: URL
        private let invoke: (String, String) async -> LauncherModel.InvocationResponse

        init(readAccessDirectory: URL, invoke: @escaping (String, String) async -> LauncherModel.InvocationResponse) {
            self.readAccessDirectory = readAccessDirectory.standardizedFileURL
            self.invoke = invoke
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
    }
}
