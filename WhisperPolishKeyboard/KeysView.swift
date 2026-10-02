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

/// Plain UIKit touch handling: SwiftUI gestures drop overlapping taps and
/// add latency, which makes fast typing feel broken.
final class KeyGridView: UIView {
    struct Configuration: Equatable {
        let layout: KeyboardLayout
        let bottomRow: BottomRowStyle
        let shift: KeyboardModel.Shift
        let returnKey: KeyboardModel.ReturnKey
        let showsNextKeyboard: Bool
    }

    private final class Tracker {
        enum Mode {
            case key
            case accents
            case trackpad
            case layoutSlide
        }

        var cap: KeyCapView? {
            didSet { if cap !== oldValue { landing = nil } }
        }
        var mode: Mode = .key
        let origin: CGPoint
        /// Where the touch landed in key units, while it's still on the key it landed on.
        var landing: CGPoint?
        var location: CGPoint
        var trackpadX: CGFloat = 0
        var trackpadY: CGFloat = 0
        var trackpadTime: TimeInterval = 0
        var pad: CursorTrackpad?
        var padIsStale = false
        var lastCursorMove: TimeInterval = 0
        var holdTimer: Timer?

        init(cap: KeyCapView, origin: CGPoint, landing: CGPoint?) {
            self.cap = cap
            self.origin = origin
            self.location = origin
            self.landing = landing
        }
    }

    private static let capInsets = UIEdgeInsets(top: 6, left: 3, bottom: 6, right: 3)
    private static let accentHoldDelay: TimeInterval = 0.4
    private static let trackpadHoldDelay: TimeInterval = 0.5
    private static let pointsPerCharacter: CGFloat = 9
    /// Slow drags move a line per this much travel, and fast drags several
    /// times further, so one swipe up the keyboard can cross a long note.
    private static let pointsPerLine: CGFloat = 12
    private static let lineSpeedForDoubleGain: CGFloat = 400
    private static let maxLineGain: CGFloat = 4
    /// The host applies cursor moves asynchronously, so its text is only
    /// re-read once it has had time to catch up.
    private static let hostCatchUp: TimeInterval = 0.08
    /// How far past its key a pressed finger has to slide before the key changes,
    /// so a thumb rolling as it presses doesn't land on the neighbor.
    private static let slideHysteresis: CGFloat = 12

    private unowned let model: KeyboardModel
    private var configuration: Configuration?
    private var rows: [[KeyCapView]] = []
    private var trackers: [UITouch: Tracker] = [:]
    private let popup = KeyPopupView()
    private let accents = AccentPopupView()

    init(model: KeyboardModel) {
        self.model = model
        super.init(frame: .zero)
        isMultipleTouchEnabled = true
        // Not `.clear`: keyboard extensions drop touches on fully transparent
        // pixels, which would lose every tap in the gaps between keys.
        backgroundColor = UIColor(white: 0, alpha: 0.02)
        clipsToBounds = false
        popup.isHidden = true
        accents.isHidden = true
        addSubview(popup)
        addSubview(accents)
    }

    required init?(coder: NSCoder) { fatalError() }

    func apply(_ newConfiguration: Configuration) {
        guard newConfiguration != configuration else { return }
        if newConfiguration.layout != configuration?.layout
            || newConfiguration.bottomRow != configuration?.bottomRow
            || newConfiguration.showsNextKeyboard != configuration?.showsNextKeyboard {
            rebuild(newConfiguration)
        }
        configuration = newConfiguration
        rows.joined().forEach { $0.apply(shift: newConfiguration.shift, returnKey: newConfiguration.returnKey) }
    }

