import Cocoa
import MetalKit
import Carbon.HIToolbox
import ServiceManagement

// MARK: - Kill switch: `xdr-boost --kill` terminates any running instance
if CommandLine.arguments.contains("--kill") || CommandLine.arguments.contains("-k") {
    // Match the exact process name: `-f` also matched editors, shells, and
    // builds whose command line mentions the xdr-boost checkout.
    let pipe = Pipe()
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    proc.arguments = ["-x", "xdr-boost"]
    proc.standardOutput = pipe
    try? proc.run()
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    proc.waitUntilExit()
    // Skip ourselves so the confirmation below is always printed.
    let pids = output.split(whereSeparator: \.isNewline)
        .compactMap { pid_t($0) }
        .filter { $0 != getpid() }
    pids.forEach { kill($0, SIGTERM) }
    fputs("Killed \(pids.count) xdr-boost instance(s)\n", stderr)
    exit(0)
}

class Renderer: NSObject, MTKViewDelegate {
    var commandQueue: MTLCommandQueue
    init(device: MTLDevice) { self.commandQueue = device.makeCommandQueue()! }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    func draw(in view: MTKView) {
        guard let desc = view.currentRenderPassDescriptor,
              let buf = commandQueue.makeCommandBuffer(),
              let enc = buf.makeRenderCommandEncoder(descriptor: desc) else { return }
        enc.endEncoding()
        if let drawable = view.currentDrawable {
            buf.present(drawable)
        }
        buf.commit()
    }
}

struct DisplayBoostControlModel {
    let identifier: String
    let name: String
    let level: Double
    let maximumLevel: Double
}

/// Rounded platter that groups related rows on top of the glass, without
/// stacking a second glass layer.
private final class CardView: NSView {
    init(content: NSView, cornerRadius: CGFloat, insets: NSEdgeInsets) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: insets.left),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -insets.right),
            content.topAnchor.constraint(equalTo: topAnchor, constant: insets.top),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -insets.bottom),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        // Resolved against the current appearance, so light/dark switches apply.
        layer?.backgroundColor = NSColor.quaternarySystemFill.cgColor
    }
}

/// Control Center–style round symbol badge that lights up while boosting.
private final class SymbolBadgeView: NSView {
    private static let diameter: CGFloat = 28
    private let imageView = NSImageView()

    var isOn = false {
        didSet {
            guard isOn != oldValue else { return }
            imageView.contentTintColor = isOn ? .white : .secondaryLabelColor
            needsDisplay = true
        }
    }

    init(symbolName: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Self.diameter / 2
        imageView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        imageView.symbolConfiguration = .init(pointSize: 14, weight: .semibold)
        imageView.contentTintColor = .secondaryLabelColor
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.diameter),
            heightAnchor.constraint(equalToConstant: Self.diameter),
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = (isOn ? NSColor.systemOrange : NSColor.tertiarySystemFill).cgColor
    }
}

/// Status item controls. Draws no background of its own: the host supplies the
/// material (a Liquid Glass panel on macOS 27, the system popover on macOS 26).
final class XDRControlsViewController: NSViewController {
    private static let width: CGFloat = 300
    private static let padding: CGFloat = 14
    private static let cardCornerRadius: CGFloat = 10

    private struct DisplayControlLayout: Equatable {
        let identifier: String
        let name: String
        let maximumLevel: Double
    }

    private final class DisplayControlRow {
        var model: DisplayBoostControlModel
        let slider: NSSlider
        let valueLabel: NSTextField

        init(model: DisplayBoostControlModel, slider: NSSlider, valueLabel: NSTextField) {
            self.model = model
            self.slider = slider
            self.valueLabel = valueLabel
        }
    }

    private let showsLoginControl: Bool
    private let badge = SymbolBadgeView(symbolName: "sun.max.fill")
    private let statusLabel = NSTextField(labelWithString: "Off")
    private let toggleSwitch = NSSwitch()
    private let displayControls = NSStackView()
    private var displayLayout: [DisplayControlLayout]?
    private var displayRows: [String: DisplayControlRow] = [:]
    private var loginButton: NSButton?
    private let screenshotWarning = NSStackView()

    var onToggle: (() -> Void)?
    var onBoostLevelChange: ((String, Double) -> Void)?
    var onLoginToggle: (() -> Void)?
    var onQuit: (() -> Void)?
    var onRequestScreenshotPermission: (() -> Void)?

    init(showsLoginControl: Bool) {
        self.showsLoginControl = showsLoginControl
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView()

        let titleLabel = NSTextField(labelWithString: "XDR Boost")
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        let titles = NSStackView(views: [titleLabel, statusLabel])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 1

        toggleSwitch.target = self
        toggleSwitch.action = #selector(toggleChanged)
        toggleSwitch.setAccessibilityLabel("Extended brightness")
        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [badge, titles, headerSpacer, toggleSwitch])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 10

        let displaysLabel = NSTextField(labelWithString: "Displays")
        displaysLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        displaysLabel.textColor = .secondaryLabelColor

        displayControls.orientation = .vertical
        displayControls.alignment = .leading
        displayControls.spacing = 14
        let displaysCard = CardView(
            content: displayControls,
            cornerRadius: Self.cardCornerRadius,
            insets: NSEdgeInsets(top: 10, left: 12, bottom: 12, right: 12)
        )

