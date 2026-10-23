// App.swift. Awayke (a fork of Sleepless by Adam Boudjemaa): a standalone menu-bar toggle that keeps the Mac running
// with the lid closed (on battery, no external display) via `pmset disablesleep`.
//
// Mechanism (verified live on this machine; disablesleep is UNDOCUMENTED in
// pmset(1) but real. It sets IORegistry "SleepDisabled" = Yes and disables
// idle + Apple-menu + lid-close clamshell sleep):
//   ON : sudo pmset -a disablesleep 1
//   OFF: sudo pmset -a disablesleep 0
//   READ (no root): pmset -g | grep -i SleepDisabled  (value 1 = ON; 0/absent = OFF)
// The OFF/ON commands run passwordless via a tightly-scoped /etc/sudoers.d drop-in.
// disablesleep is runtime-only and resets to 0 on reboot, and that reset is a
// deliberate safety feature; the app does NOT auto re-arm.
//
// UI (v1.3 "Ember"): the menu-bar CANDLE (unlit with smoke = sleeps normally, lit = kept
// awake). Single click toggles awake; hold (0.4 s by default) or right-click opens the
// SwiftUI popover (PopoverView.swift); a Settings window (SettingsView.swift) holds the rest.
// The status item has a FIXED width and both glyphs share one canvas, so nothing jitters.
//
// Safety nets: normal sleep is restored on quit (applicationWillTerminate + SIGTERM/INT/HUP),
// on a crash (a pipe-watching child process), and at launch (always starts idle).
//
// Three small, fail-safe features layer on top, none of which adds a daemon or
// persists OS state (so "reboot resets it" still holds):
//   1. Auto-off timer (1h / 2h) — a one-shot in-memory Timer that flips sleep back
//      on when it fires. Dies on quit; nothing survives a reboot.
//   2. Launch at login (SMAppService.mainApp) — OFF by default. The app always
//      launches reading the TRUE system state, so a login launch can never
//      re-enable disablesleep on its own.
//   3. Low-Power-Mode auto-off — on battery, if Low Power Mode is on, Awayke
//      turns itself off. Same shape as the battery floor, evaluated on the same tick.
//
// Build (mirrors Nexus.app): Command Line Tools `swiftc`, NO Xcode project.
//   swiftc -O -parse-as-library -target arm64-apple-macos26.0 -framework AppKit \
//          -framework ServiceManagement
//   File MUST be named App.swift and compiled -parse-as-library so the
//   @main enum + @MainActor static main() entry is Swift-6 isolation-safe.
import AppKit
import IOKit.pwr_mgt
import ServiceManagement
import SwiftUI
@preconcurrency import UserNotifications

// MARK: - Tunables
private let pollInterval: TimeInterval = 60
// Battery-floor config (user-adjustable via the popover slider; persisted in UserDefaults).
private let floorKey = "batteryFloorPercent"
private let floorDefault = 15
private let floorMin = 5
private let floorMax = 50

