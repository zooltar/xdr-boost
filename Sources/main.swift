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

    var toggleItem: NSMenuItem!
    var shortcutItem: NSMenuItem!
    var loginItem: NSMenuItem!
    var boostItems: [NSMenuItem] = []

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
        statusItem.button?.title = active ? "☀︎" : "☀"
        toggleItem.title = active ? "Turn Off" : "Turn On"
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
        window.sharingType = .none
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
            button.title = "☀"
        }

        let menu = NSMenu()

        toggleItem = NSMenuItem(title: "Turn On", action: #selector(toggleXDR), keyEquivalent: "b")
        toggleItem.target = self
        menu.addItem(toggleItem)

        shortcutItem = NSMenuItem(title: "Shortcut: Ctrl+Option+Cmd+V", action: nil, keyEquivalent: "")
        shortcutItem.isEnabled = false
        menu.addItem(shortcutItem)

        menu.addItem(NSMenuItem.separator())

        let levelHeader = NSMenuItem(title: "Brightness Level", action: nil, keyEquivalent: "")
        levelHeader.isEnabled = false
        menu.addItem(levelHeader)

        let levels: [(String, Double)] = [
            ("1.5x — Subtle", 1.5),
            ("2.0x — Normal", 2.0),
            ("3.0x — Bright", 3.0),
            ("4.0x — Max", 4.0),
        ]

        for (title, level) in levels {
            let item = NSMenuItem(title: title, action: #selector(setBoostLevel(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Int(level * 100)
            item.state = (level == boostLevel) ? .on : .off
            menu.addItem(item)
            boostItems.append(item)
        }

        if isRunningAsApp {
            menu.addItem(NSMenuItem.separator())
            loginItem = NSMenuItem(title: "Start at Login", action: #selector(toggleLoginItem), keyEquivalent: "")
            loginItem.target = self
            if #available(macOS 13.0, *) {
                loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
            }
            menu.addItem(loginItem)
        }

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
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
            guard let self = self else { return }
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

    // MARK: - Toggle

    @objc func toggleXDR() {
        if isActive {
            shouldBeActive = false
            deactivate(logMessage: "XDR OFF\n")
        } else {
            shouldBeActive = true
            activate()
        }
    }

    @objc func setBoostLevel(_ sender: NSMenuItem) {
        boostLevel = Double(sender.tag) / 100.0
        for item in boostItems {
            item.state = (item.tag == sender.tag) ? .on : .off
        }
        if isActive {
            let maxEDRByScreen = Dictionary(uniqueKeysWithValues: xdrScreens().map { ($0.id, Double($0.maxEDR)) })
            for (screenID, view) in boostViews {
                let screenMaxEDR = maxEDRByScreen[screenID] ?? Double(maxEDR)
                let levelForScreen = min(boostLevel, screenMaxEDR)
                view.clearColor = MTLClearColor(red: levelForScreen, green: levelForScreen, blue: levelForScreen, alpha: 1.0)
            }
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
            loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
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
