import UIKit

/// While space is held, the keys give way to the text the cursor moves
/// through, drawn from the same layout the cursor steers by, with the cursor
/// in it. Scrolls to keep the cursor in view.
final class TrackpadTextView: UIView {
    private static let insets = UIEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)

    private var layout: TrackpadLayout?
    private var caret = 0
    private var scroll: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .keyFill
        layer.cornerRadius = 8
        layer.cornerCurve = .continuous
        isUserInteractionEnabled = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError() }

    var textWidth: CGFloat {
        bounds.width - Self.insets.left - Self.insets.right
    }

    func show(_ layout: TrackpadLayout, caret: Int) {
        if layout !== self.layout { scroll = 0 }
        self.layout = layout
        self.caret = caret
        let visible = bounds.height - Self.insets.top - Self.insets.bottom
        let caretRect = layout.caretRect(at: caret)
        if caretRect.minY < scroll {
            scroll = caretRect.minY
        } else if caretRect.maxY > scroll + visible {
            scroll = caretRect.maxY - visible
        }
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let layout else { return }
        UIBezierPath(rect: bounds.inset(by: UIEdgeInsets(top: Self.insets.top, left: 0, bottom: Self.insets.bottom, right: 0))).addClip()
        let origin = CGPoint(x: Self.insets.left, y: Self.insets.top - scroll)
        layout.draw(at: origin)
        UIColor.systemBlue.setFill()
        UIBezierPath(roundedRect: layout.caretRect(at: caret).offsetBy(dx: origin.x, dy: origin.y), cornerRadius: 1).fill()
    }
}
