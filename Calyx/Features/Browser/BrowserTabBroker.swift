import Foundation

@MainActor
class BrowserTabBroker {
    weak var appDelegate: AppDelegate?

    func resolveTab(_ tabID: UUID?) -> BrowserTabController? {
        guard let appDelegate else { return nil }
        if let tabID {
            // Search ALL windows for this tab
            for wc in appDelegate.allWindowControllers {
                if let controller = wc.browserController(forExternal: tabID) {
                    return controller
                }
            }
            return nil
        }
        // No tab_id → active browser tab in key window
        let keyWC = appDelegate.allWindowControllers.first { $0.window?.isKeyWindow == true }
        return keyWC?.activeBrowserControllerForExternal
    }

    func listTabs() -> [(id: UUID, url: String, title: String)] {
        guard let appDelegate else { return [] }
        var result: [(id: UUID, url: String, title: String)] = []
        for wc in appDelegate.allWindowControllers {
            for group in wc.windowSession.groups {
                for tab in group.tabs {
                    if case .browser(let url) = tab.content {
                        result.append((id: tab.id, url: url.absoluteString, title: tab.title))
                    }
                }
            }
        }
        return result
    }

    func createTab(url: URL) -> UUID? {
        guard let appDelegate else { return nil }
        let keyWC = appDelegate.allWindowControllers.first { $0.window?.isKeyWindow == true }
            ?? appDelegate.allWindowControllers.first
        guard let wc = keyWC else { return nil }
        wc.createBrowserTab(url: url)
        // The last browser tab added to the active group is the one we just created
        guard let group = wc.windowSession.activeGroup,
              let lastTab = group.tabs.last,
              case .browser = lastTab.content else { return nil }
        return lastTab.id
    }
}
