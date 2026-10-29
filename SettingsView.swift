// SettingsView.swift. The Awayke Settings window (SwiftUI in an NSWindow, Ember palette).
//
// A sidebar of seven sections (General, Awake, Lid, Battery, Network, Appearance, About). Every control
// writes through PopoverModel -> AppDelegate, which saves it to UserDefaults and applies it
// at once (click behaviour, hold length, screen-awake assertion, timers, battery cutoff, lid actions, icon).
import SwiftUI
import AppKit

enum SettingsPane: String, CaseIterable, Identifiable {
    case general = "General", awake = "Awake", lid = "Lid", battery = "Battery", network = "Network", appearance = "Appearance", about = "About"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .general: "gearshape"
        case .awake: "eye"
        case .lid: "laptopcomputer"
        case .battery: "battery.50percent"
        case .network: "wifi"
        case .appearance: "paintpalette"
        case .about: "info.circle"
        }
    }
}

struct SettingsView: View {
    let model: PopoverModel
    let floorRange: ClosedRange<Int>
    @State private var pane: SettingsPane

    private let height: CGFloat

    init(model: PopoverModel, floorRange: ClosedRange<Int>, pane: SettingsPane = .general, height: CGFloat = 500) {
        self.model = model
        self.height = height
        self.floorRange = floorRange
        _pane = State(initialValue: pane)
    }
    @State private var newTimer = 30
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var accent: Color { model.accent }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(pane.rawValue)
                        .font(.system(size: 22, weight: .semibold))
                        .padding(.top, 4)
                    content
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 22)
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(pane)
                .transition(.opacity.combined(with: .offset(y: reduceMotion ? 0 : 6)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 660, height: height)
        .environment(\.sleepAccent, accent)
        .focusEffectDisabled()   // no blue keyboard-focus rings on the controls
        .tint(accent)
        .animation(reduceMotion ? nil : .spring(duration: 0.32, bounce: 0.12), value: pane)
        .animation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.2), value: model.accentIndex)
    }

    // MARK: Sidebar
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(accent)
                    Image(nsImage: EyeGlyph.image(awake: true, size: NSSize(width: 20, height: 14)))
                        .renderingMode(.template)
                        .foregroundStyle(.white)
                }
                .frame(width: 28, height: 28)
                Text("Awayke").font(.system(size: 14, weight: .semibold))
            }
            .padding(.horizontal, 10)
            .padding(.top, 34)
            .padding(.bottom, 14)

            ForEach(SettingsPane.allCases) { p in
                SidebarItem(pane: p, selected: pane == p) { pane = p }
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(width: 190)
        .frame(maxHeight: .infinity)
        .background(.regularMaterial)
    }

    @ViewBuilder private var content: some View {
        switch pane {
        case .general: general
        case .awake: awake
        case .lid: lid
        case .battery: battery
        case .network: network
        case .appearance: appearance
        case .about: about
        }
    }

    // MARK: General
    private var general: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsCard {
                SettingRow(title: "Launch at login", detail: "Start Awayke when you log in. It always starts switched off.") {
                    SmoothSwitch(isOn: model.launchAtLogin, title: "Launch at login", tint: accent) { want in DispatchQueue.main.async { model.onLogin(want) } }
                }
                CardDivider()
                SettingRow(title: "Show in Dock", detail: "Off: Awayke stays in the menu bar only.") {
                    SmoothSwitch(isOn: model.showInDock, title: "Show in Dock", tint: accent) { setting(\.showInDock).wrappedValue = $0 }
                }
            }
            SettingsCard {
                SettingRow(title: "Single click on the menu bar icon",
                           detail: model.clickOpensPanel ? "Click opens the panel. Hold to switch awake on or off."
                                                         : "Click switches awake on or off. Hold to open the panel.") {
                    Picker("", selection: setting(\.clickOpensPanel)) {
                        Text("Toggle awake").tag(false)
                        Text("Open panel").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                CardDivider()
                SettingRow(title: "Hold length", detail: "How long to hold the icon before the hold action happens. Right-click always opens the panel.") {
                    Picker("", selection: setting(\.longPressIndex)) {
                        ForEach(longPressChoices.indices, id: \.self) { i in
                            Text(longPressChoices[i].label).tag(i)
                        }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
            }
            Text("Show in the panel").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            panelCard
        }
    }

    // MARK: What the panel shows (General)
    private var panelCard: some View {
        SettingsCard {
            SettingRow(title: "Auto-off timer", detail: nil) {
                SmoothSwitch(isOn: model.showTimerRow, title: "Show auto-off timer", tint: accent) { setting(\.showTimerRow).wrappedValue = $0 }
            }
            CardDivider()
            SettingRow(title: "Battery cutoff", detail: nil) {
                SmoothSwitch(isOn: model.showBatteryRow, title: "Show battery cutoff", tint: accent) { setting(\.showBatteryRow).wrappedValue = $0 }
            }
            CardDivider()
            SettingRow(title: "Launch at login", detail: nil) {
                SmoothSwitch(isOn: model.showLoginRow, title: "Show launch at login", tint: accent) { setting(\.showLoginRow).wrappedValue = $0 }
            }
        }
    }

    // MARK: Awake
    private var awake: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsCard {
                SettingRow(title: "Keep awake with lid closed", detail: "The Mac keeps running when you close the lid, even on battery.") {
                    SmoothSwitch(isOn: model.isOn, title: "Keep awake with lid closed", tint: accent) { want in
                        DispatchQueue.main.async { model.onToggle(want) }
                    }
                }
                CardDivider()
                SettingRow(title: "What stays awake", detail: model.keepDisplayAwake
                           ? "The screen stays on too while Awayke is on."
                           : "Only the Mac stays awake. The screen can still turn off to save power.") {
                    Picker("", selection: setting(\.keepDisplayAwake)) {
                        Text("Mac only").tag(false)
                        Text("Mac and screen").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
            }
            SettingsCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Timer buttons in the panel").font(.system(size: 13, weight: .medium))
                    Text("Off is always there. Add up to \(maxTimerChoices) of your own, from 5 minutes to 30 days.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        ForEach(model.timerChoices, id: \.self) { m in
                            TimerChip(label: timerLabel(m, long: true)) {
                                model.timerChoices.removeAll { $0 == m }
                                model.onSettingsChanged()
                            }
                        }
                        if model.timerChoices.isEmpty {
                            Text("Only Off for now").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                    // Pick a length with a chip or the drum, then add it as a panel button.
                    ChipDrumPicker(title: "New timer", value: newTimer, mode: .duration(5...maxTimerMinutes),
                                   presets: [30, 60, 120, 480, 1440, 4320], tint: accent, chipColumns: 3,
                                   label: { timerLabel($0) }) { newTimer = $0 }
                        .padding(.top, 4)
                    HStack {
                        Text(timerLabel(newTimer, long: true)).font(.system(size: 12.5)).monospacedDigit()
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Add") {
                            model.timerChoices.append(newTimer)
                            model.onSettingsChanged()
                        }
                        .disabled(model.timerChoices.count >= maxTimerChoices || model.timerChoices.contains(newTimer))
                    }
                }
                .padding(14)
                CardDivider()
                SettingRow(title: "Default auto-off timer", detail: "Used each time Awayke starts. You can still change it in the panel.") {
                    Picker("", selection: setting(\.defaultTimer)) {
                        Text("Off").tag(0)
                        ForEach(model.timerChoices, id: \.self) { m in Text(timerLabel(m, long: true)).tag(m) }
                    }
                    .pickerStyle(.menu).labelsHidden().fixedSize()
                }
            }
            SettingsCard {
                SettingRow(title: "Show time left in the menu bar", detail: "While a timer runs, the time left sits next to the candle.") {
                    SmoothSwitch(isOn: model.showTimeInMenuBar, title: "Show time left in the menu bar", tint: accent) { setting(\.showTimeInMenuBar).wrappedValue = $0 }
                }
                CardDivider()
                SettingRow(title: "Warn 5 minutes before the timer ends", detail: "A notice gives you time to add more. The panel has an Add \(addTimeMinutes) min button while a timer runs.") {
                    SmoothSwitch(isOn: model.warnBeforeEnd, title: "Warn 5 minutes before the timer ends", tint: accent) { setting(\.warnBeforeEnd).wrappedValue = $0 }
                }
            }
        }
    }

    // MARK: Lid (what happens while the lid is closed and Awayke is on)
    private var lid: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("While Awayke is on and the lid is closed. Everything goes back when you open the lid, switch Awayke off or quit.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SettingsCard {
                SettingRow(title: "Turn the screen off", detail: "The screen goes dark and wakes again when you open the lid.") {
                    SmoothSwitch(isOn: model.lidScreenOff, title: "Turn the screen off", tint: accent) { setting(\.lidScreenOff).wrappedValue = $0 }
                }
                CardDivider()
                SettingRow(title: "Mute the sound", detail: "So nothing plays from a closed laptop. Unmuted when the lid opens.") {
                    SmoothSwitch(isOn: model.lidMute, title: "Mute the sound", tint: accent) { setting(\.lidMute).wrappedValue = $0 }
                }
                CardDivider()
                SettingRow(title: "Turn the keyboard light off", detail: "Comes back at the same brightness when you open the lid.") {
                    SmoothSwitch(isOn: model.lidKeyboardOff, title: "Turn the keyboard light off", tint: accent) { setting(\.lidKeyboardOff).wrappedValue = $0 }
                }
                CardDivider()
                SettingRow(title: "Switch to dark mode", detail: "Goes back to light when you open the lid, if it was light before. macOS asks once to let Awayke change this.") {
                    SmoothSwitch(isOn: model.lidDarkMode, title: "Switch to dark mode", tint: accent) { setting(\.lidDarkMode).wrappedValue = $0 }
                }
                CardDivider()
                SettingRow(title: "Turn on Low Power Mode", detail: "Saves battery while the lid is closed. Off again when you open the lid, unless the battery or heat rules still need it.") {
                    SmoothSwitch(isOn: model.lidLowPower, title: "Turn on Low Power Mode", tint: accent) { setting(\.lidLowPower).wrappedValue = $0 }
                }
                CardDivider()
                SettingRow(title: "Pause Docker when it's idle", detail: "Off by default. Pauses Docker Desktop only when no container is running.") {
                    SmoothSwitch(isOn: model.lidDocker, title: "Pause Docker when it's idle", tint: accent) { setting(\.lidDocker).wrappedValue = $0 }
                }
            }
            if !model.lowPowerAllowed { lowPowerPermission }
            SettingsCard {
                SettingRow(title: "Pause chosen apps", detail: "These apps are paused to save battery and carry on when the lid opens.") {
                    SmoothSwitch(isOn: model.lidPauseChosen, title: "Pause chosen apps", tint: accent) { setting(\.lidPauseChosen).wrappedValue = $0 }
                }
                VStack(alignment: .leading, spacing: 8) {
                    FlowChips(items: model.pauseList.map { ($0, appName($0)) }) { id in
                        model.pauseList.removeAll { $0 == id }
                        model.onSettingsChanged()
                    }
                    Menu("Add an app") {
                        let running = runningAppChoices()
                        if running.isEmpty { Text("No other apps running") }
                        ForEach(running, id: \.id) { app in
                            Button(app.name) {
                                model.pauseList.append(app.id)
                                model.onSettingsChanged()
                            }
                        }
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    .foregroundStyle(accent)
                }
                .padding(.horizontal, 14).padding(.bottom, 14)
                .opacity(model.lidPauseChosen ? 1 : 0.5)
                CardDivider()
                SettingRow(title: "Pause every other app", detail: "Off by default. Never pauses editors, terminals, browsers, AI apps, Apple apps, or meeting, recording and dictation apps.") {
                    SmoothSwitch(isOn: model.lidPauseOthers, title: "Pause every other app", tint: accent) { setting(\.lidPauseOthers).wrappedValue = $0 }
                }
            }
            SettingsCard {
                SettingRow(title: "Keep busy apps at full speed", detail: "While Awayke is on, terminals, editors and AI apps are kept out of App Nap (macOS slowing apps you are not looking at). Their own setting comes back after. Takes effect for apps opened after you switch on.") {
                    SmoothSwitch(isOn: model.appNapOff, title: "Keep busy apps at full speed", tint: accent) { setting(\.appNapOff).wrappedValue = $0 }
                }
                CardDivider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Browsers").font(.system(size: 13, weight: .medium))
                    if model.slowedBrowsers.isEmpty {
                        Text("No open browser is slowing its hidden pages. Chrome, Arc, Edge, Brave and Comet slow pages down when the lid is closed unless they were opened with Awayke's relaunch.")
                            .font(.system(size: 11.5)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("These slow their pages down while the lid is closed. Relaunch one to keep its pages working. It quits and opens again.")
                            .font(.system(size: 11.5)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(model.slowedBrowsers) { b in
                            HStack {
                                Text(b.name).font(.system(size: 12.5))
                                Spacer()
                                Button("Relaunch") { model.onRelaunchBrowser(b.id) }
                            }
                        }
                    }
                    Button("Check again") { model.onRefreshBrowsers() }
                        .buttonStyle(QuietButtonStyle())
                }
                .padding(14)
            }
        }
        .onAppear { model.onRefreshBrowsers() }
    }

    private func appName(_ id: String) -> String {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first, let n = app.localizedName { return n }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return knownAppNames[id] ?? id
    }

    private func runningAppChoices() -> [(id: String, name: String)] {
        var seen = Set(model.pauseList)
        return NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, let id = app.bundleIdentifier,
                  !isNeverPaused(id), seen.insert(id).inserted else { return nil }
            return (id, app.localizedName ?? id)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: Battery
    private var battery: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .center, spacing: 6) {
                        Text("Turn off at low battery").font(.system(size: 13, weight: .medium))
                        if model.batteryCutoff {
                            Text("\(model.floorPercent)%")
                                .font(.system(size: 13, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(accent)
                                .contentTransition(.numericText())
                        }
                        Spacer()
                        SmoothSwitch(isOn: model.batteryCutoff, title: "Turn off at low battery", tint: accent) { setting(\.batteryCutoff).wrappedValue = $0 }
                    }
                    Text(model.batteryCutoff
                         ? "Drag the line. When the battery drops to this level, Awayke switches off so your Mac can sleep instead of running flat."
                         : "Off: Awayke keeps your Mac awake until you switch it off or the timer ends, even on a low battery.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.opacity)
                    if model.batteryCutoff {
                        CutoffBar(cutoff: model.floorPercent, battery: model.batteryPercent,
                                  range: floorRange, glowing: model.isOn) { model.onFloor($0) }
                            .padding(.top, 4)
                            .transition(.opacity)
                    }
                }
                .padding(14)
                .animation(reduceMotion ? nil : .spring(duration: 0.32, bounce: 0.12), value: model.batteryCutoff)
            }
            SettingsCard {
                SettingRow(title: "Low Power Mode on low battery", detail: "On battery, below \(model.lowPowerFloor)%, Low Power Mode turns on. It goes off when you charge or switch Awayke off.") {
                    SmoothSwitch(isOn: model.lowPowerBattery, title: "Low Power Mode on low battery", tint: accent) { setting(\.lowPowerBattery).wrappedValue = $0 }
                }
                if model.lowPowerBattery {
                    HStack {
                        Text("Below").font(.system(size: 12.5))
                        Stepper(value: setting(\.lowPowerFloor), in: 10...90, step: 5) {
                            Text("\(model.lowPowerFloor)%").font(.system(size: 12.5, weight: .semibold)).monospacedDigit()
                        }
                        .fixedSize()
                        Spacer()
                    }
                    .padding(.horizontal, 14).padding(.bottom, 12)
                }
                CardDivider()
                SettingRow(title: "Heat safety", detail: "If your Mac gets very hot, Low Power Mode turns on. If it gets dangerously hot, Awayke switches off so the Mac can sleep and cool down.") {
                    SmoothSwitch(isOn: model.heatRules, title: "Heat safety", tint: accent) { setting(\.heatRules).wrappedValue = $0 }
                }
            }
            if !model.lowPowerAllowed { lowPowerPermission }
            Text("These rules only work while Awayke is running.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
    }

    private var lowPowerPermission: some View {
        SettingsCard {
            HStack(alignment: .center, spacing: 10) {
                Text("Low Power Mode needs your permission once (Touch ID or your password).")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Allow") { model.onAllowLowPower() }
            }
            .padding(14)
        }
    }

    // MARK: Network (iPhone hotspot handoff and tmux nudge, only while Awayke is on)
    @State private var hotspotPassword = ""
    private var network: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Only while Awayke is on. Both are off by default.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            SettingsCard {
                SettingRow(title: "Join my iPhone hotspot", detail: "If the Wi-Fi drops, Awayke joins your hotspot. Set iPhone hotspot joining to Automatic in System Settings > Wi-Fi. macOS asks once for Location access, only to read Wi-Fi names.") {
                    SmoothSwitch(isOn: model.hotspotOn, title: "Join my iPhone hotspot", tint: accent) { setting(\.hotspotOn).wrappedValue = $0 }
                }
                if model.hotspotOn {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Hotspot name", text: Binding(get: { model.hotspotName }, set: { model.hotspotName = $0 }))
                        SecureField(model.hotspotSaved ? "Password saved (type to change)" : "Hotspot password", text: $hotspotPassword)
                        HStack {
                            Text(model.hotspotSaved ? "Saved in your keychain." : "Not saved yet.")
                                .font(.system(size: 11.5)).foregroundStyle(.secondary)
                            Spacer()
                            Button("Save") { model.onSaveHotspot(hotspotPassword); hotspotPassword = "" }
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 14).padding(.bottom, 12)
                }
            }
            SettingsCard {
                SettingRow(title: "Nudge my coding agent", detail: "After the network is out for 90 seconds and comes back, Awayke types \"continue\" into the tmux panes listed below. A pane only counts if you marked it: tmux set-option -p -t <pane> @awayke-nudge on") {
                    SmoothSwitch(isOn: model.nudgeOn, title: "Nudge my coding agent", tint: accent) { setting(\.nudgeOn).wrappedValue = $0 }
                }
                if model.nudgeOn {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Panes, like work:1.0, agent:0.1", text: setting(\.nudgeTargets))
                            .textFieldStyle(.roundedBorder)
                        HStack {
                            Text("Press Enter after \"continue\"").font(.system(size: 12.5))
                            Spacer()
                            SmoothSwitch(isOn: model.nudgeEnter, title: "Press Enter", tint: accent) { setting(\.nudgeEnter).wrappedValue = $0 }
                        }
                    }
                    .padding(.horizontal, 14).padding(.bottom, 12)
                }
            }
        }
    }

    // MARK: Appearance
    private var appearance: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Accent colour").font(.system(size: 13, weight: .medium))
                        Spacer()
                        Text(accentChoice(model.accentIndex).name).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    AccentDots(selected: model.accentIndex, size: 22) { idx in
                        model.accentIndex = idx
                        model.onSettingsChanged()
                    }
                    Text("Used everywhere: the menu bar icon, the panel, switches, the battery bar and this window.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                .padding(14)
            }
            SettingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    SettingRow(title: "Menu bar icon when awake", detail: nil, padded: false) {
                        Picker("", selection: setting(\.monochromeIcon)) {
                            Text("Accent colour").tag(false)
                            Text("Monochrome").tag(true)
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                    }
                    HStack(spacing: 14) {
                        IconPreview(awake: false, label: "Off", tint: nil)
                        IconPreview(awake: true, label: "Awake", tint: model.monochromeIcon ? nil : accent)
                        Spacer()
                    }
                }
                .padding(14)
            }
        }
    }

    // MARK: About
    private var about: some View {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        return SettingsCard {
            HStack(alignment: .top, spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 72, height: 72)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Awayke").font(.system(size: 18, weight: .semibold))
                    Text("Version \(version)").font(.system(size: 12)).foregroundStyle(.secondary)
                    Text("Keeps your Mac running with the lid closed. Normal sleep comes back when you switch it off, quit, restart, or if the app ever crashes.")
                        .font(.system(size: 12.5))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                    Text(info?["NSHumanReadableCopyright"] as? String ?? "")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .padding(.top, 4)
                    HStack(spacing: 8) {
                        Button(model.checkingUpdates ? "Checking\u{2026}" : "Check for updates") { model.onCheckUpdates() }
                            .disabled(model.checkingUpdates)
                        if model.updateAvailable {
                            Button("Open download page") { NSWorkspace.shared.open(UpdateCheck.releasesPage) }
                        }
                        Button("Show activity log") { model.onShowLog() }
                    }
                    .padding(.top, 8)
                    if let status = model.updateStatus {
                        Text(status).font(.system(size: 11.5)).foregroundStyle(.secondary)
                            .contentTransition(.opacity)
                    }
                    Text("Checking asks GitHub once and installs nothing. The log lists what Awayke did, kept on this Mac only.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
        }
    }

    // MARK: Bindings
    private func setting<T>(_ kp: ReferenceWritableKeyPath<PopoverModel, T>) -> Binding<T> {
        Binding(get: { model[keyPath: kp] }, set: { v in
            model[keyPath: kp] = v
            model.onSettingsChanged()
        })
    }

    private func bind(_ kp: KeyPath<PopoverModel, Bool>, _ apply: @escaping (Bool) -> Void) -> Binding<Bool> {
        Binding(get: { model[keyPath: kp] }, set: { v in DispatchQueue.main.async { apply(v) } })
    }
}

