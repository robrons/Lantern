import UIKit

/// Opens the tvOS keyboard straight away for a text field on a web page. The iPhone's
/// Apple TV keyboard and Siri dictation work here like in any tvOS text field.
final class TextEntryViewController: UIViewController, UITextFieldDelegate {
    private let prompt: String
    private let initialText: String
    private let inputType: String
    private let completion: (String?) -> Void
    private let field = UITextField()
    private var finished = false

    init(prompt: String, text: String, inputType: String, completion: @escaping (String?) -> Void) {
        self.prompt = prompt
        self.initialText = text
        self.inputType = inputType
        self.completion = completion
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.7)

        let title = UILabel()
        title.text = prompt.isEmpty ? "Enter Text" : prompt
        title.font = .preferredFont(forTextStyle: .title2)
        title.textColor = .white
        title.textAlignment = .center
        title.numberOfLines = 2

        field.text = initialText
        field.placeholder = prompt.isEmpty ? nil : prompt
        field.delegate = self
        field.isSecureTextEntry = inputType == "password"
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        switch inputType {
        case "email": field.keyboardType = .emailAddress
        case "url": field.keyboardType = .URL
        case "number", "tel": field.keyboardType = .numbersAndPunctuation
        case "search": field.returnKeyType = .search
        default: break
        }

        let tip = UILabel()
        tip.text = "Tip: you can type on your iPhone. Tap the Apple TV Keyboard notification."
        tip.font = .preferredFont(forTextStyle: .footnote)
        tip.textColor = UIColor.white.withAlphaComponent(0.6)
        tip.textAlignment = .center

        let stack = UIStackView(arrangedSubviews: [title, field, tip])
        stack.axis = .vertical
        stack.spacing = 40
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.widthAnchor.constraint(equalToConstant: 1100),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !finished { field.becomeFirstResponder() }
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] { [field] }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        finish(with: textField.text ?? "")
        return true
    }

    func textFieldDidEndEditing(_ textField: UITextField, reason: UITextField.DidEndEditingReason) {
        // Leaving the keyboard with the Back button keeps what was typed, as elsewhere on tvOS,
        // but leaving it unchanged counts as cancelling.
        let text = textField.text ?? ""
        finish(with: text == initialText ? nil : text)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .menu }) {
            finish(with: nil)
        } else {
            super.pressesEnded(presses, with: event)
        }
    }

    private func finish(with text: String?) {
        guard !finished else { return }
        finished = true
        dismiss(animated: true) { [completion] in completion(text) }
    }
}
