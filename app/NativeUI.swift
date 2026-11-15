import AppKit

func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular,
                   color: NSColor = .labelColor) -> NSTextField {
    let view = MooringPrivacyLabel(labelWithString: "")
    view.stringValue = text
    view.observePrivacy()
    view.font = .systemFont(ofSize: size, weight: weight)
    view.textColor = color
    view.lineBreakMode = .byWordWrapping
    view.maximumNumberOfLines = 0
    view.preferredMaxLayoutWidth = 440
    view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return view
}

func stack(_ views: [NSView], orientation: NSUserInterfaceLayoutOrientation = .vertical,
                   spacing: CGFloat = 12) -> NSStackView {
    let view = NSStackView(views: views)
    view.orientation = orientation
    view.alignment = orientation == .vertical ? .leading : .centerY
    view.distribution = .fill
    view.spacing = spacing
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
}
