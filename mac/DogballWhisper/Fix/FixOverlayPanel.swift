import AppKit

// The dialog and the diff are Fixit's, ported from
// https://github.com/ivanrvpereira/fixit (MIT License, Copyright (c) 2026
// Ivan Pereira) so ⌘⇧1 looks and behaves the way it does there. Fixit's
// custom-instruction row is left out: S1-mini only cleans text and cannot
// follow an instruction.

/// The review dialog: a working state while the model runs, then the edit
/// with Replace, Copy and Dismiss. Unlike the dictation pill it takes focus,
/// so Return replaces and Esc dismisses.
@MainActor
final class FixOverlayPanel: NSPanel, FixPresenting {
    private static let showsDiffDefaultsKey = "fixShowsDiff"
    private let stack = NSStackView()
    private let contentWidth: CGFloat = 640
    private var fixedTextForCopy = ""
    private var streamingView: NSTextView?
    private var resultTextView: NSTextView?
    private var resultOriginal = ""
    private var resultFixed = ""
    var onAccept: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onCancel: (() -> Void)?

    private var showsDiff: Bool {
        get { UserDefaults.standard.object(forKey: Self.showsDiffDefaultsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.showsDiffDefaultsKey) }
    }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 410),
            styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        title = "Dogball Whisper"
        level = .floating
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .transient]
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        contentView = stack
    }

    func showLoading(title: String, subtitle: String) {
        rebuild {
            label(title, font: .systemFont(ofSize: 16, weight: .semibold))
            label(subtitle, font: .systemFont(ofSize: 13), color: .secondaryLabelColor)

            let (scrollView, textView) = makeTextPane(height: 180)
            textView.textColor = .secondaryLabelColor
            streamingView = textView
            addRow(scrollView)

            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed))
            cancel.controlSize = .large
            cancel.keyEquivalent = "\u{1b}"
            let buttons = NSStackView(views: [spacer, cancel])
            buttons.orientation = .horizontal
            buttons.alignment = .centerY
            buttons.spacing = 8
            addRow(buttons)
        }
        showCentered()
    }

    /// The answer so far lands here while the model is writing it.
    func updateStreaming(text: String) {
        guard let streamingView else { return }
        streamingView.string = text
        streamingView.scrollToEndOfDocument(nil)
    }

    func showResult(original: String, fixed: String, acceptTitle: String) {
        onCancel = nil
        fixedTextForCopy = fixed
        resultOriginal = original
        resultFixed = fixed
        rebuild {
            let title = NSTextField(labelWithString: "Review the edit")
            title.font = .systemFont(ofSize: 16, weight: .semibold)

            let toggle = NSSegmentedControl(
                labels: ["Diff", "Result"], trackingMode: .selectOne,
                target: self, action: #selector(diffModeChanged(_:)))
            toggle.controlSize = .small
            toggle.selectedSegment = showsDiff ? 0 : 1

            let headerSpacer = NSView()
            headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let header = NSStackView(views: [title, headerSpacer, toggle])
            header.orientation = .horizontal
            header.alignment = .centerY
            addRow(header)

            let (scrollView, textView) = makeTextPane(height: 250)
            resultTextView = textView
            addRow(scrollView)
            renderResultText()

            if original == fixed {
                label("No changes suggested.", font: .systemFont(ofSize: 13), color: .secondaryLabelColor)
            }

            let copy = NSButton(title: "Copy", target: self, action: #selector(copyPressed))
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let dismiss = NSButton(title: "Dismiss", target: self, action: #selector(dismissPressed))
            let accept = NSButton(title: acceptTitle, target: self, action: #selector(acceptPressed))
            accept.keyEquivalent = "\r"
            let buttons = NSStackView(views: [copy, spacer, dismiss, accept])
            buttons.orientation = .horizontal
            buttons.alignment = .centerY
            buttons.spacing = 8
            for button in [copy, dismiss, accept] {
                button.controlSize = .large
            }
            addRow(buttons)
        }
        showCentered()
    }

    func showError(_ message: String) {
        onCancel = nil
        rebuild {
            label("Fix failed", font: .systemFont(ofSize: 16, weight: .semibold))
            label(message, font: .systemFont(ofSize: 13), color: .secondaryLabelColor)
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let dismiss = NSButton(title: "Dismiss", target: self, action: #selector(dismissPressed))
            dismiss.controlSize = .large
            dismiss.keyEquivalent = "\r"
            let buttons = NSStackView(views: [spacer, dismiss])
            buttons.orientation = .horizontal
            buttons.alignment = .centerY
            addRow(buttons)
        }
        showCentered()
    }

    func hide() {
        orderOut(nil)
    }

    @objc private func diffModeChanged(_ sender: NSSegmentedControl) {
        showsDiff = sender.selectedSegment == 0
        renderResultText()
    }

    private func renderResultText() {
        guard let textView = resultTextView else { return }
        let font = NSFont.systemFont(ofSize: 14)
        let content: NSAttributedString
        if showsDiff {
            content = InlineDiffBuilder.attributedDiff(original: resultOriginal, fixed: resultFixed, font: font)
        } else {
            content = NSAttributedString(
                string: resultFixed, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        }
        let styled = NSMutableAttributedString(attributedString: content)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        styled.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: styled.length))
        textView.textStorage?.setAttributedString(styled)
        textView.scroll(.zero)
    }

    @objc private func acceptPressed() {
        orderOut(nil)
        onAccept?()
    }

    @objc private func dismissPressed() {
        orderOut(nil)
        onDismiss?()
    }

    @objc private func copyPressed() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(fixedTextForCopy, forType: .string)
    }

    @objc private func cancelPressed() {
        orderOut(nil)
        onCancel?()
    }

    /// Esc cancels a fix still running, otherwise just dismisses.
    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
        if let onCancel {
            onCancel()
        } else {
            onDismiss?()
        }
    }

    override func close() {
        orderOut(nil)
        if let onCancel {
            onCancel()
        } else {
            onDismiss?()
        }
    }

    private func rebuild(_ build: () -> Void) {
        streamingView = nil
        resultTextView = nil
        stack.arrangedSubviews.forEach { view in
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        build()
    }

    /// Pins top-level rows to one content width so the layout stays aligned.
    private func addRow(_ view: NSView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
    }

    private func makeTextPane(height: CGFloat) -> (NSScrollView, NSTextView) {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: contentWidth, height: height))
        textView.font = .systemFont(ofSize: 14)
        textView.isEditable = false
        textView.isSelectable = true
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.autoresizingMask = [.width]
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: contentWidth, height: height))
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.wantsLayer = true
        scrollView.layer?.cornerRadius = 8
        scrollView.layer?.masksToBounds = true
        scrollView.layer?.borderWidth = 1
        scrollView.layer?.borderColor = NSColor.separatorColor.cgColor
        scrollView.documentView = textView
        scrollView.heightAnchor.constraint(equalToConstant: height).isActive = true
        return (scrollView, textView)
    }

    private func label(_ text: String, font: NSFont, color: NSColor = .labelColor) {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = color
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.preferredMaxLayoutWidth = contentWidth
        addRow(label)
    }

    private func showCentered() {
        center()
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Word-level inline diff: removed words struck through in red, added words
/// on a green highlight.
enum InlineDiffBuilder {
    enum TokenStyle: Equatable {
        case plain
        case deleted
        case added
    }

    static func attributedDiff(original: String, fixed: String, font: NSFont) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (token, style) in operations(original: original, fixed: fixed) {
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
            switch style {
            case .plain:
                break
            case .deleted:
                attributes[.foregroundColor] = NSColor.systemRed
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            case .added:
                attributes[.backgroundColor] = NSColor.systemGreen.withAlphaComponent(0.25)
            }
            result.append(NSAttributedString(string: token, attributes: attributes))
        }
        return result
    }

    /// The diff as styled tokens, in reading order: at each change, the
    /// removed words come before the words that replace them.
    static func operations(original: String, fixed: String) -> [(String, TokenStyle)] {
        guard original != fixed else { return fixed.isEmpty ? [] : [(fixed, .plain)] }

        let oldTokens = tokenize(original)
        let newTokens = tokenize(fixed)
        let diff = newTokens.difference(from: oldTokens)

        var removedOldIndices = Set<Int>()
        var insertedNewIndices = Set<Int>()
        for change in diff {
            switch change {
            case .remove(let offset, _, _):
                removedOldIndices.insert(offset)
            case .insert(let offset, _, _):
                insertedNewIndices.insert(offset)
            }
        }

        let keptOld = oldTokens.indices.filter { !removedOldIndices.contains($0) }
        let keptNew = newTokens.indices.filter { !insertedNewIndices.contains($0) }
        var ops: [(String, TokenStyle)] = []
        var previousOld = -1
        var previousNew = -1

        for index in 0..<keptOld.count {
            let oldIndex = keptOld[index]
            let newIndex = keptNew[index]
            for oldTokenIndex in (previousOld + 1)..<oldIndex {
                ops.append((oldTokens[oldTokenIndex], .deleted))
            }
            for newTokenIndex in (previousNew + 1)..<newIndex {
                ops.append((newTokens[newTokenIndex], .added))
            }
            ops.append((oldTokens[oldIndex], .plain))
            previousOld = oldIndex
            previousNew = newIndex
        }

        for oldTokenIndex in (previousOld + 1)..<oldTokens.count {
            ops.append((oldTokens[oldTokenIndex], .deleted))
        }
        for newTokenIndex in (previousNew + 1)..<newTokens.count {
            ops.append((newTokens[newTokenIndex], .added))
        }
        return ops
    }

    /// Runs of whitespace and runs of everything else, so a diff marks whole
    /// words and keeps the spacing between them.
    static func tokenize(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var tokens: [String] = []
        var current = ""
        var currentIsWhitespace: Bool?

        for character in text {
            let isWhitespace = character.isWhitespace
            if currentIsWhitespace == isWhitespace || currentIsWhitespace == nil {
                current.append(character)
                currentIsWhitespace = isWhitespace
            } else {
                tokens.append(current)
                current = String(character)
                currentIsWhitespace = isWhitespace
            }
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }
}
