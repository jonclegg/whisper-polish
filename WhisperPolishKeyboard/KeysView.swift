import SwiftUI
import UIKit

extension UIColor {
    static let keyFill = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.42, alpha: 1) : .white }
    static let modifierKeyFill = UIColor {
        $0.userInterfaceStyle == .dark
            ? UIColor(white: 0.27, alpha: 1)
            : UIColor(red: 0.67, green: 0.69, blue: 0.73, alpha: 1)
    }
}

struct KeysView: UIViewRepresentable {
    let model: KeyboardModel

    func makeUIView(context: Context) -> KeyGridView {
        KeyGridView(model: model)
    }

    func updateUIView(_ view: KeyGridView, context: Context) {
        view.apply(KeyGridView.Configuration(
            layout: model.layout,
            shift: model.shift,
            showsNextKeyboard: model.needsInputModeSwitchKey
        ))
    }
}

/// Plain UIKit touch handling: SwiftUI gestures drop overlapping taps and
/// add latency, which makes fast typing feel broken.
final class KeyGridView: UIView {
    struct Configuration: Equatable {
        let layout: KeyboardLayout
        let shift: KeyboardModel.Shift
        let showsNextKeyboard: Bool
    }

    private static let capInsets = UIEdgeInsets(top: 6, left: 3, bottom: 6, right: 3)

    private unowned let model: KeyboardModel
    private var configuration: Configuration?
    private var rows: [[KeyCapView]] = []
    private var activeTouches: [UITouch: KeyCapView] = [:]
    private let popup = KeyPopupView()

    init(model: KeyboardModel) {
        self.model = model
        super.init(frame: .zero)
        isMultipleTouchEnabled = true
        clipsToBounds = false
        popup.isHidden = true
        addSubview(popup)
    }

    required init?(coder: NSCoder) { fatalError() }

    func apply(_ newConfiguration: Configuration) {
        guard newConfiguration != configuration else { return }
        if newConfiguration.layout != configuration?.layout
            || newConfiguration.showsNextKeyboard != configuration?.showsNextKeyboard {
            rebuild(newConfiguration)
        }
        configuration = newConfiguration
        rows.joined().forEach { $0.apply(shift: newConfiguration.shift) }
    }

    private func rebuild(_ configuration: Configuration) {
        activeTouches.removeAll()
        rows.joined().forEach { $0.removeFromSuperview() }
        rows = configuration.layout.rows(showsNextKeyboard: configuration.showsNextKeyboard).map { specs in
            specs.map { spec in
                let cap = KeyCapView(spec: spec, controller: model.controller)
                insertSubview(cap, belowSubview: popup)
                return cap
            }
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !rows.isEmpty else { return }
        let unit = bounds.width / KeySpec.rowUnits
        let rowHeight = bounds.height / CGFloat(rows.count)
        for (index, row) in rows.enumerated() {
            let rowWidth = row.reduce(0) { $0 + $1.spec.units } * unit
            var x = (bounds.width - rowWidth) / 2
            for cap in row {
                let width = cap.spec.units * unit
                cap.frame = CGRect(x: x, y: CGFloat(index) * rowHeight, width: width, height: rowHeight)
                cap.capInsets = Self.capInsets
                x += width
            }
        }
    }

    /// The key nearest the touch within its row, so gaps and row edges still hit a key.
    private func cap(at point: CGPoint) -> KeyCapView? {
        guard !rows.isEmpty, bounds.height > 0 else { return nil }
        let rowIndex = min(max(Int(point.y / (bounds.height / CGFloat(rows.count))), 0), rows.count - 1)
        return rows[rowIndex].min { abs($0.frame.midX - point.x) < abs($1.frame.midX - point.x) }
    }

    // MARK: - Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            commitHeldTypingKeys()
            guard let cap = cap(at: touch.location(in: self)) else { continue }
            activeTouches[touch] = cap
            press(cap)
            model.keyDown(cap.spec.key)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let current = activeTouches[touch], current.spec.key.slides,
                  let next = cap(at: touch.location(in: self)), next !== current, next.spec.key.slides else { continue }
            release(current)
            activeTouches[touch] = next
            press(next)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let cap = activeTouches.removeValue(forKey: touch) else { continue }
            release(cap)
            if cap.spec.key == .delete { model.keyReleased() }
            model.keyUp(cap.spec.key)
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let cap = activeTouches.removeValue(forKey: touch) else { continue }
            release(cap)
            if cap.spec.key == .delete { model.keyReleased() }
        }
    }

    /// Fast typists land the next finger before lifting the last one; the
    /// held key types immediately so letters never come out of order.
    private func commitHeldTypingKeys() {
        for (touch, cap) in activeTouches where cap.spec.key.slides {
            activeTouches.removeValue(forKey: touch)
            release(cap)
            model.keyUp(cap.spec.key)
        }
    }

    private func press(_ cap: KeyCapView) {
        cap.isPressed = true
        guard case .character = cap.spec.key else { return }
        popup.show(text: cap.displayedText, over: cap.frame.inset(by: Self.capInsets), owner: cap)
    }

    private func release(_ cap: KeyCapView) {
        cap.isPressed = false
        if popup.owner === cap { popup.hide() }
    }
}

