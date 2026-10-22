// PopoverView.swift. Awayke "Ember" popover (SwiftUI, hosted in the NSPopover).
//
// Pure presentation: every action calls back into AppDelegate, which keeps ALL the
// keep-awake logic (sudo pmset, safety nets, timer, login item) exactly as before.
// The view only reads PopoverModel, so the switch always mirrors the TRUE system state.
import SwiftUI
import AppKit
import Observation

// MARK: - Accent colours (user-selectable, saved in UserDefaults; Ember orange is the default)
struct AccentChoice {
    let name: String
    let ns: NSColor
    var color: Color { Color(nsColor: ns) }
}

// Ember is the brand orange (#FF9F0A on dark, #E07B00 on light), resolved per appearance.
private let emberNS = NSColor(name: "Ember") { app in
    app.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(srgbRed: 1.0, green: 0.624, blue: 0.039, alpha: 1)
        : NSColor(srgbRed: 0.878, green: 0.482, blue: 0.0, alpha: 1)
}

let accentChoices: [AccentChoice] = [
    AccentChoice(name: "Ember", ns: emberNS),
    AccentChoice(name: "Rose", ns: .systemPink),
    AccentChoice(name: "Violet", ns: .systemPurple),
    AccentChoice(name: "Ocean", ns: .systemBlue),
    AccentChoice(name: "Lagoon", ns: .systemTeal),
    AccentChoice(name: "Moss", ns: .systemGreen),
]

func accentChoice(_ index: Int) -> AccentChoice {
    accentChoices.indices.contains(index) ? accentChoices[index] : accentChoices[0]
}

private struct SleepAccentKey: EnvironmentKey { static let defaultValue = Color(nsColor: .systemOrange) }
extension EnvironmentValues {
    var sleepAccent: Color {
        get { self[SleepAccentKey.self] }
        set { self[SleepAccentKey.self] = newValue }
    }
}

// MARK: - Settings (UserDefaults keys + choices). Every one of these changes real behaviour.
enum Pref {
    static let accent = "accentColorIndex"
    static let clickOpensPanel = "clickOpensPanel"       // false = single click toggles awake (default)
    static let longPress = "longPressIndex"              // 0 short, 1 normal, 2 long
    static let keepDisplayAwake = "keepDisplayAwake"     // true = screen stays on too
    static let defaultTimer = "defaultAutoOffMinutes"    // 0 / 60 / 120
    static let lowPowerOff = "lowPowerAutoOff"           // turn off in Low Power Mode (on battery)
    static let monochromeIcon = "monochromeMenuIcon"     // true = awake icon stays white/black
    static let timerChoices = "autoOffChoices"           // minutes shown as timer buttons (besides Off)
    static let showTimerRow = "panelShowTimer"
    static let showBatteryRow = "panelShowBattery"
    static let showLoginRow = "panelShowLogin"
    static let showInDock = "showInDock"                  // false = menu bar only (default)
}

let maxTimerMinutes = 24 * 60
let maxTimerChoices = 5

/// Sorted, no repeats, 1 minute to 24 hours, at most five.
func cleanTimerChoices(_ list: [Int]) -> [Int] {
    Array(Set(list.filter { (1...maxTimerMinutes).contains($0) })).sorted().prefix(maxTimerChoices).map { $0 }
}

/// "30m", "1h", "1h30" for the panel; "30 minutes", "1 hour 30 min" in Settings.
func timerLabel(_ minutes: Int, long: Bool = false) -> String {
    if minutes == 0 { return "Off" }
    let h = minutes / 60, m = minutes % 60
    if long {
        let hs = h == 0 ? "" : (h == 1 ? "1 hour" : "\(h) hours")
        if m == 0 { return hs }
        return h == 0 ? "\(m) minutes" : "\(hs) \(m) min"
    }
    if h == 0 { return "\(m)m" }
    return m == 0 ? "\(h)h" : "\(h)h\(m)"
}

let longPressChoices: [(label: String, seconds: TimeInterval)] = [("Short", 0.25), ("Normal", 0.4), ("Long", 0.7)]

@MainActor
@Observable
final class PopoverModel {
    var isOn = false
    var armed = false                 // awake on battery while discharging (safety net live)
    var batteryPercent: Int? = nil    // nil = no internal battery (desktop Mac)
    var charging = false
    var floorPercent = 15
    var autoOffMinutes = 0            // 0 / 60 / 120
    var timerEnd: Date? = nil
    var timerTotal: TimeInterval = 0
    var launchAtLogin = false
    var awakeSince: Date? = nil       // when keep-awake was last switched on (for "Awake for ...")
    var openCount = 0                 // bumped on every popover open, drives the entrance spring

