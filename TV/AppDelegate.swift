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
        router.resume = { [weak self] in self?.showBrowser() }
        testServer.onOpen = { [weak self] url in self?.open(url) }
        testServer.onCommand = { [weak self] command, reply in
            guard let self else { return reply(nil) }
            self.browser.debug(command, reply: reply)
        }
        testServer.start()
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
