import AppKit
import SwiftUI

// ChipDrumPicker.swift. One reusable picker for a time of day or a length of time.
//
// Self-contained (SwiftUI + AppKit only), shared as-is by Nox and Awayke: keep the copies identical.
// Preset chips for the common values, plus a scroll-wheel "drum" (hours and minutes) for exact ones.
// The drum snaps to each row, fades and curves away at the top and bottom like iOS, follows the
// mouse wheel, trackpad and dragging, and gives a light trackpad tick on every step.
// Values are minutes: after midnight for `.clock`, a length for `.duration`.

enum ChipDrumMode: Equatable {
    case clock                          // 00:00 to 23:55, hours and minutes wrap around
    case duration(ClosedRange<Int>)     // e.g. 5...1440 minutes, hours stop at the ends
}

struct ChipDrumPicker: View {
    let title: String
    let value: Int
    var mode: ChipDrumMode = .clock
    let presets: [Int]
    var tint: Color = .accentColor
    var chipColumns = 2
    /// Text on a chip. Defaults to "07:30" for clocks and "1h 30m" for durations.
    var label: ((Int) -> String)? = nil
    let onChange: (Int) -> Void

    static let minuteStep = 5

    private var hourCount: Int {
        switch mode {
        case .clock: return 24
        case .duration(let r): return r.upperBound / 60 + 1
        }
    }
    private var wrapsHours: Bool { mode == .clock }
    private var hour: Int { value / 60 }
    private var minuteIndex: Int { ((value % 60) + Self.minuteStep / 2) / Self.minuteStep % (60 / Self.minuteStep) }

    private func text(_ v: Int) -> String {
        if let label { return label(v) }
        switch mode {
        case .clock: return String(format: "%02d:%02d", v / 60, v % 60)
        case .duration:
            let h = v / 60, m = v % 60
            if h == 0 { return "\(m)m" }
            return m == 0 ? "\(h)h" : "\(h)h \(m)m"
        }
    }

    private func clamp(_ v: Int) -> Int {
        switch mode {
        case .clock: return ((v % 1440) + 1440) % 1440
        case .duration(let r): return min(max(v, r.lowerBound), r.upperBound)
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
                    Text(text(value))
                        .font(.system(size: 13, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(tint)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: chipColumns),
                          alignment: .leading, spacing: 6) {
                    ForEach(presets, id: \.self) { p in
                        PresetChip(label: text(p), selected: p == value, tint: tint) {
                            guard p != value else { return }
                            DrumTick.play()
                            onChange(clamp(p))
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            drum
        }
    }

    private var drum: some View {
        HStack(spacing: 0) {
            DrumWheel(count: hourCount, selection: hour, wraps: wrapsHours,
                      text: { mode == .clock ? String(format: "%02d", $0) : "\($0)" },
                      accessibilityName: "\(title) hours") { h in
                onChange(clamp(h * 60 + minuteIndex * Self.minuteStep))
            }
            Text(mode == .clock ? ":" : "h")
                .font(.system(size: mode == .clock ? 17 : 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: mode == .clock ? 8 : 12)
            DrumWheel(count: 60 / Self.minuteStep, selection: minuteIndex, wraps: true,
                      text: { String(format: "%02d", $0 * Self.minuteStep) },
                      accessibilityName: "\(title) minutes") { i in
                onChange(clamp(hour * 60 + i * Self.minuteStep))
            }
            if mode != .clock {
                Text("m").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).frame(width: 12)
            }
        }
        .padding(.horizontal, 6)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.04))
                // The selection band behind the middle row.
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(tint.opacity(0.14))
                    .frame(height: DrumWheel.rowHeight)
                    .padding(.horizontal, 4)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        .fixedSize()
    }
}

private struct PresetChip: View {
    let label: String
    let selected: Bool
    let tint: Color
    let action: () -> Void
    @State private var hover = false

    private var fill: Color { selected ? tint : Color.primary.opacity(hover ? 0.10 : 0.06) }
    private var ink: Color { selected ? Color.white : Color.primary.opacity(0.85) }
    private var edge: Color { selected ? Color.clear : Color.primary.opacity(0.10) }
    private var traits: AccessibilityTraits { selected ? [.isButton, .isSelected] : .isButton }