    // Settings (mirrored to UserDefaults by AppDelegate through onSetting).
    var accentIndex = 0
    var clickOpensPanel = false
    var longPressIndex = 1
    var keepDisplayAwake = true
    var defaultTimer = 0
    var timerChoices = [60, 120]
    var showTimerRow = true
    var showBatteryRow = true
    var showLoginRow = true
    var lowPowerOff = true
    var monochromeIcon = false
    var showInDock = false

    var accent: Color { accentChoice(accentIndex).color }

    // Actions wired by AppDelegate.
    var onToggle: (Bool) -> Void = { _ in }
    var onAutoOff: (Int) -> Void = { _ in }
    var onFloor: (Int) -> Void = { _ in }
    var onLogin: (Bool) -> Void = { _ in }
    var onSettingsChanged: () -> Void = {}
    var onOpenSettings: () -> Void = {}
    var onQuit: () -> Void = {}
}

struct PopoverView: View {
    let model: PopoverModel
    let floorRange: ClosedRange<Int>
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var segNS
    @State private var appeared = true

    private var spring: Animation? { reduceMotion ? nil : .spring(duration: 0.38, bounce: 0.22) }
    private var accent: Color { model.accent }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            statusTile
            settingsGroup
            if model.showLoginRow { loginCard }
            settingsRow
            footer
        }
        .padding(14)
        .frame(width: 320, alignment: .top)
        .environment(\.sleepAccent, accent)
        .focusEffectDisabled()   // no blue keyboard-focus rings on the controls
        .animation(spring, value: model.isOn)
        .animation(spring, value: model.accentIndex)
        // Entrance: a soft spring settle each time the popover opens.
        .scaleEffect(appeared || reduceMotion ? 1 : 0.965, anchor: .top)
        .opacity(appeared ? 1 : 0)
        .onChange(of: model.openCount) { _, _ in
            guard !reduceMotion else { return }
            appeared = false
            DispatchQueue.main.async {
                withAnimation(.spring(duration: 0.42, bounce: 0.18)) { appeared = true }
            }
        }
    }

    // MARK: Status tile: state + time awake
    private var statusTile: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(model.isOn ? accent.opacity(0.20) : Color.primary.opacity(0.07))
                ZStack {
                    FlickeringCandle(size: NSSize(width: 28, height: 20), color: accent, active: model.isOn)
                        .opacity(model.isOn ? 1 : 0)
                        .scaleEffect(model.isOn ? 1 : 0.8)
                    Image(nsImage: EyeGlyph.image(awake: false, size: NSSize(width: 28, height: 20)))
                        .renderingMode(.template)
                        .foregroundStyle(.secondary)
                        .opacity(model.isOn ? 0 : 1)
                        .scaleEffect(model.isOn ? 0.8 : 1)
                }
            }
            .frame(width: 44, height: 44)
            .shadow(color: accent.opacity(model.isOn ? 0.55 : 0), radius: 14)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.isOn ? "Awake" : "Sleeps normally")
                    .font(.system(size: 17, weight: .semibold))
                    .contentTransition(.opacity)
                TimelineView(.periodic(from: .now, by: 30)) { ctx in
                    Text(statusLine(now: ctx.date))
                        .font(.system(size: 11.5))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .contentTransition(.opacity)
                }
            }
            Spacer(minLength: 0)
        }
        .tileStyle(active: model.isOn)
    }

    private func statusLine(now: Date) -> String {
        guard model.isOn else { return "Sleeps when you close the lid" }
        if model.armed { return "On battery, safety net on" }
        guard let since = model.awakeSince else { return "Stays on with the lid closed" }
        let mins = max(0, Int(now.timeIntervalSince(since) / 60))
        if mins < 1 { return "Awake for under a minute" }
        let h = mins / 60, m = mins % 60
        return h > 0 ? "Awake for \(h)h \(m)m" : "Awake for \(m) min"
    }

    // MARK: Grouped settings (one rounded group, hairline-separated rows)
    private var settingsGroup: some View {
        VStack(spacing: 0) {
            mainRow
            if model.showTimerRow {
                Divider().padding(.leading, 12).opacity(0.6)
                timerRow
            }
            if model.showBatteryRow {
                Divider().padding(.leading, 12).opacity(0.6)
                floorRow
            }
        }
        .tileStyle(active: false, padded: false)
    }

    private var mainRow: some View {
        HStack {
            Text("Keep awake with lid closed").font(.system(size: 13))
            Spacer()
            SmoothSwitch(isOn: model.isOn, title: "Keep awake with lid closed", tint: accent) { want in
                // Defer out of the view update: the toggle may show the one-time setup sheet.
                DispatchQueue.main.async { model.onToggle(want) }
            }
        }
        .rowPadding()
    }

    private var timerRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Auto-off timer").font(.system(size: 13))
                Spacer()
                timerSegments
            }
            if model.isOn, let end = model.timerEnd {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let remaining = max(0, end.timeIntervalSince(ctx.date))
                    let fraction = model.timerTotal > 0 ? remaining / model.timerTotal : 0
                    HStack(spacing: 7) {
                        ProgressRing(fraction: fraction)
                            .frame(width: 13, height: 13)
                        Text("Auto-off in \(formatRemaining(remaining))")
                            .font(.system(size: 11.5))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText(countsDown: true))
                            .animation(reduceMotion ? nil : .spring(duration: 0.3), value: Int(remaining))
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .rowPadding()
        .animation(spring, value: model.timerEnd)
    }

    private var timerSegments: some View {
        HStack(spacing: 0) {
            ForEach([0] + model.timerChoices, id: \.self) { minutes in
                let label = timerLabel(minutes)
                let selected = model.autoOffMinutes == minutes
                Button {
                    withAnimation(spring) { model.onAutoOff(minutes) }
                } label: {
                    Text(label)
                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Color.primary : Color.secondary)
                        .frame(minWidth: 30).padding(.horizontal, 4).frame(height: 22)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color(nsColor: .controlColor))
                                    .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
                                    .matchedGeometryEffect(id: "seg", in: segNS)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.08)))
    }

    // MARK: Battery: cutoff + current level in ONE bar (0-100% scale)
    private var floorRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Turn off at low battery").font(.system(size: 13))
                Text("\(model.floorPercent)%")
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(accent)
                    .contentTransition(.numericText())
                    .animation(spring, value: model.floorPercent)
                Spacer()
            }
            CutoffBar(cutoff: model.floorPercent, battery: model.batteryPercent,
                      range: floorRange, glowing: model.isOn) { model.onFloor($0) }
        }
        .rowPadding()
    }

    // MARK: "Modules" style bottom: Launch at login card, Settings row, quiet Quit
    private var loginCard: some View {
        HStack {
            Text("Launch at login").font(.system(size: 13))
            Spacer()
            SmoothSwitch(isOn: model.launchAtLogin, title: "Launch at login", tint: accent) { want in
                DispatchQueue.main.async { model.onLogin(want) }
            }
        }
        .rowPadding()
        .tileStyle(active: false, padded: false)
    }

    private var settingsRow: some View {
        Button { model.onOpenSettings() } label: {
            HStack(spacing: 8) {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("Settings\u{2026}").font(.system(size: 13))
                Spacer()
                Text("\u{2318},").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            .rowPadding()
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
        .keyboardShortcut(",", modifiers: .command)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Quit") { model.onQuit() }
                .buttonStyle(QuietButtonStyle())
                .keyboardShortcut("q", modifiers: .command)
        }
    }
}

