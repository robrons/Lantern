import UIKit

/// One open tab. Only the tab on screen is guaranteed to have a page loaded: a tab you leave is
/// paused, then unloaded after a while (or straight away if the TV runs low on memory), keeping
/// just enough to bring it back where you left off.
final class BrowserTab {
    /// The loaded page, or nil while the tab is unloaded.
    var web: LanternWebView?
    var url: URL?
    var title = ""
    /// How far down the page you were, to restore after reloading an unloaded tab.
    var scrollY: CGFloat = 0
    var restoreScrollOnLoad = false
    /// Pages visited in this tab, newest last, so Back works even after a frozen page.
    var visitedPages: [URL] = []
    /// Unloads the tab once it has been in the background for a while.
    var unloadWork: DispatchWorkItem?

    var site: Site? {
        guard let url = web?.url ?? url else { return nil }
        let title = web?.title ?? self.title
        return Site(url: url, title: title, iconURL: nil, visited: Date())
    }
}