    var body: some View {
        let chip = Text(label)
            .font(.system(size: 12, weight: selected ? .semibold : .medium))
            .monospacedDigit()
            .foregroundStyle(ink)
            .frame(maxWidth: .infinity)
            .frame(height: 26)
            .background(Capsule().fill(fill))
            .overlay(Capsule().strokeBorder(edge, lineWidth: 1))
        return chip
            .contentShape(Capsule())
            .onTapGesture(perform: action)
            .onHover { hover = $0 }
            .animation(.spring(response: 0.28, dampingFraction: 0.82), value: selected)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityAddTraits(traits)
            .accessibilityAction { action() }
    }
}

/// A light trackpad tick (only on Macs with a Force Touch trackpad; silent elsewhere).
enum DrumTick {
    static func play() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
}

/// One wheel of the drum. `pos` is the row under the middle line, as a fraction while it moves.
struct DrumWheel: View {
    static let rowHeight: CGFloat = 23
    static let visibleRows = 5
    let count: Int
    let selection: Int
    let wraps: Bool
    let text: (Int) -> String
    var accessibilityName = ""
    let onSelect: (Int) -> Void

    @State private var pos: Double?
    @State private var lastTicked: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var current: Double { pos ?? Double(selection) }
    private var snap: Animation? { reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.86) }

    private func index(of p: Double) -> Int {
        let r = Int(p.rounded())
        return wraps ? ((r % count) + count) % count : min(max(r, 0), count - 1)
    }

    private func limited(_ p: Double) -> Double {
        guard !wraps else { return p }
        // Past either end the wheel resists, like a rubber band.
        let lo = 0.0, hi = Double(count - 1)
        if p < lo { return lo - min(0.6, (lo - p) * 0.35) }
        if p > hi { return hi + min(0.6, (p - hi) * 0.35) }
        return p
    }

    private func moved(to p: Double) {
        let p = limited(p)
        pos = p
        let i = index(of: p)
        if i != lastTicked { lastTicked = i; DrumTick.play() }
    }

    private func settle(projected: Double? = nil) {
        var target = (projected ?? current).rounded()
        if !wraps { target = min(max(target, 0), Double(count - 1)) }
        withAnimation(snap) { pos = target }
        let i = index(of: target)
        if i != lastTicked { lastTicked = i; DrumTick.play() }
        if i != selection { onSelect(i) }
    }

    var body: some View {
        DrumRows(pos: current, count: count, wraps: wraps, text: text)
            .frame(width: 34, height: Self.rowHeight * CGFloat(Self.visibleRows))
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.3),
                                         .init(color: .black, location: 0.7), .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
            .overlay(DrumInput(
                rowHeight: Self.rowHeight,
                onBegin: { lastTicked = index(of: current) },
                onScroll: { rows in moved(to: current - rows) },
                onStep: { step in
                    let target = current.rounded() + Double(step)
                    let clamped = wraps ? target : min(max(target, 0), Double(count - 1))
                    withAnimation(snap) { pos = clamped }
                    let i = index(of: clamped)
                    if i != lastTicked { lastTicked = i; DrumTick.play() }
                },
                onEnd: { velocityRows in settle(projected: current - velocityRows * 0.12) },
                onClick: { rowsFromCenter in
                    guard rowsFromCenter != 0 else { return }
                    settle(projected: current.rounded() + Double(rowsFromCenter))
                }))
            .onChange(of: selection) { newValue in
                // Changed from outside (a chip, or a clamp): roll to it the short way round.
                guard index(of: current) != newValue else { return }
                var delta = Double(newValue) - Double(index(of: current))
                if wraps {
                    let n = Double(count)
                    if delta > n / 2 { delta -= n } else if delta < -n / 2 { delta += n }
                }
                lastTicked = newValue
                withAnimation(snap) { pos = current.rounded() + delta }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityName)
            .accessibilityValue(text(selection))
            .accessibilityAdjustableAction { dir in
                let step = dir == .increment ? 1 : -1
                let next = wraps ? (((selection + step) % count) + count) % count : min(max(selection + step, 0), count - 1)
                if next != selection { onSelect(next) }
            }
    }
}

/// The rows themselves. Animatable, so a snap moves every row smoothly frame by frame.
private struct DrumRows: View, Animatable {
    var pos: Double
    let count: Int
    let wraps: Bool
    let text: (Int) -> String

    var animatableData: Double {
        get { pos }
        set { pos = newValue }
    }