// MARK: - Pieces

private struct ProgressRing: View {
    let fraction: Double
    @Environment(\.sleepAccent) private var accent
    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.15), lineWidth: 2)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, fraction)))
                .stroke(accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 1), value: fraction)
        }
    }
}

struct AccentDots: View {
    let selected: Int
    var size: CGFloat = 11
    let onPick: (Int) -> Void
    var body: some View {
        HStack(spacing: size * 0.7) {
            ForEach(accentChoices.indices, id: \.self) { i in
                let isSel = i == selected
                Button { onPick(i) } label: {
                    Circle()
                        .fill(accentChoices[i].color)
                        .frame(width: size, height: size)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
                        .padding(size * 0.23)
                        .overlay(Circle().strokeBorder(isSel ? accentChoices[i].color : .clear, lineWidth: max(1.5, size * 0.1)))
                        .scaleEffect(isSel ? 1 : 0.86)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(accentChoices[i].name)
                .accessibilityLabel("\(accentChoices[i].name) accent")
                .accessibilityAddTraits(isSel ? .isSelected : [])
            }
        }
    }
}

private struct QuietButtonStyle: ButtonStyle {
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .foregroundStyle(hover ? Color.primary : Color.secondary)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(hover ? 0.08 : 0)))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
            .onHover { hover = $0 }
    }
}

struct RowButtonStyle: ButtonStyle {
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.primary)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.11 : (hover ? 0.08 : 0.055)))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
            .onHover { hover = $0 }
    }
}

struct TileStyle: ViewModifier {
    let active: Bool
    let padded: Bool
    @Environment(\.sleepAccent) private var accent
    func body(content: Content) -> some View {
        content
            .padding(padded ? 12 : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(active ? accent.opacity(0.13) : Color.primary.opacity(0.055))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(active ? accent.opacity(0.42) : Color.primary.opacity(0.07), lineWidth: 1)
            }
    }
}