        let controls = NSStackView(views: [header, displaysLabel, displaysCard])
        controls.orientation = .vertical
        controls.alignment = .leading
        controls.spacing = 6
        controls.setCustomSpacing(14, after: header)
        for fullWidthView in [header, displaysCard] {
            fullWidthView.widthAnchor.constraint(equalTo: controls.widthAnchor).isActive = true
        }

        if showsLoginControl {
            let loginButton = NSButton(
                checkboxWithTitle: "Start at Login",
                target: self,
                action: #selector(loginChanged)
            )
            controls.setCustomSpacing(12, after: displaysCard)
            controls.addArrangedSubview(loginButton)
            self.loginButton = loginButton
        }

        let warningIcon = NSImageView()
        warningIcon.image = NSImage(
            systemSymbolName: "exclamationmark.triangle.fill",
            accessibilityDescription: "Warning"
        )
        warningIcon.contentTintColor = .systemYellow
        warningIcon.setContentHuggingPriority(.required, for: .horizontal)
        let warningLabel = NSTextField(
            wrappingLabelWithString: "Screenshots need permission to hide the boost."
        )
        warningLabel.font = .systemFont(ofSize: 11)
        warningLabel.textColor = .secondaryLabelColor
        warningLabel.preferredMaxLayoutWidth = 180
        screenshotWarning.toolTip = "Allow Input Monitoring in System Settings so XDR Boost can hide the boost while ⌘⇧3, ⌘⇧4, ⌘⇧5, or ⌘⇧6 captures the screen."
        let allowButton = NSButton(
            title: "Allow…",
            target: self,
            action: #selector(requestScreenshotPermission)
        )
        allowButton.bezelStyle = .glass
        allowButton.controlSize = .small
        allowButton.setContentHuggingPriority(.required, for: .horizontal)
        let warningSpacer = NSView()
        warningSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        screenshotWarning.setViews([warningIcon, warningLabel, warningSpacer, allowButton], in: .leading)
        screenshotWarning.orientation = .horizontal
        screenshotWarning.alignment = .centerY
        screenshotWarning.spacing = 8
        screenshotWarning.isHidden = true
        controls.setCustomSpacing(12, after: controls.arrangedSubviews.last ?? displaysCard)
        controls.addArrangedSubview(screenshotWarning)
        screenshotWarning.widthAnchor.constraint(equalTo: controls.widthAnchor).isActive = true

        let separator = NSBox()
        separator.boxType = .separator

        let shortcutLabel = NSTextField(
            labelWithString: "Shortcut: Ctrl+Option+Cmd+V (⌃⌥⌘V)"
        )
        shortcutLabel.font = .systemFont(ofSize: 11)
        shortcutLabel.textColor = .secondaryLabelColor