    var body: some View {
        let base = Int(pos.rounded(.down))
        let h = DrumWheel.rowHeight
        let radius = h * 2.6
        ZStack {
            ForEach(-3...4, id: \.self) { k in
                let raw = base + k
                let valid = wraps || (0..<count).contains(raw)
                let d = Double(raw) - pos                    // rows away from the middle
                let angle = max(-1.45, min(1.45, d * Double(h / radius)))
                let near = max(0, 1 - abs(d) * 0.6)
                if valid {
                    Text(text(((raw % count) + count) % count))
                        .font(.system(size: 15, weight: abs(d) < 0.5 ? .semibold : .regular))
                        .monospacedDigit()
                        .foregroundStyle(Color.primary.opacity(0.35 + 0.65 * near))
                        .frame(height: h)
                        .scaleEffect(y: CGFloat(cos(angle)))
                        .rotation3DEffect(.radians(-angle), axis: (x: 1, y: 0, z: 0), perspective: 0.4)
                        .offset(y: CGFloat(sin(angle)) * radius)
                        .opacity(cos(angle) > 0.15 ? 1 : 0)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }
}

/// Catches the mouse wheel, trackpad and drags over a wheel (SwiftUI on macOS 13 has no wheel events).
private struct DrumInput: NSViewRepresentable {
    let rowHeight: CGFloat
    let onBegin: () -> Void
    let onScroll: (Double) -> Void       // rows moved (positive = content moves down)
    let onStep: (Int) -> Void            // one mouse-wheel notch
    let onEnd: (Double) -> Void          // finished; velocity in rows per second
    let onClick: (Int) -> Void           // click on a row above (-) or below (+) the middle

    func makeNSView(context: Context) -> DrumInputView { DrumInputView() }

    func updateNSView(_ view: DrumInputView, context: Context) {
        view.rowHeight = rowHeight
        view.onBegin = onBegin
        view.onScroll = onScroll
        view.onStep = onStep
        view.onEnd = onEnd
        view.onClick = onClick
    }
}

final class DrumInputView: NSView {
    var rowHeight: CGFloat = 26
    var onBegin: () -> Void = {}
    var onScroll: (Double) -> Void = { _ in }
    var onStep: (Int) -> Void = { _ in }
    var onEnd: (Double) -> Void = { _ in }
    var onClick: (Int) -> Void = { _ in }

    private var settleTimer: Timer?
    private var scrolling = false
    private var dragStart: CGFloat?
    private var lastY: CGFloat = 0
    private var samples: [(t: TimeInterval, y: CGFloat)] = []

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { false }

    override func scrollWheel(with event: NSEvent) {
        if !event.hasPreciseScrollingDeltas {
            // A classic mouse wheel: one notch, one row.
            let dy = event.scrollingDeltaY
            guard dy != 0 else { return }
            if !scrolling { scrolling = true; onBegin() }
            onStep(dy > 0 ? -1 : 1)
            scheduleSettle(after: 0.25)
            return
        }
        if event.phase == .began || (!scrolling && event.momentumPhase == []) {
            if !scrolling { scrolling = true; onBegin() }
        }
        let rows = Double(event.scrollingDeltaY / rowHeight)
        if rows != 0 { onScroll(rows) }
        // Settle shortly after the last movement (covers the fling that follows a swipe).
        let ended = event.momentumPhase == .ended || (event.phase == .ended && event.momentumPhase == [])
        scheduleSettle(after: ended ? 0.06 : 0.14)
    }

    /// Settles (and saves) shortly after the last wheel or trackpad movement.
    private func scheduleSettle(after delay: TimeInterval) {
        settleTimer?.invalidate()
        let t = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.scrolling = false
            self.onEnd(0)
        }
        RunLoop.main.add(t, forMode: .common)
        settleTimer = t
    }

    override func mouseDown(with event: NSEvent) {
        let y = convert(event.locationInWindow, from: nil).y
        dragStart = y
        lastY = y
        samples = [(event.timestamp, y)]
        settleTimer?.invalidate()
        onBegin()
    }

    override func mouseDragged(with event: NSEvent) {
        let y = convert(event.locationInWindow, from: nil).y
        onScroll(Double((y - lastY) / rowHeight))
        lastY = y
        samples.append((event.timestamp, y))
        if samples.count > 6 { samples.removeFirst(samples.count - 6) }
    }

    override func mouseUp(with event: NSEvent) {
        let y = convert(event.locationInWindow, from: nil).y
        defer { dragStart = nil }
        if let start = dragStart, abs(y - start) < 3 {
            // A click: jump to the row that was clicked.
            let rows = Int(((y - bounds.midY) / rowHeight).rounded())
            onClick(rows)
            return
        }
        var velocity = 0.0
        if let first = samples.first, let last = samples.last, last.t - first.t > 0.005,
           event.timestamp - last.t < 0.08 {
            velocity = Double((last.y - first.y) / rowHeight) / (last.t - first.t)
        }
        onEnd(max(-25, min(25, velocity)))
    }
}
