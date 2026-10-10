import Observation
import SwiftUI
import UIKit

/// Adopting `UIInputViewAudioFeedback` lets `playInputClick()` follow the system keyboard-click setting.
final class ClickingInputView: UIInputView, UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
}

final class KeyboardViewController: UIInputViewController {
    private lazy var model = KeyboardModel(controller: self)
    private lazy var keyGrid = KeyGridView(model: model)
    private var dictationTimer: Timer?
    private var pasteboardObserver: NSObjectProtocol?
    private var isSyncScheduled = false

    override func loadView() {
        view = ClickingInputView(frame: .zero, inputViewStyle: .keyboard)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        requestSupplementaryLexicon { [weak self] lexicon in
            Task { @MainActor in self?.model.predictor.setSupplementaryLexicon(lexicon) }
        }
        let host = UIHostingController(rootView: KeyboardView(model: model))
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(host)
        view.addSubview(host.view)
        // The keys live outside the SwiftUI hierarchy so SwiftUI's gesture
        // recognizers can never delay or cancel their touches.
        keyGrid.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(keyGrid)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.heightAnchor.constraint(equalToConstant: KeyboardView.height),
            keyGrid.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            keyGrid.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            keyGrid.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            keyGrid.heightAnchor.constraint(equalToConstant: KeyboardView.keysHeight),
        ])
        host.didMove(toParent: self)
        pasteConfiguration = UIPasteConfiguration(forAccepting: NSString.self)
        observeModel()
    }

    private func observeModel() {
        withObservationTracking {
            keyGrid.apply(KeyGridView.Configuration(
                layout: model.layout,
                bottomRow: model.bottomRow,
                shift: model.shift,
                returnKey: model.returnKey,
                showsNextKeyboard: model.needsInputModeSwitchKey
            ))
            let isPicking = model.isPickingStyle
            if keyGrid.isUserInteractionEnabled == isPicking {
                keyGrid.isUserInteractionEnabled = !isPicking
                UIView.animate(withDuration: 0.2) { self.keyGrid.alpha = isPicking ? 0 : 1 }
            }
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.observeModel() }
        }
    }

    /// The system gate recognizers otherwise hold back touches near the
    /// screen edges, so taps on the outer and bottom keys arrive late or not
    /// at all. Depending on the iOS version they sit on the window or on the
    /// views hosting the keyboard.
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        var ancestor: UIView? = view
        while let current = ancestor {
            current.gestureRecognizers?.forEach { $0.delaysTouchesBegan = false }
            ancestor = current.superview
        }
        view.window?.gestureRecognizers?.forEach { $0.delaysTouchesBegan = false }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        model.refresh()
        pasteboardObserver = NotificationCenter.default.addObserver(
            forName: UIPasteboard.changedNotification,
            object: UIPasteboard.general,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.updatePasteOffer() }
        }
        // The app hands dictation back through the app group, possibly
        // after the keyboard is already showing again.
        dictationTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.insertPendingDictation() }
        }
        model.insertPendingDictation()
    }

    /// The bar's paste control delivers the pasteboard here once the user taps it.
    override func paste(itemProviders: [NSItemProvider]) {
        guard let provider = itemProviders.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return }
        _ = provider.loadObject(ofClass: NSString.self) { [weak self] object, _ in
            guard let text = object as? NSString else { return }
            Task { @MainActor in self?.model.paste(text as String) }
        }
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        scheduleSync()
    }

    override func selectionDidChange(_ textInput: UITextInput?) {
        super.selectionDidChange(textInput)
        scheduleSync()
    }

    /// The host reports each keystroke several times; one refresh per run loop pass is enough.
    private func scheduleSync() {
        guard !isSyncScheduled else { return }
        isSyncScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            isSyncScheduled = false
            model.textDidChange()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        model.savePersonal()
        dictationTimer?.invalidate()
        dictationTimer = nil
        if let pasteboardObserver {
            NotificationCenter.default.removeObserver(pasteboardObserver)
            self.pasteboardObserver = nil
        }
    }

    /// Keyboards can't call `UIApplication.open` directly, so walk the
    /// responder chain to the host application and invoke it dynamically.
    func openContainingApp(_ url: URL) {
        typealias OpenURL = @convention(c) (NSObject, Selector, NSURL, NSDictionary, NSObject?) -> Void
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let current = responder {
            if current.isKind(of: NSClassFromString("UIApplication")!) {
                let open = unsafeBitCast(current.method(for: selector), to: OpenURL.self)
                open(current, selector, url as NSURL, NSDictionary(), nil)
                return
            }
            responder = current.next
        }
    }
}