        let footerSpacer = NSView()
        footerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let quitButton = NSButton(title: "Quit", target: self, action: #selector(quit))
        quitButton.bezelStyle = .glass
        quitButton.controlSize = .small
        let footer = NSStackView(views: [shortcutLabel, footerSpacer, quitButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY

        let root = NSStackView(views: [controls, separator, footer])
        root.translatesAutoresizingMaskIntoConstraints = false
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        view.addSubview(root)

        let contentWidth = Self.width - Self.padding * 2
        // Trailing/bottom sit just below required so the host's interim frame
        // (zero-sized before the first show) never produces a conflict.
        let trailing = root.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Self.padding)
        trailing.priority = .init(999)
        let bottom = root.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -Self.padding)
        bottom.priority = .init(999)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Self.padding),
            root.topAnchor.constraint(equalTo: view.topAnchor, constant: Self.padding),
            trailing,
            bottom,
            root.widthAnchor.constraint(equalToConstant: contentWidth),
            controls.widthAnchor.constraint(equalTo: root.widthAnchor),
            separator.widthAnchor.constraint(equalTo: root.widthAnchor),
            footer.widthAnchor.constraint(equalTo: root.widthAnchor),
        ])
    }

    /// - Parameters:
    ///   - isEnabled: The user wants boost on, even if no XDR display can show it yet.
    ///   - isActive: Overlays are currently boosting.
    func update(
        isEnabled: Bool,
        isActive: Bool,
        displays: [DisplayBoostControlModel],
        loginEnabled: Bool?,
        showsScreenshotPermissionWarning: Bool
    ) {
        toggleSwitch.state = isEnabled ? .on : .off
        badge.isOn = isActive
        if displays.isEmpty {
            statusLabel.stringValue = isEnabled ? "Waiting for an XDR display" : "No XDR display"
        } else if !isEnabled {
            statusLabel.stringValue = "Off"
        } else if displays.count == 1, let display = displays.first {
            statusLabel.stringValue = "On · \(formatted(level: display.level))"
        } else {
            statusLabel.stringValue = "On · \(displays.count) displays"
        }

        let newLayout = displays.map {
            DisplayControlLayout(
                identifier: $0.identifier,
                name: $0.name,
                maximumLevel: $0.maximumLevel
            )
        }
        var needsResize = false
        if newLayout != displayLayout {
            rebuildDisplayControls(with: displays)
            displayLayout = newLayout
            needsResize = true
        }
        if screenshotWarning.isHidden == showsScreenshotPermissionWarning {
            screenshotWarning.isHidden = !showsScreenshotPermissionWarning
            needsResize = true
        }
        if needsResize {
            view.layoutSubtreeIfNeeded()
            preferredContentSize = view.fittingSize
        }

        for display in displays {
            guard let row = displayRows[display.identifier] else { continue }
            row.model = display
            row.slider.doubleValue = display.level
            row.slider.setAccessibilityValue(formatted(level: display.level))
            row.valueLabel.stringValue = formatted(level: display.level)
        }

        if let loginEnabled {
            loginButton?.state = loginEnabled ? .on : .off
        }
    }

    private func rebuildDisplayControls(with displays: [DisplayBoostControlModel]) {
        for arrangedView in displayControls.arrangedSubviews {
            displayControls.removeArrangedSubview(arrangedView)
            arrangedView.removeFromSuperview()
        }
        displayRows.removeAll()

        guard !displays.isEmpty else {
            let emptyLabel = NSTextField(labelWithString: "No XDR-capable displays connected")
            emptyLabel.font = .systemFont(ofSize: 12)
            emptyLabel.textColor = .secondaryLabelColor
            displayControls.addArrangedSubview(emptyLabel)
            return
        }

        for display in displays {
            let nameLabel = NSTextField(labelWithString: display.name)
            nameLabel.font = .systemFont(ofSize: 12, weight: .medium)
            nameLabel.lineBreakMode = .byTruncatingMiddle
            nameLabel.toolTip = display.name
            nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            let valueLabel = NSTextField(labelWithString: formatted(level: display.level))
            valueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            valueLabel.textColor = .secondaryLabelColor
            valueLabel.alignment = .right

            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let displayHeader = NSStackView(views: [nameLabel, spacer, valueLabel])
            displayHeader.orientation = .horizontal
            displayHeader.alignment = .centerY

            let slider = NSSlider(
                value: display.level,
                minValue: BoostLevelSettings.minimumLevel,
                maxValue: display.maximumLevel,
                target: self,
                action: #selector(boostLevelChanged(_:))
            )
            slider.identifier = NSUserInterfaceItemIdentifier(display.identifier)
            slider.isContinuous = true
            slider.setAccessibilityLabel("\(display.name) boost")
            slider.setAccessibilityHelp(
                "Adjust from 1.0× to \(formatted(level: display.maximumLevel)) in 0.1× steps."
            )

            let sliderRow = NSStackView(views: [
                sliderSymbol("sun.min", pointSize: 11),
                slider,
                sliderSymbol("sun.max", pointSize: 14),
            ])
            sliderRow.orientation = .horizontal
            sliderRow.alignment = .centerY
            sliderRow.spacing = 8

            let row = NSStackView(views: [displayHeader, sliderRow])
            row.orientation = .vertical
            row.alignment = .leading
            row.spacing = 4
            displayHeader.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
            sliderRow.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
            displayControls.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: displayControls.widthAnchor).isActive = true

            displayRows[display.identifier] = DisplayControlRow(
                model: display,
                slider: slider,
                valueLabel: valueLabel
            )
        }
    }

    private func sliderSymbol(_ symbolName: String, pointSize: CGFloat) -> NSImageView {
        let imageView = NSImageView()
        imageView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        imageView.symbolConfiguration = .init(pointSize: pointSize, weight: .regular)
        imageView.contentTintColor = .secondaryLabelColor
        imageView.setContentHuggingPriority(.required, for: .horizontal)
        return imageView
    }

    private func formatted(level: Double) -> String {
        String(format: "%.1f×", level)
    }

    @objc private func toggleChanged() {
        onToggle?()
    }

    @objc private func boostLevelChanged(_ sender: NSSlider) {
        guard let identifier = sender.identifier?.rawValue,
              let row = displayRows[identifier] else { return }
        let level = BoostLevelSettings.normalized(sender.doubleValue, maximum: row.model.maximumLevel)
        sender.doubleValue = level
        sender.setAccessibilityValue(formatted(level: level))
        row.valueLabel.stringValue = formatted(level: level)
        onBoostLevelChange?(identifier, level)
    }

    @objc private func loginChanged() {
        onLoginToggle?()
    }

    @objc private func quit() {
        onQuit?()
    }

    @objc private func requestScreenshotPermission() {
        onRequestScreenshotPermission?()
    }
}

struct XDRScreenInfo {
    let screen: NSScreen
    let id: NSNumber
    let persistentIdentifier: String
    let name: String
    let maxEDR: CGFloat
}

