// Intro.swift: the welcome window shown once after installing Awayke. Three short pages:
// what Awayke does, the one-time permission (with Apple's own Touch ID / password sheet behind
// the button), and how to use it. Skippable. Springs throughout; Reduce Motion gets fades.
import AppKit
import Combine
import SwiftUI

enum IntroPref { static let done = "introDone" }

/// Each element of a page rises in a little after the one above it.
private struct Rise: ViewModifier {
    let index: Int
    let shown: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 14)
            .blur(radius: shown || reduceMotion ? 0 : 4)
            .animation(reduceMotion ? .easeOut(duration: 0.2)
                       : .spring(response: 0.55, dampingFraction: 0.84).delay(0.08 + Double(index) * 0.07), value: shown)
    }
}

/// Frosted-glass panel on a plain soft backdrop. Nothing from the screen shows through it.
private struct Glass: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        let dark = scheme == .dark
        content
            .background(RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(dark ? 0.50 : 0.60)))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(LinearGradient(colors: [Color.white.opacity(dark ? 0.20 : 0.85), Color.white.opacity(dark ? 0.04 : 0.15)],
                                             startPoint: .top, endPoint: .bottom), lineWidth: 1))
            .shadow(color: .black.opacity(dark ? 0.45 : 0.16), radius: 22, y: 12)
    }
}

private extension View {
    func glass() -> some View { modifier(Glass()) }
    func rise(_ i: Int, _ shown: Bool) -> some View { modifier(Rise(index: i, shown: shown)) }
    func introCard() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.055)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.07), lineWidth: 1))
    }
}

/// What the welcome window can ask the app.
struct IntroActions {
    let permissionReady: () -> Bool
    let setUpPermission: () -> Void
    let finish: (_ openPanel: Bool) -> Void
}

