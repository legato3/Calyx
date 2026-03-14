//
//  BrowserToolHandler.swift
//  Calyx
//

import Foundation

struct BrowserToolResult: Sendable {
    let text: String
    let isError: Bool
}

@MainActor
class BrowserToolHandler {
    let broker: BrowserTabBroker

    init(broker: BrowserTabBroker) {
        self.broker = broker
    }

    var isScriptingEnabled: Bool {
        UserDefaults.standard.bool(forKey: "browserScriptingEnabled")
    }

    static func isRestrictedForEval(url: String) -> Bool {
        let lowered = url.lowercased()
        let restrictedPaths = ["/login", "/auth", "/oauth", "/signin"]
        guard let urlObj = URL(string: lowered) else {
            return restrictedPaths.contains { lowered.contains($0) }
        }
        let path = urlObj.path.lowercased()
        return restrictedPaths.contains { path.contains($0) }
    }

    func handleTool(name: String, arguments: [String: Any]?) async -> BrowserToolResult {
        guard isScriptingEnabled else {
            return BrowserToolResult(
                text: "Browser scripting is not enabled. Enable it via Command Palette.",
                isError: true
            )
        }

        switch name {
        case "browser_open":
            return await handleOpen(arguments)
        case "browser_list":
            return handleList()
        case "browser_navigate":
            return await handleNavigate(arguments)
        case "browser_back":
            return await handleBack(arguments)
        case "browser_forward":
            return await handleForward(arguments)
        case "browser_reload":
            return await handleReload(arguments)
        case "browser_snapshot":
            return await handleSnapshot(arguments)
        case "browser_screenshot":
            return await handleScreenshot(arguments)
        case "browser_get_text":
            return await handleGetText(arguments)
        case "browser_get_html":
            return await handleGetHTML(arguments)
        case "browser_eval":
            return await handleEval(arguments)
        case "browser_click":
            return await handleClick(arguments)
        case "browser_fill":
            return await handleFill(arguments)
        case "browser_type":
            return await handleType(arguments)
        case "browser_press":
            return await handlePress(arguments)
        case "browser_select":
            return await handleSelect(arguments)
        case "browser_check":
            return await handleCheck(arguments)
        case "browser_uncheck":
            return await handleUncheck(arguments)
        case "browser_wait":
            return await handleWait(arguments)
        default:
            return BrowserToolResult(text: "Unknown browser tool: \(name)", isError: true)
        }
    }

    // MARK: - Private Helpers

    private func checkAuthRestriction(_ controller: BrowserTabController) -> BrowserToolResult? {
        let currentURL = controller.browserState.url.absoluteString
        if Self.isRestrictedForEval(url: currentURL) {
            return BrowserToolResult(
                text: "Interaction blocked on auth page: \(currentURL)",
                isError: true
            )
        }
        return nil
    }

    private func resolveTab(_ arguments: [String: Any]?) -> (controller: BrowserTabController?, error: BrowserToolResult?) {
        let tabIDStr = arguments?["tab_id"] as? String
        let tabID = tabIDStr.flatMap { UUID(uuidString: $0) }

        guard let controller = broker.resolveTab(tabID) else {
            if let tabID {
                return (nil, BrowserToolResult(
                    text: BrowserAutomationError.tabNotFound(tabID).localizedDescription,
                    isError: true
                ))
            }
            return (nil, BrowserToolResult(
                text: BrowserAutomationError.noActiveBrowserTab.localizedDescription,
                isError: true
            ))
        }
        return (controller, nil)
    }

    private func runJS(_ controller: BrowserTabController, _ script: String) async -> BrowserToolResult {
        do {
            let result = try await controller.evaluateJavaScript(script)
            let response = BrowserAutomation.parseResponse(result)
            if response.ok {
                return BrowserToolResult(text: response.value ?? "", isError: false)
            } else {
                return BrowserToolResult(text: response.error ?? "Unknown error", isError: true)
            }
        } catch {
            return BrowserToolResult(
                text: "JavaScript evaluation failed: \(error.localizedDescription)",
                isError: true
            )
        }
    }

    // MARK: - Tool Handlers

    private func handleOpen(_ arguments: [String: Any]?) async -> BrowserToolResult {
        guard let urlStr = arguments?["url"] as? String,
              let url = URL(string: urlStr) else {
            return BrowserToolResult(text: "Missing or invalid 'url' parameter", isError: true)
        }
        guard let tabID = broker.createTab(url: url) else {
            return BrowserToolResult(text: "Failed to create browser tab", isError: true)
        }
        return BrowserToolResult(text: "{\"tab_id\":\"\(tabID.uuidString)\"}", isError: false)
    }

