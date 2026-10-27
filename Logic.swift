// Logic.swift. Plain rules with no AppKit, so they can be checked by the small swiftc
// logic tests in tests/ (no window, no sound, nothing touches the Mac's settings).
import Foundation

// MARK: - Timer lengths

/// Longest timer: 30 days (in minutes). Adding time never goes past this either.
let maxTimerMinutes = 30 * 24 * 60
let maxTimerChoices = 5
/// How much "Add time" adds to a running timer.
let addTimeMinutes = 30
/// The early warning before a timer ends.
let reminderLeadSeconds: TimeInterval = 5 * 60

/// Sorted, no repeats, 1 minute to 30 days, at most five.
func cleanTimerChoices(_ list: [Int]) -> [Int] {
    Array(Set(list.filter { (1...maxTimerMinutes).contains($0) })).sorted().prefix(maxTimerChoices).map { $0 }
}

/// "30m", "1h", "1h30", "2d", "1d4h" for the panel; "30 minutes", "1 hour 30 min", "2 days 4 hours" in Settings.
func timerLabel(_ minutes: Int, long: Bool = false) -> String {
    if minutes <= 0 { return "Off" }
    let d = minutes / 1440, h = (minutes % 1440) / 60, m = minutes % 60
    if long {
        var parts: [String] = []
        if d > 0 { parts.append(d == 1 ? "1 day" : "\(d) days") }
        if h > 0 { parts.append(h == 1 ? "1 hour" : "\(h) hours") }
        if m > 0 { parts.append(parts.isEmpty ? "\(m) minutes" : "\(m) min") }
        return parts.joined(separator: " ")
    }
    if d > 0 { return h == 0 && m == 0 ? "\(d)d" : (m == 0 ? "\(d)d\(h)h" : "\(d)d\(h)h\(m)") }
    if h == 0 { return "\(m)m" }
    return m == 0 ? "\(h)h" : "\(h)h\(m)"
}

/// Time left as "4:05", "1:02:03" or "2d 3:04:05".
func formatRemaining(_ seconds: TimeInterval) -> String {
    let r = max(0, Int(seconds.rounded()))
    let d = r / 86400, h = (r % 86400) / 3600, m = (r % 3600) / 60, s = r % 60
    if d > 0 { return String(format: "%dd %d:%02d:%02d", d, h, m, s) }
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}

/// Short time left for the menu bar: "45m", "3h 05m", "2d 4h". Under a minute shows "1m".
func menuBarRemaining(_ seconds: TimeInterval) -> String {
    let mins = max(1, Int((seconds / 60).rounded(.up)))
    let d = mins / 1440, h = (mins % 1440) / 60, m = mins % 60
    if d > 0 { return "\(d)d \(h)h" }
    if h > 0 { return String(format: "%dh %02dm", h, m) }
    return "\(m)m"
}

/// A new end time after adding time, capped so the whole session stays within 30 days of `start`.
/// Returns the new end and the new total length (for the progress ring).
func extendedEnd(end: Date, start: Date, addMinutes: Int, now: Date = Date()) -> (end: Date, total: TimeInterval) {
    let base = max(end, now)
    let cap = start.addingTimeInterval(TimeInterval(maxTimerMinutes * 60))
    let newEnd = min(base.addingTimeInterval(TimeInterval(addMinutes * 60)), cap)
    return (newEnd, newEnd.timeIntervalSince(start))
}

/// When to post the "5 minutes left" warning, or nil when the timer is already that short.
func reminderDate(end: Date, now: Date = Date()) -> Date? {
    let at = end.addingTimeInterval(-reminderLeadSeconds)
    return at > now ? at : nil
}

// MARK: - Pausing apps while the lid is closed

/// Apps paused by default when "Pause chosen apps" is on: chat apps that use battery in the background.
let defaultPauseList: [String] = [
    "com.tinyspeck.slackmacgap",   // Slack
    "net.whatsapp.WhatsApp",       // WhatsApp
    "com.hnc.Discord",             // Discord
]

/// Names to show for the default apps when they are not installed.
let knownAppNames: [String: String] = [
    "com.tinyspeck.slackmacgap": "Slack", "net.whatsapp.WhatsApp": "WhatsApp", "com.hnc.Discord": "Discord",
]

