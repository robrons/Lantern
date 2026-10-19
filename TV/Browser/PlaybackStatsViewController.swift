import AVKit
import UIKit

/// "Stats for nerds" for the full-screen player: what's actually playing and where the sound
/// goes. It's a tab in the panel you get by swiping down while a video plays, updated live.
/// Keep on Screen pins a compact copy over the video until you turn it off again.
final class PlaybackStatsViewController: UIViewController {
    /// The pinned copy; the player puts it over the video.
    let overlay = PlaybackStatsOverlay()
    private static let pinnedKey = "playbackStatsPinned"
    private var isPinned: Bool {
        get { UserDefaults.standard.bool(forKey: Self.pinnedKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.pinnedKey) }
    }
    private let pinButton = UIButton(type: .system)
    private weak var player: AVPlayer?
    private let videoColumn = UIStackView()
    private let streamColumn = UIStackView()
    private let audioColumn = UIStackView()
    /// One size for every line, so the columns match.
    private static let font = UIFont.systemFont(ofSize: 26)
    private var timer: Timer?
    /// Details read from the stream, which take a moment to load.
    private var variants: [AVAssetVariant] = []
    private var audioChannelsFromStream: Int?
    private var trackFormats: [Int32: CMFormatDescription] = [:]
    private var loadedFor: AVPlayerItem?

    init(player: AVPlayer) {
        self.player = player
        super.init(nibName: nil, bundle: nil)
        title = "Stats"
        // Three short columns, so everything fits in the panel without scrolling.
        preferredContentSize = CGSize(width: 0, height: 360)
        // Runs for as long as the player is open, for the pinned copy.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
    }

