import Cocoa
import MetalKit
import Carbon.HIToolbox
import ServiceManagement

// MARK: - Kill switch: `xdr-boost --kill` terminates any running instance
if CommandLine.arguments.contains("--kill") || CommandLine.arguments.contains("-k") {
    let pipe = Pipe()
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
    proc.arguments = ["-f", "xdr-boost"]
    proc.standardOutput = pipe
    proc.standardError = pipe
    try? proc.run()
    proc.waitUntilExit()
    fputs("All xdr-boost instances killed\n", stderr)
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

final class XDRPopoverViewController: NSViewController {
    private static let presets: [(label: String, level: Double)] = [
        ("1.5×", 1.5),
        ("2×", 2.0),
        ("3×", 3.0),
        ("4×", 4.0),
    ]
    private let showsLoginControl: Bool
    private let statusLabel = NSTextField(labelWithString: "Off")
    private let toggleSwitch = NSSwitch()
    private let boostControl: NSSegmentedControl
    private var loginButton: NSButton?

    var onToggle: (() -> Void)?
    var onBoostLevelChange: ((Double) -> Void)?
    var onLoginToggle: (() -> Void)?
    var onQuit: (() -> Void)?

    init(showsLoginControl: Bool) {
        self.showsLoginControl = showsLoginControl
        boostControl = NSSegmentedControl(
            labels: Self.presets.map(\.label),
            trackingMode: .selectOne,
            target: nil,
            action: nil
        )
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .followsWindowActiveState
        view = background
        preferredContentSize = NSSize(width: 286, height: showsLoginControl ? 220 : 190)

        let titleLabel = NSTextField(labelWithString: "XDR Boost")
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)

        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .right

        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [titleLabel, headerSpacer, statusLabel])
        header.orientation = .horizontal
        header.alignment = .centerY

        let toggleTitle = NSTextField(labelWithString: "Extended brightness")
        toggleTitle.font = .systemFont(ofSize: 13, weight: .medium)
        let toggleDescription = NSTextField(labelWithString: "Use the display's extra XDR brightness.")
        toggleDescription.font = .systemFont(ofSize: 11)
        toggleDescription.textColor = .secondaryLabelColor
        let toggleLabels = NSStackView(views: [toggleTitle, toggleDescription])
        toggleLabels.orientation = .vertical
        toggleLabels.alignment = .leading
        toggleLabels.spacing = 2

        toggleSwitch.target = self
        toggleSwitch.action = #selector(toggleChanged)
        toggleSwitch.setAccessibilityLabel("Extended brightness")
        let toggleSpacer = NSView()
        toggleSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let toggleRow = NSStackView(views: [toggleLabels, toggleSpacer, toggleSwitch])
        toggleRow.orientation = .horizontal
        toggleRow.alignment = .centerY

        let brightnessLabel = NSTextField(labelWithString: "Brightness")
        brightnessLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        brightnessLabel.textColor = .secondaryLabelColor

        boostControl.target = self
        boostControl.action = #selector(boostLevelChanged)
        boostControl.segmentStyle = .rounded
        boostControl.segmentDistribution = .fillEqually
        boostControl.setAccessibilityLabel("Brightness level")

        let controls = NSStackView(views: [header, toggleRow, brightnessLabel, boostControl])
        controls.orientation = .vertical
        controls.alignment = .leading
        controls.spacing = 10
        header.widthAnchor.constraint(equalTo: controls.widthAnchor).isActive = true
        toggleRow.widthAnchor.constraint(equalTo: controls.widthAnchor).isActive = true
        boostControl.widthAnchor.constraint(equalTo: controls.widthAnchor).isActive = true

        if showsLoginControl {
            let loginButton = NSButton(
                checkboxWithTitle: "Start at Login",
                target: self,
                action: #selector(loginChanged)
            )
            loginButton.font = .systemFont(ofSize: 12)
            controls.addArrangedSubview(loginButton)
            self.loginButton = loginButton
        }

        let separator = NSBox()
        separator.boxType = .separator

        let shortcutLabel = NSTextField(labelWithString: "Shortcut  ⌃⌥⌘V")
        shortcutLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        shortcutLabel.textColor = .secondaryLabelColor

        let footerSpacer = NSView()
        footerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let quitButton = NSButton(title: "Quit", target: self, action: #selector(quit))
        quitButton.bezelStyle = .inline
        quitButton.font = .systemFont(ofSize: 12)
        let footer = NSStackView(views: [shortcutLabel, footerSpacer, quitButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY

        let root = NSStackView(views: [controls, separator, footer])
        root.translatesAutoresizingMaskIntoConstraints = false
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        background.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 16),
            root.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -16),
            root.topAnchor.constraint(equalTo: background.topAnchor, constant: 14),
            root.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -12),
            controls.widthAnchor.constraint(equalTo: root.widthAnchor),
            separator.widthAnchor.constraint(equalTo: root.widthAnchor),
            footer.widthAnchor.constraint(equalTo: root.widthAnchor),
        ])
    }

    func update(isActive: Bool, boostLevel: Double, loginEnabled: Bool?) {
        toggleSwitch.state = isActive ? .on : .off
        statusLabel.stringValue = isActive ? "On · \(formatted(level: boostLevel))" : "Off"
        statusLabel.textColor = isActive ? .systemOrange : .secondaryLabelColor

        let selectedIndex = Self.presets.enumerated().min {
            abs($0.element.level - boostLevel) < abs($1.element.level - boostLevel)
        }?.offset ?? 0
        boostControl.selectedSegment = selectedIndex

        if let loginEnabled {
            loginButton?.state = loginEnabled ? .on : .off
        }
    }

    private func formatted(level: Double) -> String {
        level.rounded() == level ? "\(Int(level))×" : String(format: "%.1f×", level)
    }

    @objc private func toggleChanged() {
        onToggle?()
    }

    @objc private func boostLevelChanged() {
        guard boostControl.selectedSegment >= 0 else { return }
        onBoostLevelChange?(Self.presets[boostControl.selectedSegment].level)
    }

    @objc private func loginChanged() {
        onLoginToggle?()
    }

    @objc private func quit() {
        onQuit?()
    }
}

