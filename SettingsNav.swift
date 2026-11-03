// SettingsNav.swift. Keyboard walk through the Settings window: Up/Down moves a soft highlight
// from row to row (wrapping), Left/Right or Space/Return changes the highlighted setting, Esc closes.
import SwiftUI
import AppKit

/// Pure ordering logic, kept free of UI so a headless test can check it.
enum NavOrder {
    /// The next id when moving `step` (+1 / -1) through `ids`, wrapping at both ends.
    /// With nothing highlighted yet, Down picks the first row and Up picks the last.
    static func move<ID: Equatable>(_ ids: [ID], from current: ID?, step: Int) -> ID? {
        guard !ids.isEmpty else { return nil }
        guard let current, let i = ids.firstIndex(of: current) else { return step >= 0 ? ids.first : ids.last }
        return ids[((i + step) % ids.count + ids.count) % ids.count]
    }
    /// Steps through a list of options (Left/Right = -1/+1, Space/Return = 0 = next), wrapping.
    static func step<T: Equatable>(_ options: [T], current: T, by d: Int) -> T? {
        guard !options.isEmpty else { return nil }
        let i = options.firstIndex(of: current) ?? 0
        let s = d == 0 ? 1 : d
        return options[((i + s) % options.count + options.count) % options.count]
    }
}

struct NavItem: Equatable {
    var frame: CGRect
    var adjust: (Int) -> Void
    static func == (a: NavItem, b: NavItem) -> Bool { a.frame == b.frame }   // closures read live state
}

struct NavItemsKey: PreferenceKey {
    static var defaultValue: [UUID: NavItem] = [:]
    static func reduce(value: inout [UUID: NavItem], nextValue: () -> [UUID: NavItem]) {
        value.merge(nextValue()) { $1 }
    }
}

@MainActor
final class SettingsNav: ObservableObject {
    @Published var current: UUID?
    @Published var items: [UUID: NavItem] = [:]

    var ordered: [UUID] { items.sorted { $0.value.frame.minY < $1.value.frame.minY }.map(\.key) }
    func move(_ step: Int) { current = NavOrder.move(ordered, from: current, step: step) }
    func adjust(_ d: Int) {
        guard let c = current, let item = items[c] else { return }
        item.adjust(d)
    }
}

/// Marks a view as one stop in the keyboard walk. `adjust` gets -1, +1 or 0 (activate).
private struct NavRowModifier: ViewModifier {
    @State private var id = UUID()
    let adjust: (Int) -> Void
    func body(content: Content) -> some View {
        content
            .background {
                GeometryReader { g in
                    Color.clear.preference(key: NavItemsKey.self,
                                           value: [id: NavItem(frame: g.frame(in: .named("settingsContent")), adjust: adjust)])
                }
            }
            .id(id)
    }
}

extension View {
    func navRow(_ adjust: @escaping (Int) -> Void) -> some View { modifier(NavRowModifier(adjust: adjust)) }
}

/// The soft pill that glides between rows. Same look in light and dark: a tint of the accent.
struct NavPill: View {
    @ObservedObject var nav: SettingsNav
    let accent: Color
    let reduceMotion: Bool
    var body: some View {
        let f = nav.current.flatMap { nav.items[$0]?.frame }
        RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(accent.opacity(0.13))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(accent.opacity(0.38), lineWidth: 1))
            .frame(width: max((f?.width ?? 0) - 8, 0), height: max((f?.height ?? 0) - 6, 0))
            .offset(x: (f?.minX ?? 0) + 4, y: (f?.minY ?? 0) + 3)
            .opacity(f == nil ? 0 : 1)
            .animation(reduceMotion ? nil : .spring(duration: 0.34, bounce: 0.16), value: f)
            .animation(.easeOut(duration: 0.15), value: f == nil)
            .allowsHitTesting(false)
    }
}
