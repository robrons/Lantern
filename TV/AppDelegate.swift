import SwiftUI
import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = RootViewController()
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}

/// Shows the home screen, with the browser presented over it. The browser is kept between
/// visits so Continue returns to the same page instantly.
final class RootViewController: UIViewController {
    private let library = Library.shared
    private let router = Router()
    private let testServer = TestServer()
    private lazy var home = UIHostingController(rootView: HomeView(library: library, router: router))
    private lazy var browser: BrowserViewController = {
        let browser = BrowserViewController(library: library)
        browser.onClose = { [weak self] in self?.showHome() }
        browser.onPageChange = { [weak self] site in self?.router.currentPage = site }
        browser.onTabsChange = { [weak self] sites, current in
            self?.router.tabs = sites
            self?.router.currentTabIndex = current
        }
        return browser
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(home)
        home.view.frame = view.bounds
        home.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(home.view)
        home.didMove(toParent: self)

        router.openURL = { [weak self] url in self?.open(url) }
        router.resume = { [weak self] in
            self?.browser.resumeCurrentTab()
            self?.showBrowser()
        }
        router.askForAddress = { [weak self] in
            guard let self else { return }
            let entry = TextEntryViewController(prompt: "Search or enter website", text: "", inputType: "search") { [weak self] text in
                if let text { self?.router.open(text: text) }
            }
            self.present(entry, animated: true)
        }
        router.resumeTab = { [weak self] index in
            self?.browser.resumeTab(at: index)
            self?.showBrowser()
        }
        testServer.onOpen = { [weak self] url in self?.open(url) }
        testServer.onCommand = { [weak self] command, reply in
            guard let self else { return reply(nil) }
            self.browser.debug(command, reply: reply)
        }
        testServer.start()

        // Testing from the Mac: `-LanternTour "<address>|<address>|..."` visits each page in turn,
        // scrolling it, and logs every visit, to find pages that crash without someone at the TV.
        if let tour = UserDefaults.standard.string(forKey: "LanternTour") {
            let pages = tour.split(separator: "|").compactMap { URL(string: String($0)) }
            let rounds = max(1, UserDefaults.standard.integer(forKey: "LanternTourRounds"))
            DispatchQueue.main.async { [weak self] in self?.runTour(Array(repeating: pages, count: rounds).flatMap { $0 }, step: 0) }
        }

        // Testing from the Mac: `devicectl ... launch com.robinronson.lantern -LanternOpenURL <address>`
        // opens that page straight away. Launch arguments aren't saved, so this never repeats.
        if let address = UserDefaults.standard.string(forKey: "LanternOpenURL"), let url = URL(string: address) {
            DispatchQueue.main.async { [weak self] in self?.open(url) }
        }
    }

    /// Visits each page for 35 seconds: loads it, then scrolls down a few times.
    private func runTour(_ pages: [URL], step: Int) {
        UIApplication.shared.isIdleTimerDisabled = step < pages.count
        guard step < pages.count else {
            PageHealthLog.record("tour", url: nil, detail: "finished")
            return
        }
        let url = pages[step]
        PageHealthLog.record("visit", url: url, detail: "page \(step + 1) of \(pages.count)")
        open(url)
        for (index, delay) in [12.0, 16.0, 20.0, 24.0, 28.0].enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                // Scroll back up on the last step so the next page starts clean.
                index < 4 ? self?.browser.tourScroll() : nil
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 35) { [weak self] in
            self?.runTour(pages, step: step + 1)
        }
    }

    private func open(_ url: URL) {
        browser.load(url)
        showBrowser()
    }

    private func showBrowser() {
        if browser.presentingViewController != nil { return }
        if let presented = presentedViewController {
            // Something else (like the keyboard) is up; replace it with the browser.
            presented.dismiss(animated: false) { [weak self] in self?.showBrowser() }
            return
        }
        present(browser, animated: true)
    }

    private func showHome() {
        browser.dismiss(animated: true)
    }
}