class XDRApp: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var overlayWindows: [NSNumber: NSWindow] = [:]
    var boostViews: [NSNumber: MTKView] = [:]
    var device: MTLDevice!
    var boostRenderers: [NSNumber: Renderer] = [:]
    let boostSettings = BoostLevelSettings()
    var isActive = false
    var shouldBeActive = false {  // tracks user intent across sleep/lock cycles
        didSet {
            if shouldBeActive != oldValue { updateWatchdog() }
        }
    }
    var commandLineBoostLevel: Double?
    var displaysCustomizedDuringSession: Set<String> = []
    var hotkeyRef: EventHotKeyRef?
    var watchdogTimer: Timer?
    var displayRefreshWorkItem: DispatchWorkItem?
    var overlayRefreshTimer: Timer?
    var activeDisplaySignature: String?

    var screenshotTap: CFMachPort?
    var didRequestScreenshotPermission = false
    var screenshotPermissionWatch: Timer?
    // System-owned state, cached because each read is a round trip to another
    // process. Refreshed when the controls open or the setting changes, not
    // on every slider tick.
    var loginItemEnabled: Bool?
    var suppressedForScreenshot = false
    var screenshotRestoreTimer: Timer?

    var controlsController: XDRControlsViewController!
    var statusPanel: StatusPanel?          // macOS 27+: glass panel in a menu bar session
    var statusPopover: NSPopover?          // macOS 26: system popover
    var panelClickMonitor: Any?

    var isRunningAsApp: Bool {
        Bundle.main.bundlePath.hasSuffix(".app")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let dev = MTLCreateSystemDefaultDevice() else {
            fputs("No Metal device\n", stderr); exit(1)
        }
        device = dev
        let launchScreens = xdrScreens()
        // Keep running without an XDR display (lid closed on an external
        // monitor, or a login before displays settle). The controls show an
        // empty state and boost becomes available once one connects.
        if launchScreens.isEmpty {
            fputs("No connected display supports XDR yet\n", stderr)
        }

        if CommandLine.arguments.count > 1, let level = Double(CommandLine.arguments[1]) {
            commandLineBoostLevel = max(level, BoostLevelSettings.minimumLevel)
        }

        setupStatusBar()
        registerGlobalHotkey()
        observeSleepWake()
        observeScreenshots()
        if screenshotTap == nil {
            fputs("Screenshot detection needs Input Monitoring access (System Settings > Privacy & Security > Input Monitoring)\n", stderr)
        }
        fputs("XDR Boost ready — click menu bar icon or press Ctrl+Option+Cmd+V to toggle\n", stderr)
        fputs("Emergency kill: run `xdr-boost --kill` or press Ctrl+Option+Cmd+V\n", stderr)
        for screen in launchScreens {
            fputs("\(screen.name): max EDR \(screen.maxEDR)x\n", stderr)
        }
    }

    // MARK: - Global Hotkey (Ctrl+Option+Cmd+V)

    func displayID(for screen: NSScreen) -> NSNumber? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    }

    func persistentIdentifier(for displayID: NSNumber) -> String {
        let directDisplayID = CGDirectDisplayID(displayID.uint32Value)
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(directDisplayID)?.takeRetainedValue() else {
            return "display-\(displayID.uint32Value)"
        }
        return CFUUIDCreateString(nil, uuid) as String
    }

    func xdrScreens() -> [XDRScreenInfo] {
        let eligibleScreens = NSScreen.screens.compactMap { screen -> (NSScreen, NSNumber, CGFloat)? in
            guard let id = displayID(for: screen) else { return nil }
            let screenMaxEDR = screen.maximumPotentialExtendedDynamicRangeColorComponentValue
            guard screenMaxEDR > 1.0 else { return nil }
            return (screen, id, screenMaxEDR)
        }

        let nameCounts = Dictionary(grouping: eligibleScreens, by: { $0.0.localizedName })
            .mapValues(\.count)
        var nameOccurrences: [String: Int] = [:]

        return eligibleScreens.map { screen, id, screenMaxEDR in
            let baseName = screen.localizedName
            nameOccurrences[baseName, default: 0] += 1
            let name: String
            if nameCounts[baseName, default: 0] > 1 {
                name = "\(baseName) \(nameOccurrences[baseName, default: 1])"
            } else {
                name = baseName
            }
            return XDRScreenInfo(
                screen: screen,
                id: id,
                persistentIdentifier: persistentIdentifier(for: id),
                name: name,
                maxEDR: screenMaxEDR
            )
        }
    }

    func boostLevel(for screen: XDRScreenInfo) -> Double {
        if let commandLineBoostLevel,
           !displaysCustomizedDuringSession.contains(screen.persistentIdentifier) {
            return BoostLevelSettings.normalizedForHardware(
                commandLineBoostLevel,
                maximum: Double(screen.maxEDR)
            )
        }
        return boostSettings.level(
            for: screen.persistentIdentifier,
            maximum: Double(screen.maxEDR)
        )
    }

    func displayControlModels(for screens: [XDRScreenInfo]) -> [DisplayBoostControlModel] {
        screens.map { screen in
            DisplayBoostControlModel(
                identifier: screen.persistentIdentifier,
                name: screen.name,
                level: boostLevel(for: screen),
                maximumLevel: BoostLevelSettings.maximumSelectableLevel(for: Double(screen.maxEDR))
            )
        }
    }

    func displaySignature(for screens: [XDRScreenInfo]) -> String {
        screens
            .sorted { $0.id.intValue < $1.id.intValue }
            .map { screen in
                let frame = screen.screen.frame.integral
                return [
                    String(screen.id.intValue),
                    String(format: "%.0f", frame.origin.x),
                    String(format: "%.0f", frame.origin.y),
                    String(format: "%.0f", frame.size.width),
                    String(format: "%.0f", frame.size.height),
                    String(format: "%.2f", screen.maxEDR),
                ].joined(separator: ":")
            }
            .joined(separator: "|")
    }

    func setActiveUI(_ active: Bool) {
        isActive = active
        updateStatusItemImage()
        updateControls()
    }

    func updateStatusItemImage() {
        guard let button = statusItem.button else { return }
        // A small vs. large filled sun stays tellable apart at menu bar size,
        // unlike outline vs. filled versions of the same glyph.
        button.image = NSImage(
            systemSymbolName: isActive ? "sun.max.fill" : "sun.min",
            accessibilityDescription: isActive ? "XDR Boost on" : "XDR Boost off"
        )
        button.image?.isTemplate = true
        button.toolTip = isActive ? "XDR Boost is on" : "XDR Boost is off"
    }

    func makeOverlay(for xdrScreen: XDRScreenInfo) -> (window: NSWindow, view: MTKView, renderer: Renderer) {
        let frame = xdrScreen.screen.frame
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = .screenSaver
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.hidesOnDeactivate = false
        // Do not exclude this window from captures: the multiply filter would
        // composite against an excluded black window and black out the result.
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        let boostView = MTKView(frame: frame, device: device)
        boostView.colorPixelFormat = .rgba16Float
        boostView.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        boostView.layer?.isOpaque = false
        // The boost is one uniform colour, so render it into a tiny drawable
        // that the layer stretches across the screen instead of a pool of
        // full-resolution float buffers. Frames come from the overlay refresh
        // timer and from level changes rather than the view's own display link.
        boostView.isPaused = true
        boostView.enableSetNeedsDisplay = false
        boostView.autoResizeDrawable = false
        boostView.drawableSize = CGSize(width: 16, height: 16)
        let levelForScreen = boostLevel(for: xdrScreen)
        boostView.clearColor = MTLClearColor(red: levelForScreen, green: levelForScreen, blue: levelForScreen, alpha: 1.0)
        if let layer = boostView.layer as? CAMetalLayer {
            layer.wantsExtendedDynamicRangeContent = true
        }
        let renderer = Renderer(device: device)
        boostView.delegate = renderer
        boostView.wantsLayer = true

        window.contentView = boostView
        window.contentView?.layer?.compositingFilter = "multiply"
        return (window, boostView, renderer)
    }

    func installOverlays(for screens: [XDRScreenInfo], logMessage: String?) {
        let oldWindows = overlayWindows
        var newWindows: [NSNumber: NSWindow] = [:]
        var newViews: [NSNumber: MTKView] = [:]
        var newRenderers: [NSNumber: Renderer] = [:]

        for xdrScreen in screens {
            let overlay = makeOverlay(for: xdrScreen)
            overlay.window.orderFrontRegardless()
            overlay.view.draw()
            newWindows[xdrScreen.id] = overlay.window
            newViews[xdrScreen.id] = overlay.view
            newRenderers[xdrScreen.id] = overlay.renderer
        }

        overlayWindows = newWindows
        boostViews = newViews
        boostRenderers = newRenderers
        activeDisplaySignature = displaySignature(for: screens)
        startOverlayRefresh()
        setActiveUI(true)
        oldWindows.values.forEach { $0.orderOut(nil) }

        if let logMessage {
            fputs(logMessage, stderr)
        }
    }

    func scheduleDisplayRefresh() {
        displayRefreshWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            self?.refreshDisplaysIfNeeded(reason: "Display changed — XDR refreshed\n")
        }

        displayRefreshWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: workItem)
    }

    func refreshDisplaysIfNeeded(reason: String? = nil) {
        let screens = xdrScreens()

        guard shouldBeActive else { return }

        guard !screens.isEmpty else {
            if isActive {
                deactivate(logMessage: "XDR OFF — no XDR display available\n")
            }
            return
        }

        let expectedDisplayIDs = Set(screens.map(\.id))
        let activeDisplayIDs = Set(overlayWindows.keys)
        let missingOverlay = overlayWindows.values.contains { !$0.isVisible }
        let currentSignature = displaySignature(for: screens)
        let configChanged = activeDisplaySignature != currentSignature

        if !isActive || missingOverlay || expectedDisplayIDs != activeDisplayIDs || configChanged {
            let message: String?
            if !isActive {
                message = "XDR ON — configured levels on \(screens.count) display(s)\n"
            } else {
                message = reason
            }
            installOverlays(for: screens, logMessage: message)
        }
    }

    func registerGlobalHotkey() {
        let hotkeyID = EventHotKeyID(signature: OSType(0x58445242), id: 1) // "XDRB"
        var ref: EventHotKeyRef?

        // Ctrl+Option+Cmd+V  (kVK_ANSI_V = 0x09)
        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_V),
            UInt32(controlKey | optionKey | cmdKey),
            hotkeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )

        if status == noErr {
            hotkeyRef = ref
            // Install Carbon event handler for hotkey
            var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { (_, event, userData) -> OSStatus in
                let app = Unmanaged<XDRApp>.fromOpaque(userData!).takeUnretainedValue()
                DispatchQueue.main.async { app.toggleXDR() }
                return noErr
            }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), nil)
        } else {
            fputs("Could not register global hotkey (Ctrl+Option+Cmd+V)\n", stderr)
        }
    }

    // MARK: - Status Bar

    func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusItemImage()

        controlsController = XDRControlsViewController(showsLoginControl: isRunningAsApp)
        controlsController.onToggle = { [weak self] in self?.toggleXDR() }
        controlsController.onBoostLevelChange = { [weak self] displayIdentifier, level in
            self?.setBoostLevel(level, for: displayIdentifier)
        }
        controlsController.onLoginToggle = { [weak self] in self?.toggleLoginItem() }
        controlsController.onQuit = { [weak self] in self?.quit() }
        controlsController.onRequestScreenshotPermission = { [weak self] in
            self?.requestScreenshotPermission()
        }
        controlsController.loadViewIfNeeded()

        if #available(macOS 27.0, *) {
            // The menu bar owns the open/close lifecycle, so the item joins
            // menu tracking (sliding across extras, keyboard navigation) like
            // the system's own items. No target/action on the button.
            let panel = StatusPanel(controlsController: controlsController)
            panel.onCancel = { [weak self] in self?.endStatusPanelSession() }
            statusPanel = panel
            statusItem.expandedInterfaceDelegate = self
        } else {
            statusItem.button?.target = self
            statusItem.button?.action = #selector(togglePopover)
            let popover = NSPopover()
            popover.behavior = .transient
            popover.animates = true
            popover.contentViewController = controlsController
            statusPopover = popover
        }
        refreshSystemState()
        updateControls()
    }

    @objc func togglePopover() {
        guard let button = statusItem.button, let statusPopover else { return }
        if statusPopover.isShown {
            statusPopover.performClose(nil)
        } else {
            refreshSystemState()
            updateControls()
            statusPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate()
        }
    }

    func endStatusPanelSession() {
        if #available(macOS 27.0, *) {
            statusItem.expandedInterfaceSession?.cancel()
        }
    }

    func refreshSystemState() {
        if isRunningAsApp, #available(macOS 13.0, *) {
            loginItemEnabled = SMAppService.mainApp.status == .enabled
        } else {
            loginItemEnabled = nil
        }
        // Picks up access granted while running.
        observeScreenshots()
    }

    /// Pass `screens` when the caller already scanned them, as slider drags do
    /// on every tick.
    func updateControls(screens knownScreens: [XDRScreenInfo]? = nil) {
        guard controlsController != nil else { return }
        let screens = knownScreens ?? xdrScreens()
        controlsController.update(
            isEnabled: shouldBeActive,
            isActive: isActive,
            displays: displayControlModels(for: screens),
            loginEnabled: loginItemEnabled,
            showsScreenshotPermissionWarning: screenshotTap == nil
        )
        statusItem.button?.appearsDisabled = screens.isEmpty
        statusPanel?.resizeToFit()
    }

    // MARK: - Watchdog & Display Changes

    func observeSleepWake() {
        // Display config changed (resolution, arrangement, external monitors)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleDisplayChange),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    // Watchdog: while boost is wanted, every 3 seconds restore it if an overlay
    // died or the displays changed. This handles sleep/wake, lid close/open,
    // lock/unlock — all of them. With boost off there is nothing to restore,
    // so the timer stops instead of waking the CPU for nothing.
    func updateWatchdog() {
        guard shouldBeActive else {
            watchdogTimer?.invalidate()
            watchdogTimer = nil
            return
        }
        guard watchdogTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            // Overlays hidden for a capture would look dead; leave them alone.
            guard let self, !self.suppressedForScreenshot else { return }
            self.refreshDisplaysIfNeeded(reason: "Watchdog — overlay recreated\n")
        }
        timer.tolerance = 1.0
        watchdogTimer = timer
    }

    // About 1.5 s after an overlay stops presenting, macOS frees the
    // full-screen composite behind its multiply filter and the boost vanishes
    // while EDR headroom still reads as active. Presenting the tiny frame at
    // 2 Hz keeps it well inside that window for ~0.5% CPU, versus ~3.5% for
    // the old full-resolution 10 fps redraw. Common modes keep it running
    // during slider drags and menu tracking.
    func startOverlayRefresh() {
        guard overlayRefreshTimer == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.redrawOverlays()
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        overlayRefreshTimer = timer
    }

    func stopOverlayRefresh() {
        overlayRefreshTimer?.invalidate()
        overlayRefreshTimer = nil
    }

    func redrawOverlays() {
        boostViews.values.forEach { $0.draw() }
    }

    @objc func handleDisplayChange() {
        updateControls()
        guard shouldBeActive else { return }

        let screens = xdrScreens()
        if screens.isEmpty {
            scheduleDisplayRefresh()
            return
        }

        let signature = displaySignature(for: screens)
        if !isActive || activeDisplaySignature != signature {
            scheduleDisplayRefresh()
        }
    }

    // MARK: - Screenshot suppression
    //
    // The overlay uses a `multiply` compositing filter, which can't be excluded
    // from screen capture without turning the shot black (see activate()). So to
    // keep screenshots looking normal we briefly hide the overlay while a capture
    // is in progress, then restore it.
    //
    // Detection: a listen-only event tap watches for the system screenshot
    // shortcuts (⌘⇧3/4/5/6, with or without ⌃ for the clipboard). A listen-only
    // tap needs Input Monitoring access, which is what the app requests; an
    // NSEvent global key monitor needs Accessibility instead. Creating the tap
    // fails without access, so a live tap doubles as the permission check.

    func observeScreenshots() {
        // Only create the tap once access exists, so launching never prompts.
        guard screenshotTap == nil,
              CGPreflightListenEventAccess() || AXIsProcessTrusted() else { return }
        let keyDownMask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: keyDownMask,
            callback: { _, type, event, userInfo in
                if let userInfo {
                    let app = Unmanaged<XDRApp>.fromOpaque(userInfo).takeUnretainedValue()
                    app.handleScreenshotTapEvent(type: type, event: event)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        screenshotTap = tap
    }

    func handleScreenshotTapEvent(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let screenshotTap {
                CGEvent.tapEnable(tap: screenshotTap, enable: true)
            }
        case .keyDown:
            // keyCodes: 3 = 20, 4 = 21, 5 = 23, 6 = 22
            let shotKeys: Set<Int64> = [20, 21, 23, 22]
            let flags = event.flags
            if flags.contains(.maskCommand), flags.contains(.maskShift),
               !flags.contains(.maskAlternate),
               shotKeys.contains(event.getIntegerValueField(.keyboardEventKeycode)) {
                suppressForScreenshot()
            }
        default:
            break
        }
    }

    /// Asks for Input Monitoring the first time boost turns on, since hiding
    /// the boost for screenshots only matters then. macOS shows its prompt
    /// once per app; after that the warning row in the controls is the way in.
    func requestScreenshotPermissionIfNeeded() {
        guard screenshotTap == nil, !didRequestScreenshotPermission else { return }
        didRequestScreenshotPermission = true
        _ = CGRequestListenEventAccess()
        watchForScreenshotPermission()
    }

    /// Starts detection as soon as access is granted in System Settings,
    /// without waiting for the controls to reopen. Gives up after two minutes.
    func watchForScreenshotPermission() {
        screenshotPermissionWatch?.invalidate()
        var checks = 0
        screenshotPermissionWatch = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            checks += 1
            self.observeScreenshots()
            if self.screenshotTap != nil {
                self.updateControls()
            }
            if self.screenshotTap != nil || checks >= 60 {
                timer.invalidate()
                self.screenshotPermissionWatch = nil
            }
        }
    }

    func requestScreenshotPermission() {
        // Adds the app to the Input Monitoring list (prompting once), then
        // opens that pane so the user can switch it on.
        didRequestScreenshotPermission = true
        _ = CGRequestListenEventAccess()
        watchForScreenshotPermission()
        endStatusPanelSession()
        statusPopover?.performClose(nil)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    func suppressForScreenshot() {
        guard isActive, !overlayWindows.isEmpty, !suppressedForScreenshot else { return }
        suppressedForScreenshot = true
        overlayWindows.values.forEach { $0.orderOut(nil) }
        fputs("Screenshot detected — overlay hidden\n", stderr)
        scheduleScreenshotRestore()
    }

    // Matches the interactive screenshot UI process. The bundle id has moved
    // around between macOS versions (e.g. Tahoe), so fall back to the bundle/
    // executable path — otherwise a renamed id breaks detection and the overlay
    // gets restored mid-capture (which is what corrupts ⌘⇧4-Space window shots).
    func isCaptureUI(_ app: NSRunningApplication) -> Bool {
        let captureBundleIDs: Set = [
            "com.apple.screencaptureui",
            "com.apple.screenshot",
            "com.apple.screenshot.launcher",  // Screenshot.app on macOS 27
        ]
        if let id = app.bundleIdentifier, captureBundleIDs.contains(id) {
            return true
        }
        // Only trust the path for Apple's apps on the system volume: a bare
        // "screenshot" match also caught third-party apps that stay running,
        // keeping the overlay hidden until the 30 s cap after every capture.
        let path = (app.bundleURL ?? app.executableURL)?.path.lowercased() ?? ""
        guard path.hasPrefix("/system/") else { return false }
        return path.contains("screencaptureui") || path.contains("screenshot")
    }

    func captureUIIsRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { isCaptureUI($0) }
    }

    func scheduleScreenshotRestore() {
        screenshotRestoreTimer?.invalidate()
        var ticks = 0
        var sawCaptureUI = false
        // Keep the overlay hidden for the WHOLE capture session. Interactive
        // captures (⌘⇧4 region, ⌘⇧4-Space window pick, ⌘⇧5 panel) spawn the
        // capture UI — wait until we've seen it appear AND go away, so a slow
        // window pick can't trigger an early restore. Instant captures (⌘⇧3/6)
        // never spawn a UI, so a ticks>=3 (~1.2s) grace covers them. The grace
        // also absorbs the brief lag before the UI first shows up. Hard cap
        // (~30s) guarantees the overlay always returns.
        screenshotRestoreTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            ticks += 1
            if self.captureUIIsRunning() {
                sawCaptureUI = true
                return  // stay hidden while the capture UI is up
            }
            let interactiveDone = sawCaptureUI
            let instantDone = !sawCaptureUI && ticks >= 3
            if interactiveDone || instantDone || ticks > 75 {
                timer.invalidate()
                self.screenshotRestoreTimer = nil
                self.restoreAfterScreenshot()
            }
        }
    }

    func restoreAfterScreenshot() {
        guard suppressedForScreenshot else { return }
        suppressedForScreenshot = false
        guard shouldBeActive else { return }
        if !overlayWindows.isEmpty {
            overlayWindows.values.forEach { $0.orderFrontRegardless() }
            redrawOverlays()
        } else {
            activate()
        }
        fputs("Screenshot done — overlay restored\n", stderr)
    }

    // MARK: - Toggle

    @objc func toggleXDR() {
        // Toggle the user's intent, not the overlay state: with only non-XDR
        // displays attached the overlay is down while the intent is still on,
        // and toggling must be able to clear it.
        if shouldBeActive {
            shouldBeActive = false
            deactivate(logMessage: "XDR OFF\n")
        } else {
            shouldBeActive = true
            activate()
        }
        updateControls()
    }

    func setBoostLevel(_ level: Double, for displayIdentifier: String) {
        let screens = xdrScreens()
        guard let screen = screens.first(where: {
            $0.persistentIdentifier == displayIdentifier
        }) else { return }

        displaysCustomizedDuringSession.insert(displayIdentifier)
        let normalizedLevel = boostSettings.setLevel(
            level,
            for: displayIdentifier,
            maximum: Double(screen.maxEDR)
        )
        if isActive {
            if let view = boostViews[screen.id] {
                view.clearColor = MTLClearColor(
                    red: normalizedLevel,
                    green: normalizedLevel,
                    blue: normalizedLevel,
                    alpha: 1.0
                )
                view.draw()
            }
            updateControls(screens: screens)
        } else {
            shouldBeActive = true
            activate()
        }
    }

    // MARK: - XDR Overlay

    func activate() {
        let screens = xdrScreens()
        guard !screens.isEmpty else {
            fputs("No connected display supports XDR\n", stderr)
            return
        }

        installOverlays(
            for: screens,
            logMessage: "XDR ON — configured levels on \(screens.count) display(s)\n"
        )
        requestScreenshotPermissionIfNeeded()
    }

    func deactivate(logMessage: String? = nil) {
        displayRefreshWorkItem?.cancel()
        displayRefreshWorkItem = nil
        stopOverlayRefresh()
        overlayWindows.values.forEach { $0.orderOut(nil) }
        overlayWindows.removeAll()
        boostViews.removeAll()
        boostRenderers.removeAll()
        activeDisplaySignature = nil

        let wasActive = isActive
        setActiveUI(false)
        if wasActive, let logMessage {
            fputs(logMessage, stderr)
        }
    }

    @objc func toggleLoginItem() {
        if #available(macOS 13.0, *) {
            do {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                } else {
                    try SMAppService.mainApp.register()
                }
            } catch {
                fputs("Login item toggle failed: \(error)\n", stderr)
            }
            refreshSystemState()
            updateControls()
        }
    }

    @objc func quit() {
        endStatusPanelSession()
        deactivate(logMessage: "XDR OFF\n")
        NSApp.terminate(nil)
    }
}

