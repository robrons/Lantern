import UIKit

/// Opens the tvOS keyboard straight away, for a text field on a web page, the address bar or
/// the home screen's search. The iPhone's Apple TV keyboard and dictation work as in any tvOS
/// text field, and after dictating it finishes by itself, with no trip to the Done button.
final class TextEntryViewController: UIViewController, UITextFieldDelegate {
    private let prompt: String
    private let initialText: String
    private let inputType: String
    private let completion: (String?) -> Void
    private let field = DictationTextField()
    private var finished = false
    /// The text as last seen, and when it last changed.
    private var lastText = ""
    private var lastChange = Date()
    /// Set once dictation has been seen: tvOS said recording ended, or a phrase arrived at once.
    private var dictated = false
    private var watch: Timer?
    /// How the text arrived, kept for the log when the keyboard closes.
    private var biggestChunk = 0
    private var heardRecordingEnd = false

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
        lastText = initialText
        field.placeholder = prompt.isEmpty ? nil : prompt
        field.delegate = self
        field.addTarget(self, action: #selector(textChanged), for: .editingChanged)
        field.onRecordingEnded = { [weak self] in
            self?.heardRecordingEnd = true
            self?.dictated = true
            self?.lastChange = Date()
        }
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
        tip.text = "Hold the mic button and speak; Lantern finishes when you\u{2019}re done. Or type, then press Back to keep it. You can also type on your iPhone."
        tip.font = .preferredFont(forTextStyle: .footnote)
        tip.textColor = UIColor.white.withAlphaComponent(0.6)
        tip.textAlignment = .center
        tip.numberOfLines = 2

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
        guard !finished else { return }
        field.becomeFirstResponder()
        // Dictated text doesn't always arrive through the field's change events, so also look
        // at the text a few times a second.
        watch?.invalidate()
        watch = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.textChanged()
            self?.finishAfterDictation()
        }
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] { [field] }

    /// Typing on the keyboard adds one letter at a time, while dictation (or a word sent from an
    /// iPhone) arrives several letters at once, sometimes in pieces as it's recognized.
    @objc private func textChanged() {
        let text = field.text ?? ""
        guard text != lastText else { return }
        let added = text.count - lastText.count
        lastText = text
        lastChange = Date()
        biggestChunk = max(biggestChunk, abs(added))
        if abs(added) >= 2 {
            dictated = true
        }
    }

    /// Once dictation has been seen, finish when the text has settled, so there's no trip to
    /// the Done button.
    private func finishAfterDictation() {
        guard dictated, !finished, field.markedTextRange == nil,
              !(field.text ?? "").isEmpty, Date().timeIntervalSince(lastChange) >= 1.1
        else { return }
        finish(with: field.text ?? "", how: "after dictation")
    }

    /// Test-only: acts as if dictation had inserted `text`, in pieces as tvOS can, optionally
    /// without the field's change events.
    func simulateDictation(_ text: String, pieces: Int = 1, quietly: Bool = false) {
        let words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        let size = max(1, (words.count + pieces - 1) / pieces)
        for (index, start) in stride(from: 0, to: words.count, by: size).enumerated() {
            let piece = (start == 0 ? "" : " ") + words[start..<min(words.count, start + size)].joined(separator: " ")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6 * Double(index)) { [weak self] in
                guard let self else { return }
                if quietly { self.field.text = (self.field.text ?? "") + piece } else { self.field.insertText(piece) }
            }
        }
        if pieces > 1 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6 * Double(pieces)) { [weak self] in
                self?.field.dictationRecordingDidEnd()
            }
        }
    }

    /// Test-only: types one letter, as the on-screen keyboard does.
    func simulateKeyPress(_ letter: String) {
        field.insertText(letter)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        finish(with: textField.text ?? "", how: "Done")
        return true
    }

    func textFieldDidEndEditing(_ textField: UITextField, reason: UITextField.DidEndEditingReason) {
        // Leaving the keyboard with the Back button keeps what was typed, as elsewhere on tvOS,
        // but leaving it unchanged counts as cancelling.
        let text = textField.text ?? ""
        finish(with: text == initialText ? nil : text, how: "Back")
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .menu }) {
            finish(with: nil, how: "Back")
        } else {
            super.pressesEnded(presses, with: event)
        }
    }

    private func finish(with text: String?, how: String) {
        guard !finished else { return }
        finished = true
        watch?.invalidate()
        PageHealthLog.record("typing", url: nil, detail: "finished by \(how); dictation \(dictated ? "seen" : "not seen"), recording-end \(heardRecordingEnd ? "heard" : "not heard"), biggest piece \(biggestChunk) letters")
        // Dismissing from the page below also closes the system keyboard if it's still up.
        let presenter = presentingViewController
        if field.isFirstResponder { field.resignFirstResponder() }
        presenter?.dismiss(animated: true) { [completion] in completion(text) }
    }
}

/// A text field that hears when tvOS stops recording dictation. UITextField doesn't implement
/// this part of UITextInput itself, so nothing is lost by answering it here.
final class DictationTextField: UITextField {
    var onRecordingEnded: (() -> Void)?

    override func dictationRecordingDidEnd() {
        onRecordingEnded?()
    }
}
