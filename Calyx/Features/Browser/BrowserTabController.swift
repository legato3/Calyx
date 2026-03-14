import Foundation
import OSLog

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.calyx.terminal",
    category: "BrowserTabController"
)

@MainActor
class BrowserTabController {
    let browserState: BrowserState
    private(set) var browserView: BrowserView
    private(set) var snapshotGeneration: Int = 0
    var onNavigationCommit: (() -> Void)?

    init(url: URL) {
        let state = BrowserState(url: url)
        self.browserState = state
        self.browserView = BrowserView(state: state)

        browserView.onNavigationCommit = { [weak self] in
            self?.snapshotGeneration = 0
            self?.onNavigationCommit?()
        }
    }

    func incrementSnapshotGeneration() {
        snapshotGeneration += 1
    }

    func evaluateJavaScript(_ script: String) async throws -> String {
        try await browserView.evaluateJavaScript(script)
    }

    func takeScreenshot() async throws -> Data {
        try await browserView.takeScreenshot()
    }

    func goBack() { browserView.goBack() }
    func goForward() { browserView.goForward() }
    func reload() { browserView.reload() }
    func loadURL(_ url: URL) { browserView.loadURL(url) }

    deinit {
        logger.debug("BrowserTabController deinit")
    }
}
