import AppKit

/// Compact capsule toolbar pinned to the top-right of a floating panel.
/// Hidden until the pointer hovers the panel; expands in pen mode.
final class PanelToolbar: NSVisualEffectView {

    enum Action {
        case pen, copy, save, close
        case color(Int), undo, clear, done
    }

    enum Mode { case normal, pen }

    static let penColors: [NSColor] = [.systemRed, .systemYellow, .systemGreen, .systemBlue]

    var onAction: ((Action) -> Void)?

    private(set) var mode: Mode = .normal
    private var penModeActive: Bool { mode == .pen }
    private var colorIndex = 0
    private let stack = NSStackView()

    override init(frame frameRect: NSRect = .zero) {
        super.init(frame: frameRect)
        material = .popover
        state = .active
        blendingMode = .withinWindow
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.masksToBounds = true
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        rebuild()
        alphaValue = 0
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func setMode(_ newMode: Mode) {
        mode = newMode
        rebuild()
    }

    func setColorIndex(_ index: Int) {
        colorIndex = index
        rebuild()
    }

    func show() {
        isHidden = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            animator().alphaValue = 1
        }
    }

    func hide() {
        guard !penModeActive else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor in
                if let self, self.alphaValue < 0.05, !self.penModeActive {
                    self.isHidden = true
                }
            }
        }
    }

    // MARK: - Buttons

    private func rebuild() {
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        switch mode {
        case .normal:
            addButton(symbol: "pencil.tip", tag: 1, tip: "펜으로 표시 (P)")
            addButton(symbol: "doc.on.doc", tag: 2, tip: "복사 (⌘C)")
            addButton(symbol: "square.and.arrow.down", tag: 3, tip: "다른 이름으로 저장 (⌘S)")
            addButton(symbol: "xmark", tag: 4, tip: "닫기 (Esc)")
        case .pen:
            for (i, color) in Self.penColors.enumerated() {
                addColorButton(index: i, color: color)
            }
            addSeparator()
            addButton(symbol: "arrow.uturn.left", tag: 5, tip: "되돌리기 (⌘Z)")
            addButton(symbol: "trash", tag: 6, tip: "전체 지우기")
            addButton(symbol: "checkmark", tag: 7, tip: "완료 — 이미지에 적용")
        }
        // Keep the top-right corner anchored as the capsule resizes.
        if let host = superview {
            let size = fittingSize
            frame = CGRect(x: host.bounds.maxX - size.width - 8,
                           y: host.bounds.maxY - size.height - 8,
                           width: size.width, height: size.height)
        } else {
            frame.size = fittingSize
        }
    }

    private func addButton(symbol: String, tag: Int, tip: String) {
        let button = NSButton()
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = .labelColor
        button.target = self
        button.action = #selector(buttonTapped(_:))
        button.tag = tag
        button.toolTip = tip
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 24),
            button.heightAnchor.constraint(equalToConstant: 24),
        ])
        stack.addArrangedSubview(button)
    }

    private func addColorButton(index: Int, color: NSColor) {
        let button = NSButton()
        button.isBordered = false
        let symbol = index == colorIndex ? "circle.inset.filled" : "circle.fill"
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "색상")
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = color
        button.target = self
        button.action = #selector(buttonTapped(_:))
        button.tag = 100 + index
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 20),
            button.heightAnchor.constraint(equalToConstant: 24),
        ])
        stack.addArrangedSubview(button)
    }

    private func addSeparator() {
        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            sep.widthAnchor.constraint(equalToConstant: 8),
            sep.heightAnchor.constraint(equalToConstant: 16),
        ])
        stack.addArrangedSubview(sep)
    }

    @objc private func buttonTapped(_ sender: NSButton) {
        let action: Action
        switch sender.tag {
        case 1: action = .pen
        case 2: action = .copy
        case 3: action = .save
        case 4: action = .close
        case 5: action = .undo
        case 6: action = .clear
        case 7: action = .done
        default: action = .color(sender.tag - 100)
        }
        onAction?(action)
    }
}