struct IntroView: View {
    let accent: Color
    let actions: IntroActions
    @State var page = 0
    @State private var shown = false
    @State private var seen: Set<Int> = [0]     // pages whose rise-in already played; it never replays
    @State private var forward = true
    @State private var ready = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    static let pages = 3
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                switch page {
                case 0: welcome.transition(slide)
                case 1: permission.transition(slide)
                default: howTo.transition(slide)
                }
            }
            .padding(.vertical, 10)
            .frame(height: 392, alignment: .top)
            .clipped()
            footer
        }
        .padding(.horizontal, 22).padding(.top, 26).padding(.bottom, 16)
        .glass()
        .padding(16)
        .frame(width: 456)
        .background(backdrop)
        .tint(accent)
        .onAppear { shown = true; ready = actions.permissionReady() }
        .onReceive(tick) { _ in if page == 1 { ready = actions.permissionReady() } }
    }

    private var slide: AnyTransition {
        reduceMotion ? .opacity
            : .asymmetric(insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                          removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity))
    }

    /// Plain soft wash of the app colour. Opaque, so nothing behind the window shows.
    private var backdrop: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            RadialGradient(colors: [accent.opacity(0.28), accent.opacity(0)], center: .topLeading, startRadius: 0, endRadius: 420)
            RadialGradient(colors: [Color.gray.opacity(0.18), Color.gray.opacity(0)], center: .bottomTrailing, startRadius: 0, endRadius: 420)
        }
        .ignoresSafeArea()
    }

    // MARK: Pages

    private var welcome: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 92, height: 92)
                .shadow(color: accent.opacity(0.35), radius: 16, y: 8)
                .scaleEffect(shown || reduceMotion ? 1 : 0.55)
                .animation(reduceMotion ? nil : .spring(response: 0.7, dampingFraction: 0.6).delay(0.05), value: shown)
                .rise(0, shown)
            Text("Welcome to Awayke").font(.system(size: 24, weight: .semibold, design: .rounded)).rise(1, shown)
            Text("Keeps your Mac awake, even with the lid closed.").font(.system(size: 13)).foregroundStyle(.secondary)
                .rise(2, shown)
            VStack(spacing: 8) {
                feature("cup.and.saucer.fill", "Downloads and music keep going", "Close the lid and long jobs still finish.").rise(3, shown)
                feature("laptopcomputer", "Quiet with the lid shut", "Screen off and sound muted until you open it.").rise(4, shown)
                feature("timer", "Or for a set time", "30 minutes, an hour, or until you say so.").rise(5, shown)
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
    }

    private var permission: some View {
        VStack(spacing: 14) {
            tile("lock.open.fill", 64).rise(0, shown)
            Text("One permission, once").font(.system(size: 22, weight: .semibold, design: .rounded)).rise(1, shown)
            Text("Staying awake with the lid closed is a protected macOS setting. Allow it once with Touch ID or your password, and the switch works instantly from then on.")
                .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .rise(2, shown)
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(ready ? accent : Color.primary.opacity(0.08))
                    Image(systemName: ready ? "checkmark" : "lock.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(ready ? Color.white : Color.secondary)
                        .contentTransition(.symbolEffect(.replace))
                }
                .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(ready ? "All set" : "Not set up yet").font(.system(size: 13, weight: .medium))
                    Text(ready ? "Awayke can switch on with one click." : "Or do it later, any time.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                if !ready {
                    Button("Allow…") { actions.setUpPermission(); ready = actions.permissionReady() }
                        .buttonStyle(PillStyle(accent: accent))
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(12)
            .introCard()
            .animation(.spring(response: 0.4, dampingFraction: 0.75), value: ready)
            .rise(3, shown)
            Text("It only allows one thing: turning sleep off and on. Remove it any time with uninstall.sh.")
                .font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .rise(4, shown)
        }
        .frame(maxWidth: .infinity)
    }

    private var howTo: some View {
        VStack(spacing: 14) {
            tile("menubar.arrow.up.rectangle", 64)
                .scaleEffect(shown || reduceMotion ? 1 : 0.5)
                .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.55), value: shown)
                .rise(0, shown)
            Text("It lives in your menu bar").font(.system(size: 22, weight: .semibold, design: .rounded)).rise(1, shown)
            VStack(spacing: 8) {
                feature("cursorarrow.click", "Click the icon", "Switches keeping awake on or off.").rise(2, shown)
                feature("hand.tap.fill", "Hold it, or right-click", "Opens the panel: timer, battery cutoff and more.").rise(3, shown)
                feature("gearshape.fill", "Settings", "Accent colour, open at login and what a click does.").rise(4, shown)
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
    }

    private func tile(_ symbol: String, _ size: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: size * 0.29, style: .continuous)
            .fill(accent.gradient)
            .frame(width: size, height: size)
            .overlay(Image(systemName: symbol).font(.system(size: size * 0.44, weight: .semibold)).foregroundStyle(.white))
            .shadow(color: accent.opacity(0.3), radius: 10, y: 5)
    }

    private func feature(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(spacing: 12) {
            tile(symbol, 30).shadow(radius: 0)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .introCard()
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if page == 0 {
                Button("Skip") { actions.finish(false) }.buttonStyle(QuietStyle()).focusEffectDisabled()
            } else {
                Button("Back") { go(page - 1) }.buttonStyle(QuietStyle()).focusEffectDisabled()
            }
            Spacer()
            HStack(spacing: 6) {
                ForEach(0..<Self.pages, id: \.self) { i in
                    Capsule().fill(i == page ? accent : Color.primary.opacity(0.18))
                        .frame(width: i == page ? 18 : 6, height: 6)
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.75), value: page)
            Spacer()
            Button { page < Self.pages - 1 ? go(page + 1) : actions.finish(true) } label: {
                Text(page < Self.pages - 1 ? "Continue" : "Open Awayke")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 18).frame(height: 34)
                    .background(Capsule().fill(accent))
            }
            .buttonStyle(PressStyle())
            .keyboardShortcut(.defaultAction)
        }
    }

    private func go(_ p: Int) {
        guard (0..<Self.pages).contains(p) else { return }
        forward = p > page
        let first = !seen.contains(p)
        seen.insert(p)
        if first { shown = false }                  // only a page seen for the first time rises in
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.5, dampingFraction: 0.86)) { page = p }
        if first { DispatchQueue.main.async { shown = true } }
    }
}

private struct PressStyle: ButtonStyle {
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .brightness(hover ? 0.05 : 0)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
            .onHover { hover = $0 }
    }
}

private struct PillStyle: ButtonStyle {
    let accent: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(Capsule().fill(accent))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

private struct QuietStyle: ButtonStyle {
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .foregroundStyle(hover ? Color.primary : Color.secondary)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(hover ? 0.08 : 0)))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
            .onHover { hover = $0 }
    }
}
