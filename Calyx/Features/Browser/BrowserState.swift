import Foundation

@MainActor @Observable
class BrowserState {
    var url: URL
    var isLoading: Bool = false
    var canGoBack: Bool = false
    var canGoForward: Bool = false
    var title: String
    var lastError: String?

    init(url: URL) {
        self.url = url
        self.title = url.host() ?? url.absoluteString
    }
}

struct BrowserSnapshot: Codable {
    let url: URL
}
