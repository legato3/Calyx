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

    init(url: URL) {
        let state = BrowserState(url: url)
        self.browserState = state
        self.browserView = BrowserView(state: state)
    }

    func goBack() { browserView.goBack() }
    func goForward() { browserView.goForward() }
    func reload() { browserView.reload() }
    func loadURL(_ url: URL) { browserView.loadURL(url) }

    deinit {
        logger.debug("BrowserTabController deinit")
    }
}
