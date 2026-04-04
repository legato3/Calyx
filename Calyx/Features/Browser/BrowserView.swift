import AppKit
import WebKit
import OSLog

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.legato3.terminal",
    category: "BrowserView"
)

@MainActor
class BrowserView: NSView {
    private let webView: WKWebView
    private let state: BrowserState
    private let downloadManager: DownloadManager
    // Keyed by WKFrameInfo identity — tracks redirect depth per frame.
    // Entries are cleared in didCommit (navigation committed) so they don't accumulate.
    private var redirectCounts: [ObjectIdentifier: Int] = [:]
    var onTitleChanged: ((String) -> Void)?
    var onURLChanged: ((URL) -> Void)?
    var onNavigationCommit: (() -> Void)?

    init(state: BrowserState, downloadManager: DownloadManager = DownloadManager()) {
        self.state = state
        self.downloadManager = downloadManager

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        self.webView = WKWebView(frame: .zero, configuration: config)

        super.init(frame: .zero)

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.frame = bounds
        webView.autoresizingMask = [.width, .height]
        addSubview(webView)

        webView.load(URLRequest(url: state.url))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    func loadURL(_ url: URL) {
        state.url = url
        onURLChanged?(url)
        webView.load(URLRequest(url: url))
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload() { webView.reload() }

    func evaluateJavaScript(_ script: String) async throws -> String {
        let result: Any?
        if script.contains("await") {
            result = try await webView.callAsyncJavaScript(
                script, contentWorld: .page
            )
        } else {
            result = try await webView.evaluateJavaScript(script)
        }
        if let str = result as? String {
            return str
        }
        return String(describing: result)
    }

    func takeScreenshot() async throws -> Data {
        let config = WKSnapshotConfiguration()
        let image = try await webView.takeSnapshot(configuration: config)
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw BrowserAutomationError.screenshotFailed
        }
        return pngData
    }
}

// MARK: - WKNavigationDelegate

extension BrowserView: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url,
              let scheme = url.scheme else {
            return .cancel
        }

        if navigationAction.targetFrame?.isMainFrame == true {
            guard BrowserSecurity.isAllowedTopLevelScheme(scheme) else {
                logger.warning("Blocked top-level navigation to disallowed scheme: \(scheme)")
                return .cancel
            }

            if navigationAction.navigationType == .other && navigationAction.sourceFrame.isMainFrame {
                let frameKey = ObjectIdentifier(navigationAction.sourceFrame)
                let count = redirectCounts[frameKey, default: 0] + 1
                if count > BrowserSecurity.maxRedirectDepth {
                    logger.warning("Blocked navigation: exceeded max redirect depth (\(BrowserSecurity.maxRedirectDepth))")
                    redirectCounts.removeValue(forKey: frameKey)
                    return .cancel
                }
                redirectCounts[frameKey] = count
            }

            return .allow
        } else {
            guard BrowserSecurity.isAllowedSubresourceScheme(scheme) else {
                logger.warning("Blocked subresource with disallowed scheme: \(scheme)")
                return .cancel
            }
            return .allow
        }
    }

    func webView(
        _ webView: WKWebView,
        navigationAction: WKNavigationAction,
        didBecome download: WKDownload
    ) {
        download.delegate = downloadManager
    }

    func webView(
        _ webView: WKWebView,
        navigationResponse: WKNavigationResponse,
        didBecome download: WKDownload
    ) {
        download.delegate = downloadManager
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        // A navigation committed — the redirect chain for the main frame is resolved.
        // Clear all frame-keyed redirect counts so they don't accumulate across navigations.
        redirectCounts.removeAll()
        state.isLoading = true
        state.canGoBack = webView.canGoBack
        state.canGoForward = webView.canGoForward
        state.title = webView.title ?? state.url.host() ?? state.url.absoluteString
        onTitleChanged?(state.title)
        if let currentURL = webView.url {
            state.url = currentURL
            onURLChanged?(currentURL)
        }
        onNavigationCommit?()
    }

    func webView(
        _ webView: WKWebView,
        didStartProvisionalNavigation navigation: WKNavigation!
    ) {
        state.isLoading = true
        state.lastError = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        redirectCounts.removeAll()
        state.isLoading = false
        state.canGoBack = webView.canGoBack
        state.canGoForward = webView.canGoForward
        state.title = webView.title ?? state.url.host() ?? state.url.absoluteString
        onTitleChanged?(state.title)
        if let currentURL = webView.url {
            state.url = currentURL
            onURLChanged?(currentURL)
        }
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: any Error
    ) {
        redirectCounts.removeAll()
        state.isLoading = false
        state.lastError = error.localizedDescription
        logger.error("Navigation failed: \(error.localizedDescription)")
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: any Error
    ) {
        redirectCounts.removeAll()
        state.isLoading = false
        state.lastError = error.localizedDescription
        logger.error("Provisional navigation failed: \(error.localizedDescription)")
    }
}

// MARK: - WKUIDelegate

extension BrowserView: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url {
            webView.load(URLRequest(url: url))
        }
        return nil
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo
    ) async {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host() ?? "Web Page"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo
    ) async -> Bool {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host() ?? "Web Page"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        return response == .alertFirstButtonReturn
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo
    ) async -> String? {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host() ?? "Web Page"
        alert.informativeText = prompt
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        textField.stringValue = defaultText ?? ""
        alert.accessoryView = textField

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            return textField.stringValue
        } else {
            return nil
        }
    }
}
