import AppKit

/// Compact capsule toolbar pinned to the top-right of a floating panel.
/// Hidden until the pointer hovers the panel; expands in pen mode.
final class PanelToolbar: NSVisualEffectView {

    enum Action {
        case pen, copy, save, close
        case color(Int), undo, clear, done
        case toggleLock, ocr
        case tool(Int)
    }

    enum Mode { case normal, pen }

    static let penColors: [NSColor] = [.systemRed, .systemYellow, .systemGreen, .systemBlue]

    /// SF Symbols + tooltips for the annotation tools, in AnnotationTool order.
    private static let toolButtons: [(symbol: String, tip: String)] = [
        ("pencil.tip", "펜 — 자유곡선"),
        ("highlighter", "형광펜 — 반투명 강조"),
        ("arrow.up.right", "화살표"),
        ("square", "사각형"),
        ("square.grid.3x3", "모자이크"),
        ("", "텍스트"),
        ("hand.point.up.left", "이동 — 주석을 드래그로 옮기기"),
    ]
    private static func toolTip(at index: Int) -> String {
        L10n.tr(toolButtons[index].tip)
    }

    /// Size of the button stack, including insets — reliable right after
    /// rebuild(), unlike NSVisualEffectView.fittingSize.
    var contentSize: CGSize { stack.fittingSize }

    var onAction: ((Action) -> Void)?
    /// Fired when the pointer leaves the toolbar — used to collapse a
    /// detached bar once the cursor is off both panel and bar.
    var onExit: (() -> Void)?

    private(set) var mode: Mode = .normal
    private var penModeActive: Bool { mode == .pen }
    private var colorIndex = 0
    private var toolIndex = 0
    private var aspectLocked = true
    private let stack = NSStackView()
    private var tracking: NSTrackingArea?

    /// Semi-transparent while idle so it doesn't obscure the image;
    /// full opacity while the pointer is over the toolbar itself.
    private static let restingAlpha: CGFloat = 0.8

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

    func setToolIndex(_ index: Int) {
        toolIndex = index
        rebuild()
    }

    func setLocked(_ locked: Bool) {
        aspectLocked = locked
        rebuild()
    }

    func show() {
        isHidden = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            animator().alphaValue = Self.restingAlpha
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        tracking = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(tracking!)
    }

    override func mouseEntered(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            animator().alphaValue = 1
        }
    }

    override func mouseExited(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            animator().alphaValue = Self.restingAlpha
        }
        onExit?()
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
            addButton(symbol: "pencil.tip", tag: 1, tip: L10n.tr("펜으로 표시 (P)"))
            addButton(symbol: "doc.on.doc", tag: 2, tip: L10n.tr("복사 (⌘C)"))
            addButton(symbol: "square.and.arrow.down", tag: 3, tip: L10n.tr("다른 이름으로 저장 (⌘S)"))
            addButton(symbol: "text.viewfinder", tag: 9, tip: L10n.tr("텍스트 추출 (OCR) — 클립보드로 복사"))
            addButton(symbol: aspectLocked ? "lock.fill" : "lock.open.fill",
                      tag: 8, tip: L10n.tr("비율 잠금 — 해제 시 자유 리사이즈"),
                      tint: aspectLocked ? nil : .controlAccentColor)
            addButton(symbol: "xmark", tag: 4, tip: L10n.tr("닫기 (⌘W/Esc)"))
        case .pen:
            for (i, spec) in Self.toolButtons.enumerated() {
                // The text tool uses a literal "Aa" — SF Symbols' textformat
                // glyph localizes to "가가" under Korean, which reads oddly.
                if spec.symbol.isEmpty {
                    addTextButton(title: "Aa", tag: 200 + i, tip: Self.toolTip(at: i),
                                  tint: i == toolIndex ? .controlAccentColor : nil)
                } else {
                    addButton(symbol: spec.symbol, tag: 200 + i, tip: Self.toolTip(at: i),
                              tint: i == toolIndex ? .controlAccentColor : nil)
                }
            }
            addSeparator()
            for (i, color) in Self.penColors.enumerated() {
                addColorButton(index: i, color: color)
            }
            addSeparator()
            addButton(symbol: "arrow.uturn.left", tag: 5, tip: L10n.tr("되돌리기 (⌘Z)"))
            addButton(symbol: "trash", tag: 6, tip: L10n.tr("전체 지우기"))
            addButton(symbol: "checkmark", tag: 7, tip: L10n.tr("완료 — 이미지에 적용"))
        }
        // Keep the top-right corner anchored as the capsule resizes.
        // Use the stack's fitting size — the effect view's fittingSize can
        // lag behind a rebuild and produce a too-narrow frame that lets
        // buttons spill past the panel edge.
        let size = contentSize
        if let host = superview {
            frame = CGRect(x: host.bounds.maxX - size.width - 8,
                           y: host.bounds.maxY - size.height - 8,
                           width: size.width, height: size.height)
        } else {
            frame.size = size
        }
    }

    private func addButton(symbol: String, tag: Int, tip: String, tint: NSColor? = nil) {
        let button = NSButton()
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = tint ?? .labelColor
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

    private func addTextButton(title: String, tag: Int, tip: String, tint: NSColor? = nil) {
        let button = NSButton()
        button.isBordered = false
        button.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: tint ?? .labelColor,
            ])
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
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: L10n.tr("색상"))
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
        case 8: action = .toggleLock
        case 9: action = .ocr
        default:
            // Tool buttons are tagged 200+, color swatches 100+.
            action = sender.tag >= 200
                ? .tool(sender.tag - 200)
                : .color(sender.tag - 100)
        }
        onAction?(action)
    }
}