extension View {
    func tileStyle(active: Bool, padded: Bool = true) -> some View { modifier(TileStyle(active: active, padded: padded)) }
    func rowPadding() -> some View { padding(.horizontal, 12).padding(.vertical, 10) }
}

// One capsule on a 0-100% battery scale. The accent fill runs up to the auto-off cutoff;
// a thin handle line sits exactly where accent meets grey and is dragged to change it
// (clamped to the cutoff range). The current battery level is a small tick on the same bar.
// On release the handle overshoots slightly and settles with a spring (off under Reduce Motion).
struct CutoffBar: View {
    let cutoff: Int
    let battery: Int?
    let range: ClosedRange<Int>
    let glowing: Bool
    let onChange: (Int) -> Void
    @Environment(\.sleepAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragX: CGFloat? = nil
    @State private var dragging = false
    @State private var lastDX: CGFloat = 0

    private let barH: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let x = dragX ?? w * CGFloat(cutoff) / 100
            ZStack(alignment: .topLeading) {
                Capsule().fill(Color.primary.opacity(0.10)).frame(height: barH)
                Capsule()
                    .fill(LinearGradient(colors: [accent.opacity(0.7), accent], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(barH, x + barH / 2), height: barH)
                    .shadow(color: accent.opacity(glowing || dragging ? 0.55 : 0.22), radius: dragging ? 9 : 6)
                    .mask(alignment: .leading) { Rectangle().frame(width: max(0, x)) }
                if let b = battery {
                    let bx = w * CGFloat(min(max(b, 0), 100)) / 100
                    Capsule()
                        .fill(Color.primary.opacity(0.55))
                        .frame(width: 2, height: barH - 6)
                        .offset(x: bx - 1, y: 3)
                    Text("\(b)% now")
                        .font(.system(size: 10, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .position(x: min(max(bx, 24), w - 24), y: barH + 10)
                }
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(Color.primary)
                    .frame(width: 3, height: barH + 8)
                    .shadow(color: .black.opacity(0.3), radius: 1.5, y: 0.5)
                    .scaleEffect(x: 1, y: dragging && !reduceMotion ? 1.18 : 1)
                    .offset(x: x - 1.5, y: -4)
            }
            .frame(width: w, height: barH + 18, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    if !dragging { withAnimation(.spring(duration: 0.2)) { dragging = true } }
                    let lo = w * CGFloat(range.lowerBound) / 100, hi = w * CGFloat(range.upperBound) / 100
                    let nx = min(max(g.location.x, lo), hi)
                    lastDX = nx - (dragX ?? nx)
                    dragX = nx
                    onChange(Int((nx / w * 100).rounded()))
                }
                .onEnded { _ in settle() })
        }
        .frame(height: barH + 18)
        .accessibilityElement()
        .accessibilityLabel("Turn off at low battery")
        .accessibilityValue("\(cutoff) percent" + (battery.map { ", battery now \($0) percent" } ?? ""))
        .accessibilityAdjustableAction { dir in
            switch dir {
            case .increment: onChange(min(range.upperBound, cutoff + 1))
            case .decrement: onChange(max(range.lowerBound, cutoff - 1))
            @unknown default: break
            }
        }
    }

    // Overshoot a few points in the direction of travel, then spring onto the snapped value.
    private func settle() {
        guard !reduceMotion, let x = dragX else {
            withAnimation(.easeOut(duration: 0.18)) { dragX = nil; dragging = false }
            return
        }
        let push: CGFloat = lastDX >= 0 ? 4 : -4
        withAnimation(.spring(duration: 0.12)) { dragX = x + push }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            withAnimation(.spring(duration: 0.5, bounce: 0.3)) {
                dragX = nil
                dragging = false
            }
        }
    }
}

func formatRemaining(_ seconds: TimeInterval) -> String {
    let r = Int(seconds.rounded())
    let h = r / 3600, m = (r % 3600) / 60, s = r % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}


/// The lit candle. The candle keeps one steady colour and brightness; only the flame sways,
/// redrawn smoothly in place (no fading between poses).
struct FlickeringCandle: View {
    let size: NSSize
    let color: Color
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !active || reduceMotion)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            // Two slow waves of different speeds = a natural, never-repeating sway.
            let sway = active && !reduceMotion ? CGFloat(sin(t * 2.1) * 0.6 + sin(t * 3.7 + 1.3) * 0.35) : 0
            Image(nsImage: EyeGlyph.image(awake: true, size: size, flicker: sway))
                .renderingMode(.template)
                .foregroundStyle(color)
        }
    }
}
