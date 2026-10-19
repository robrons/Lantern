import UIKit

/// A short message at the bottom of the screen.
final class ToastView: UIView {
    private let label = UILabel()
    private var hideWork: DispatchWorkItem?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        alpha = 0
        backgroundColor = UIColor.black.withAlphaComponent(0.8)
        layer.cornerRadius = 36
        label.font = .preferredFont(forTextStyle: .callout)
        label.textColor = .white
        label.textAlignment = .center
        label.numberOfLines = 2
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 40),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -40),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20),
            widthAnchor.constraint(lessThanOrEqualToConstant: 1200),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(_ text: String, for seconds: TimeInterval = 3) {
        label.text = text
        hideWork?.cancel()
        UIView.animate(withDuration: 0.25) { self.alpha = 1 }
        let work = DispatchWorkItem { [weak self] in
            UIView.animate(withDuration: 0.4) { self?.alpha = 0 }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}

/// How to use the remote, shown the first few times the browser opens and from the menu.
final class RemoteHintView: UIView {
    private var hideWork: DispatchWorkItem?

    private static let rows: [(String, String)] = [
        ("hand.point.up.left", "Swipe to move the pointer. Flick up or down to scroll, as on an iPhone."),
        ("hand.tap", "Click to select. Hold the click to open the menu with the address bar."),
        ("plus.magnifyingglass", "Zoom in or out from the menu. Each site remembers its zoom."),
        ("chevron.up.chevron.down", "Click the top or bottom of the clickpad to scroll a little at a time."),
        ("arrow.uturn.backward", "Back goes to the previous page, then home."),
        ("playpause", "Play/Pause plays or pauses the video on the page. Hold it for full screen."),
    ]

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        alpha = 0

        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
        blur.layer.cornerRadius = 40
        blur.clipsToBounds = true
        blur.translatesAutoresizingMaskIntoConstraints = false
        addSubview(blur)

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 22
        stack.translatesAutoresizingMaskIntoConstraints = false
        for (symbol, text) in Self.rows {
            let icon = UIImageView(image: UIImage(systemName: symbol))
            icon.tintColor = .white
            icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 34, weight: .medium)
            icon.contentMode = .scaleAspectFit
            icon.widthAnchor.constraint(equalToConstant: 48).isActive = true
            let label = UILabel()
            label.text = text
            label.textColor = .white
            label.font = .preferredFont(forTextStyle: .callout)
            label.numberOfLines = 2
            let row = UIStackView(arrangedSubviews: [icon, label])
            row.spacing = 28
            row.alignment = .center
            stack.addArrangedSubview(row)
        }
        blur.contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            blur.leadingAnchor.constraint(equalTo: leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: trailingAnchor),
            blur.topAnchor.constraint(equalTo: topAnchor),
            blur.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: blur.contentView.leadingAnchor, constant: 48),
            stack.trailingAnchor.constraint(equalTo: blur.contentView.trailingAnchor, constant: -48),
            stack.topAnchor.constraint(equalTo: blur.contentView.topAnchor, constant: 40),
            stack.bottomAnchor.constraint(equalTo: blur.contentView.bottomAnchor, constant: -40),
            widthAnchor.constraint(equalToConstant: 1100),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(for seconds: TimeInterval = 9) {
        hideWork?.cancel()
        UIView.animate(withDuration: 0.3) { self.alpha = 1 }
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func hide() {
        hideWork?.cancel()
        UIView.animate(withDuration: 0.4) { self.alpha = 0 }
    }
}

/// The browser's root view. It takes focus while the menu is closed, so remote presses
/// arrive at the browser instead of anything inside the page.
final class CanvasView: UIView {
    var focusable = true

    override var canBecomeFocused: Bool { focusable }
}