typealias XDRScreenInfo = (screen: NSScreen, id: NSNumber, maxEDR: CGFloat)

class XDRApp: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var overlayWindows: [NSNumber: NSWindow] = [:]
    var boostViews: [NSNumber: MTKView] = [:]
    var device: MTLDevice!
    var boostRenderers: [NSNumber: Renderer] = [:]
    var isActive = false
    var shouldBeActive = false  // tracks user intent across sleep/lock cycles
    var boostLevel: Double = 2.0
    var maxEDR: CGFloat = 1.0
    var hotkeyRef: EventHotKeyRef?
    var watchdogTimer: Timer?
    var displayRefreshWorkItem: DispatchWorkItem?
    var activeDisplaySignature: String?

    var screenshotMonitor: Any?
    var suppressedForScreenshot = false
    var screenshotRestoreTimer: Timer?

    var statusPopover: NSPopover!
    var popoverController: XDRPopoverViewController!

    var isRunningAsApp: Bool {
        Bundle.main.bundlePath.hasSuffix(".app")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let dev = MTLCreateSystemDefaultDevice() else {
            fputs("No Metal device\n", stderr); exit(1)
        }
        device = dev
        maxEDR = globalMaxEDR()
        guard maxEDR > 1.0 else {
            fputs("No connected display supports XDR\n", stderr); exit(1)
        }

        if CommandLine.arguments.count > 1, let v = Double(CommandLine.arguments[1]) {
            boostLevel = min(max(v, 1.0), Double(maxEDR))
        }

        setupStatusBar()
        registerGlobalHotkey()
        observeSleepWake()
        observeScreenshots()
        fputs("XDR Boost ready — click menu bar icon or press Ctrl+Option+Cmd+V to toggle\n", stderr)
        fputs("Emergency kill: run `xdr-boost --kill` or press Ctrl+Option+Cmd+V\n", stderr)
        fputs("Max EDR: \(maxEDR)x\n", stderr)
    }

    // MARK: - Global Hotkey (Ctrl+Option+Cmd+V)

    func displayID(for screen: NSScreen) -> NSNumber? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    }

    func xdrScreens() -> [(screen: NSScreen, id: NSNumber, maxEDR: CGFloat)] {
        NSScreen.screens.compactMap { screen in
            guard let id = displayID(for: screen) else { return nil }
            let screenMaxEDR = screen.maximumPotentialExtendedDynamicRangeColorComponentValue
            guard screenMaxEDR > 1.0 else { return nil }
            return (screen: screen, id: id, maxEDR: screenMaxEDR)
        }
    }

    func globalMaxEDR() -> CGFloat {
        xdrScreens().map(\.maxEDR).max() ?? 1.0
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
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: active ? "sun.max.fill" : "sun.max",
                accessibilityDescription: active ? "XDR Boost on" : "XDR Boost off"
            )
            button.image?.isTemplate = true
            button.toolTip = active ? "XDR Boost is on" : "XDR Boost is off"
        }
        updatePopoverUI()
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
        boostView.preferredFramesPerSecond = 10
        let levelForScreen = min(boostLevel, Double(xdrScreen.maxEDR))
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
            newWindows[xdrScreen.id] = overlay.window
            newViews[xdrScreen.id] = overlay.view
            newRenderers[xdrScreen.id] = overlay.renderer
        }

        overlayWindows = newWindows
        boostViews = newViews
        boostRenderers = newRenderers
        activeDisplaySignature = displaySignature(for: screens)
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

    func refreshDisplaysIfNeeded(reason: String? = nil, force: Bool = false) {
        maxEDR = globalMaxEDR()
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

        if force || !isActive || missingOverlay || expectedDisplayIDs != activeDisplayIDs || configChanged {
            let message: String?
            if !isActive {
                message = "XDR ON — \(boostLevel)x on \(screens.count) display(s)\n"
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
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "sun.max", accessibilityDescription: "XDR Boost off")
            button.image?.isTemplate = true
            button.toolTip = "XDR Boost is off"
            button.target = self
            button.action = #selector(togglePopover)
        }

        popoverController = XDRPopoverViewController(showsLoginControl: isRunningAsApp)
        popoverController.onToggle = { [weak self] in self?.toggleXDR() }
        popoverController.onBoostLevelChange = { [weak self] level in self?.setBoostLevel(level) }
        popoverController.onLoginToggle = { [weak self] in self?.toggleLoginItem() }
        popoverController.onQuit = { [weak self] in self?.quit() }
        popoverController.loadViewIfNeeded()

        statusPopover = NSPopover()
        statusPopover.behavior = .transient
        statusPopover.animates = true
        statusPopover.contentViewController = popoverController
        updatePopoverUI()
    }

    @objc func togglePopover() {
        guard let button = statusItem.button else { return }
        if statusPopover.isShown {
            statusPopover.performClose(nil)
        } else {
            updatePopoverUI()
            statusPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func updatePopoverUI() {
        guard popoverController != nil else { return }
        let loginEnabled: Bool?
        if isRunningAsApp, #available(macOS 13.0, *) {
            loginEnabled = SMAppService.mainApp.status == .enabled
        } else {
            loginEnabled = nil
        }
        popoverController.update(
            isActive: isActive,
            boostLevel: boostLevel,
            loginEnabled: loginEnabled
        )
    }

    // MARK: - Watchdog & Display Changes

    func observeSleepWake() {
        // Display config changed (resolution, arrangement, external monitors)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleDisplayChange),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        // Watchdog: every 3 seconds, check if XDR should be on but overlay is dead
        // This handles sleep/wake, lid close/open, lock/unlock — all of them
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self = self, !self.suppressedForScreenshot else { return }
            if self.shouldBeActive && !self.isActive {
                self.refreshDisplaysIfNeeded(reason: "Watchdog — XDR restored\n", force: true)
            } else if self.shouldBeActive && self.isActive {
                let screens = self.xdrScreens()
                let expectedDisplayIDs = Set(screens.map(\.id))
                let activeDisplayIDs = Set(self.overlayWindows.keys)
                let missingOverlay = self.overlayWindows.values.contains { !$0.isVisible }
                let configChanged = self.activeDisplaySignature != self.displaySignature(for: screens)

                if missingOverlay || expectedDisplayIDs != activeDisplayIDs || configChanged {
                    self.refreshDisplaysIfNeeded(reason: "Watchdog — overlay recreated\n", force: true)
                }
            }
        }
    }

    @objc func handleDisplayChange() {
        maxEDR = globalMaxEDR()
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
    // Detection: a non-consuming global key monitor watches for the system
    // screenshot shortcuts (⌘⇧3/4/5/6). Requires Input Monitoring permission.

    func observeScreenshots() {
        // keyCodes: 3 = 20, 4 = 21, 5 = 23, 6 = 22
        let shotKeys: Set<UInt16> = [20, 21, 23, 22]
        screenshotMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags == [.command, .shift] && shotKeys.contains(event.keyCode) {
                self.suppressForScreenshot()
            }
        }
        if screenshotMonitor == nil {
            fputs("Could not install screenshot monitor (grant Input Monitoring permission)\n", stderr)
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
        if let id = app.bundleIdentifier,
           id == "com.apple.screencaptureui" || id == "com.apple.screenshot" {
            return true
        }
        let path = (app.bundleURL ?? app.executableURL)?.path.lowercased() ?? ""
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
        } else {
            activate()
        }
        fputs("Screenshot done — overlay restored\n", stderr)
    }

    // MARK: - Toggle

    @objc func toggleXDR() {
        if isActive {
            shouldBeActive = false
            deactivate(logMessage: "XDR OFF\n")
        } else {
            shouldBeActive = true
            activate()
        }
        updatePopoverUI()
    }

    func setBoostLevel(_ level: Double) {
        boostLevel = level
        if isActive {
            let maxEDRByScreen = Dictionary(uniqueKeysWithValues: xdrScreens().map { ($0.id, Double($0.maxEDR)) })
            for (screenID, view) in boostViews {
                let screenMaxEDR = maxEDRByScreen[screenID] ?? Double(maxEDR)
                let levelForScreen = min(boostLevel, screenMaxEDR)
                view.clearColor = MTLClearColor(red: levelForScreen, green: levelForScreen, blue: levelForScreen, alpha: 1.0)
                view.draw()
            }
            updatePopoverUI()
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

        installOverlays(for: screens, logMessage: "XDR ON — \(boostLevel)x on \(screens.count) display(s)\n")
    }

    func deactivate(logMessage: String? = nil) {
        displayRefreshWorkItem?.cancel()
        displayRefreshWorkItem = nil
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
            updatePopoverUI()
        }
    }

    @objc func quit() {
        deactivate(logMessage: "XDR OFF\n")
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let del = XDRApp()
app.delegate = del
signal(SIGINT) { _ in exit(0) }
signal(SIGTERM) { _ in exit(0) }
app.run()
