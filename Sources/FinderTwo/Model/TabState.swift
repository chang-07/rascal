import Foundation

/// One tab inside a pane: navigation history + its own DirectoryModel.
final class TabState {
    private(set) var currentURL: URL
    var backStack: [URL] = []
    var forwardStack: [URL] = []
    let model: DirectoryModel

    init(url: URL) {
        self.currentURL = url
        self.model = DirectoryModel(url: url)
    }

    func navigate(to url: URL) {
        guard url != currentURL else { return }
        backStack.append(currentURL)
        forwardStack.removeAll()
        currentURL = url
        model.navigate(to: url)
    }

    @discardableResult
    func goBack() -> Bool {
        guard let prev = backStack.popLast() else { return false }
        forwardStack.append(currentURL)
        currentURL = prev
        model.navigate(to: prev)
        return true
    }

    @discardableResult
    func goForward() -> Bool {
        guard let nxt = forwardStack.popLast() else { return false }
        backStack.append(currentURL)
        currentURL = nxt
        model.navigate(to: nxt)
        return true
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
}