private extension Key {
    /// Typing keys commit on release and can be slid between.
    var slides: Bool {
        switch self {
        case .character, .space: return true
        default: return false
        }
    }
}

final class KeyCapView: UIView {
    let spec: KeySpec
    var capInsets: UIEdgeInsets = .zero { didSet { setNeedsLayout() } }
    var isPressed = false { didSet { updateFill() } }

    private let cap = UIView()
    private let label = UILabel()
    private let icon = UIImageView()
    private var shift: KeyboardModel.Shift = .off

    init(spec: KeySpec, controller: UIInputViewController) {
        self.spec = spec
        super.init(frame: .zero)
        cap.layer.cornerRadius = 8
        cap.layer.shadowColor = UIColor.black.cgColor
        cap.layer.shadowOpacity = 0.3
        cap.layer.shadowRadius = 0
        cap.layer.shadowOffset = CGSize(width: 0, height: 1)
        cap.isUserInteractionEnabled = false
        addSubview(cap)
        // Touches go to the grid, except the globe, which is a real button.
        isUserInteractionEnabled = spec.key == .nextKeyboard

        label.textAlignment = .center
        label.textColor = .label
        icon.tintColor = .label
        icon.contentMode = .center
        cap.addSubview(label)
        cap.addSubview(icon)

        if spec.key == .nextKeyboard {
            let button = UIButton(type: .system)
            button.setImage(UIImage(systemName: "globe"), for: .normal)
            button.tintColor = .label
            button.addTarget(controller, action: #selector(UIInputViewController.handleInputModeList(from:with:)), for: .allTouchEvents)
            button.frame = bounds
            button.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(button)
        }
        apply(shift: .off)
    }

    required init?(coder: NSCoder) { fatalError() }

    var displayedText: String {
        guard case .character(let character) = spec.key else { return "" }
        return shift == .off ? character : character.uppercased()
    }

    func apply(shift: KeyboardModel.Shift) {
        self.shift = shift
        label.text = nil
        icon.image = nil
        let symbolConfiguration = UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)
        switch spec.key {
        case .character:
            label.font = .systemFont(ofSize: 23)
            label.text = displayedText
        case .shift:
            let name = switch shift {
            case .off: "shift"
            case .once: "shift.fill"
            case .locked: "capslock.fill"
            }
            icon.image = UIImage(systemName: name, withConfiguration: symbolConfiguration)
        case .delete:
            icon.image = UIImage(systemName: "delete.left", withConfiguration: symbolConfiguration)
        case .space:
            label.font = .systemFont(ofSize: 16)
            label.text = "space"
        case .returnKey:
            label.font = .systemFont(ofSize: 16)
            label.text = "return"
        case .layout(let layout):
            label.font = .systemFont(ofSize: 16)
            label.text = layout.switchLabel
        case .nextKeyboard:
            break
        }
        updateFill()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        cap.frame = bounds.inset(by: capInsets)
        label.frame = cap.bounds
        icon.frame = cap.bounds
    }

    private func updateFill() {
        switch spec.key {
        case .character, .space:
            cap.backgroundColor = isPressed ? .modifierKeyFill : .keyFill
        case .shift where shift != .off:
            cap.backgroundColor = .keyFill
        default:
            cap.backgroundColor = isPressed ? .keyFill : .modifierKeyFill
        }
    }
}

/// The enlarged letter shown above a pressed key.
final class KeyPopupView: UIView {
    private(set) weak var owner: KeyCapView?
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .keyFill
        layer.cornerRadius = 10
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.25
        layer.shadowRadius = 3
        layer.shadowOffset = CGSize(width: 0, height: 1)
        isUserInteractionEnabled = false
        label.font = .systemFont(ofSize: 32)
        label.textAlignment = .center
        label.textColor = .label
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(text: String, over capFrame: CGRect, owner: KeyCapView) {
        self.owner = owner
        label.text = text
        frame = CGRect(x: capFrame.minX - 6, y: capFrame.minY - 50, width: capFrame.width + 12, height: capFrame.height + 50)
        label.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 54)
        isHidden = false
    }

    func hide() {
        owner = nil
        isHidden = true
    }
}
