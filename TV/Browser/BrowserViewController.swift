import SwiftUI
import UIKit

/// The page on screen. The Siri Remote drives a pointer: swipes move it, clicks are passed to
/// the page as mouse clicks, and the clickpad edges, Back and Play/Pause do what they do
/// elsewhere on tvOS.
final class BrowserViewController: UIViewController {
    var onClose: (() -> Void)?
    /// The page now open, for the home screen's Continue tile.
    var onPageChange: ((Site?) -> Void)?
    /// The open tabs and which one is on screen, for the home screen.
    var onTabsChange: (([Site], Int) -> Void)?

    private let library: Library
    /// Open tabs, at most three. The one on screen has its page loaded; the others are paused
    /// and then unloaded to save memory, and reload where you left off when you return.
    private var tabs: [BrowserTab] = []
    private var currentTabIndex = 0
    static let maxTabs = 3
    /// Set by New Tab: the next page you open from the home screen gets a tab of its own.
    private var openNextInNewTab = false
    private var currentTab: BrowserTab? { tabs.indices.contains(currentTabIndex) ? tabs[currentTabIndex] : nil }
    /// The page on screen.
    private var web: LanternWebView? { currentTab?.web }
    private let canvas = CanvasView()
    private let pointer = PointerView()
    private let progressBar = UIProgressView(progressViewStyle: .default)
    private let toast = ToastView()
    private let targetOutline = UIView()
    private let hint = RemoteHintView()
    private let toolbarModel = ToolbarModel()
    private lazy var toolbarHost = UIHostingController(rootView: BrowserToolbar(model: toolbarModel))

    private var pendingURL: URL?
    private var currentPageKey: String?
    private var toolbarVisible = false
    private var inTheater = false
    /// Set once the page has played audio or video, so Play/Pause controls it.
    private var mediaSeen = false

    // Pointer
    private var pointerPosition = CGPoint.zero
    private var pointerVisible = true
    private var trail: [(time: CFTimeInterval, point: CGPoint)] = []
    private var panStart: (time: CFTimeInterval, point: CGPoint)?
    private var lastTranslation = CGPoint.zero
    private var lastHover: CFTimeInterval = 0
    private var hoverWork: DispatchWorkItem?
    private var hideWork: DispatchWorkItem?
    /// Pointer movement too small to show yet; kept so slow, careful swipes still add up.
    private var pendingMove = CGPoint.zero
    /// Where the pointer is drawn. It glides toward `pointerPosition` each frame, so fast
    /// swipes look smooth instead of jumping.
    private var drawnPointer = CGPoint.zero
    private var pointerLink: CADisplayLink?
    /// A smoothed swipe speed, so the pointer's speed doesn't lurch from frame to frame.
    private var swipeSpeed: CGFloat = 0
    private var hoverInFlight = false
    private var hoverAgain = false

    // Scrolling
    /// Whether the pointer is over a scrollable box inside the page (scrolled by the page
    /// script) rather than the page itself (scrolled natively). Checked as each swipe starts.
    private var scrollsInnerBox = false
    private var scriptScrollInFlight = false
    private var pendingScriptScroll = CGPoint.zero

    // Keeping the page from being swamped
    /// Page script calls still waiting for an answer, with when each was sent.
    private var pendingCalls: [Int: CFTimeInterval] = [:]
    private var nextCallID = 0
    private var busyNoticeShown = false
    private var lastPageCrash: Date?
    /// What to do once a frozen page has been shut down (go back, go home, load something).
    private var afterFrozenPageStops: (() -> Void)?
    /// Pages visited in this session, newest last. Shutting down a frozen page also clears the
    /// engine's own back list, so Lantern keeps this to still be able to go back.
    private var visitedPages: [URL] {
        get { currentTab?.visitedPages ?? [] }
        set { currentTab?.visitedPages = newValue }
    }
    private var fullScreenTipPage: String?
    private var verificationNoticePage: String?

    // Pop-up windows (sign-ins). While one is open, the pointer and remote work in it.
    private var popup: LanternWebView?
    private let popupBackdrop = UIView()
    private let popupTitle = UILabel()
    /// The page the remote is working in: an open pop-up, otherwise the main page.
    private var activeWeb: LanternWebView? { popup ?? web }

    // Presses the browser has taken charge of, so their release is handled here too.
    private var ownedPresses = Set<ObjectIdentifier>()
    private var clickPoint: CGPoint?
    private var longPressWork: DispatchWorkItem?
    private var longPressFired = false

    private static let hintCountKey = "remoteHintShown"
    private static let pointerSpeedKey = "pointerSpeedSetting"
    private static let pointerSpeeds: [(name: String, value: CGFloat)] = [("Slow", 0.6), ("Normal", 1), ("Fast", 1.6)]
    private var pointerSpeed: CGFloat {
        get {
            let stored = UserDefaults.standard.double(forKey: Self.pointerSpeedKey)
            return stored > 0 ? stored : 1
        }
        set { UserDefaults.standard.set(Double(newValue), forKey: Self.pointerSpeedKey) }
    }
    /// What "100%" means underneath. Pages lay out to the TV's full width, where text is as
    /// small as on a computer screen; 1.5x makes 100% comfortable from the couch.
    static let baseZoom: CGFloat = 1.5

    /// The current page's zoom as shown in the menu; each site remembers its own.
    private var zoom: CGFloat {
        web?.url.map(library.zoom(for:)) ?? 1
    }

    init(library: Library) {
        self.library = library
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = canvas
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        guard LanternWebView.isEngineAvailable() else {
            let label = UILabel()
            label.text = "This Apple TV's web engine couldn't be loaded."
            label.textColor = .white
            label.textAlignment = .center
            label.frame = view.bounds
            label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(label)
            return
        }

        NotificationCenter.default.addObserver(self, selector: #selector(memoryIsLow),
                                               name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(leftLantern),
                                               name: UIApplication.didEnterBackgroundNotification, object: nil)

        progressBar.trackTintColor = .clear
        progressBar.progressTintColor = .systemBlue
        progressBar.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: 8)
        progressBar.autoresizingMask = [.flexibleWidth]
        progressBar.alpha = 0
        view.addSubview(progressBar)

