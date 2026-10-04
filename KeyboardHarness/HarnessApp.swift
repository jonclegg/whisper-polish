import UIKit

@main
final class HarnessAppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        window = UIWindow(frame: UIScreen.main.bounds)
        window!.rootViewController = HarnessViewController()
        window!.makeKeyAndVisible()
        return true
    }
}

/// A plain text view that records which visual line the caret sits on after every move.
final class HarnessViewController: UIViewController, UITextViewDelegate {
    private let textView = UITextView()
    private let trace = UILabel()
    private var visits: [String] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let environment = ProcessInfo.processInfo.environment
        let inset = CGFloat(Double(environment["HARNESS_INSET"] ?? "16")!)
        let fontSize = CGFloat(Double(environment["HARNESS_FONT_SIZE"] ?? "17")!)
        textView.font = .systemFont(ofSize: fontSize)
        textView.text = environment["HARNESS_TEXT"] ?? ""
        textView.accessibilityIdentifier = "editor"
        textView.autocorrectionType = .no
        textView.delegate = self
        trace.accessibilityIdentifier = "trace"
        trace.font = .systemFont(ofSize: 6)
        trace.numberOfLines = 1
        for subview in [textView, trace] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            trace.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            trace.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            trace.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            trace.heightAnchor.constraint(equalToConstant: 8),
            textView.topAnchor.constraint(equalTo: trace.bottomAnchor),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: inset),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -inset),
            textView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        textView.becomeFirstResponder()
        let atStart = ProcessInfo.processInfo.environment["HARNESS_CURSOR"] == "start"
        textView.selectedRange = NSRange(location: atStart ? 0 : (textView.text as NSString).length, length: 0)
        visits = []
        record()
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        record()
    }

    private func record() {
        let caret = textView.caretRect(for: textView.selectedTextRange!.start)
        var lineTops: [CGFloat] = []
        let layoutManager = textView.layoutManager
        layoutManager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: layoutManager.numberOfGlyphs)) { rect, _, _, _, _ in
            lineTops.append(rect.minY + self.textView.textContainerInset.top)
        }
        if layoutManager.extraLineFragmentRect.height > 0 { lineTops.append(layoutManager.extraLineFragmentRect.minY + textView.textContainerInset.top) }
        let line = max(0, (lineTops.lastIndex { $0 <= caret.midY } ?? 0))
        visits.append("\(textView.selectedRange.location):\(line):\(Int(caret.midY))")
        trace.text = visits.joined(separator: " ")
    }
}