@available(macOS 27.0, *)
extension XDRApp: NSStatusItemExpandedInterfaceDelegate {
    func statusItem(
        _ statusItem: NSStatusItem,
        didBegin expandedInterfaceSession: NSStatusItemExpandedInterfaceSession
    ) {
        guard let button = statusItem.button, let statusPanel else {
            expandedInterfaceSession.cancel()
            return
        }
        refreshSystemState()
        updateControls()
        statusPanel.show(below: button)
        // Clicks in other apps end the session; mouse monitors need no
        // Accessibility permission. Our own windows never reach this monitor.
        panelClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            self?.endStatusPanelSession()
        }
    }

    func statusItemDidEndExpandedInterfaceSession(_ statusItem: NSStatusItem, animated: Bool) {
        if let panelClickMonitor {
            NSEvent.removeMonitor(panelClickMonitor)
            self.panelClickMonitor = nil
        }
        statusPanel?.dismiss(animated: animated)
    }
}

// One instance per user: the launch agent plus the app bundle (or two CLI
// runs) would stack a second multiply overlay and compound the boost. The
// kernel releases the lock when the process exits, including after a crash.
let instanceLockPath = FileManager.default
    .urls(for: .cachesDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("xdr-boost.lock").path
let instanceLock = open(instanceLockPath, O_CREAT | O_RDWR, 0o600)
if instanceLock >= 0, flock(instanceLock, LOCK_EX | LOCK_NB) != 0 {
    fputs("xdr-boost is already running\n", stderr)
    exit(0)  // a successful exit, so the launch agent doesn't relaunch it
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let del = XDRApp()
app.delegate = del
signal(SIGINT) { _ in exit(0) }
signal(SIGTERM) { _ in exit(0) }
app.run()
