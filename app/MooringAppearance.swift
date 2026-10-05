import AppKit

/// Shared presentation only. Connection policy and storage stay in Rust.
enum MooringAppearance {
    static func prepare(_ window: NSWindow) {
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.backgroundColor = MooringBrand.canvas
        window.contentView?.setAccessibilityIdentifier("Mooring." + window.title)
    }

    static func header(_ title: String, subtitle: String) -> NSStackView {
        let icon = NSImageView(image: MooringBrand.image(size: 48))
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setAccessibilityElement(false)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 48),
            icon.heightAnchor.constraint(equalToConstant: 48)
        ])
        let titleView = label(title, size: 23, weight: .semibold)
        let note = label(subtitle, size: 12, color: .secondaryLabelColor)
        note.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let copy = stack([titleView, note], spacing: 4)
        note.widthAnchor.constraint(equalTo: copy.widthAnchor).isActive = true
        return stack([icon, copy], orientation: .horizontal, spacing: 14)
    }

    static func primary(_ button: NSButton) {
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.font = .systemFont(ofSize: 13, weight: .semibold)
        let title = button.title
        let target = button.target
        let action = button.action
        let key = button.keyEquivalent
        let modifiers = button.keyEquivalentModifierMask
        let enabled = button.isEnabled
        let font = button.font
        let cell = MooringActionCell(textCell: title)
        cell.bezelStyle = .rounded
        cell.controlSize = .large
        cell.font = font
        button.cell = cell
        button.target = target
        button.action = action
        button.keyEquivalent = key
        button.keyEquivalentModifierMask = modifiers
        button.isEnabled = enabled
    }

    static func sectionTitle(_ title: String, symbol: String) -> NSStackView {
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!)
        icon.contentTintColor = MooringBrand.accent
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 20).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 20).isActive = true
        return stack([icon, label(title, size: 15, weight: .semibold)], orientation: .horizontal, spacing: 9)
    }

    static func surface(_ content: NSView, inset: CGFloat = 18) -> NSView {
        let surface = MooringSurface()
        surface.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: inset),
            content.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -inset),
            content.topAnchor.constraint(equalTo: surface.topAnchor, constant: inset),
            content.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -inset)
        ])
        return surface
    }

    static func scrollBody(_ body: NSStackView, in root: NSView) {
        let document = MooringDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(body)
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = document
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            body.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 26),
            body.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -26),
            body.topAnchor.constraint(equalTo: document.topAnchor, constant: 24),
            body.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -26)
        ])
        for view in body.arrangedSubviews { view.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true }
    }
}

private final class MooringDocumentView: NSView {
    override var isFlipped: Bool { true }
}

/// Dynamic AppKit colors are resolved again when macOS changes appearance.
final class MooringSurface: NSView {
    override var wantsUpdateLayer: Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 12
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
            layer?.borderWidth = 1
        }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// A bright action keeps graphite text, including when it is the default key.
/// AppKit still handles focus, keyboard activation, disabled state and tracking.
private final class MooringActionCell: NSButtonCell {
    override func drawBezel(withFrame frame: NSRect, in controlView: NSView) {
        let color = isEnabled ? MooringBrand.marigold : NSColor.quaternaryLabelColor
        (isHighlighted ? color.blended(withFraction: 0.12, of: MooringBrand.graphite)! : color).setFill()
        NSBezierPath(roundedRect: frame.insetBy(dx: 1, dy: 2), xRadius: 8, yRadius: 8).fill()
    }
    override func drawTitle(_ title: NSAttributedString, withFrame frame: NSRect, in controlView: NSView) -> NSRect {
        let copy = NSMutableAttributedString(attributedString: title)
        copy.addAttribute(.foregroundColor, value: isEnabled ? MooringBrand.graphite : NSColor.secondaryLabelColor,
                          range: NSRange(location: 0, length: copy.length))
        return super.drawTitle(copy, withFrame: frame, in: controlView)
    }
}
