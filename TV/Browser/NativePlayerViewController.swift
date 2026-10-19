import AVKit
import UIKit

/// Plays a page's video full screen in Apple's own player, with the usual Siri Remote
/// controls: click to pause, swipe to scrub, Back to return to the page.
final class NativePlayerViewController: AVPlayerViewController {
    struct Request {
        var url: URL
        var startTime: Double
        var isLive: Bool
        /// The page the video came from. Many video hosts only serve pages they recognise.
        var pageURL: URL?
        var userAgent: String?
        /// The captions showing on the page, if any, to keep showing here.
        var captions: Captions?
    }

    /// Called when the viewer leaves, with how far into the video they got.
    var onClose: ((Double) -> Void)?
    /// Called if the stream won't play outside the page.
    var onFailure: (() -> Void)?

    private let request: Request
    private var statusObservation: NSKeyValueObservation?
    private var closed = false
    private var stats: PlaybackStatsViewController!
    private let captionOverlay = CaptionOverlay()
    private var cookies: [HTTPCookie] = []

    init(request: Request, cookies: [HTTPCookie]) {
        self.request = request
        self.cookies = cookies
        super.init(nibName: nil, bundle: nil)

        var headers: [String: String] = [:]
        if let page = request.pageURL {
            headers["Referer"] = page.absoluteString
            if let scheme = page.scheme, let host = page.host {
                headers["Origin"] = "\(scheme)://\(host)"
            }
        }
        var options: [String: Any] = [
            AVURLAssetHTTPCookiesKey: cookies,
            // Not a published constant, but AVFoundation honours it for extra request headers.
            "AVURLAssetHTTPHeaderFieldsKey": headers,
        ]
        if let agent = request.userAgent {
            options[AVURLAssetHTTPUserAgentKey] = agent
        }
        let item = AVPlayerItem(asset: AVURLAsset(url: request.url, options: options))
        let player = AVPlayer(playerItem: item)
        stats = PlaybackStatsViewController(player: player)
        self.player = player
        // Swipe down while playing for an extra tab with what's actually playing.
        customInfoViewControllers = [stats]

        statusObservation = item.observe(\.status) { [weak self] item, _ in
            DispatchQueue.main.async { self?.itemStatusChanged(item.status) }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // The pinned stats sit over the top-left of the video, under the player's own controls.
        guard let overlayHost = contentOverlayView else { return }
        captionOverlay.translatesAutoresizingMaskIntoConstraints = false
        overlayHost.addSubview(captionOverlay)
        NSLayoutConstraint.activate([
            captionOverlay.topAnchor.constraint(equalTo: overlayHost.topAnchor),
            captionOverlay.bottomAnchor.constraint(equalTo: overlayHost.bottomAnchor),
            captionOverlay.leadingAnchor.constraint(equalTo: overlayHost.leadingAnchor),
            captionOverlay.trailingAnchor.constraint(equalTo: overlayHost.trailingAnchor),
        ])
        let overlay = stats.overlay
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlayHost.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: overlayHost.topAnchor, constant: 60),
            overlay.leadingAnchor.constraint(equalTo: overlayHost.leadingAnchor, constant: 80),
            overlay.widthAnchor.constraint(lessThanOrEqualTo: overlayHost.widthAnchor, constant: -160),
        ])
    }

    private func itemStatusChanged(_ status: AVPlayerItem.Status) {
        switch status {
        case .readyToPlay:
            if !request.isLive, request.startTime > 1 {
                player?.seek(to: CMTime(seconds: request.startTime, preferredTimescale: 600),
                             toleranceBefore: .zero, toleranceAfter: .zero)
            }
            player?.play()
            if let captions = request.captions, let item = player?.currentItem {
                Task { await self.showCaptions(captions, for: item) }
            }
        case .failed:
            let failure = onFailure
            close()
            dismiss(animated: true) { failure?() }
        default:
            break
        }
    }

    /// Keeps the page's captions on. Streams with their own subtitles get the matching language
    /// switched on in Apple's player (and its Subtitles menu); otherwise Lantern draws the page's.
    private func showCaptions(_ captions: Captions, for item: AVPlayerItem) async {
        if let group = try? await item.asset.loadMediaSelectionGroup(for: .legible) {
            let options = group.options.filter { !$0.hasMediaCharacteristic(.containsOnlyForcedSubtitles) }
            let language = captions.language.lowercased().split(separator: "-").first.map(String.init) ?? ""
            let match = options.first { option in
                !language.isEmpty && option.extendedLanguageTag?.lowercased().hasPrefix(language) == true
            } ?? options.first { !captions.label.isEmpty && $0.displayName == captions.label }
                ?? options.first
            if let match {
                item.select(match, in: group)
                return
            }
        }
        var cues = captions.cues
        if cues.isEmpty, let source = captions.source {
            var fileRequest = URLRequest(url: source)
            if let page = request.pageURL { fileRequest.setValue(page.absoluteString, forHTTPHeaderField: "Referer") }
            if let agent = request.userAgent { fileRequest.setValue(agent, forHTTPHeaderField: "User-Agent") }
            let cookieHeaders = HTTPCookie.requestHeaderFields(with: cookies.filter { source.host?.hasSuffix($0.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))) == true })
            for (name, value) in cookieHeaders { fileRequest.setValue(value, forHTTPHeaderField: name) }
            if let (data, _) = try? await URLSession.shared.data(for: fileRequest), let text = String(data: data, encoding: .utf8) {
                cues = CaptionOverlay.parse(webVTT: text)
            }
        }
        guard !cues.isEmpty, let player, !closed else { return }
        captionOverlay.start(cues, with: player)
    }

    /// Test-only: the caption on screen now, or which subtitle the player has switched on.
    var captionStatus: String {
        if !captionOverlay.currentText.isEmpty { return "drawn: " + captionOverlay.currentText }
        guard let item = player?.currentItem,
              let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: .legible) else { return "none" }
        return "player: " + (item.currentMediaSelection.selectedMediaOption(in: group)?.displayName ?? "off")
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil {
            close()
        }
    }

    private func close() {
        guard !closed else { return }
        closed = true
        stats.stop()
        captionOverlay.stop()
        player?.pause()
        statusObservation = nil
        let seconds = player?.currentTime().seconds ?? request.startTime
        onClose?(seconds.isFinite ? seconds : request.startTime)
    }
}