    /// Touches that are mid-press keep their tracker so sliding off 123 still lands on the new layout.
    private func rebuild(_ configuration: Configuration) {
        rows.joined().forEach { $0.removeFromSuperview() }
        popup.hide()
        rows = configuration.layout.rows(bottomRow: configuration.bottomRow, showsNextKeyboard: configuration.showsNextKeyboard).map { specs in
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

    /// The key whose area holds the touch, gaps included; row edges belong to the end keys.
    private func cap(at point: CGPoint) -> KeyCapView? {
        guard !rows.isEmpty, bounds.width > 0, bounds.height > 0 else { return nil }
        let units = keyUnits(point)
        let row = rows[min(max(Int(units.y), 0), rows.count - 1)]
        return row.map(\.spec).index(atUnit: units.x).map { row[$0] }
    }

    /// `point` in key units: x in key widths, y in rows.
    private func keyUnits(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x / (bounds.width / KeySpec.rowUnits), y: point.y / (bounds.height / CGFloat(rows.count)))
    }

    /// Near a letter's edge, the neighbor that better fits the word wins, like
    /// the system keyboard's invisible key resizing.
    private func intendedCap(for nearest: KeyCapView, at point: CGPoint) -> KeyCapView {
        guard configuration?.layout == .letters, case .character(let character) = nearest.spec.key else { return nearest }
        let letter = model.resolveLetter(at: point, nearest: character)
        guard letter != character else { return nearest }
        return rows.joined().first { $0.spec.key == .character(letter) } ?? nearest
    }

    // MARK: - Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            commitHeldTypingKeys()
            let point = touch.location(in: self)
            guard let nearest = cap(at: point) else { continue }
            let units = keyUnits(point)
            let cap = intendedCap(for: nearest, at: units)
            let tracker = Tracker(cap: cap, origin: point, landing: units)
            trackers[touch] = tracker
            UIDevice.current.playInputClick()
            press(cap)
            if case .layout = cap.spec.key { tracker.mode = .layoutSlide }
            scheduleHold(for: tracker)
            model.keyDown(cap.spec.key)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let tracker = trackers[touch] else { continue }
            let point = touch.location(in: self)
            tracker.location = point
            switch tracker.mode {
            case .trackpad:
                moveCursor(tracker, to: point, at: touch.timestamp)
            case .accents:
                accents.select(atX: convert(point, to: accents).x)
            case .layoutSlide:
                let next = cap(at: point)
                guard next !== tracker.cap else { continue }
                if let current = tracker.cap { release(current) }
                tracker.cap = next
                if let next { press(next) }
            case .key:
                guard let current = tracker.cap, current.spec.key.slides,
                      !current.frame.insetBy(dx: -Self.slideHysteresis, dy: -Self.slideHysteresis).contains(point),
                      let next = cap(at: point), next !== current, next.spec.key.slides,
                      // A resolved neighbor stays put while the finger rests on the key it touched.
                      tracker.landing == nil || next !== cap(at: tracker.origin) else { continue }
                release(current)
                tracker.cap = next
                press(next)
                scheduleHold(for: tracker)
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let tracker = trackers.removeValue(forKey: touch) else { continue }
            tracker.holdTimer?.invalidate()
            switch tracker.mode {
            case .trackpad:
                endTrackpad()
            case .accents:
                accents.hide()
                if let cap = tracker.cap { release(cap) }
                model.keyUp(.character(accents.selection))
            case .layoutSlide:
                guard let cap = tracker.cap else { continue }
                release(cap)
                if case .character(let character) = cap.spec.key { model.typeAfterLayoutSlide(character) }
            case .key:
                guard let cap = tracker.cap else { continue }
                release(cap)
                model.keyUp(cap.spec.key, at: tracker.landing)
            }
        }
    }

