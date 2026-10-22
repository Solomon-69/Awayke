// SettingsView.swift. The Awayke Settings window (SwiftUI in an NSWindow, Ember palette).
//
// A sidebar of five sections (General, Awake, Battery, Appearance, About). Every control
// writes through PopoverModel -> AppDelegate, which saves it to UserDefaults and applies it
// at once (click behaviour, hold length, screen-awake assertion, timers, safety nets, icon).
import SwiftUI
import AppKit

enum SettingsPane: String, CaseIterable, Identifiable {
    case general = "General", awake = "Awake", battery = "Battery", appearance = "Appearance", about = "About"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .general: "gearshape"
        case .awake: "eye"
        case .battery: "battery.50percent"
        case .appearance: "paintpalette"
        case .about: "info.circle"
        }
    }
}

struct SettingsView: View {
    let model: PopoverModel
    let floorRange: ClosedRange<Int>
    @State private var pane: SettingsPane = .general
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
        .frame(width: 660, height: 470)
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
        case .battery: battery
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
                    Text("Off is always there. Add up to \(maxTimerChoices) of your own, from 5 minutes to 24 hours.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        ForEach(model.timerChoices, id: \.self) { m in
                            TimerChip(label: timerLabel(m, long: true)) {
                                model.timerChoices.removeAll { $0 == m }
                                model.onSettingsChanged()
                            }
                        }
                        if model.timerChoices.isEmpty {
                            Text("Only Off for now").font(.system(size: 12)).foregroundStyle(.tertiary)
                        }
                    }
                    // Pick a length with a chip or the drum, then add it as a panel button.
                    ChipDrumPicker(title: "New timer", value: newTimer, mode: .duration(5...maxTimerMinutes),
                                   presets: [15, 30, 60, 120], tint: accent, chipColumns: 4,
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
        }
    }

    // MARK: Battery
    private var battery: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("Turn off at low battery").font(.system(size: 13, weight: .medium))
                        Text("\(model.floorPercent)%")
                            .font(.system(size: 13, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(accent)
                            .contentTransition(.numericText())
                        Spacer()
                    }
                    Text("Drag the line. When the battery drops to this level, Awayke switches off so your Mac can sleep.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    CutoffBar(cutoff: model.floorPercent, battery: model.batteryPercent,
                              range: floorRange, glowing: model.isOn) { model.onFloor($0) }
                        .padding(.top, 4)
                }
                .padding(14)
            }
            SettingsCard {
                SettingRow(title: "Turn off in Low Power Mode", detail: "On battery, switch off when Low Power Mode is on (unless you just turned it on yourself).") {
                    SmoothSwitch(isOn: model.lowPowerOff, title: "Turn off in Low Power Mode", tint: accent) { setting(\.lowPowerOff).wrappedValue = $0 }
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
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                        .padding(.top, 4)
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