// MARK: - Menu-bar glyph geometry (see Glyph.swift)
// Fixed status-item width: the one shared glyph canvas plus the standard side padding.
private let statusItemLength: CGFloat = NSStatusItem.variableLength
private let debugNotification = Notification.Name("com.aboudjem.Sleepless.debug")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    // The candle is a view drawn on top of the button (see CandleView); the button keeps one clear picture forever.
    private let candle = CandleView()
    private let iconPlaceholder = CandleView.placeholder(label: "Awayke")
    private var glyphKey = ""                // state + colour + style, to skip redundant swaps

    // Settings window (SwiftUI in an NSWindow, created on first open)
    private var settingsWindow: NSWindow?
    private var introWindow: NSWindow?
    // "Mac and screen" option: a display-sleep assertion held only while awake
    private var displayAssertion: IOPMAssertionID = 0
    // Hold-to-open feedback on the menu-bar icon
    private var holdRing: CAShapeLayer?

    // Popover UI (SwiftUI "Ember" view, driven by this model; logic stays in this class)
    private let popover = NSPopover()
    private let model = PopoverModel()
    private var clickMonitor: Any?
    private var batteryFloorPercent = floorDefault
    private var isOn = false
    private var userForcedOn = false   // user deliberately turned it on; honor over the Low Power Mode auto-off (the hard battery floor still wins)

    // Auto-off timer (in-memory; dies on quit, never survives a reboot)
    private var autoOffMinutes = 0           // 0 = none (stay on until off), 60, or 120
    private var keepAwakeTimer: Timer?       // one-shot: flips sleep back on when it fires
    private var countdownTicker: Timer?      // 1 Hz refresh, only while the popover is open
    private var timerEndDate: Date?

    // Safety nets: restore normal sleep on quit, on crash, and at launch.
    private var signalSources: [DispatchSourceSignal] = []
    private var watchdogPipe: Pipe?          // kept open for the app's lifetime; EOF = we died

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Renamed/moved app: point the login item at this copy.
        if SMAppService.mainApp.status == .enabled { try? SMAppService.mainApp.register() }
        batteryFloorPercent = min(max((UserDefaults.standard.object(forKey: floorKey) as? Int) ?? floorDefault, floorMin), floorMax)
        loadSettings()
        applyDockPolicy()
        autoOffMinutes = model.defaultTimer
        model.autoOffMinutes = autoOffMinutes
        installMainMenu()

        // LAUNCH safety net: always start idle. If sleep was left disabled (a crash, a force
        // quit, an older build), restore normal sleep before showing anything.
        if readSleepDisabled() { setDisableSleep(false) }
        installQuitSignalHandlers()
        startCrashWatchdog()

        // FIXED length (not variableLength): the item can never resize, so the icon and the
        // popover arrow stay put when the state changes.
        statusItem = NSStatusBar.system.statusItem(withLength: statusItemLength)
        if let button = statusItem.button {
            button.image = iconPlaceholder   // never replaced: the candle view does the drawing
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone
            button.wantsLayer = true   // set once here, never toggled later (no relayout on pulse)
            attachCandle(to: button)
            button.action = #selector(statusClicked)
            button.target = self
            // Quick click = toggle; hold (0.4 s default) or right-click = open the popover.
            button.sendAction(on: [.leftMouseDown, .leftMouseUp, .rightMouseUp])
            installPressMonitor()
            button.setAccessibilityLabel("Awayke")
        }
        // Screenshot / scripting helper: lets a local script open the panel or Settings, or
        // toggle, WITHOUT bringing Awayke to the front. UI-only actions plus the same toggle
        // a click does; nothing here can do more than the menu-bar icon already can.
        // One panel at a time: another of our apps opening its panel closes this one.
        PanelGroup.listen { [weak self] in if self?.popover.isShown == true { self?.closePopover() } }
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(debugCommand(_:)),
                                                            name: debugNotification, object: nil)
        let wsc = NSWorkspace.shared.notificationCenter
        wsc.addObserver(self, selector: #selector(screensSlept(_:)), name: NSWorkspace.screensDidSleepNotification, object: nil)
        wsc.addObserver(self, selector: #selector(screensWoke(_:)), name: NSWorkspace.screensDidWakeNotification, object: nil)
        wsc.addObserver(self, selector: #selector(screensWoke(_:)), name: NSWorkspace.didWakeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screensWoke(_:)),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        popover.behavior = .applicationDefined   // app-managed dismissal (no transient close/reopen flicker)
        popover.animates = true
        popover.contentViewController = makeContentController()

        refresh()   // reflect TRUE system state on launch (never a stale assumption)
        if !UserDefaults.standard.bool(forKey: IntroPref.done) { showIntro() }
        timer = Timer.scheduledTimer(timeInterval: pollInterval, target: self,
                                     selector: #selector(poll), userInfo: nil, repeats: true)
    }

    // QUIT safety net (menu Quit, logout, restart, SIGTERM/SIGINT/SIGHUP all land here).
    func applicationWillTerminate(_ notification: Notification) {
        if displayAssertion != 0 { IOPMAssertionRelease(displayAssertion); displayAssertion = 0 }
        if readSleepDisabled() { setDisableSleep(false) }
    }

    private func installQuitSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)   // let the dispatch source handle it on the main queue
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { NSApp.terminate(nil) }
            src.resume()
            signalSources.append(src)
        }
    }

    // CRASH safety net: a tiny child shell blocks reading a pipe whose write end only this app
    // holds. If the app dies for ANY reason (crash, kill -9), the kernel closes that end, the
    // read returns, and the child restores normal sleep with the same scoped, passwordless
    // command the app already uses. No daemon, nothing persisted; it lives and dies with us.
    private func startCrashWatchdog() {
        let pipe = Pipe()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", "read _; exec /usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0 </dev/null >/dev/null 2>&1"]
        proc.standardInput = pipe
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            try? pipe.fileHandleForReading.close()   // only the child reads; we keep the write end
            watchdogPipe = pipe
        } catch {
            NSLog("Awayke: crash watchdog failed to start: %@", error.localizedDescription)
        }
    }

    // MARK: - Popover content (SwiftUI "Ember" design)
    private func makeContentController() -> NSViewController {
        model.floorPercent = batteryFloorPercent
        model.onToggle = { [weak self] want in
            guard let self else { return }
            // Setup needed or failed: only a failed turn-ON is forced to off; a failed turn-off keeps
            // the real state that refresh() already showed.
            if self.performToggle(wantOn: want), want { self.model.isOn = false }
        }
        model.onAutoOff = { [weak self] minutes in self?.setAutoOff(minutes) }
        model.onFloor = { [weak self] v in self?.setFloor(v) }
        model.onLogin = { [weak self] want in self?.setLoginItem(want) }
        model.onSettingsChanged = { [weak self] in self?.settingsChanged() }
        model.onOpenSettings = { [weak self] in self?.openSettings(activate: true) }
        model.onQuit = { [weak self] in self?.quit() }
        let host = NSHostingController(rootView: PopoverView(model: model, floorRange: floorMin...floorMax))
        host.sizingOptions = [.preferredContentSize]
        return host
    }

    // MARK: - Settings (UserDefaults <-> model; applied immediately)
    private func loadSettings() {
        let d = UserDefaults.standard
        model.accentIndex = min(max(d.integer(forKey: Pref.accent), 0), accentChoices.count - 1)
        model.clickOpensPanel = d.bool(forKey: Pref.clickOpensPanel)
        model.longPressIndex = (d.object(forKey: Pref.longPress) as? Int).map { min(max($0, 0), longPressChoices.count - 1) } ?? 1
        model.keepDisplayAwake = d.object(forKey: Pref.keepDisplayAwake) as? Bool ?? true   // screen stays on by default
        let t = d.integer(forKey: Pref.defaultTimer)
        let choices = (d.array(forKey: Pref.timerChoices) as? [Int]).map(cleanTimerChoices) ?? [60, 120]
        model.timerChoices = choices
        model.defaultTimer = choices.contains(t) ? t : 0
        model.showTimerRow = d.object(forKey: Pref.showTimerRow) as? Bool ?? true
        model.showBatteryRow = d.object(forKey: Pref.showBatteryRow) as? Bool ?? true
        model.showLoginRow = d.object(forKey: Pref.showLoginRow) as? Bool ?? true
        model.lowPowerOff = (d.object(forKey: Pref.lowPowerOff) as? Bool) ?? true
        model.monochromeIcon = d.bool(forKey: Pref.monochromeIcon)
        model.showInDock = d.bool(forKey: Pref.showInDock)
    }

    /// Clicking the Dock icon (when shown) or opening Awayke again from Finder opens Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openSettings(activate: true) }
        return false
    }

    /// Dock icon only when "Show in Dock" is on. Off (the default), Awayke lives in the menu bar alone.
    private func applyDockPolicy() {
        let policy: NSApplication.ActivationPolicy = model.showInDock ? .regular : .accessory
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
    }

    private func settingsChanged() {
        let d = UserDefaults.standard
        d.set(model.accentIndex, forKey: Pref.accent)
        d.set(model.clickOpensPanel, forKey: Pref.clickOpensPanel)
        d.set(model.longPressIndex, forKey: Pref.longPress)
        d.set(model.keepDisplayAwake, forKey: Pref.keepDisplayAwake)
        model.timerChoices = cleanTimerChoices(model.timerChoices)
        if !model.timerChoices.contains(model.defaultTimer) { model.defaultTimer = 0 }
        d.set(model.timerChoices, forKey: Pref.timerChoices)
        d.set(model.defaultTimer, forKey: Pref.defaultTimer)
        d.set(model.showTimerRow, forKey: Pref.showTimerRow)
        d.set(model.showBatteryRow, forKey: Pref.showBatteryRow)
        d.set(model.showLoginRow, forKey: Pref.showLoginRow)
        d.set(model.lowPowerOff, forKey: Pref.lowPowerOff)
        d.set(model.monochromeIcon, forKey: Pref.monochromeIcon)
        d.set(model.showInDock, forKey: Pref.showInDock)
        applyDockPolicy()
        updateDisplayAssertion()
        updateStatusGlyph(animated: true)
        if isOn { enforceSafetyNets() }
    }

    private var longPressDelay: TimeInterval { longPressChoices[model.longPressIndex].seconds }

    // MARK: - Screen-awake assertion ("Mac and screen")
    private func updateDisplayAssertion() {
        let want = isOn && model.keepDisplayAwake
        if want, displayAssertion == 0 {
            var id: IOPMAssertionID = 0
            let r = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                "Awayke: keep the screen on" as CFString, &id)
            if r == kIOReturnSuccess { displayAssertion = id }
            else { NSLog("Awayke: display assertion failed (%d)", r) }
        } else if !want, displayAssertion != 0 {
            IOPMAssertionRelease(displayAssertion)
            displayAssertion = 0
        }
    }

    // MARK: - Settings window
    private func openSettings(activate: Bool) {
        if popover.isShown { closePopover() }
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView(model: model, floorRange: floorMin...floorMax))
            let w = NSWindow(contentViewController: host)
            w.title = "Awayke Settings"
            w.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 660, height: 470))
            w.center()
            settingsWindow = w
        }
        refresh()
        model.launchAtLogin = loginItemEnabled()
        if activate {
            NSApp.activate(ignoringOtherApps: true)
            settingsWindow?.makeKeyAndOrderFront(nil)
        } else {
            settingsWindow?.orderFrontRegardless()   // scripted: show without stealing focus
        }
    }

    @objc private func openSettingsFromMenu() { openSettings(activate: true) }

    // A minimal main menu so Cmd+, (Settings) and Cmd+Q work whenever Awayke is active.
    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Awayke")
        let settings = NSMenuItem(title: "Settings\u{2026}", action: #selector(openSettingsFromMenu), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        let quitItem = NSMenuItem(title: "Quit Awayke", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        appMenu.addItem(quitItem)
        appItem.submenu = appMenu
        main.addItem(appItem)
        NSApp.mainMenu = main
    }

    // MARK: - Welcome (shown once after install)

    private func showIntro(page: Int = 0) {
        introWindow?.close()
        let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.title = "Welcome to Awayke"
        let actions = IntroActions(
            permissionReady: { [weak self] in self?.grantInstalled() ?? false },
            setUpPermission: { [weak self] in _ = self?.installGrantViaAuth(ask: false) },
            finish: { [weak self] openPanel in
                UserDefaults.standard.set(true, forKey: IntroPref.done)
                self?.introWindow?.close()
                self?.introWindow = nil
                if openPanel { DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self?.openPopover(activate: false) } }
            })
        w.contentView = NSHostingView(rootView: IntroView(accent: model.accent, actions: actions, page: page))
        w.setContentSize(w.contentView!.fittingSize)
        w.center()
        introWindow = w
        NSApp.activate(ignoringOtherApps: true)   // a deliberate first-run window
        w.makeKeyAndOrderFront(nil)
        w.orderFrontRegardless()
    }

    /// True when the one-time passwordless rule is in place (asks sudo, never prompts).
    private func grantInstalled() -> Bool {
        runPrivileged(["-n", "-l", "/usr/bin/pmset", "-a", "disablesleep", "0"]).exit == 0
    }

    @objc private func debugCommand(_ note: Notification) {
        let cmd = note.object as? String ?? ""
        if cmd.hasPrefix("intro") {   // intro or intro:<page 0-2>
            showIntro(page: Int(cmd.split(separator: ":").last ?? "") ?? 0); return
        }
        if cmd == "sharetest" { ShareFriend.selfTest(report: "/tmp/awayke-share-test.txt"); return }
        if cmd == "closeintro" { introWindow?.close(); introWindow = nil; return }
        if cmd.hasPrefix("warp:") {   // warp:<hours>  pretend the candle has been lit that long
            flickerWarp = (Double(cmd.dropFirst(5)) ?? 0) * 3600; return
        }
        if cmd == "iconstress" { iconStress(); return }
        switch note.object as? String {
        case "popover": if !popover.isShown { openPopover(activate: false) }
        case "settings": openSettings(activate: false)
        case "toggle": quickToggle()
        case "look:light": NSApp.appearance = NSAppearance(named: .aqua)   // app only, for screenshots
        case "look:dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "look:auto": NSApp.appearance = nil
        case "notify": notify("Test: notifications now come from Awayke.")
        case "quit": quit()
        case "close":
            if popover.isShown { closePopover() }
            settingsWindow?.orderOut(nil)
        case "frame":
            // Write the icon's on-screen rectangle (for screenshots) to a temp file.
            if let b = statusItem.button, let w = b.window {
                let r = w.convertToScreen(b.convert(b.bounds, to: nil))
                let txt = "\(Int(r.minX)) \(Int(r.minY)) \(Int(r.width)) \(Int(r.height)) \(Int(NSScreen.main?.frame.height ?? 0))"
                #if DEBUG
                try? txt.write(toFile: "/tmp/sleepless-statusitem.txt", atomically: true, encoding: .utf8)
                #endif
            }
        default: break
        }
    }

    // MARK: - Menu-bar icon clicks
    // Quick left click  -> the "single click" action (default: toggle awake).
    // Hold (0.4 s)      -> the other action (default: open the popover), fired while still held.
    // Right click       -> open / close the popover.
    // Any other trigger (VoiceOver press, keyboard) -> treated as a quick click.
    //
    // LONG-PRESS FIX: while the mouse is down the button runs an event-tracking run loop, so a
    // timer scheduled in the default mode never fired and every press looked "quick". The timer
    // now runs in .common modes, and mouse-up also checks the elapsed time as a backstop.
    private var pressTimer: Timer?
    private var downStamp: TimeInterval?
    private var pressStart: TimeInterval?   // system uptime, the same clock as event timestamps
    private var longPressFired = false

    @objc private func statusClicked() {
        switch NSApp.currentEvent?.type {
        case .leftMouseDown?:
            // macOS hands this over only on release, but its time stamp is when you really pressed.
            downStamp = NSApp.currentEvent?.timestamp
            // The local monitor normally starts the hold first; only start here as a fallback.
            if pressStart != nil { return }
            startHold()
        case .leftMouseUp? where NSApp.currentEvent?.modifierFlags.contains(.option) == true
                              || NSApp.currentEvent?.modifierFlags.contains(.control) == true:
            // Option-click or Control-click opens the panel (a reliable alternative to holding).
            cancelHold()
            if popover.isShown { closePopover() } else { openPopover(activate: true) }
        case .leftMouseUp?:
            pressTimer?.invalidate(); pressTimer = nil
            // Measured with the click's own time stamp: on a busy Mac the release can arrive late,
            // which used to turn a normal click into a hold and open the panel by mistake.
            let upAt = NSApp.currentEvent?.timestamp ?? ProcessInfo.processInfo.systemUptime
            let held = (downStamp ?? pressStart).map { max(0, upAt - $0) } ?? 0
            downStamp = nil
            pressStart = nil
            if longPressFired { return }                       // hold already handled
            if held >= longPressDelay { longPressReached(); return }   // backstop
            endHoldFeedback(completed: false)
            singleClickAction()
        case .rightMouseDown?, .rightMouseUp?:
            pressTimer?.invalidate(); pressTimer = nil; pressStart = nil
            endHoldFeedback(completed: false)
            if popover.isShown { closePopover() } else { openPopover(activate: true) }
        default:
            singleClickAction()
        }
    }

    /// macOS holds back the status button's mouse-down until the mouse is released (the menu
    /// bar waits to see if you are dragging the icon), so neither the action nor an event
    /// monitor learns about a press in time. Instead, while the pointer is over the icon,
    /// watch the real mouse button state and start the hold the moment it goes down.
    private var hoverTimer: Timer?
    private var buttonWasDown = false

    private func installPressMonitor() {
        guard let button = statusItem.button else { return }
        button.addTrackingArea(NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .assumeInside], owner: self, userInfo: nil))
        // macOS doesn't reliably say when the pointer reaches a menu bar icon, so also follow the
        // pointer itself and start or stop watching as it moves onto or off the icon.
        let follow: (NSEvent) -> Void = { [weak self] _ in MainActor.assumeIsolated { self?.pointerMoved() } }
        pointerMonitors = [
            NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: follow) as Any,
            NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { follow($0); return $0 } as Any,
        ]
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in MainActor.assumeIsolated { self?.pointerMoved() } }
    }

    private var pointerMonitors: [Any] = []

    private func pointerMoved() {
        guard let frame = statusItem.button?.window?.frame else { return }
        let inside = frame.contains(NSEvent.mouseLocation)
        if inside, hoverTimer == nil { startHoverWatch() }
        if !inside, hoverTimer != nil { stopHoverWatch() }
    }

    @objc func mouseEntered(_ event: NSEvent) { startHoverWatch() }

    private func startHoverWatch() {
        hoverTimer?.invalidate()
        // A button already held when the pointer arrives (a drag from elsewhere) is not a press here.
        buttonWasDown = CGEventSource.buttonState(.hidSystemState, button: .left)
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollButton() }
        }
        RunLoop.main.add(t, forMode: .common)
        hoverTimer = t
    }

    @objc func mouseExited(_ event: NSEvent) { stopHoverWatch() }

    private func stopHoverWatch() {
        hoverTimer?.invalidate(); hoverTimer = nil
        if buttonWasDown, !longPressFired { cancelHold() }
        buttonWasDown = false
    }

    private func pollButton() {
        let down = CGEventSource.buttonState(.hidSystemState, button: .left)
        if down, !buttonWasDown { startHold() }
        buttonWasDown = down
    }

    private func cancelHold() {
        pressTimer?.invalidate(); pressTimer = nil; pressStart = nil
        endHoldFeedback(completed: false)
    }

    private func startHold() {
        longPressFired = false
        pressStart = ProcessInfo.processInfo.systemUptime
        pressTimer?.invalidate()
        let t = Timer(timeInterval: longPressDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.longPressReached() }
        }
        RunLoop.main.add(t, forMode: .common)
        pressTimer = t
        beginHoldFeedback(duration: longPressDelay)
    }

    private func longPressReached() {
        guard !longPressFired else { return }
        // Only a real hold: if the button is already up, the (late) release will do a normal click.
        if pressTimer != nil, !CGEventSource.buttonState(.hidSystemState, button: .left) { pressTimer = nil; return }
        pressTimer?.invalidate(); pressTimer = nil
        longPressFired = true
        endHoldFeedback(completed: true)
        if model.clickOpensPanel {
            quickToggle()
        } else if !popover.isShown {
            openPopover(activate: true)
        }
    }

    private func singleClickAction() {
        if model.clickOpensPanel {
            if popover.isShown { closePopover() } else { openPopover(activate: true) }
        } else {
            quickToggle()
        }
    }

    // MARK: - Icon motion (hold ring, grow, bounce). Core Animation only, never layout.
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    // Scale about the button's centre regardless of the layer's anchor point.
    private func centredScale(_ s: CGFloat, in b: NSView) -> CATransform3D {
        let c = CGPoint(x: b.bounds.midX, y: b.bounds.midY)
        var t = CATransform3DMakeTranslation(c.x, c.y, 0)
        t = CATransform3DScale(t, s, s, 1)
        return CATransform3DTranslate(t, -c.x, -c.y, 0)
    }

    private func beginHoldFeedback(duration: TimeInterval) {
        guard let b = statusItem.button, let layer = b.layer else { return }
        holdRing?.removeFromSuperlayer()
        holdRing = nil
        // No ring any more (Solomon: the orange circle looked messy); the icon just grows while held.
        guard !reduceMotion else { return }
        let grow = CABasicAnimation(keyPath: "transform")
        grow.fromValue = CATransform3DIdentity
        grow.toValue = centredScale(1.15, in: b)
        grow.duration = duration
        grow.timingFunction = CAMediaTimingFunction(name: .easeOut)
        grow.fillMode = .forwards; grow.isRemovedOnCompletion = false
        layer.add(grow, forKey: "hold")
    }

    private func unusedRingFeedback(duration: TimeInterval) {
        guard let b = statusItem.button, let layer = b.layer else { return }
        let d = min(b.bounds.height, b.bounds.width) - 1
        let ring = CAShapeLayer()
        ring.frame = b.bounds
        let rect = CGRect(x: b.bounds.midX - d / 2, y: b.bounds.midY - d / 2, width: d, height: d)
        // Start at 12 o'clock and run clockwise (layer may be flipped; a full circle reads the same).
        ring.path = CGPath(ellipseIn: rect, transform: nil)
        ring.fillColor = nil
        ring.strokeColor = accentChoice(model.accentIndex).ns.cgColor
        ring.lineWidth = 2
        ring.lineCap = .round
        ring.strokeEnd = 0
        layer.addSublayer(ring)
        holdRing = ring
        let fill = CABasicAnimation(keyPath: "strokeEnd")
        fill.fromValue = 0; fill.toValue = 1
        fill.duration = duration
        fill.timingFunction = CAMediaTimingFunction(name: .linear)
        fill.fillMode = .forwards; fill.isRemovedOnCompletion = false
        ring.add(fill, forKey: "fill")
        guard !reduceMotion else { return }
        let grow = CABasicAnimation(keyPath: "transform")
        grow.fromValue = CATransform3DIdentity
        grow.toValue = centredScale(1.15, in: b)
        grow.duration = duration
        grow.timingFunction = CAMediaTimingFunction(name: .easeOut)
        grow.fillMode = .forwards; grow.isRemovedOnCompletion = false
        layer.add(grow, forKey: "hold")
    }

    private func endHoldFeedback(completed: Bool) {
        guard let b = statusItem.button, let layer = b.layer else { return }
        if let ring = holdRing {
            holdRing = nil
            CATransaction.begin()
            CATransaction.setCompletionBlock { ring.removeFromSuperlayer() }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1; fade.toValue = 0; fade.duration = 0.18
            fade.fillMode = .forwards; fade.isRemovedOnCompletion = false
            ring.add(fade, forKey: "fade")
            CATransaction.commit()
        }
        let current = layer.presentation()?.transform ?? CATransform3DIdentity
        layer.removeAnimation(forKey: "hold")
        guard !reduceMotion else { return }
        // Released early: ease back. Completed: a small springy bounce back to rest.
        let back = CASpringAnimation(keyPath: "transform")
        back.fromValue = current
        back.toValue = CATransform3DIdentity
        back.mass = 1; back.stiffness = completed ? 320 : 400; back.damping = completed ? 11 : 26
        back.initialVelocity = completed ? 6 : 0
        back.duration = back.settlingDuration
        layer.add(back, forKey: "bounce")
    }

    // Small bounce when the popover opens without a hold (right-click, menu, script).
    private func bounceIcon() {
        guard !reduceMotion, let b = statusItem.button, let layer = b.layer else { return }
        let bounce = CASpringAnimation(keyPath: "transform")
        bounce.fromValue = centredScale(1.12, in: b)
        bounce.toValue = CATransform3DIdentity
        bounce.mass = 1; bounce.stiffness = 320; bounce.damping = 11
        bounce.duration = bounce.settlingDuration
        layer.add(bounce, forKey: "bounce")
    }

    private func quickToggle() {
        performToggle(wantOn: !readSleepDisabled())
    }

    private func openPopover(activate: Bool) {
        refresh()                              // sync switch/caption to TRUE state before showing
        model.launchAtLogin = loginItemEnabled()
        guard let button = statusItem.button else { return }
        if !longPressFired { bounceIcon() }    // a completed hold already bounced
        PanelGroup.announceOpen()   // close our other apps' panels
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Never activate the app: that would swap the whole menu bar to Awayke's menus behind
        // the popover. A non-activating panel still takes clicks and keys.
        if let panel = popover.contentViewController?.view.window as? NSPanel {
            panel.styleMask.insert(.nonactivatingPanel)
        }
        if activate { popover.contentViewController?.view.window?.makeKey() }
        if keepAwakeTimer != nil { startCountdownTicker() }
        updateCountdownLabel()
        model.openCount += 1   // entrance spring in the SwiftUI content
        // Close when the user clicks anywhere outside the app (status bar, another app, desktop).
        MenuBarStrip.startEsc(window: { [weak self] in self?.popover.contentViewController?.view.window }, close: { [weak self] in self?.closePopover() })
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            if PanelGroup.isOnNoxSwitch() { return }   // Nox's quick dark-mode switch never closes a panel
            self?.closePopover()   // any other click outside (desktop, other apps, any menu bar item) closes it
        }
    }

    private func closePopover() {
        popover.performClose(nil)
        countdownTicker?.invalidate(); countdownTicker = nil   // stop the 1 Hz label refresh (keep-awake timer keeps running)
        if let monitor = clickMonitor { NSEvent.removeMonitor(monitor); clickMonitor = nil }
        MenuBarStrip.stopEsc()
    }

    // Core keep-awake toggle, decoupled from the UI sender. Returns true ONLY when the user
    // must act (the passwordless grant is missing and setup did not complete) so the caller can
    // reflect OFF. The decision to prompt is made on the REAL sudo result (see setDisableSleep),
    // never by re-reading SleepDisabled: a successful sudo means the command ran, even if a
    // safety net (Low Power Mode / battery floor) legitimately turns sleep back on afterwards —
    // which must NOT be mistaken for "permission missing" and trigger a password prompt. This
    // unobservable, state-proxy decision is what made earlier releases re-prompt spuriously.
    @discardableResult
    private func performToggle(wantOn: Bool) -> Bool {
        var result = setDisableSleep(wantOn)
        // Only a genuinely MISSING grant warrants the one-time native-auth setup. A successful
        // sudo (.ok) — or any other failure — never re-prompts here.
        if wantOn, result == .grantMissing {
            if installGrantViaAuth() { result = setDisableSleep(true) }
            if result != .ok {
                notify("Couldn't keep awake. The permission isn't set up yet.")
                return true
            }
        }
        if case .failed(let why) = result {
            NSLog("Awayke: pmset change failed: %@", why)
            notify(wantOn ? "Couldn't keep your Mac awake. Try again." : "Couldn't turn keep-awake off. Try again.")
            refresh()
            return true
        }
        // A deliberate, successful turn-on wins over the Low Power Mode auto-off (hard floor still wins).
        userForcedOn = wantOn && result == .ok
        refresh()                              // applies UI + safety nets; switch reflects reality
        if isOn, autoOffMinutes > 0 { startKeepAwakeTimer(minutes: autoOffMinutes) }
        return false
    }

    // Install the one-time scoped grant via a SINGLE native macOS authorization (the
    // standard Touch ID / password sheet) — no Terminal. Runs the bundled, audited
    // grant.sh as root through osascript's "with administrator privileges"; grant.sh is
    // root-aware so it writes the sudoers drop-in directly with no inner sudo prompt.
    // Returns true once the passwordless grant is in place; after that the app never asks again.
    @discardableResult
    private func installGrantViaAuth(ask: Bool = true) -> Bool {
        if ask {
        let intro = NSAlert()
        intro.alertStyle = .informational
        intro.messageText = "Enable keeping your Mac awake"
        intro.informativeText = "Awayke flips a protected macOS setting (pmset disablesleep), so it needs your permission once. macOS will ask you to authenticate (Touch ID or your password). After that the switch works instantly, with no more prompts."
        intro.addButton(withTitle: "Enable")
        intro.addButton(withTitle: "Not now")
        NSApp.activate(ignoringOtherApps: true)
        guard intro.runModal() == .alertFirstButtonReturn else { return false }
        }

        guard let res = Bundle.main.resourcePath else { return false }
        let grant = res + "/grant.sh"
        // Pass the REAL user: under the native auth sheet grant.sh runs as root with
        // SUDO_USER unset, so without this the grant would be written for "root" (useless).
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let shellCmd = "SLEEPLESS_USER=\(q(NSUserName())) /bin/bash \(q(grant)) --yes"
        // escape for an AppleScript string literal, then run with one native auth sheet
        let escaped = shellCmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let osa = "do shell script \"\(escaped)\" with administrator privileges"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", osa]
        proc.standardOutput = Pipe(); proc.standardError = Pipe()
        do { try proc.run(); proc.waitUntilExit() }
        catch { notify("Couldn't start the one-time setup."); return false }
        if proc.terminationStatus == 0 { return true }   // grant.sh installed the rule successfully
        if proc.terminationStatus != 128 {               // 128 = user cancelled the auth sheet
            notify("Setup didn't complete. Try again, or run grant.sh from the app bundle.")
        }
        return false
    }

    @objc private func poll() { refresh() }

    // MARK: - Auto-off timer (Feature 1)
    private func setAutoOff(_ minutes: Int) {
        autoOffMinutes = (1...maxTimerMinutes).contains(minutes) ? minutes : 0
        model.autoOffMinutes = autoOffMinutes
        if isOn, autoOffMinutes > 0 {
            startKeepAwakeTimer(minutes: autoOffMinutes)
        } else {
            cancelKeepAwakeTimer()
            updateCountdownLabel()
        }
    }

    private func startKeepAwakeTimer(minutes: Int) {
        cancelKeepAwakeTimer()
        guard minutes > 0, isOn else { updateCountdownLabel(); return }
        let seconds = TimeInterval(minutes * 60)
        timerEndDate = Date().addingTimeInterval(seconds)
        keepAwakeTimer = Timer.scheduledTimer(timeInterval: seconds, target: self,
                                              selector: #selector(keepAwakeTimerFired), userInfo: nil, repeats: false)
        if popover.isShown { startCountdownTicker() }
        updateCountdownLabel()
    }

    private func cancelKeepAwakeTimer() {
        keepAwakeTimer?.invalidate(); keepAwakeTimer = nil
        countdownTicker?.invalidate(); countdownTicker = nil
        timerEndDate = nil
    }

    @objc private func keepAwakeTimerFired() {
        let result = setDisableSleep(false)
        cancelKeepAwakeTimer()
        autoOffMinutes = 0
        model.autoOffMinutes = 0
        applyUI(on: readSleepDisabled())
        if result == .ok {
            notify("Auto-off timer ended. Awayke turned off.")
        } else {
            NSLog("Awayke: auto-off could not turn keep-awake off")
            notify("Auto-off timer ended, but Awayke couldn't turn off. Switch it off by hand.")
        }
    }

    private func startCountdownTicker() {
        countdownTicker?.invalidate()
        countdownTicker = Timer.scheduledTimer(timeInterval: 1, target: self,
                                               selector: #selector(countdownTick), userInfo: nil, repeats: true)
    }

    @objc private func countdownTick() { updateCountdownLabel() }

    // The popover draws the live countdown itself (TimelineView); this keeps its inputs true.
    private func updateCountdownLabel() {
        guard let end = timerEndDate, isOn, end.timeIntervalSinceNow > 0 else {
            if model.timerEnd != nil { model.timerEnd = nil }
            return
        }
        if model.timerEnd != end {
            model.timerEnd = end
            model.timerTotal = TimeInterval(autoOffMinutes * 60)
        }
    }

    // MARK: - Launch at login (Feature 2) — OFF by default; never re-enables sleep prevention
    private func setLoginItem(_ want: Bool) {
        do {
            if want { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Awayke: login item update failed: %@", error.localizedDescription)
            notify("Couldn't update Launch at login.")
        }
        model.launchAtLogin = loginItemEnabled()
    }

    private func loginItemEnabled() -> Bool { SMAppService.mainApp.status == .enabled }

    // MARK: - Core state sync
    @objc private func refresh() {
        let on = readSleepDisabled()
        updateBatteryModel()
        applyUI(on: on)
        if on { enforceSafetyNets() }
    }

    private func applyUI(on: Bool) {
        isOn = on
        if !on { cancelKeepAwakeTimer() }   // going OFF clears any countdown/timer
        // ARMED = kept awake while actively discharging on battery (safety net live).
        var armed = false
        if on {
            let (onBattery, discharging, _) = batteryStatus()
            armed = onBattery && discharging
        }
        updateStatusGlyph(animated: true)
        if let button = statusItem.button {
            button.toolTip = on
                ? (armed
                    ? "Awayke: on (battery). Turns off at \(batteryFloorPercent)%."
                    : "Awayke: on. Stays awake with the lid closed.")
                : "Awayke: off. Sleeps normally."
        }
        if on, model.awakeSince == nil { model.awakeSince = Date() }
        if !on { model.awakeSince = nil }
        model.isOn = on
        model.armed = armed
        updateDisplayAssertion()
        renderText()
        updateCountdownLabel()
    }

    // Menu-bar candle: OFF = unlit, in the menu bar's own colour; AWAKE = lit, in the accent colour (or the menu bar's
    // colour when "Monochrome" is chosen). Drawn by CandleView on top of the button: the button's picture is never
    // swapped and no layer transition is ever added to it (that is what made the candle flip after long awake runs).
    private func attachCandle(to button: NSStatusBarButton) {
        if candle.superview !== button { candle.removeFromSuperview(); button.addSubview(candle) }
        candle.frame = button.bounds
        candle.autoresizingMask = [.width, .height]
        candle.needsDisplay = true
    }

    private func updateStatusGlyph(animated: Bool) {
        guard let button = statusItem.button else { return }
        let awake = isOn
        let key = "\(awake)-\(model.accentIndex)-\(model.monochromeIcon)"
        guard key != glyphKey else { return }
        glyphKey = key
        attachCandle(to: button)
        candle.color = awake && !model.monochromeIcon ? accentChoice(model.accentIndex).ns : nil
        candle.awake = awake
        candle.flicker = 0
        button.setAccessibilityValue(awake ? "awake" : "off")
        updateFlicker(awake: awake)
    }

    // MARK: - Candle flicker: while awake, the flame gently sways (leans and stretches a little), redrawn in place.
    private var flickerTimer: Timer?
    private var flickerClock = CACurrentMediaTime()
    private var flickerWarp: Double = 0          // test hook: pretend the candle has been lit for hours
    private static let flickerPeriod: Double = 4.4   // one slow sway left and right
    private static let flickerLean: CGFloat = 0.3

    private func updateFlicker(awake: Bool) {
        flickerTimer?.invalidate(); flickerTimer = nil   // only ever one timer, however often this is called
        candle.flicker = 0
        guard awake, !reduceMotion, !screensAsleep else { return }
        flickerClock = CACurrentMediaTime()
        let t = Timer(timeInterval: 1.0 / 12.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.flickerStep() }
        }
        t.tolerance = 0.02
        RunLoop.main.add(t, forMode: .common)
        flickerTimer = t
    }

    /// The sway at `elapsed` seconds: a sine wave folded into one period first, so it stays exact however long the
    /// candle has been lit (days, weeks).
    static func flickerValue(elapsed: Double) -> CGFloat {
        let p = elapsed.truncatingRemainder(dividingBy: flickerPeriod)
        let v = flickerLean * CGFloat(sin(2 * Double.pi * p / flickerPeriod))
        return v.isFinite ? v : 0
    }

    private func flickerStep() {
        guard isOn else { updateFlicker(awake: false); return }
        candle.flicker = Self.flickerValue(elapsed: CACurrentMediaTime() - flickerClock + flickerWarp)
    }

    /// Test hook ("iconstress"): days of sway in a few seconds plus repeated sleep/wake, then checks that nothing
    /// drifted: the candle is still on the button, upright, the button picture never changed, no stray animations.
    private func iconStress() {
        guard let button = statusItem.button else { return }
        var worst: CGFloat = 0, bad = 0
        let base = 3.0 * 86400   // three days lit
        for i in 0..<200_000 {
            let v = Self.flickerValue(elapsed: base + Double(i) * 1.37)
            if !v.isFinite || abs(v) > Self.flickerLean + 1e-6 { bad += 1 }
            worst = max(worst, abs(v))
            if i % 2000 == 0 { candle.flicker = v; candle.display() }
        }
        for _ in 0..<40 {
            screensSlept(Notification(name: NSWorkspace.screensDidSleepNotification))
            screensWoke(Notification(name: NSWorkspace.screensDidWakeNotification))
        }
        flickerWarp = base
        let keys = button.layer?.animationKeys() ?? []
        let lines = [
            "frames=200000 bad=\(bad) worstLean=\(String(format: "%.4f", worst))",
            "candleOnButton=\(candle.superview === button) candleFlipped=\(candle.isFlipped) frameMatches=\(candle.frame == button.bounds)",
            "buttonImageUnchanged=\(button.image === iconPlaceholder) buttonLayerAnimations=\(keys)",
            "timerRunning=\(flickerTimer?.isValid ?? false) isOn=\(isOn)"
        ]
        try? lines.joined(separator: "\n").write(toFile: "/tmp/awayke-iconstress.txt", atomically: true, encoding: .utf8)
    }

    // Screens asleep: stop redrawing. Back from sleep or after a display change: re-seat the candle and redraw.
    private var screensAsleep = false
    @objc private func screensSlept(_ n: Notification) { screensAsleep = true; flickerTimer?.invalidate(); flickerTimer = nil }
    @objc private func screensWoke(_ n: Notification) {
        screensAsleep = false
        if let b = statusItem.button { attachCandle(to: b) }
        updateFlicker(awake: isOn)
    }

    // Update text labels only (no pmset subprocess; safe to call on every slider tick).
    private func renderText() {
        model.floorPercent = batteryFloorPercent
    }

    private func setFloor(_ value: Int) {
        let v = min(max(value, floorMin), floorMax)
        if v != batteryFloorPercent {
            batteryFloorPercent = v
            UserDefaults.standard.set(v, forKey: floorKey)
        }
        renderText()
    }

    // Result of the privileged keep-awake toggle, based on sudo's REAL exit status — not on a
    // second, independent state read. `.ok` = the command ran; `.grantMissing` = the passwordless
    // sudoers grant isn't installed (sudo -n refused), the one case that warrants setup; `.failed`
    // = any other error. Using sudo's own result (instead of re-reading SleepDisabled) is the fix:
    // a safety net flipping sleep back on must never look like "permission missing" and re-prompt.
    private enum ToggleResult: Equatable { case ok, grantMissing, failed(String) }

    @discardableResult
    private func setDisableSleep(_ on: Bool) -> ToggleResult {
        // sudo -n: never prompt (GUI app has no TTY). The exact argument vector matches the
        // NOPASSWD sudoers grant, so this runs without a password.
        let (exit, _, err) = runPrivileged(["-n", "/usr/bin/pmset", "-a", "disablesleep", on ? "1" : "0"])
        let result: ToggleResult
        if exit == 0 {
            result = .ok
        } else if err.range(of: "a password is required", options: .caseInsensitive) != nil
               || err.range(of: "not allowed", options: .caseInsensitive) != nil
               || err.range(of: "may not run", options: .caseInsensitive) != nil {
            result = .grantMissing   // grant absent/removed -> sudo -n refused to run passwordless
        } else {
            result = .failed(err.isEmpty ? "exit \(exit)" : err.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result
    }

    // Run a privileged command via sudo, capturing exit status + stderr (which the generic
    // runCapture discards). stdin is /dev/null so a GUI process with no controlling TTY can
    // never block on a prompt. This is what lets the app KNOW whether its own toggle worked.
    private func runPrivileged(_ args: [String]) -> (exit: Int32, out: String, err: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
        env["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        process.environment = env
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice
        do { try process.run() }
        catch {
            NSLog("Awayke: failed to launch sudo: %@", error.localizedDescription)
            return (-1, "", "launch failed: \(error.localizedDescription)")
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus,
                String(data: outData, encoding: .utf8) ?? "",
                String(data: errData, encoding: .utf8) ?? "")
    }

    // MARK: - Battery + Low-Power-Mode safety nets (silent; no extra UI) — Feature 3
    private func enforceSafetyNets() {
        let (onBattery, discharging, percent) = batteryStatus()
        guard onBattery, discharging else { return }
        // Hard battery floor ALWAYS wins, even over a deliberate turn-on: never drain to empty.
        if percent <= batteryFloorPercent {
            setDisableSleep(false); userForcedOn = false
            applyUI(on: readSleepDisabled())
            notify("Battery low (\(percent)%). Awayke turned off.")
            return
        }
        // Low Power Mode auto-off (a setting), UNLESS the user deliberately chose to keep awake this session.
        if model.lowPowerOff && ProcessInfo.processInfo.isLowPowerModeEnabled && !userForcedOn {
            setDisableSleep(false)
            applyUI(on: readSleepDisabled())
            notify("Low Power Mode on. Awayke turned off.")
        }
    }

    // MARK: - Readers (no root needed)
    private func readSleepDisabled() -> Bool {
        let out = runCapture("/usr/bin/pmset", ["-g"])
        for line in out.split(whereSeparator: { $0 == "\n" }) {
            if line.range(of: "SleepDisabled", options: .caseInsensitive) != nil {
                let toks = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                if let last = toks.last { return last == "1" }
            }
        }
        return false   // line absent -> OFF
    }

    // Popover battery readout (display only; the safety nets keep using batteryStatus()).
    private func updateBatteryModel() {
        let out = runCapture("/usr/bin/pmset", ["-g", "batt"])
        guard out.contains("InternalBattery") else { model.batteryPercent = nil; return }
        var percent: Int?
        for tok in out.split(whereSeparator: { " \t\n;".contains($0) }) {
            if tok.hasSuffix("%"), let v = Int(tok.dropLast()) { percent = v; break }
        }
        model.batteryPercent = percent
        model.charging = out.contains("AC Power")
    }

    private func batteryStatus() -> (onBattery: Bool, discharging: Bool, percent: Int) {
        let out = runCapture("/usr/bin/pmset", ["-g", "batt"])
        let onBattery = out.contains("Battery Power")
        let discharging = out.range(of: "discharging", options: .caseInsensitive) != nil
        var percent = 100
        for tok in out.split(whereSeparator: { " \t\n;".contains($0) }) {
            if tok.hasSuffix("%"), let v = Int(tok.dropLast()) { percent = v; break }
        }
        return (onBattery, discharging, percent)
    }

    // MARK: - Notification (mirrors Nexus' osascript approach)
    /// Posts as Awayke itself (its own name and candle icon). Falls back to a plain
    /// AppleScript notice only if notifications for Awayke are turned off or unavailable.
    private func notify(_ message: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else {
                let script = "display notification \"\(message)\" with title \"Awayke\" sound name \"Tink\""
                DispatchQueue.main.async { _ = self.runCapture("/usr/bin/osascript", ["-e", script]) }
                return
            }
            let content = UNMutableNotificationContent()
            content.title = "Awayke"
            content.body = message
            content.sound = UNNotificationSound(named: UNNotificationSoundName("Tink"))
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    // MARK: - Process runner (explicit PATH/HOME; captures stdout)
    @discardableResult
    private func runCapture(_ launchPath: String, _ args: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
        env["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() }
        catch { NSLog("Awayke: failed to launch %@: %@", launchPath, error.localizedDescription); return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Fold the panel away with its normal close animation first, then quit.
    @objc private func quit() {
        guard popover.isShown else { NSApp.terminate(nil); return }
        closePopover()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { NSApp.terminate(nil) }
    }
}

@main
enum SleeplessApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        objc_setAssociatedObject(app, &delegateKey, delegate, .OBJC_ASSOCIATION_RETAIN)
        app.run()
    }
}

nonisolated(unsafe) private var delegateKey = 0