/// Apps "Pause every other app" never touches: editors, AI apps, terminals, browsers, VPNs,
/// password managers, local databases, and meeting, recording and dictation apps.
/// (List adapted from Insomnia by Krish Garg, MIT licence; see THIRD_PARTY.md.)
let neverPause: Set<String> = [
    "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.vscodium", "com.todesktop.230313mzl4w4u92",
    "com.exafunction.windsurf", "dev.zed.Zed", "com.google.antigravity", "com.google.android.studio",
    "com.sublimetext.4", "com.panic.Nova", "com.anthropic.claudefordesktop", "com.openai.codex",
    "com.openai.chat", "com.conductor.app",
    "dev.warp.Warp-Stable", "com.mitchellh.ghostty", "com.googlecode.iterm2", "org.alacritty",
    "net.kovidgoyal.kitty", "com.github.wez.wezterm", "co.zeit.hyper",
    "company.thebrowser.Browser", "com.google.Chrome", "org.chromium.Chromium", "com.microsoft.edgemac",
    "com.brave.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera", "org.mozilla.firefox",
    "app.zen-browser.zen", "ai.perplexity.comet",
    "io.tailscale.ipn.macsys", "ai.elementlabs.lmstudio", "com.electron.ollama", "com.docker.docker",
    "com.electron.dockerdesktop", "com.1password.1password", "com.bitwarden.desktop",
    "com.postgresapp.Postgres2", "dev.kdrag0n.MacVirt",
    "us.zoom.xos", "com.microsoft.teams2", "com.microsoft.teams", "Cisco-Systems.Spark",
    "com.electron.wispr-flow", "com.granola.app", "com.otterai.desktop", "com.obsproject.obs-studio",
    "com.loom.desktop",
]
let neverPausePrefixes = ["com.apple.", "com.jetbrains.", "us.zoom.", "com.cisco.webex.", "com.aboudjem."]

func isNeverPaused(_ bundleID: String) -> Bool {
    neverPause.contains(bundleID) || neverPausePrefixes.contains { bundleID.hasPrefix($0) }
}

/// Which running apps to pause. `running` = (bundle id, is a normal Dock app).
/// Chosen apps are paused unless protected; with `everyOther` on, every other Dock app is too.
func appsToPause(running: [(id: String, regular: Bool)], chosen: [String], everyOther: Bool, chosenOn: Bool) -> [String] {
    var out: [String] = []
    for app in running where !isNeverPaused(app.id) && !out.contains(app.id) {
        if chosenOn && chosen.contains(app.id) { out.append(app.id) }
        else if everyOther && app.regular { out.append(app.id) }
    }
    return out
}

/// A paused process we can safely resume: the same pid AND the same start time
/// (a reused pid belongs to some other program and is left alone).
struct PausedProcess: Codable, Equatable {
    let pid: Int32
    let started: UInt64   // process start time, seconds since 1970
}

func shouldResume(_ saved: PausedProcess, currentStart: UInt64?) -> Bool {
    currentStart == saved.started
}

// MARK: - Browsers that slow down hidden windows

let chromiumBrowsers: [String] = [
    "com.google.Chrome", "org.chromium.Chromium", "company.thebrowser.Browser", "ai.perplexity.comet",
    "com.microsoft.edgemac", "com.brave.Browser",
]
let unthrottleFlags = ["--disable-backgrounding-occluded-windows", "--disable-renderer-backgrounding"]

/// True when the browser was started with both flags (as their own words in its command line).
func hasUnthrottleFlags(commandLine: String) -> Bool {
    let words = Set(commandLine.split(separator: " ").map(String.init))
    return unthrottleFlags.allSatisfy { words.contains($0) }
}

// MARK: - App Nap

/// Apps kept out of App Nap during a session when that setting is on (terminals, editors, AI apps).
let appNapApps: [String] = [
    "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
    "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed", "com.anthropic.claudefordesktop",
    "com.openai.codex", "com.google.Chrome", "company.thebrowser.Browser", "com.docker.docker",
    "io.tailscale.ipn.macsys", "ai.elementlabs.lmstudio", "com.electron.ollama",
]

// MARK: - Updates

/// "v1.5.0" / "1.5" / "1.4.3" compared number by number. True when `latest` is newer than `current`.
func isNewerVersion(_ latest: String, than current: String) -> Bool {
    func parts(_ s: String) -> [Int] {
        s.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")).split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }
    let a = parts(latest), b = parts(current)
    for i in 0..<max(a.count, b.count) {
        let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
        if x != y { return x > y }
    }
    return false
}