        targetOutline.isUserInteractionEnabled = false
        targetOutline.layer.borderColor = UIColor.white.cgColor
        targetOutline.layer.borderWidth = 4
        targetOutline.layer.cornerRadius = 12
        targetOutline.layer.shadowColor = UIColor.black.cgColor
        targetOutline.layer.shadowOpacity = 0.5
        targetOutline.layer.shadowRadius = 10
        targetOutline.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        targetOutline.alpha = 0
        view.addSubview(targetOutline)
        view.addSubview(pointer)

        toast.translatesAutoresizingMaskIntoConstraints = false
        hint.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(toast)
        view.addSubview(hint)
        NSLayoutConstraint.activate([
            toast.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            toast.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -80),
            hint.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            hint.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -80),
        ])

        addChild(toolbarHost)
        toolbarHost.view.frame = view.bounds
        toolbarHost.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        toolbarHost.view.backgroundColor = .clear
        toolbarHost.view.isHidden = true
        view.addSubview(toolbarHost.view)
        toolbarHost.didMove(toParent: self)
        toolbarModel.perform = { [weak self] action in self?.perform(action) }

        let link = CADisplayLink(target: self, selector: #selector(stepPointer))
        link.add(to: .main, forMode: .common)
        pointerLink = link

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        view.addGestureRecognizer(pan)

        if let pendingURL {
            self.pendingURL = nil
            load(pendingURL)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // The view has no size until its first layout; start the pointer in the middle.
        if pointerPosition == .zero, view.bounds.width > 0 {
            setPointer(CGPoint(x: view.bounds.midX, y: view.bounds.midY))
            drawnPointer = pointerPosition
            pointer.center = drawnPointer
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        let shown = UserDefaults.standard.integer(forKey: Self.hintCountKey)
        if shown < 3 {
            UserDefaults.standard.set(shown + 1, forKey: Self.hintCountKey)
            hint.show()
        }
        showPointer()
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        toolbarVisible ? [toolbarHost] : [canvas]
    }

    // MARK: Pages

    func load(_ url: URL) {
        guard isViewLoaded, LanternWebView.isEngineAvailable() else {
            pendingURL = url
            return
        }
        hideToolbar()
        if inTheater { setTheater(false) }
        if tabs.isEmpty || (openNextInNewTab && tabs.count < Self.maxTabs) {
            openNextInNewTab = false
            tabs.append(BrowserTab())
            switchToTab(at: tabs.count - 1, loading: url)
            return
        }
        openNextInNewTab = false
        guard let tab = currentTab else { return }
        loadedPage(for: tab).loadURL(url)
    }

    /// Returns to the tab you were on (the home screen's Continue tile).
    func resumeCurrentTab() {
        openNextInNewTab = false
        if let tab = currentTab, tab.web == nil { switchToTab(at: currentTabIndex) }
    }

    /// Opens one of the tabs from the home screen.
    func resumeTab(at index: Int) {
        openNextInNewTab = false
        switchToTab(at: index)
    }

    private func makePage() -> LanternWebView {
        let web = LanternWebView(frame: view.bounds, isolatedScript: PageScripts.isolated, pageScript: PageScripts.page)
        web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        web.delegate = self
        web.desktopUserAgent = UserAgent.desktopSafari
        web.mobileUserAgent = UserAgent.iPhoneSafari
        web.prefersMobileSite = { [weak self] url in self?.library.prefersMobileSite(url) ?? false }
        web.layoutZoom = Self.baseZoom
        web.installContentRules(ContentRules.blockedDomains)
        return web
    }

    /// The tab's page, creating it if the tab was unloaded.
    private func loadedPage(for tab: BrowserTab) -> LanternWebView {
        if let web = tab.web { return web }
        let web = makePage()
        tab.web = web
        view.insertSubview(web, at: 0)
        return web
    }

    private func switchToTab(at index: Int, loading url: URL? = nil) {
        guard tabs.indices.contains(index) else { return }
        closePopup()
        if index != currentTabIndex, let leaving = currentTab {
            sendToBackground(leaving)
        }
        currentTabIndex = index
        let tab = tabs[index]
        tab.unloadWork?.cancel()
        let wasUnloaded = tab.web == nil
        let page = loadedPage(for: tab)
        page.isHidden = false
        if let url {
            page.loadURL(url)
        } else if wasUnloaded, let saved = tab.url {
            tab.restoreScrollOnLoad = true
            page.loadURL(saved)
        }
        for other in tabs where other !== tab { other.web?.isHidden = true }

        // Start fresh for the page now on screen.
        currentPageKey = nil
        resetPageWork()
        mediaSeen = false
        if inTheater { setTheater(false) }
        webViewStateDidChange(page)
        publishTabs()
        showPointer()
    }

    /// Pauses a tab you've left and unloads it after 20 seconds, freeing its memory.
    private func sendToBackground(_ tab: BrowserTab) {
        guard let page = tab.web else { return }
        run(PageScripts.call("media", "pause"), in: page)
        tab.url = page.url ?? tab.url
        tab.title = page.title ?? tab.title
        tab.scrollY = page.scrollView?.contentOffset.y ?? tab.scrollY
        page.isHidden = true
        let work = DispatchWorkItem { [weak self, weak tab] in
            guard let self, let tab, tab !== self.currentTab else { return }
            self.unload(tab)
        }
        tab.unloadWork?.cancel()
        tab.unloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: work)
    }

    private func unload(_ tab: BrowserTab) {
        guard let page = tab.web else { return }
        tab.url = page.url ?? tab.url
        tab.title = page.title ?? tab.title
        tab.scrollY = page.scrollView?.contentOffset.y ?? tab.scrollY
        page.delegate = nil
        page.removeFromSuperview()
        tab.web = nil
    }

    /// The TV is running low on memory: unload every tab that isn't on screen.
    @objc private func memoryIsLow() {
        for tab in tabs where tab !== currentTab { unload(tab) }
        LanternWebView.clearEngineMemoryCaches()
        library.clearMemoryCaches()
        Task { await IconLoader.shared.clear() }
    }

    /// You switched to another app: pause the video and keep only the tab you were on, so
    /// Lantern takes up as little memory as possible while you're away.
    @objc private func leftLantern() {
        if let page = web { run(PageScripts.call("media", "pause"), in: page) }
        for tab in tabs where tab !== currentTab { unload(tab) }
        LanternWebView.clearEngineMemoryCaches()
        library.clearMemoryCaches()
    }

    private func startNewTab() {
        guard tabs.count < Self.maxTabs else {
            toast.show("Lantern keeps up to \(Self.maxTabs) tabs. Close one first.", for: 3)
            return
        }
        openNextInNewTab = true
        close()
    }

    private func closeTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        let tab = tabs[index]
        tab.unloadWork?.cancel()
        closePopup()
        unload(tab)
        tabs.remove(at: index)
        if tabs.isEmpty {
            currentTabIndex = 0
            currentPageKey = nil
            onPageChange?(nil)
            publishTabs()
            close()
            return
        }
        // No tab is on screen any more, so there is nothing to send to the background.
        currentTabIndex = -1
        switchToTab(at: min(index, tabs.count - 1))
    }

    private func publishTabs() {
        let sites = tabs.compactMap(\.site)
        onTabsChange?(sites, max(0, currentTabIndex))
        toolbarModel.tabTitles = tabs.map { tab in
            let title = tab.web?.title ?? tab.title
            return title.isEmpty ? (tab.site?.host ?? "New Tab") : title
        }
        toolbarModel.currentTab = currentTabIndex
        toolbarModel.canAddTab = tabs.count < Self.maxTabs
    }

    private func tab(for page: LanternWebView) -> BrowserTab? {
        tabs.first { $0.web === page }
    }

    private var currentSite: Site? {
        guard let web, let url = web.url else { return nil }
        return Site(url: url, title: web.title ?? "", iconURL: nil, visited: Date())
    }

    private func close() {
        hideToolbar()
        hint.hide()
        saveSnapshot()
        onClose?()
    }

    private func saveSnapshot() {
        guard let web, let url = web.url else { return }
        web.takeSnapshot(withWidth: 640) { [weak self] image in
            guard let image else { return }
            self?.library.saveSnapshot(image, for: url)
        }
    }

    /// The pointer in the active page's own coordinates, and that page's width.
    private func pagePoint(_ point: CGPoint) -> CGPoint {
        guard let page = activeWeb else { return point }
        return view.convert(point, to: page)
    }

    private var pageWidth: CGFloat { activeWeb?.bounds.width ?? view.bounds.width }

    /// Runs a script in the page the remote is working in (or `target`, if given).
    private func run(_ script: String, in target: LanternWebView? = nil, completion: ((Any?) -> Void)? = nil) {
        guard let web = target ?? activeWeb else {
            completion?(nil)
            return
        }
        let id = nextCallID
        nextCallID += 1
        pendingCalls[id] = CACurrentMediaTime()
        web.evaluateJavaScript(script) { [weak self] result, _ in
            if let self {
                self.pendingCalls[id] = nil
                if self.pendingCalls.isEmpty { self.busyNoticeShown = false }
            }
            completion?(result)
        }
    }

    /// Whether the page is keeping up. A page that hasn't answered for a few seconds gets no
    /// more work until it catches up, so it can never be buried under a backlog; Back, Home and
    /// the menu keep working regardless.
    private func pageIsResponsive() -> Bool {
        guard let oldest = pendingCalls.values.min(), CACurrentMediaTime() - oldest > 3 else { return true }
        if !busyNoticeShown {
            busyNoticeShown = true
            toast.show("This page isn't responding. Press Back to leave it, or hold the click and choose Reload.", for: 6)
        }
        return false
    }

    /// Leaves the current page with `action`. If the page has frozen, the engine would wait for
    /// it forever, so when it doesn't answer within a few seconds Lantern shuts it down and runs
    /// `afterStopping` instead (by default, `action` again).
    private func leavePage(_ action: @escaping () -> Void, afterStopping: (() -> Void)? = nil) {
        action()
        guard web != nil, afterFrozenPageStops == nil else { return }
        var answered = false
        run("true") { _ in answered = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, !answered, let web = self.web, self.afterFrozenPageStops == nil else { return }
            self.afterFrozenPageStops = afterStopping ?? action
            self.toast.show("This page froze, so Lantern closed it.", for: 4)
            web.stopFrozenPage()
        }
    }

    /// Goes back a page, even from a page that has frozen.
    private func goBackOnePage() {
        guard let web else { return }
        // Decided now, before shutting a frozen page down shuffles the engine's own history.
        let previous = visitedPages.count >= 2 ? visitedPages[visitedPages.count - 2] : nil
        leavePage({ web.goBack() }, afterStopping: { [weak self] in
            guard let self else { return }
            if let previous {
                self.load(previous)
            } else {
                self.close()
            }
        })
    }

    /// Notes each new page so Lantern can go back without the engine's help.
    private func notePageVisit(_ url: URL) {
        if visitedPages.count >= 2, Library.key(for: visitedPages[visitedPages.count - 2]) == Library.key(for: url) {
            visitedPages.removeLast()
        } else if visitedPages.last.map({ Library.key(for: $0) }) != Library.key(for: url) {
            visitedPages.append(url)
            if visitedPages.count > 50 { visitedPages.removeFirst() }
        }
    }

    /// Shows a window a page opened, over the page, until it closes itself or you press Back.
    private func showPopup(_ newPopup: LanternWebView) {
        closePopup()
        hideToolbar()
        hideTargetOutline()
        popup = newPopup
        newPopup.delegate = self
        newPopup.layoutZoom = Self.baseZoom

        popupBackdrop.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        popupBackdrop.frame = view.bounds
        popupBackdrop.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        popupTitle.textColor = .white
        popupTitle.font = .preferredFont(forTextStyle: .callout)
        popupTitle.textAlignment = .center
        popupTitle.frame = CGRect(x: 0, y: 40, width: view.bounds.width, height: 50)
        popupTitle.autoresizingMask = [.flexibleWidth]
        popupTitle.text = "Opening a window\u{2026}"
        popupBackdrop.addSubview(popupTitle)

        newPopup.frame = view.bounds.inset(by: UIEdgeInsets(top: 110, left: 180, bottom: 70, right: 180))
        newPopup.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        newPopup.layer.cornerRadius = 24
        newPopup.clipsToBounds = true
        popupBackdrop.addSubview(newPopup)
        if let web {
            view.insertSubview(popupBackdrop, aboveSubview: web)
        }
        popupBackdrop.alpha = 0
        UIView.animate(withDuration: 0.25) { self.popupBackdrop.alpha = 1 }
        resetPageWork()
        showPointer()
    }

    private func closePopup() {
        guard let closing = popup else { return }
        popup = nil
        resetPageWork()
        hideTargetOutline()
        scheduleHover(after: 0.3)
        UIView.animate(withDuration: 0.2, animations: {
            self.popupBackdrop.alpha = 0
        }, completion: { _ in
            closing.removeFromSuperview()
            if self.popup == nil { self.popupBackdrop.removeFromSuperview() }
        })
        showPointer()
    }

    private func updatePopupTitle() {
        guard let popup else { return }
        let host = popup.url?.host ?? ""
        popupTitle.text = host.isEmpty ? "Window" : "\(host) \u{2014} press Back to close"
    }

    /// Forgets work sent to a page that has gone away.
    private func resetPageWork() {
        pendingCalls.removeAll()
        busyNoticeShown = false
        hoverInFlight = false
        hoverAgain = false
        scriptScrollInFlight = false
        pendingScriptScroll = .zero
    }

    // MARK: Remote buttons

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        for press in presses {
            if canHandle(press) {
                ownedPresses.insert(ObjectIdentifier(press))
                pressBegan(press.type)
            } else {
                unhandled.insert(press)
            }
        }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        for press in presses {
            if ownedPresses.remove(ObjectIdentifier(press)) != nil {
                pressEnded(press.type)
            } else {
                unhandled.insert(press)
            }
        }
        if !unhandled.isEmpty { super.pressesEnded(unhandled, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        for press in presses {
            if ownedPresses.remove(ObjectIdentifier(press)) != nil {
                if press.type == .select { cancelSelect() }
            } else {
                unhandled.insert(press)
            }
        }
        if !unhandled.isEmpty { super.pressesCancelled(unhandled, with: event) }
    }

    private func canHandle(_ press: UIPress) -> Bool {
        guard web != nil, presentedViewController == nil else { return false }
        // Back always stays inside the browser, so it can never drop you out of Lantern.
        if press.type == .menu { return true }
        guard !toolbarVisible else { return false }
        switch press.type {
        case .select, .menu, .playPause, .upArrow, .downArrow, .leftArrow, .rightArrow:
            return true
        default:
            return false
        }
    }

    private func pressBegan(_ type: UIPress.PressType) {
        switch type {
        case .select:
            // Fingers drift as they press; click where the pointer was a moment before.
            clickPoint = pointerPoint(before: 0.08)
            pointer.setPressed(true)
            // Holding the click opens the menu.
            startLongPress { [weak self] in
                self?.pointer.setPressed(false)
                self?.showToolbar()
            }
        case .playPause:
            // Holding Play/Pause switches full-screen video on or off.
            startLongPress { [weak self] in self?.toggleFullScreen() }
        default:
            break
        }
    }

    private func startLongPress(_ action: @escaping () -> Void) {
        longPressWork?.cancel()
        longPressFired = false
        let work = DispatchWorkItem { [weak self] in
            self?.longPressFired = true
            action()
        }
        longPressWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    /// Full screen for the page's video: Apple's player when the video has a real stream
    /// address, otherwise the page's own video stretched over the screen.
    private func toggleFullScreen() {
        if inTheater {
            run(PageScripts.call("exitTheater"))
            setTheater(false)
        } else {
            run(PageScripts.call("fullScreen")) { [weak self] result in
                if result as? Bool != true { self?.toast.show("There's no video on this page.") }
            }
        }
    }

    private func playInNativePlayer(_ body: [String: Any]) {
        guard presentedViewController == nil, let web,
              let source = body["src"] as? String, let url = URL(string: source)
        else { return }
        hideToolbar()
        hideTargetOutline()
        let request = NativePlayerViewController.Request(
            url: url,
            startTime: body["time"] as? Double ?? 0,
            isLive: body["live"] as? Bool == true,
            pageURL: (body["page"] as? String).flatMap(URL.init(string:)),
            userAgent: body["agent"] as? String
        )
        web.fetchCookies { [weak self] cookies in
            guard let self, self.presentedViewController == nil else { return }
            let player = NativePlayerViewController(request: request, cookies: cookies)
            player.onClose = { [weak self] seconds in
                self?.run(PageScripts.call("resumeAt", seconds))
                self?.showPointer()
            }
            player.onFailure = { [weak self] in
                // The stream refused to play outside the page; fill the screen with it instead.
                self?.run(PageScripts.call("theater"))
            }
            self.present(player, animated: true)
        }
    }

    private func pressEnded(_ type: UIPress.PressType) {
        hint.hide()
        switch type {
        case .select:
            longPressWork?.cancel()
            pointer.setPressed(false)
            guard !longPressFired else { return }
            if inTheater && !pointerVisible {
                run(PageScripts.call("media", "toggle"))
            } else if !pointerVisible {
                showPointer()
            } else {
                click()
            }
        case .menu:
            if toolbarVisible {
                hideToolbar()
            } else {
                goBack()
            }
        case .playPause:
            longPressWork?.cancel()
            guard !longPressFired else { return }
            if inTheater || mediaSeen {
                run(PageScripts.call("media", "toggle"))
            } else {
                toast.show("Nothing is playing. Hold the click to open the menu.", for: 3)
            }
        case .upArrow:
            if !inTheater { pageScroll(-1) }
        case .downArrow:
            if !inTheater { pageScroll(1) }
        case .leftArrow:
            if inTheater { run(PageScripts.call("media", "seek", -10.0)) } else { scroll(dx: -view.bounds.width * 0.25, dy: 0, smooth: true) }
        case .rightArrow:
            if inTheater { run(PageScripts.call("media", "seek", 10.0)) } else { scroll(dx: view.bounds.width * 0.25, dy: 0, smooth: true) }
        default:
            break
        }
    }

    private func cancelSelect() {
        longPressWork?.cancel()
        pointer.setPressed(false)
    }

    private func goBack() {
        if let popup {
            if popup.canGoBack { popup.goBack() } else { closePopup() }
            return
        }
        if inTheater {
            run(PageScripts.call("exitTheater"))
            setTheater(false)
        } else if let web, web.canGoBack {
            goBackOnePage()
        } else {
            leavePage { [weak self] in self?.close() }
        }
    }

    private func click() {
        let point = clickPoint ?? pointerPosition
        clickPoint = nil
        setPointer(point)
        pointer.pulse()
        scheduleHide()
        guard pageIsResponsive() else { return }
        let target = pagePoint(point)
        run(PageScripts.call("click", target.x, target.y, pageWidth))
    }

    /// Test-only: scrolls down a step, as the page tour does to exercise each page.
    func tourScroll() {
        pageScroll(1)
    }

    /// Clicking the top or bottom of the clickpad scrolls about a quarter of a screen, little
    /// enough that you don't lose your place.
    private func pageScroll(_ direction: Int) {
        checkScroller { [weak self] in
            guard let self else { return }
            self.scroll(dx: 0, dy: CGFloat(direction) * self.view.bounds.height * 0.25, smooth: true)
        }
    }

    /// Finds out whether the pointer is over a scrollable box inside the page.
    private func checkScroller(then action: (() -> Void)? = nil) {
        guard pageIsResponsive() else { return }
        let target = pagePoint(pointerPosition)
        run(PageScripts.call("scroller", target.x, target.y, pageWidth)) { [weak self] result in
            self?.scrollsInnerBox = result as? String == "inner"
            action?()
        }
    }

    private func scroll(dx: CGFloat, dy: CGFloat, smooth: Bool) {
        if !scrollsInnerBox, scrollPageNatively(dx: dx, dy: dy, animated: smooth) { return }
        scrollWithScript(dx: dx, dy: dy, smooth: smooth)
    }

    /// Scrolls the whole page with Apple's own scrolling: smooth, and no round trip to the page.
    /// Returns false when the page itself doesn't scroll (some sites scroll a box instead).
    private func scrollPageNatively(dx: CGFloat, dy: CGFloat, animated: Bool) -> Bool {
        guard let scrollView = activeWeb?.scrollView else { return false }
        let size = scrollView.contentSize
        let bounds = scrollView.bounds.size
        let scrollsVertically = size.height > bounds.height + 1
        let scrollsHorizontally = size.width > bounds.width + 1
        guard (dy != 0 && scrollsVertically) || (dx != 0 && scrollsHorizontally) else { return false }
        let current = scrollView.contentOffset
        let target = CGPoint(
            x: min(max(current.x + dx, 0), max(0, size.width - bounds.width)),
            y: min(max(current.y + dy, 0), max(0, size.height - bounds.height))
        )
        if target != current {
            scrollView.setContentOffset(target, animated: animated)
        }
        // What's under the pointer has moved.
        scheduleHover(after: animated ? 0.4 : 0.12)
        return true
    }

    /// Scrolls a box inside the page through the page script. Requests are combined while one
    /// is on its way, so a busy page gets one scroll instead of a backlog of them.
    private func scrollWithScript(dx: CGFloat, dy: CGFloat, smooth: Bool) {
        pendingScriptScroll.x += dx
        pendingScriptScroll.y += dy
        guard !scriptScrollInFlight, pendingScriptScroll != .zero, pageIsResponsive() else { return }
        let amount = pendingScriptScroll
        pendingScriptScroll = .zero
        scriptScrollInFlight = true
        let target = pagePoint(pointerPosition)
        run(PageScripts.call("scroll", target.x, target.y, amount.x, amount.y, pageWidth, smooth)) { [weak self] _ in
            guard let self else { return }
            self.scriptScrollInFlight = false
            self.scheduleHover(after: smooth ? 0.45 : 0.1)
            if self.pendingScriptScroll != .zero {
                self.scrollWithScript(dx: 0, dy: 0, smooth: smooth)
            }
        }
    }

    // MARK: Pointer

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard !toolbarVisible, presentedViewController == nil else { return }
        let now = CACurrentMediaTime()
        switch gesture.state {
        case .began:
            panStart = (now, pointerPosition)
            lastTranslation = .zero
            pendingMove = .zero
            swipeSpeed = 0
            hint.hide()
            showPointer()
            checkScroller()
        case .changed:
            let translation = gesture.translation(in: view)
            let delta = CGPoint(x: translation.x - lastTranslation.x, y: translation.y - lastTranslation.y)
            lastTranslation = translation
            let velocity = gesture.velocity(in: view)
            swipeSpeed = swipeSpeed * 0.8 + hypot(velocity.x, velocity.y) * 0.2
            // A steady speed, with a little extra reach on long, fast swipes.
            let gain = (0.17 + min(swipeSpeed / 9000, 0.13)) * pointerSpeed
            pendingMove.x += delta.x * gain
            pendingMove.y += delta.y * gain
            // Ignore sub-point twitches from a resting thumb; they still count once they add up.
            if hypot(pendingMove.x, pendingMove.y) >= 1 {
                movePointer(by: pendingMove)
                pendingMove = .zero
            }
        case .ended, .cancelled:
            let velocity = gesture.velocity(in: view)
            if let start = panStart, now - start.time < 0.2, abs(velocity.y) > 3200, abs(velocity.y) > abs(velocity.x) * 2.5 {
                // A quick, deliberate flick scrolls the page instead of moving the pointer, by at
                // most about a quarter of a screen so you don't lose your place.
                setPointer(start.point)
                let reach = view.bounds.height * 0.25
                scroll(dx: 0, dy: max(-reach, min(reach, velocity.y * 0.08)), smooth: true)
                hideTargetOutline()
            }
            panStart = nil
            scheduleHide()
        default:
            break
        }
    }

    private func movePointer(by delta: CGPoint) {
        let bounds = view.bounds.insetBy(dx: 6, dy: 6)
        var point = CGPoint(x: pointerPosition.x + delta.x, y: pointerPosition.y + delta.y)
        var overflow = CGPoint.zero
        if point.x < bounds.minX {
            overflow.x = point.x - bounds.minX
            point.x = bounds.minX
        } else if point.x > bounds.maxX {
            overflow.x = point.x - bounds.maxX
            point.x = bounds.maxX
        }
        if point.y < bounds.minY {
            overflow.y = point.y - bounds.minY
            point.y = bounds.minY
        } else if point.y > bounds.maxY {
            overflow.y = point.y - bounds.maxY
            point.y = bounds.maxY
        }
        setPointer(point)
        // Pushing past an edge scrolls the page that way.
        if overflow != .zero && !inTheater {
            scroll(dx: overflow.x * 1.2, dy: overflow.y * 1.2, smooth: false)
        }
        scheduleHover()
    }

    private func setPointer(_ point: CGPoint) {
        pointerPosition = point
        let now = CACurrentMediaTime()
        trail.append((now, point))
        trail.removeAll { now - $0.time > 0.4 }
    }

    /// Eases the drawn pointer toward its real position, once per screen refresh.
    @objc private func stepPointer() {
        let dx = pointerPosition.x - drawnPointer.x
        let dy = pointerPosition.y - drawnPointer.y
        guard dx != 0 || dy != 0 else { return }
        if abs(dx) < 0.5 && abs(dy) < 0.5 {
            drawnPointer = pointerPosition
        } else {
            drawnPointer.x += dx * 0.45
            drawnPointer.y += dy * 0.45
        }
        pointer.center = drawnPointer
    }

    private func pointerPoint(before interval: CFTimeInterval) -> CGPoint {
        let cutoff = CACurrentMediaTime() - interval
        return trail.last(where: { $0.time <= cutoff })?.point ?? trail.first?.point ?? pointerPosition
    }

    private func scheduleHover(after delay: CFTimeInterval = 0) {
        hoverWork?.cancel()
        let wait = max(delay, 0.1 - (CACurrentMediaTime() - lastHover))
        let work = DispatchWorkItem { [weak self] in self?.hover() }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
    }

    /// Notes how far down the page you are, so a page tvOS had to stop can come back there.
    private func rememberScrollPosition() {
        guard let tab = currentTab, let y = tab.web?.scrollView?.contentOffset.y, y > 0 else { return }
        tab.scrollY = y
    }

    private func hover() {
        rememberScrollPosition()
        // One check at a time: if the page is slow to answer, the next check simply waits.
        guard !hoverInFlight else {
            hoverAgain = true
            return
        }
        guard pageIsResponsive() else { return }
        hoverInFlight = true
        lastHover = CACurrentMediaTime()
        let target = pagePoint(pointerPosition)
        let page = activeWeb
        run(PageScripts.call("hover", target.x, target.y, pageWidth)) { [weak self] result in
            guard let self else { return }
            self.hoverInFlight = false
            if self.hoverAgain {
                self.hoverAgain = false
                self.scheduleHover()
            }
            let info = result as? [String: Any]
            self.pointer.style = (info?["kind"] as? String).flatMap(PointerView.Style.init(rawValue:)) ?? .normal
            let rect = (info?["rect"] as? [NSNumber])?.map { CGFloat($0.doubleValue) }
            if let rect, rect.count == 4, self.pointerVisible, !self.toolbarVisible, !self.inTheater {
                let pageRect = CGRect(x: rect[0], y: rect[1], width: rect[2], height: rect[3])
                self.showTargetOutline(page.map { $0.convert(pageRect, to: self.view) } ?? pageRect)
            } else {
                self.hideTargetOutline()
            }
        }
    }

    /// Outlines what a click will select, like a focused item elsewhere on tvOS.
    private func showTargetOutline(_ rect: CGRect) {
        let frame = rect.insetBy(dx: -8, dy: -6)
        if targetOutline.alpha == 0 {
            targetOutline.frame = frame
            UIView.animate(withDuration: 0.15) { self.targetOutline.alpha = 1 }
        } else {
            UIView.animate(withDuration: 0.15, delay: 0, options: [.beginFromCurrentState]) {
                self.targetOutline.frame = frame
            }
        }
    }

    private func hideTargetOutline() {
        guard targetOutline.alpha > 0 else { return }
        UIView.animate(withDuration: 0.15) { self.targetOutline.alpha = 0 }
    }

    private func showPointer() {
        guard !toolbarVisible else { return }
        pointerVisible = true
        UIView.animate(withDuration: 0.15) { self.pointer.alpha = 1 }
        scheduleHide()
    }

    private func scheduleHide() {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hidePointer() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (inTheater ? 2.5 : 6), execute: work)
    }

    private func hidePointer() {
        hideWork?.cancel()
        pointerVisible = false
        UIView.animate(withDuration: 0.4) { self.pointer.alpha = 0 }
        hideTargetOutline()
    }

    private func setTheater(_ on: Bool) {
        inTheater = on
        if on {
            hideToolbar()
            hidePointer()
            progressBar.alpha = 0
        } else {
            showPointer()
        }
    }

    // MARK: Menu

    private func showToolbar() {
        guard !toolbarVisible, web != nil else { return }
        refreshToolbar()
        toolbarVisible = true
        canvas.focusable = false
        hidePointer()
        hint.hide()
        toolbarHost.view.alpha = 0
        toolbarHost.view.isHidden = false
        UIView.animate(withDuration: 0.2) { self.toolbarHost.view.alpha = 1 }
        toolbarModel.openCount += 1
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    private func hideToolbar() {
        guard toolbarVisible else { return }
        toolbarVisible = false
        canvas.focusable = true
        UIView.animate(withDuration: 0.2, animations: {
            self.toolbarHost.view.alpha = 0
        }, completion: { _ in
            if !self.toolbarVisible { self.toolbarHost.view.isHidden = true }
        })
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
        showPointer()
    }

    private func refreshToolbar() {
        guard let web else { return }
        toolbarModel.address = web.url?.absoluteString ?? ""
        toolbarModel.canGoBack = web.canGoBack
        toolbarModel.canGoForward = web.canGoForward
        toolbarModel.isLoading = web.isLoading
        toolbarModel.isFavorite = web.url.map(library.isFavorite) ?? false
        toolbarModel.isMobileSite = web.url.map(library.prefersMobileSite) ?? false
        toolbarModel.zoomText = "\(Int((zoom * 100).rounded()))%"
        toolbarModel.pointerSpeedName = Self.pointerSpeeds.first { $0.value == pointerSpeed }?.name ?? "Normal"
    }

    private func perform(_ action: ToolbarAction) {
        guard let web else { return }
        switch action {
        case .home:
            leavePage { [weak self] in self?.close() }
        case .back:
            hideToolbar()
            goBackOnePage()
        case .forward:
            hideToolbar()
            leavePage { web.goForward() }
        case .reload:
            hideToolbar()
            let current = web.url
            leavePage({ web.reload() }, afterStopping: { [weak self] in
                if let current { self?.load(current) }
            })
        case .stop:
            web.stopLoading()
            refreshToolbar()
        case .editAddress:
            hideToolbar()
            let current = web.url?.host ?? ""
            let entry = TextEntryViewController(prompt: current.isEmpty ? "Search or enter website" : "Search or enter website (now \(current))",
                                                text: "", inputType: "search") { [weak self] text in
                guard let self, let text, let url = URLInput.resolve(text) else { return }
                self.leavePage { [weak self] in self?.load(url) }
            }
            present(entry, animated: true)
        case .favorite:
            guard let url = web.url else { return }
            run(PageScripts.call("info")) { [weak self] result in
                guard let self else { return }
                let icon = ((result as? [String: Any])?["icon"] as? String).flatMap(URL.init(string:))
                self.library.toggleFavorite(url: url, title: web.title ?? "", iconURL: icon)
                self.refreshToolbar()
                self.toast.show(self.library.isFavorite(url) ? "Added to Favorites" : "Removed from Favorites", for: 2)
            }
        case .theater:
            hideToolbar()
            toggleFullScreen()
        case .siteVersion:
            guard let url = web.url else { return }
            setMobileSite(!library.prefersMobileSite(url), for: url)
        case .pointerSpeed:
            let speeds = Self.pointerSpeeds
            let index = speeds.firstIndex { $0.value == pointerSpeed } ?? 1
            pointerSpeed = speeds[(index + 1) % speeds.count].value
            refreshToolbar()
        case .zoomIn, .zoomOut:
            let step: CGFloat = action.isZoomIn ? 0.1 : -0.1
            guard let url = web.url else { return }
            let newZoom = max(0.5, min(2.5, ((zoom + step) * 10).rounded() / 10))
            library.setZoom(newZoom, for: url)
            web.layoutZoom = newZoom * Self.baseZoom
            refreshToolbar()
        case .selectTab(let index):
            hideToolbar()
            if index != currentTabIndex { switchToTab(at: index) }
        case .newTab:
            hideToolbar()
            startNewTab()
        case .closeTab:
            hideToolbar()
            closeTab(at: currentTabIndex)
        case .help:
            hideToolbar()
            hint.show(for: 12)
        case .dismiss:
            hideToolbar()
        }
    }

    /// Switches a site between its desktop and mobile versions and reloads it.
    private func setMobileSite(_ mobile: Bool, for url: URL) {
        library.setPrefersMobileSite(mobile, for: url)
        hideToolbar()
        toast.show(mobile ? "Showing the mobile site. Videos often play better there." : "Showing the desktop site.", for: 3)
        web?.loadURL(url)
    }

    // MARK: Messages from the page

    private func handle(message body: [String: Any]) {
        switch body["type"] as? String {
        case "input":
            presentTextEntry(body)
        case "select":
            presentChoices(body)
        case "media":
            mediaSeen = true
            if body["playing"] as? Bool == true, !inTheater, presentedViewController == nil,
               let page = currentPageKey, fullScreenTipPage != page {
                fullScreenTipPage = page
                toast.show("Hold Play/Pause to watch full screen.", for: 4)
            }
        case "video":
            playInNativePlayer(body)
        case "theater":
            setTheater(body["on"] as? Bool == true)
        case "verification":
            if let page = currentPageKey, verificationNoticePage != page {
                verificationNoticePage = page
                toast.show("Lantern can\u{2019}t click \u{201C}verify you\u{2019}re human\u{201D} checks; they need a real touch. Some pass on their own after a few seconds. Press Back to leave the page.", for: 8)
            }
        case "popupBlocked":
            toast.show("Blocked a pop-up", for: 2)
        case "adBlocked":
            toast.show("Blocked a jump to an ad page", for: 2)
        default:
            break
        }
    }

    private func presentTextEntry(_ body: [String: Any]) {
        guard presentedViewController == nil else { return }
        let entry = TextEntryViewController(
            prompt: body["label"] as? String ?? "",
            text: body["value"] as? String ?? "",
            inputType: body["inputType"] as? String ?? "text"
        ) { [weak self] text in
            guard let self, let text else { return }
            self.run(PageScripts.call("setText", text))
        }
        present(entry, animated: true)
    }

    private func presentChoices(_ body: [String: Any]) {
        guard presentedViewController == nil, let options = body["options"] as? [[String: Any]], !options.isEmpty else { return }
        let label = body["label"] as? String ?? ""
        let selected = body["selectedIndex"] as? Int ?? -1
        let sheet = UIAlertController(title: label.isEmpty ? nil : label, message: nil, preferredStyle: .actionSheet)
        for (index, option) in options.enumerated() where option["disabled"] as? Bool != true {
            let title = option["label"] as? String ?? ""
            sheet.addAction(UIAlertAction(title: index == selected ? "✓ \(title)" : title, style: .default) { [weak self] _ in
                self?.run(PageScripts.call("choose", index))
            })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(sheet, animated: true)
    }
}

// MARK: Testing

extension BrowserViewController {
    /// Simulates the remote for testing in the simulator; see TestServer.
    func debug(_ command: [String: Any], reply: @escaping (Any?) -> Void) {
        if let script = command["js"] as? String {
            run(script, completion: reply)
            return
        }
        if let move = command["move"] as? [Double], move.count == 2 {
            showPointer()
            movePointer(by: CGPoint(x: move[0], y: move[1]))
            return reply("\(pointerPosition)")
        }
        let presses: [String: UIPress.PressType] = [
            "select": .select, "menu": .menu, "playPause": .playPause,
            "up": .upArrow, "down": .downArrow, "left": .leftArrow, "right": .rightArrow,
        ]
        if let name = command["press"] as? String, let type = presses[name] {
            pressBegan(type)
            let hold = command["hold"] as? Double ?? 0.05
            DispatchQueue.main.asyncAfter(deadline: .now() + hold) {
                self.pressEnded(type)
                reply(name)
            }
            return
        }
        if let mobile = command["mobile"] as? Bool, let url = web?.url {
            setMobileSite(mobile, for: url)
            return reply(mobile)
        }
        if command["engine"] != nil {
            return reply(LanternWebView.engineDiagnostics())
        }
        if let zoom = command["zoom"] as? Double {
            web?.pageZoom = 1
            web?.layoutZoom = CGFloat(zoom)
            return reply("zoom \(zoom)")
        }
        if let action = command["action"] as? String {
            switch action {
            case "editAddress":
                perform(.editAddress)
                return reply("address entry")
            case "newTab": perform(.newTab)
            case "closeTab": perform(.closeTab)
            case "nextTab": perform(.selectTab((currentTabIndex + 1) % max(1, tabs.count)))
            case "unloadOthers": memoryIsLow()
            case "tabs":
                return reply(tabs.enumerated().map { index, tab in
                    "\(index == currentTabIndex ? "*" : " ")\(index): \(tab.web == nil ? "unloaded" : "loaded") \(tab.url?.host ?? "-") y=\(Int(tab.web?.scrollView?.contentOffset.y ?? tab.scrollY))"
                }.joined(separator: " | "))
            case "zoomIn": perform(.zoomIn)
            case "zoomOut": perform(.zoomOut)
            default: break
            }
            return reply(toolbarModel.zoomText)
        }
        if let words = command["dictate"] as? String {
            (presentedViewController as? TextEntryViewController)?.simulateDictation(
                words, pieces: command["pieces"] as? Int ?? 1, quietly: command["quietly"] != nil)
            return reply(presentedViewController is TextEntryViewController ? "dictated" : "no keyboard open")
        }
        if let letter = command["keypress"] as? String {
            (presentedViewController as? TextEntryViewController)?.simulateKeyPress(letter)
            return reply("typed \(letter)")
        }
        if command["dismiss"] != nil {
            presentedViewController?.dismiss(animated: true)
            return reply("dismissed")
        }
        if command["toolbar"] as? String == "hide" {
            hideToolbar()
        }
        reply("pageMB \((web?.pageMemoryFootprint ?? 0) / 1_048_576) presented \(presentedViewController.map { String(describing: type(of: $0)) } ?? "none") outline \(targetOutline.alpha > 0) toolbar \(toolbarVisible) theater \(inTheater) media \(mediaSeen) pointer \(pointerPosition) style \(pointer.style)")
    }
}

private extension ToolbarAction {
    var isZoomIn: Bool {
        if case .zoomIn = self { return true }
        return false
    }
}

extension BrowserViewController: LanternWebViewDelegate {
    func webViewStateDidChange(_ webView: LanternWebView) {
        guard webView === web else {
            if webView === popup {
                updatePopupTitle()
            } else if let tab = tab(for: webView) {
                tab.url = webView.url ?? tab.url
                tab.title = webView.title ?? tab.title
                publishTabs()
            }
            return
        }
        if let tab = currentTab {
            tab.url = webView.url ?? tab.url
            tab.title = webView.title ?? tab.title
        }
        let loading = webView.isLoading
        progressBar.setProgress(Float(webView.estimatedProgress), animated: true)
        UIView.animate(withDuration: 0.3) {
            self.progressBar.alpha = loading && !self.inTheater ? 1 : 0
        }

        let key = webView.url.map(Library.key(for:))
        if key != currentPageKey {
            currentPageKey = key
            resetPageWork()
            if let url = webView.url { notePageVisit(url) }
            if let url = webView.url { webView.layoutZoom = library.zoom(for: url) * Self.baseZoom }
            mediaSeen = false
            if inTheater { setTheater(false) }
            onPageChange?(currentSite)
            publishTabs()
        }
        if toolbarVisible {
            toolbarModel.canGoBack = webView.canGoBack
            toolbarModel.canGoForward = webView.canGoForward
            toolbarModel.isLoading = loading
        }
    }

    func webView(_ webView: LanternWebView, didFinishLoading url: URL?) {
        guard webView === web, let url else { return }
        // A tab that was unloaded comes back where you were.
        if let tab = currentTab, tab.restoreScrollOnLoad {
            tab.restoreScrollOnLoad = false
            let y = tab.scrollY
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                guard let scrollView = webView.scrollView else { return }
                let maxY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
                scrollView.setContentOffset(CGPoint(x: 0, y: min(y, maxY)), animated: false)
            }
        }
        publishTabs()
        run(PageScripts.call("info"), in: webView) { [weak self] result in
            guard let self else { return }
            let icon = ((result as? [String: Any])?["icon"] as? String).flatMap(URL.init(string:))
            self.library.recordVisit(url: url, title: webView.title ?? "", iconURL: icon)
            self.onPageChange?(self.currentSite)
        }
        // Give the page a moment to draw before taking the home screen snapshot.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, webView.url == url else { return }
            self.saveSnapshot()
        }
    }

    func webViewContentProcessDidTerminate(_ webView: LanternWebView) {
        if webView === popup {
            closePopup()
            return
        }
        // A background tab whose page stopped just reloads when you return to it.
        if webView !== web, let tab = tab(for: webView) {
            unload(tab)
            return
        }
        let reasons = [0: "too much memory", 1: "too much CPU", 2: "stopped by Lantern", 3: "crashed"]
        let reason = reasons[webView.lastStopReason] ?? "no reason given"
        PageHealthLog.record("stopped", url: webView.url ?? currentTab?.url, detail: reason)
        resetPageWork()
        // Lantern shut down a frozen page on purpose; carry on with what you asked for.
        if let action = afterFrozenPageStops {
            afterFrozenPageStops = nil
            action()
            return
        }
        let now = Date()
        defer { lastPageCrash = now }
        // Reload once; a page that crashes again right away is left alone instead of looping.
        if let last = lastPageCrash, now.timeIntervalSince(last) < 60 {
            toast.show("This page keeps running out of memory, so Lantern stopped reloading it. Press Back to leave it, or close other apps on the TV to free memory.", for: 9)
        } else {
            toast.show(webView.lastStopReason == 3 ? "This page crashed, so Lantern reloaded it." : "This page ran out of memory, so Lantern reloaded it.", for: 4)
            rememberScrollPosition()
            currentTab?.restoreScrollOnLoad = true
            webView.reload()
        }
    }

    func webView(_ webView: LanternWebView, shouldOpenPopupFor url: URL) -> Bool {
        webView === web && popup == nil && PopupPolicy.allows(url, openedFrom: webView.url)
    }

    func webView(_ webView: LanternWebView, didOpenPopup newPopup: LanternWebView) {
        showPopup(newPopup)
    }

    func webViewDidClose(_ webView: LanternWebView) {
        if webView === popup { closePopup() }
    }

    func webView(_ webView: LanternWebView, didFailWithError error: Error) {
        toast.show(error.localizedDescription, for: 5)
    }

    func webView(_ webView: LanternWebView, didReceiveMessage body: Any) {
        if let body = body as? [String: Any] { handle(message: body) }
    }

    func webView(_ webView: LanternWebView, showAlert message: String, confirm isConfirm: Bool, completion: @escaping (Bool) -> Void) {
        guard presentedViewController == nil else {
            completion(false)
            return
        }
        let alert = UIAlertController(title: webView.url?.host, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completion(true) })
        if isConfirm {
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completion(false) })
        }
        present(alert, animated: true)
    }
}