// MARK: - Pieces

private struct SidebarItem: View {
    let pane: SettingsPane
    let selected: Bool
    let action: () -> Void
    @Environment(\.sleepAccent) private var accent
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: pane.icon)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)
                    .foregroundStyle(selected ? Color.white : accent)
                Text(pane.rawValue).font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.white : Color.primary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? accent : Color.primary.opacity(hover ? 0.07 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.045))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            }
    }
}

private struct TimerChip: View {
    let label: String
    let remove: () -> Void
    @Environment(\.sleepAccent) private var accent
    var body: some View {
        HStack(spacing: 5) {
            Text(label).font(.system(size: 12, weight: .medium))
            Button(action: remove) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(label)")
        }
        .padding(.horizontal, 10).frame(height: 26)
        .background(Capsule().fill(accent.opacity(0.16)))
        .overlay(Capsule().strokeBorder(accent.opacity(0.4), lineWidth: 1))
    }
}

/// Removable chips that wrap onto new lines.
private struct FlowChips: View {
    let items: [(id: String, name: String)]
    let remove: (String) -> Void
    var body: some View {
        if items.isEmpty {
            Text("No apps chosen").font(.system(size: 12)).foregroundStyle(.secondary)
        } else {
            WrapLayout(spacing: 6) {
                ForEach(items, id: \.id) { item in
                    TimerChip(label: item.name) { remove(item.id) }
                }
            }
        }
    }
}

private struct WrapLayout: Layout {
    var spacing: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > width { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
        return CGSize(width: width, height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
    }
}

private struct CardDivider: View {
    var body: some View { Divider().padding(.leading, 14).opacity(0.7) }
}

private struct SettingRow<Control: View>: View {
    let title: String
    let detail: String?
    var padded = true
    @ViewBuilder let control: Control
    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .medium))
                if let detail {
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.opacity)
                }
            }
            Spacer(minLength: 8)
            control
        }
        .padding(padded ? 14 : 0)
    }
}

private struct IconPreview: View {
    let awake: Bool
    let label: String
    let tint: Color?
    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.08))
                Image(nsImage: EyeGlyph.image(awake: awake, size: NSSize(width: 30, height: 22)))
                    .renderingMode(.template)
                    .foregroundStyle(tint ?? Color.primary)
            }
            .frame(width: 64, height: 40)
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}