    /// The system cancels touches near the screen edges when it suspects a
    /// system swipe; a letter tap that gets cancelled was still a letter tap.
    /// Space is left out because swiping up from the bottom row goes home.
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let tracker = trackers.removeValue(forKey: touch) else { continue }
            tracker.holdTimer?.invalidate()
            if tracker.mode == .trackpad { endTrackpad() }
            if tracker.mode == .accents { accents.hide() }
            guard let cap = tracker.cap else { continue }
            release(cap)
            if tracker.mode == .key, case .character = cap.spec.key {
                model.keyUp(cap.spec.key, at: tracker.landing)
            } else {
                model.keyCancelled(cap.spec.key)
            }
        }
    }

    /// Fast typists land the next finger before lifting the last one; the
    /// held key types immediately so letters never come out of order.
    private func commitHeldTypingKeys() {
        for (touch, tracker) in trackers where tracker.mode == .key {
            guard let cap = tracker.cap, cap.spec.key.slides else { continue }
            tracker.holdTimer?.invalidate()
            trackers.removeValue(forKey: touch)
            release(cap)
            model.keyUp(cap.spec.key, at: tracker.landing)
        }
    }

    // MARK: - Holding

    private func scheduleHold(for tracker: Tracker) {
        tracker.holdTimer?.invalidate()
        tracker.holdTimer = nil
        guard tracker.mode == .key, let cap = tracker.cap else { return }
        let delay: TimeInterval
        switch cap.spec.key {
        case .space:
            delay = Self.trackpadHoldDelay
        case .character(let character) where !Accents.choices(for: character).isEmpty:
            delay = Self.accentHoldDelay
        default:
            return
        }
        tracker.holdTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self, weak tracker] _ in
            MainActor.assumeIsolated {
                guard let self, let tracker, self.trackers.values.contains(where: { $0 === tracker }) else { return }
                if tracker.cap?.spec.key == .space {
                    self.startTrackpad(tracker, at: tracker.location)
                } else {
                    self.showAccents(tracker)
                }
            }
        }
    }

    private func showAccents(_ tracker: Tracker) {
        guard let cap = tracker.cap, case .character(let character) = cap.spec.key else { return }
        popup.hide()
        tracker.mode = .accents
        accents.show(
            choices: Accents.choices(for: character),
            displayed: Accents.choices(for: character).map(cap.displayed),
            over: cap.frame.inset(by: Self.capInsets),
            within: bounds
        )
    }

    // MARK: - Trackpad

    /// Holding the space bar turns the keys into a trackpad that moves the cursor.
    private func startTrackpad(_ tracker: Tracker, at point: CGPoint) {
        tracker.holdTimer?.invalidate()
        tracker.mode = .trackpad
        tracker.trackpadX = point.x
        tracker.trackpadY = point.y
        tracker.trackpadTime = ProcessInfo.processInfo.systemUptime
        tracker.pad = nil
        tracker.padIsStale = false
        if let cap = tracker.cap { release(cap) }
        UIView.animate(withDuration: 0.15) {
            self.rows.joined().forEach { $0.setLabelHidden(true) }
        }
    }

    private func moveCursor(_ tracker: Tracker, to point: CGPoint, at time: TimeInterval) {
        let xSteps = Int((point.x - tracker.trackpadX) / Self.pointsPerCharacter)
        tracker.trackpadX += CGFloat(xSteps) * Self.pointsPerCharacter
        let dy = point.y - tracker.trackpadY
        let speed = abs(dy) / CGFloat(max(time - tracker.trackpadTime, 1.0 / 120))
        let gain = min(1 + speed / Self.lineSpeedForDoubleGain, Self.maxLineGain)
        tracker.trackpadY = point.y
        tracker.trackpadTime = time

        if tracker.pad == nil || (tracker.padIsStale && time - tracker.lastCursorMove > Self.hostCatchUp) {
            let context = model.trackpadContext()
            tracker.pad = CursorTrackpad(
                before: context.before,
                after: context.after,
                keyboardWidth: bounds.width,
                preferredColumn: tracker.pad?.preferredColumn
            )
            tracker.padIsStale = false
        }
        guard var pad = tracker.pad, !tracker.padIsStale else { return }
        var offset = 0
        if xSteps != 0 {
            let moved = pad.moveHorizontally(by: xSteps)
            offset += moved.offset
            tracker.padIsStale = moved.reachedEdge
        }
        if dy != 0, !tracker.padIsStale {
            let moved = pad.moveVertically(by: Double(dy * gain / Self.pointsPerLine))
            offset += moved.offset
            if moved.reachedEdge {
                tracker.padIsStale = true
                // Hosts cut the shared text at paragraphs, so stepping over
                // the boundary is what lets the next read see further.
                if dy < 0, pad.isAtStart { offset -= 1 }
                if dy > 0, pad.isAtEnd { offset += 1 }
            }
        }
        tracker.pad = pad
        guard offset != 0 else { return }
        tracker.lastCursorMove = time
        model.moveCursor(by: offset)
    }

    private func endTrackpad() {
        UIView.animate(withDuration: 0.15) {
            self.rows.joined().forEach { $0.setLabelHidden(false) }
        }
        model.cursorMoveEnded()
    }

    // MARK: - Pressing

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
    private var returnKey = KeyboardModel.ReturnKey()

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
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.6
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
        apply(shift: .off, returnKey: returnKey)
    }

    required init?(coder: NSCoder) { fatalError() }

    var displayedText: String {
        guard case .character(let character) = spec.key else { return "" }
        return displayed(character)
    }

    func displayed(_ character: String) -> String {
        shift == .off ? character : character.uppercased()
    }

    func apply(shift: KeyboardModel.Shift, returnKey: KeyboardModel.ReturnKey) {
        self.shift = shift
        self.returnKey = returnKey
        label.text = nil
        label.textColor = .label
        icon.image = nil
        let symbolConfiguration = UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)
        switch spec.key {
        case .character(let character):
            label.font = .systemFont(ofSize: character.count > 1 ? 16 : 23)
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
            label.text = returnKey.label
            if returnKey.isPrimary { label.textColor = .white }
            if !returnKey.isEnabled { label.textColor = .tertiaryLabel }
        case .layout(let layout):
            label.font = .systemFont(ofSize: 16)
            label.text = layout.switchLabel
        case .nextKeyboard:
            break
        }
        updateFill()
    }

    func setLabelHidden(_ hidden: Bool) {
        label.alpha = hidden ? 0 : 1
        icon.alpha = hidden ? 0 : 1
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        cap.frame = bounds.inset(by: capInsets)
        // Without a path, every key's shadow is re-rendered offscreen each frame.
        cap.layer.shadowPath = UIBezierPath(roundedRect: cap.bounds, cornerRadius: cap.layer.cornerRadius).cgPath
        label.frame = cap.bounds.insetBy(dx: 2, dy: 0)
        icon.frame = cap.bounds
    }

    private func updateFill() {
        switch spec.key {
        case .character, .space:
            cap.backgroundColor = isPressed ? .modifierKeyFill : .keyFill
        case .shift where shift != .off:
            cap.backgroundColor = .keyFill
        case .returnKey where returnKey.isPrimary && returnKey.isEnabled:
            cap.backgroundColor = isPressed ? .keyFill : .systemBlue
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
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.5
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(text: String, over capFrame: CGRect, owner: KeyCapView) {
        self.owner = owner
        label.text = text
        frame = CGRect(x: capFrame.minX - 6, y: capFrame.minY - 50, width: capFrame.width + 12, height: capFrame.height + 50)
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: layer.cornerRadius).cgPath
        label.frame = CGRect(x: 4, y: 0, width: bounds.width - 8, height: 54)
        isHidden = false
    }

    func hide() {
        owner = nil
        isHidden = true
    }
}

