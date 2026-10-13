import UIKit

/// Takes taps on the suggestion bar's slots outside SwiftUI, like the keys do:
/// SwiftUI's buttons there held back and dropped taps. SwiftUI still draws the
/// slots underneath; this view only finds which slot was tapped and shows it
/// pressed at once.
final class SuggestionTapView: UIView {
    /// How many slots split the width; none means the bar shows something else.
    var slotCount = 0 {
        didSet {
            isHidden = slotCount == 0
            if slotCount == 0 { release() }
        }
    }

    private unowned let model: KeyboardModel
    private let highlight = UIView()
    private var pressed: Int?

    init(model: KeyboardModel) {
        self.model = model
        super.init(frame: .zero)
        // Not `.clear`: keyboard extensions drop touches on fully transparent pixels.
        backgroundColor = UIColor(white: 0, alpha: 0.02)
        isMultipleTouchEnabled = false
        highlight.backgroundColor = UIColor.keyFill.withAlphaComponent(0.7)
        highlight.layer.cornerRadius = 8
        highlight.isHidden = true
        addSubview(highlight)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func slot(at point: CGPoint) -> Int? {
        guard slotCount > 0, bounds.insetBy(dx: -12, dy: -12).contains(point) else { return nil }
        return min(max(Int(point.x / (bounds.width / CGFloat(slotCount))), 0), slotCount - 1)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let point = touches.first?.location(in: self), let slot = slot(at: point) else { return }
        pressed = slot
        let width = bounds.width / CGFloat(slotCount)
        highlight.frame = CGRect(x: CGFloat(slot) * width, y: (bounds.height - 32) / 2, width: width, height: 32)
        highlight.isHidden = false
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let point = touches.first?.location(in: self), pressed != nil, slot(at: point) != pressed else { return }
        release()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        let tapped = pressed
        release()
        if let tapped { model.tapBarSlot(tapped) }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        release()
    }

    private func release() {
        pressed = nil
        highlight.isHidden = true
    }
}