    private func handleList() -> BrowserToolResult {
        let tabs = broker.listTabs()
        let tabDicts = tabs.map { tab -> [String: String] in
            ["id": tab.id.uuidString, "url": tab.url, "title": tab.title]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: ["tabs": tabDicts]),
              let json = String(data: data, encoding: .utf8) else {
            return BrowserToolResult(text: "{\"tabs\":[]}", isError: false)
        }
        return BrowserToolResult(text: json, isError: false)
    }

    private func handleNavigate(_ arguments: [String: Any]?) async -> BrowserToolResult {
        guard let urlStr = arguments?["url"] as? String,
              let url = URL(string: urlStr) else {
            return BrowserToolResult(text: "Missing or invalid 'url' parameter", isError: true)
        }
        let resolved = resolveTab(arguments)
        guard let controller = resolved.controller else { return resolved.error! }
        controller.loadURL(url)
        return BrowserToolResult(text: "Navigated to \(urlStr)", isError: false)
    }

    private func handleBack(_ arguments: [String: Any]?) async -> BrowserToolResult {
        let resolved = resolveTab(arguments)
        guard let controller = resolved.controller else { return resolved.error! }
        controller.goBack()
        return BrowserToolResult(text: "Navigated back", isError: false)
    }

    private func handleForward(_ arguments: [String: Any]?) async -> BrowserToolResult {
        let resolved = resolveTab(arguments)
        guard let controller = resolved.controller else { return resolved.error! }
        controller.goForward()
        return BrowserToolResult(text: "Navigated forward", isError: false)
    }

    private func handleReload(_ arguments: [String: Any]?) async -> BrowserToolResult {
        let resolved = resolveTab(arguments)
        guard let controller = resolved.controller else { return resolved.error! }
        controller.reload()
        return BrowserToolResult(text: "Reloaded", isError: false)
    }

    private func handleSnapshot(_ arguments: [String: Any]?) async -> BrowserToolResult {
        let resolved = resolveTab(arguments)
        guard let controller = resolved.controller else { return resolved.error! }
        controller.incrementSnapshotGeneration()
        let js = BrowserAutomation.snapshot()
        return await runJS(controller, js)
    }

    private func handleScreenshot(_ arguments: [String: Any]?) async -> BrowserToolResult {
        let resolved = resolveTab(arguments)
        guard let controller = resolved.controller else { return resolved.error! }
        do {
            let data = try await controller.takeScreenshot()
            let tmpPath = "/tmp/calyx-screenshot-\(UUID().uuidString).png"
            try data.write(to: URL(fileURLWithPath: tmpPath))
            return BrowserToolResult(text: "{\"path\":\"\(tmpPath)\"}", isError: false)
        } catch {
            return BrowserToolResult(
                text: "Screenshot failed: \(error.localizedDescription)",
                isError: true
            )
        }
    }

    private func handleGetText(_ arguments: [String: Any]?) async -> BrowserToolResult {
        guard let selector = arguments?["selector"] as? String else {
            return BrowserToolResult(text: "Missing 'selector' parameter", isError: true)
        }
        let resolved = resolveTab(arguments)
        guard let controller = resolved.controller else { return resolved.error! }
        let js = BrowserAutomation.getText(selector: selector)
        return await runJS(controller, js)
    }

    private func handleGetHTML(_ arguments: [String: Any]?) async -> BrowserToolResult {
        guard let selector = arguments?["selector"] as? String else {
            return BrowserToolResult(text: "Missing 'selector' parameter", isError: true)
        }
        let resolved = resolveTab(arguments)
        guard let controller = resolved.controller else { return resolved.error! }
        let maxLength = arguments?["max_length"] as? Int ?? 512000
        let js = BrowserAutomation.getHTML(selector: selector, maxLength: maxLength)
        return await runJS(controller, js)
    }

    private func handleEval(_ arguments: [String: Any]?) async -> BrowserToolResult {
        guard let code = arguments?["code"] as? String else {
            return BrowserToolResult(text: "Missing 'code' parameter", isError: true)
        }
        let resolved = resolveTab(arguments)
        guard let controller = resolved.controller else { return resolved.error! }
        let currentURL = controller.browserState.url.absoluteString
        if Self.isRestrictedForEval(url: currentURL) {
            return BrowserToolResult(
                text: BrowserAutomationError.restrictedPage(currentURL).localizedDescription,
                isError: true
            )
        }
        let js = BrowserAutomation.eval(code: code)
        return await runJS(controller, js)
    }

