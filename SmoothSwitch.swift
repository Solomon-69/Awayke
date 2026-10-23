import SwiftUI

/// A glitch-free on/off switch. It flips the moment you tap it (it never waits for the app
/// to catch up, so it can't jump back and forth), slides one knob with one smooth spring, and has
/// no keyboard focus ring. Use it instead of `Toggle(...).toggleStyle(.switch)`.
///
/// The knob is a single view moved with an offset (never re-laid out), and the whole switch is
/// flattened into one layer, so it can't leave ghost copies of the knob behind while it moves.
struct SmoothSwitch: View {
    let isOn: Bool
    var title: String = ""
    var tint: Color = .accentColor
    var width: CGFloat = 38
    let onChange: (Bool) -> Void

    @State private var shown: Bool?
    @State private var pendingReset: DispatchWorkItem?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var on: Bool { shown ?? isOn }
    private var spring: Animation? { reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.82) }

    var body: some View {
        let height = width * 0.58
        let knob = height - 4
        ZStack(alignment: .leading) {
            // Off: a soft filled track with a thin outline, so the full shape reads on light and dark.
            Capsule().fill(Color.primary.opacity(0.10))
            Capsule().fill(tint).opacity(on ? 1 : 0)
            Capsule().strokeBorder(Color.primary.opacity(on ? 0 : 0.22), lineWidth: 1)
            Circle()
                .fill(.white)
                .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
                .frame(width: knob, height: knob)
                .offset(x: on ? width - knob - 2 : 2)
        }
        .frame(width: width, height: height)
        .compositingGroup()
        .animation(spring, value: on)
        .contentShape(Capsule())
        .onTapGesture {
            let want = !on
            shown = want
            onChange(want)
            // If the change didn't take (refused, failed, cancelled), slide back to the real value.
            pendingReset?.cancel()
            let reset = DispatchWorkItem { shown = nil }
            pendingReset = reset
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: reset)
        }
        // Once the real value catches up, hand control back to it (no second animation).
        .onChange(of: isOn) { _, value in
            if shown == value { pendingReset?.cancel(); shown = nil }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(on ? "On" : "Off")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onChange(!on) }
    }
}

extension View {
    /// Hides the blue keyboard-focus ring (macOS 14+; older systems keep the default).
    @ViewBuilder func noFocusRing() -> some View {
        if #available(macOS 14.0, *) { focusEffectDisabled() } else { self }
    }
}