    /// Stops updating; the player calls this when it closes.
    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func togglePin() {
        isPinned.toggle()
        refresh()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        for column in [videoColumn, streamColumn, audioColumn] {
            column.axis = .vertical
            column.spacing = 6
            column.alignment = .fill
        }
        let columns = UIStackView(arrangedSubviews: [videoColumn, streamColumn, audioColumn])
        columns.axis = .horizontal
        columns.spacing = 70
        columns.distribution = .fillEqually
        columns.alignment = .top
        pinButton.addAction(UIAction { [weak self] _ in self?.togglePin() }, for: .primaryActionTriggered)
        let content = UIStackView(arrangedSubviews: [columns, pinButton])
        content.axis = .vertical
        content.spacing = 24
        content.alignment = .leading
        columns.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 80),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -80),
            content.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            columns.widthAnchor.constraint(equalTo: content.widthAnchor),
        ])
        refresh()
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] { [pinButton] }

    // MARK: Reading the stats

    private func refresh() {
        guard let item = player?.currentItem else { return }
        loadStreamDetails(for: item)
        let log = item.accessLog()?.events.last
        let variant = currentVariant(bitrate: log?.indicatedBitrate)
        let videoFormat = format(of: .video, in: item)
        let audioFormat = format(of: .audio, in: item)

        var video: [(String, String)] = []
        let size = item.presentationSize
        if size.width > 0 {
            video.append(("Resolution", "\(Int(size.width))×\(Int(size.height)) (\(Self.resolutionName(size)))"))
        }
        let frameRate = item.tracks.first { $0.assetTrack?.mediaType == .video }?.currentVideoFrameRate
            ?? variant?.videoAttributes?.nominalFrameRate.map(Float.init)
        if let frameRate, frameRate > 0 {
            video.append(("Frame rate", String(format: "%.3g fps", frameRate)))
        }
        let codecs = videoFormat.map { [CMFormatDescriptionGetMediaSubType($0)] }
            ?? variant?.videoAttributes?.codecTypes ?? []
        if let codec = codecs.first {
            video.append(("Codec", Self.videoCodecName(codec)))
        }
        if let range = Self.dynamicRange(format: videoFormat, codecs: codecs, variant: variant) {
            video.append(("Dynamic range", range))
        }
        if let host = (item.asset as? AVURLAsset)?.url.host {
            video.append(("From", host))
        }

        var stream: [(String, String)] = []
        let streamKind = variants.isEmpty ? "Single file" : "HLS, \(variants.count) versions"
        stream.append(("Type", log?.playbackType == "LIVE" ? "Live \(streamKind)" : streamKind))
        if let log {
            if log.indicatedBitrate > 0 {
                stream.append(("Bitrate", Self.bitrate(log.indicatedBitrate)))
            }
            if log.observedBitrate > 0 {
                stream.append(("Connection", Self.bitrate(log.observedBitrate)))
            }
            stream.append(("Dropped frames", "\(max(0, log.numberOfDroppedVideoFrames))"))
            if log.numberOfStalls > 0 {
                stream.append(("Stalls", "\(log.numberOfStalls)"))
            }
        }
        if let buffered = Self.bufferedAhead(item) {
            stream.append(("Buffered", String(format: "%.0f s", buffered)))
        }

        var audio: [(String, String)] = []
        let audioCodec = audioFormat.map { CMFormatDescriptionGetMediaSubType($0) }
            ?? variant?.audioAttributes?.formatIDs.first
        if let audioCodec {
            audio.append(("Format", Self.audioCodecName(audioCodec)))
        }
        let channels = audioFormat.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mChannelsPerFrame }
            .map(Int.init) ?? audioChannelsFromStream
        if let channels, channels > 0 {
            audio.append(("Channels", Self.channelName(channels)))
        }
        if let sampleRate = audioFormat.flatMap({ CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mSampleRate }),
           sampleRate > 0 {
            audio.append(("Sample rate", String(format: "%.1f kHz", sampleRate / 1000)))
        }
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs.map { "\($0.portName) (\(Self.portName($0.portType)))" }
        if !outputs.isEmpty {
            audio.append(("Output", outputs.joined(separator: ", ")))
        }
        audio.append(("Output channels", "\(session.outputNumberOfChannels) of \(session.maximumOutputNumberOfChannels)"))
        audio.append(("TV HDR", AVPlayer.eligibleForHDRPlayback ? "On" : "Off (SDR)"))

        overlay.isHidden = !isPinned
        if isPinned {
            overlay.show([
                video.filter { $0.0 != "From" }.map(\.1).joined(separator: " · "),
                stream.filter { $0.0 != "Type" }.map { "\($0.0) \($0.1)" }.joined(separator: " · "),
                audio.filter { !$0.0.hasPrefix("Output channels") && $0.0 != "TV HDR" }.map(\.1).joined(separator: " · "),
            ])
        }
        guard isViewLoaded else { return }
        var pin = UIButton.Configuration.plain()
        pin.title = isPinned ? "Remove from Screen" : "Keep on Screen"
        pin.image = UIImage(systemName: isPinned ? "pin.slash" : "pin")
        pin.imagePadding = 12
        pinButton.configuration = pin
        fill(videoColumn, heading: "Video", rows: video)
        fill(streamColumn, heading: "Stream", rows: stream)
        fill(audioColumn, heading: "Audio and TV", rows: audio)
    }

    private func format(of type: AVMediaType, in item: AVPlayerItem) -> CMFormatDescription? {
        for track in item.tracks where track.isEnabled {
            if let asset = track.assetTrack, asset.mediaType == type, let format = trackFormats[asset.trackID] {
                return format
            }
        }
        return nil
    }

    /// Loads the stream's qualities and each track's format once; they arrive asynchronously.
    private func loadStreamDetails(for item: AVPlayerItem) {
        let tracks = item.tracks.compactMap(\.assetTrack).filter { trackFormats[$0.trackID] == nil }
        for track in tracks {
            Task { [weak self] in
                guard let format = try? await track.load(.formatDescriptions).first else { return }
                self?.trackFormats[track.trackID] = format
            }
        }
        guard loadedFor !== item, let asset = item.asset as? AVURLAsset else { return }
        loadedFor = item
        Task { [weak self] in
            let variants = (try? await asset.load(.variants)) ?? []
            var channels: Int?
            if let group = try? await asset.loadMediaSelectionGroup(for: .audible),
               let option = item.currentMediaSelection.selectedMediaOption(in: group) ?? group.defaultOption {
                channels = variants.lazy.compactMap { $0.audioAttributes?.renditionSpecificAttributes(for: option)?.channelCount }.first
            }
            self?.variants = variants
            self?.audioChannelsFromStream = channels
        }
    }

    /// The quality the player is on now, matched by the bitrate it reports.
    private func currentVariant(bitrate: Double?) -> AVAssetVariant? {
        guard let bitrate, bitrate > 0 else { return nil }
        return variants.min {
            abs(($0.peakBitRate ?? $0.averageBitRate ?? 0) - bitrate) < abs(($1.peakBitRate ?? $1.averageBitRate ?? 0) - bitrate)
        }
    }

    /// Test-only: the stats as text.
    func debugText() -> String {
        loadViewIfNeeded()
        refresh()
        return [videoColumn, streamColumn, audioColumn].map { column in
            column.arrangedSubviews.map { view -> String in
                if let label = view as? UILabel { return "[\(label.text ?? "")]" }
                let labels = (view as? UIStackView)?.arrangedSubviews.compactMap { ($0 as? UILabel)?.text } ?? []
                return labels.joined(separator: ": ")
            }.joined(separator: "\n")
        }.joined(separator: "\n")
    }

    // MARK: Presenting

    private func fill(_ column: UIStackView, heading: String, rows: [(String, String)]) {
        column.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let title = UILabel()
        title.text = heading
        title.font = .systemFont(ofSize: Self.font.pointSize, weight: .semibold)
        column.addArrangedSubview(title)
        for (name, value) in rows {
            let nameLabel = UILabel()
            nameLabel.text = name
            nameLabel.font = Self.font
            nameLabel.textColor = .secondaryLabel
            let valueLabel = UILabel()
            valueLabel.text = value
            valueLabel.font = .monospacedDigitSystemFont(ofSize: Self.font.pointSize, weight: .regular)
            valueLabel.textAlignment = .right
            // Long values are shortened rather than shrunk, so every line stays the same size.
            valueLabel.lineBreakMode = .byTruncatingMiddle
            let row = UIStackView(arrangedSubviews: [nameLabel, valueLabel])
            row.axis = .horizontal
            row.spacing = 20
            nameLabel.setContentHuggingPriority(.required, for: .horizontal)
            column.addArrangedSubview(row)
        }
    }

    // MARK: Names

    private static func resolutionName(_ size: CGSize) -> String {
        let lines = min(size.width, size.height)
        switch lines {
        case 2000...: return "4K"
        case 1400..<2000: return "1440p"
        case 1000..<1400: return "1080p"
        case 700..<1000: return "720p"
        case 560..<700: return "576p"
        case 460..<560: return "480p"
        default: return "\(Int(lines))p"
        }
    }

    private static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        return String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? "\(code)"
    }

    private static func videoCodecName(_ code: FourCharCode) -> String {
        switch fourCC(code) {
        case "avc1", "avc3": "H.264"
        case "hvc1", "hev1": "HEVC (H.265)"
        case "dvh1", "dvhe": "Dolby Vision (HEVC)"
        case "dva1", "dvav": "Dolby Vision (H.264)"
        case "av01": "AV1"
        case "vp09": "VP9"
        case let other: other
        }
    }

    private static func dynamicRange(format: CMFormatDescription?, codecs: [FourCharCode], variant: AVAssetVariant?) -> String? {
        if codecs.contains(where: { fourCC($0).hasPrefix("dv") }) {
            return "Dolby Vision"
        }
        if let format, let transfer = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String {
            if transfer == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String) { return "HDR10" }
            if transfer == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String) { return "HLG" }
            return "SDR"
        }
        switch variant?.videoAttributes?.videoRange {
        case .pq?: return "HDR10"
        case .hlg?: return "HLG"
        case .sdr?: return "SDR"
        default: return nil
        }
    }

    private static func audioCodecName(_ code: FourCharCode) -> String {
        switch fourCC(code) {
        case "aac", "mp4a": "AAC"
        case "ac-3": "Dolby Digital"
        case "ec-3": "Dolby Digital Plus"
        case "ac-4": "Dolby AC-4"
        case "alac": "Apple Lossless"
        case "lpcm": "PCM (uncompressed)"
        case "opus": "Opus"
        case ".mp3": "MP3"
        case "fLaC": "FLAC"
        case let other: other
        }
    }

    private static func channelName(_ channels: Int) -> String {
        switch channels {
        case 1: "Mono"
        case 2: "Stereo"
        case 6: "5.1 surround"
        case 8: "7.1 surround"
        case 16: "Atmos (object audio)"
        default: "\(channels) channels"
        }
    }

    private static func portName(_ type: AVAudioSession.Port) -> String {
        switch type {
        case .HDMI: "HDMI"
        case .airPlay: "AirPlay"
        case .bluetoothA2DP, .bluetoothLE, .bluetoothHFP: "Bluetooth"
        case .usbAudio: "USB"
        default: type.rawValue
        }
    }

    private static func bitrate(_ bitsPerSecond: Double) -> String {
        bitsPerSecond >= 1_000_000
            ? String(format: "%.1f Mbps", bitsPerSecond / 1_000_000)
            : String(format: "%.0f kbps", bitsPerSecond / 1000)
    }

    private static func bufferedAhead(_ item: AVPlayerItem) -> Double? {
        let now = item.currentTime()
        for value in item.loadedTimeRanges {
            let range = value.timeRangeValue
            if range.containsTime(now) {
                return (range.end - now).seconds
            }
        }
        return nil
    }
}