    private func handleClick(_ arguments: [String: Any]?) async -> BrowserToolResult {
        guard let selector = arguments?["selector"] as? String else {
            return BrowserToolResult(text: "Missing 'selector' parameter", isError: true)
        }
        let resolved = resolveTab(arguments)
        guard let controller = resolved.controller else { return resolved.error! }
        if let restricted = checkAuthRestriction(controller) { return restricted }
        let js = BrowserAutomation.click(selector: selector)
        return await runJS(controller, js)
    }

    private func handleFill(_ arguments: [String: Any]?) async -> BrowserToolResult {
        guard let selector = arguments?["selector"] as? String,
              let value = arguments?["value"] as? String else {
            return BrowserToolResult(text: "Missing 'selector' or 'value' parameter", isError: true)
        }
        let resolved = resolveTab(arguments)
        guard let controller = resolved.controller else { return resolved.error! }
        if let restricted = checkAuthRestriction(controller) { return restricted }
        let js = BrowserAutomation.fill(selector: selector, value: value)
        return await runJS(controller, js)
    }

    private func handleType(_ arguments: [String: Any]?) async -> BrowserToolResult {
        guard let text = arguments?["text"] as? String else {
            return BrowserToolResult(text: "Missing 'text' parameter", isError: true)
        }
        let resolved = resolveTab(arguments)
        guard let controller = resolved.controller else { return resolved.error! }
        if let restricted = checkAuthRestriction(controller) { return restricted }
        let js = BrowserAutomation.type(text: text)
        return await runJS(controller, js)
    }

    private func handlePress(_ arguments: [String: Any]?) async -> BrowserToolResult {
        guard let key = arguments?["key"] as? String else {
            return BrowserToolResult(text: "Missing 'key' parameter", isError: true)
        }
        let resolved = resolveTab(arguments)
        guard let controller = resolved.controller else { return resolved.error! }
        if let restricted = checkAuthRestriction(controller) { return restricted }
        let js = BrowserAutomation.press(key: key)
        return await runJS(controller, js)
    }

    private func handleSelect(_ arguments: [String: Any]?) async -> BrowserToolResult {
        guard let selector = arguments?["selector"] as? String,
              let value = arguments?["value"] as? String else {
            return BrowserToolResult(text: "Missing 'selector' or 'value' parameter", isError: true)
        }
        let resolved = resolveTab(arguments)
        guard let controller = resolved.controller else { return resolved.error! }
        if let restricted = checkAuthRestriction(controller) { return restricted }
        let js = BrowserAutomation.select(selector: selector, value: value)
        return await runJS(controller, js)
    }

    private func handleCheck(_ arguments: [String: Any]?) async -> BrowserToolResult {
        guard let selector = arguments?["selector"] as? String else {
            return BrowserToolResult(text: "Missing 'selector' parameter", isError: true)
        }
        let resolved = resolveTab(arguments)
        guard let controller = resolved.controller else { return resolved.error! }
        if let restricted = checkAuthRestriction(controller) { return restricted }
        let js = BrowserAutomation.check(selector: selector)
        return await runJS(controller, js)
    }

    private func handleUncheck(_ arguments: [String: Any]?) async -> BrowserToolResult {
        guard let selector = arguments?["selector"] as? String else {
            return BrowserToolResult(text: "Missing 'selector' parameter", isError: true)
        }
        let resolved = resolveTab(arguments)
        guard let controller = resolved.controller else { return resolved.error! }
        if let restricted = checkAuthRestriction(controller) { return restricted }
        let js = BrowserAutomation.uncheck(selector: selector)
        return await runJS(controller, js)
    }

    private func handleWait(_ arguments: [String: Any]?) async -> BrowserToolResult {
        let selector = arguments?["selector"] as? String
        let text = arguments?["text"] as? String
        let url = arguments?["url"] as? String
        let timeout = arguments?["timeout"] as? Int ?? 5000

        guard selector != nil || text != nil || url != nil else {
            return BrowserToolResult(
                text: "At least one of 'selector', 'text', or 'url' must be provided",
                isError: true
            )
        }

        let resolved = resolveTab(arguments)
        guard let controller = resolved.controller else { return resolved.error! }
        let js = BrowserAutomation.wait(selector: selector, text: text, url: url, timeout: timeout)
        return await runJS(controller, js)
    }
}
