import Cocoa

/// Borderless Liquid Glass panel that drops down from the status item, the way
/// the system's own menu bar extras do. The menu bar drives its lifetime through
/// an expanded interface session (macOS 27+).
final class StatusPanel: NSPanel {
    private static let cornerRadius: CGFloat = 24
    private static let menuBarGap: CGFloat = 6
    private static let screenMargin: CGFloat = 8
    // Transparent room around the glass for its own soft shadow, which the
    // window edge would otherwise clip into a visible rectangle. The top inset
    // matches the menu bar gap so the window never overlaps the menu bar.
    private static let shadowInsets = NSEdgeInsets(top: menuBarGap, left: 28, bottom: 36, right: 28)

    private let controlsController: NSViewController
    private let glassView = NSGlassEffectView()
    private var presentationID = 0

    var onCancel: (() -> Void)?

    init(controlsController: NSViewController) {
        self.controlsController = controlsController
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isOpaque = false
        backgroundColor = .clear
        // The window shadow ignores the glass corner radius and outlines the
        // full rectangle; the glass draws its own shadow and edge highlight.
        hasShadow = false
        level = .popUpMenu
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]

        glassView.cornerRadius = Self.cornerRadius
        glassView.contentView = controlsController.view
        glassView.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(glassView)
        NSLayoutConstraint.activate([
            glassView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Self.shadowInsets.left),
            glassView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Self.shadowInsets.right),
            glassView.topAnchor.constraint(equalTo: container.topAnchor, constant: Self.shadowInsets.top),
            glassView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Self.shadowInsets.bottom),
        ])
        contentView = container
    }

    // Borderless windows can't become key by default. Becoming key activates
    // the app (as the old popover did), which keeps controls tinted and lets
    // Esc reach cancelOperation.
    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func sendEvent(_ event: NSEvent) {
        // Clicks in the transparent shadow inset still land on this window, so
        // the outside-click monitor never sees them. Treat them as outside.
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            if !glassView.frame.contains(event.locationInWindow) {
                onCancel?()
                return
            }
        default:
            break
        }
        super.sendEvent(event)
    }

    func show(below button: NSStatusBarButton) {
        guard let buttonWindow = button.window else { return }
        presentationID += 1
        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        setFrame(frame(below: buttonFrame, on: buttonWindow.screen), display: true)
        alphaValue = 1
        makeKeyAndOrderFront(nil)
    }

    func resizeToFit() {
        guard isVisible else { return }
        let size = windowSize
        guard size != frame.size else { return }
        // Keep the top edge pinned under the menu bar while rows come and go.
        let resized = NSRect(
            x: frame.minX,
            y: frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
        setFrame(resized, display: true)
    }

    func dismiss(animated: Bool) {
        guard isVisible else { return }
        guard animated else {
            orderOut(nil)
            return
        }

        let dismissedPresentation = presentationID
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // A new session may have reopened the panel mid-fade.
            guard let self, self.presentationID == dismissedPresentation else { return }
            self.orderOut(nil)
            self.alphaValue = 1
        })
    }

    private var windowSize: NSSize {
        let contentSize = controlsController.preferredContentSize
        return NSSize(
            width: contentSize.width + Self.shadowInsets.left + Self.shadowInsets.right,
            height: contentSize.height + Self.shadowInsets.top + Self.shadowInsets.bottom
        )
    }

    private func frame(below buttonFrame: NSRect, on screen: NSScreen?) -> NSRect {
        let size = windowSize
        // Position the glass (not the transparent inset) under the status item.
        let glassTop = buttonFrame.minY - Self.menuBarGap
        var origin = NSPoint(
            x: buttonFrame.minX - Self.shadowInsets.left,
            y: glassTop + Self.shadowInsets.top - size.height
        )
        if let visibleFrame = (screen ?? NSScreen.main)?.visibleFrame {
            let glassWidth = size.width - Self.shadowInsets.left - Self.shadowInsets.right
            let glassMinX = min(
                max(origin.x + Self.shadowInsets.left, visibleFrame.minX + Self.screenMargin),
                visibleFrame.maxX - glassWidth - Self.screenMargin
            )
            origin.x = glassMinX - Self.shadowInsets.left
        }
        return NSRect(origin: origin, size: size)
    }
}