/// The pinned stats: three short lines in a dark box over the corner of the video.
final class PlaybackStatsOverlay: UIView {
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isHidden = true
        let box = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
        box.layer.cornerRadius = 16
        box.clipsToBounds = true
        box.translatesAutoresizingMaskIntoConstraints = false
        addSubview(box)
        label.numberOfLines = 3
        label.textColor = .white
        label.font = .monospacedDigitSystemFont(ofSize: 22, weight: .regular)
        label.translatesAutoresizingMaskIntoConstraints = false
        box.contentView.addSubview(label)
        NSLayoutConstraint.activate([
            box.topAnchor.constraint(equalTo: topAnchor),
            box.leadingAnchor.constraint(equalTo: leadingAnchor),
            box.trailingAnchor.constraint(equalTo: trailingAnchor),
            box.bottomAnchor.constraint(equalTo: bottomAnchor),
            label.topAnchor.constraint(equalTo: box.contentView.topAnchor, constant: 14),
            label.bottomAnchor.constraint(equalTo: box.contentView.bottomAnchor, constant: -14),
            label.leadingAnchor.constraint(equalTo: box.contentView.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: box.contentView.trailingAnchor, constant: -20),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(_ lines: [String]) {
        label.text = lines.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    var text: String { label.text ?? "" }
}
