import UIKit

/// The on-screen pointer. It changes shape like the iPad pointer: a dot over plain content,
/// a larger tinted circle over links and buttons, and a bar over text fields.
final class PointerView: UIView {
    enum Style: String {
        case normal = "none"
        case link
        case text
        case video
        case frame
    }

    var style: Style = .normal {
        didSet {
            if style != oldValue { applyStyle(animated: true) }
        }
    }

    private let shape = UIView()

    override init(frame: CGRect) {
        super.init(frame: CGRect(x: 0, y: 0, width: 80, height: 80))
        isUserInteractionEnabled = false
        shape.layer.borderColor = UIColor.white.cgColor
        shape.layer.shadowColor = UIColor.black.cgColor
        shape.layer.shadowOpacity = 0.45
        shape.layer.shadowRadius = 8
        shape.layer.shadowOffset = CGSize(width: 0, height: 3)
        addSubview(shape)
        applyStyle(animated: false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setPressed(_ pressed: Bool) {
        UIView.animate(withDuration: 0.12) {
            self.shape.transform = pressed ? CGAffineTransform(scaleX: 0.78, y: 0.78) : .identity
        }
    }

    func pulse() {
        shape.transform = CGAffineTransform(scaleX: 0.7, y: 0.7)
        UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.5, initialSpringVelocity: 0.8) {
            self.shape.transform = .identity
        }
    }

    private func applyStyle(animated: Bool) {
        let size: CGSize
        let fill: UIColor
        let border: CGFloat
        switch style {
        case .link, .frame, .video:
            size = CGSize(width: 54, height: 54)
            fill = UIColor.systemBlue.withAlphaComponent(0.35)
            border = 3
        case .text:
            size = CGSize(width: 10, height: 54)
            fill = UIColor.white.withAlphaComponent(0.95)
            border = 0
        case .normal:
            size = CGSize(width: 30, height: 30)
            fill = UIColor.white.withAlphaComponent(0.92)
            border = 2
        }
        let changes = {
            self.shape.bounds = CGRect(origin: .zero, size: size)
            self.shape.center = CGPoint(x: self.bounds.midX, y: self.bounds.midY)
            self.shape.layer.cornerRadius = min(size.width, size.height) / 2
            self.shape.backgroundColor = fill
            self.shape.layer.borderWidth = border
            self.shape.layer.borderColor = (self.style == .normal ? UIColor.black.withAlphaComponent(0.35) : UIColor.white).cgColor
        }
        if animated {
            UIView.animate(withDuration: 0.25, delay: 0, usingSpringWithDamping: 0.75, initialSpringVelocity: 0, options: [.beginFromCurrentState], animations: changes)
        } else {
            changes()
        }
    }
}
