import AppKit

/// The diagnostic footer of both viewers, Mac-to-Mac and Linux, so the two
/// look and behave the same: a 34-point band below the picture, in a window
/// and in full screen, on the window's background. The Mooring mark and one
/// line of status, then the viewer's own items, Allow ⌘-Tab… while
/// Accessibility is missing, Exit Full Screen in full screen, more of the
/// viewer's items, and a chevron that hides it. View → Diagnostic Footer
/// (⌃⌘D) toggles it. Each viewer sets the buttons' targets and actions.
final class ViewerFooter {
    static let height: CGFloat = 34
    let status = label("Connecting…", size: 11, color: .secondaryLabelColor)
    let allowSystemKeys = NSButton(title: "Allow ⌘-Tab…", target: nil, action: nil)
    let exitFullScreen = NSButton(title: "Exit Full Screen", target: nil, action: nil)
    let hide = NSButton(image: NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Hide diagnostic footer")!,
                        target: nil, action: nil)
    /// The row of items, 22 points tall, 12 points in from each side.
    let bar = NSStackView()
    private var pictureBottom: NSLayoutConstraint?
    private(set) var isVisible = true

    init() {
        status.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        status.maximumNumberOfLines = 1
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for button in [allowSystemKeys, exitFullScreen, hide] { button.bezelStyle = .inline }
        allowSystemKeys.isHidden = true
        exitFullScreen.isHidden = true
        exitFullScreen.toolTip = "Or press ⌃⌘F. Swiping between Spaces also shows this Mac without leaving full screen."
        hide.toolTip = "Hide diagnostic footer. Restore with ⌃⌘D or View → Diagnostic Footer."
        bar.orientation = .horizontal
        bar.alignment = .centerY
        bar.distribution = .fill
        bar.spacing = 12
        bar.translatesAutoresizingMaskIntoConstraints = false
    }

    /// Adds the footer along the bottom of `root`, below `picture`, which
    /// fills the rest of `root` from the top. `leading` items go before
    /// Allow ⌘-Tab…, `trailing` items after Exit Full Screen.
    func install(in root: NSView, below picture: NSView, leading: [NSView] = [], trailing: [NSView] = []) {
        let mark = NSImageView(image: MooringBrand.menuBarImage)
        mark.contentTintColor = MooringBrand.accent
        mark.translatesAutoresizingMaskIntoConstraints = false
        mark.widthAnchor.constraint(equalToConstant: 18).isActive = true
        mark.heightAnchor.constraint(equalToConstant: 18).isActive = true
        for view in [mark, status, NSView()] + leading + [allowSystemKeys, exitFullScreen] + trailing + [hide] {
            bar.addArrangedSubview(view)
        }
        root.addSubview(bar)
        let bottom = picture.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        pictureBottom = bottom
        NSLayoutConstraint.activate([
            picture.leadingAnchor.constraint(equalTo: root.leadingAnchor), picture.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            picture.topAnchor.constraint(equalTo: root.topAnchor), bottom,
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            bar.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -(Self.height - 22) / 2),
            bar.heightAnchor.constraint(equalToConstant: 22),
        ])
        setVisible(isVisible)
    }

    /// Shown, the picture ends the footer's height above the bottom edge;
    /// hidden, it reaches the edge.
    func setVisible(_ visible: Bool) {
        isVisible = visible
        bar.isHidden = !visible
        pictureBottom?.constant = visible ? -Self.height : 0
        bar.superview?.layoutSubtreeIfNeeded()
    }
}
