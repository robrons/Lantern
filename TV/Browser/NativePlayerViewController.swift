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
    }

    /// Called when the viewer leaves, with how far into the video they got.
    var onClose: ((Double) -> Void)?
    /// Called if the stream won't play outside the page.
    var onFailure: (() -> Void)?

    private let request: Request
    private var statusObservation: NSKeyValueObservation?
    private var closed = false

    init(request: Request, cookies: [HTTPCookie]) {
        self.request = request
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
        player = AVPlayer(playerItem: item)

        statusObservation = item.observe(\.status) { [weak self] item, _ in
            DispatchQueue.main.async { self?.itemStatusChanged(item.status) }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func itemStatusChanged(_ status: AVPlayerItem.Status) {
        switch status {
        case .readyToPlay:
            if !request.isLive, request.startTime > 1 {
                player?.seek(to: CMTime(seconds: request.startTime, preferredTimescale: 600),
                             toleranceBefore: .zero, toleranceAfter: .zero)
            }
            player?.play()
        case .failed:
            let failure = onFailure
            close()
            dismiss(animated: true) { failure?() }
        default:
            break
        }
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
        player?.pause()
        statusObservation = nil
        let seconds = player?.currentTime().seconds ?? request.startTime
        onClose?(seconds.isFinite ? seconds : request.startTime)
    }
}
