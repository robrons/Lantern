import AVKit
import UIKit

extension NativePlayerViewController {
    /// The captions that were showing on the page when the video went full screen.
    struct Captions {
        struct Cue {
            var start: Double
            var end: Double
            var text: String
        }

        var language: String
        var label: String
        /// The page's caption file, if it had one.
        var source: URL?
        /// Caption lines the page had already loaded.
        var cues: [Cue]

        init(_ body: [String: Any]) {
            language = body["language"] as? String ?? ""
            label = body["label"] as? String ?? ""
            source = (body["src"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }
            cues = (body["cues"] as? [[Any]] ?? []).compactMap { cue in
                guard cue.count == 3, let start = cue[0] as? Double, let end = cue[1] as? Double,
                      let text = cue[2] as? String else { return nil }
                return Cue(start: start, end: end, text: text)
            }
        }
    }
}

/// Draws captions over the video, in step with playback, for streams that don't carry their
/// own (Apple's player shows those itself).
final class CaptionOverlay: UIView {
    private let label = PaddedLabel()
    private var cues: [NativePlayerViewController.Captions.Cue] = []
    private var timeObserver: Any?
    private weak var player: AVPlayer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = .white
        label.font = .systemFont(ofSize: 44, weight: .medium)
        label.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        label.layer.cornerRadius = 10
        label.clipsToBounds = true
        label.isHidden = true
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            // High enough to clear the player's progress bar when the controls show.
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -170),
            label.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.8),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func start(_ cues: [NativePlayerViewController.Captions.Cue], with player: AVPlayer) {
        stop()
        self.cues = cues
        self.player = player
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 5), queue: .main) { [weak self] time in
            self?.show(at: time.seconds)
        }
    }

    func stop() {
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
    }

    /// Test-only: what's on screen now.
    var currentText: String { label.isHidden ? "" : (label.text ?? "") }

    private func show(at seconds: Double) {
        let text = cues.filter { $0.start <= seconds && seconds < $0.end }
            .map { Self.plainText($0.text) }
            .joined(separator: "\n")
        label.isHidden = text.isEmpty
        if label.text != text { label.text = text }
    }

    /// Caption text without WebVTT's styling tags (<i>, <c.yellow>, <v Speaker>...).
    private static func plainText(_ text: String) -> String {
        text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
    }

    /// Reads a WebVTT caption file.
    static func parse(webVTT: String) -> [NativePlayerViewController.Captions.Cue] {
        var cues: [NativePlayerViewController.Captions.Cue] = []
        let blocks = webVTT.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
        for block in blocks {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let timing = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[timing].components(separatedBy: "-->")
            guard parts.count == 2, let start = seconds(parts[0]),
                  let end = seconds(parts[1].trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first ?? "")
            else { continue }
            let text = lines[(timing + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                cues.append(.init(start: start, end: end, text: text))
            }
        }
        return cues
    }

    /// "01:02:03.456" or "02:03.456" in seconds.
    private static func seconds(_ stamp: String) -> Double? {
        let fields = stamp.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard (2...3).contains(fields.count) else { return nil }
        var total = 0.0
        for field in fields {
            guard let value = Double(field) else { return nil }
            total = total * 60 + value
        }
        return total
    }
}

/// A label with room around its text, for caption backgrounds.
private final class PaddedLabel: UILabel {
    private let padding = UIEdgeInsets(top: 8, left: 20, bottom: 8, right: 20)

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: padding))
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + padding.left + padding.right, height: size.height + padding.top + padding.bottom)
    }

    override func textRect(forBounds bounds: CGRect, limitedToNumberOfLines numberOfLines: Int) -> CGRect {
        let inner = super.textRect(forBounds: bounds.inset(by: padding), limitedToNumberOfLines: numberOfLines)
        return inner.inset(by: UIEdgeInsets(top: -padding.top, left: -padding.left, bottom: -padding.bottom, right: -padding.right))
    }
}