/// The strip of accented letters shown when a key is held; sliding picks one.
final class AccentPopupView: UIView {
    private static let padding: CGFloat = 6

    private var choices: [String] = []
    private var labels: [UILabel] = []
    private var cellWidth: CGFloat = 0
    /// Near the right edge the strip grows leftward, keeping the key's own letter under the finger.
    private var growsLeft = false
    private var selectedIndex = 0

    var selection: String { choices[selectedIndex] }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .keyFill
        layer.cornerRadius = 10
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.25
        layer.shadowRadius = 3
        layer.shadowOffset = CGSize(width: 0, height: 1)
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(choices: [String], displayed: [String], over capFrame: CGRect, within container: CGRect) {
        self.choices = choices
        labels.forEach { $0.removeFromSuperview() }
        cellWidth = max(capFrame.width, 30)
        let width = cellWidth * CGFloat(choices.count) + Self.padding * 2
        growsLeft = capFrame.minX - Self.padding + width > container.maxX
        let x = growsLeft ? capFrame.maxX + Self.padding - width : capFrame.minX - Self.padding
        frame = CGRect(x: max(x, container.minX), y: capFrame.minY - capFrame.height - 10, width: width, height: capFrame.height + 4)
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: layer.cornerRadius).cgPath
        labels = displayed.enumerated().map { index, text in
            let label = UILabel()
            label.text = text
            label.font = .systemFont(ofSize: text.count > 1 ? 16 : 26)
            label.textAlignment = .center
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.5
            label.layer.cornerRadius = 6
            label.layer.masksToBounds = true
            let position = growsLeft ? choices.count - 1 - index : index
            label.frame = CGRect(x: Self.padding + CGFloat(position) * cellWidth, y: 2, width: cellWidth, height: bounds.height - 4)
            addSubview(label)
            return label
        }
        select(index: 0)
        isHidden = false
    }

    func select(atX x: CGFloat) {
        let position = min(max(Int((x - Self.padding) / cellWidth), 0), choices.count - 1)
        select(index: growsLeft ? choices.count - 1 - position : position)
    }

    func hide() {
        isHidden = true
    }

    private func select(index: Int) {
        selectedIndex = index
        for (labelIndex, label) in labels.enumerated() {
            let isSelected = labelIndex == index
            label.backgroundColor = isSelected ? .systemBlue : .clear
            label.textColor = isSelected ? .white : .label
        }
    }
}
