// PowerExtras.swift. More things Awayke can do while it is on, ported from Insomnia
// (Krish Garg, MIT licence, see THIRD_PARTY.md); the code is Awayke's own.
//
//   KeyboardLight  built-in keyboard backlight off at lid close, back on at lid open
//   Appearance     dark mode on at lid close, back to light at lid open (if it was light)
//   LowPower       Low Power Mode, shared by the lid, battery and heat rules
//   Docker         pause Docker Desktop while the lid is closed and no container runs
//   Hotspot        join your iPhone hotspot when the Wi-Fi drops
//   TmuxNudge      type "continue" into marked tmux panes after a long outage
import AppKit
import CoreWLAN
import CoreLocation
import Network
import Security

// MARK: - Keyboard light (private CoreBrightness KeyboardBrightnessClient, checked before use)

@objc private protocol KeyboardBrightnessBridge: NSObjectProtocol {
    @objc(copyKeyboardBacklightIDs) func copyKeyboardBacklightIDs() -> NSArray?
    @objc(isKeyboardBuiltIn:) func isKeyboardBuiltIn(_ id: UInt64) -> Bool
    @objc(brightnessForKeyboard:) func brightness(forKeyboard id: UInt64) -> Float
    @objc(setBrightness:forKeyboard:) func setBrightness(_ value: Float, forKeyboard id: UInt64) -> Bool
}

@MainActor
enum KeyboardLight {
    /// Method type encodings measured on macOS 26. A changed signature means "leave it alone".
    private static let measured = ["copyKeyboardBacklightIDs": "@@:", "isKeyboardBuiltIn:": "B@:Q",
                                   "brightnessForKeyboard:": "f@:Q", "setBrightness:forKeyboard:": "B@:fQ"]
    private static var client: KeyboardBrightnessBridge? = {
        guard dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY) != nil,
              let cls = NSClassFromString("KeyboardBrightnessClient") else { return nil }
        for (name, enc) in measured {
            guard let m = class_getInstanceMethod(cls, NSSelectorFromString(name)),
                  let e = method_getTypeEncoding(m),
                  String(cString: e).filter({ !$0.isNumber }) == enc else {   // ignore frame offsets
                ActivityLog.write("Keyboard light left alone: \(name) changed in this macOS.")
                return nil
            }
        }
        guard let type = cls as? NSObject.Type else { return nil }
        return unsafeBitCast(type.init(), to: KeyboardBrightnessBridge.self)
    }()

    private static func builtIn() -> [UInt64] {
        guard let c = client else { return [] }
        let ids = (c.copyKeyboardBacklightIDs() as? [NSNumber])?.map(\.uint64Value) ?? []
        return ids.filter { c.isKeyboardBuiltIn($0) }
    }

    /// Current level of the built-in keyboard light (nil = no light or not readable).
    static func level() -> Float? {
        guard let c = client, let id = builtIn().first else { return nil }
        return c.brightness(forKeyboard: id)
    }

    private static let savedKey = "keyboardLightSaved"   // survives a crash, restored on next start

    /// Turns the light off and remembers the old level. Returns false if there is no keyboard light.
    static func turnOff() -> Bool {
        guard let c = client, let id = builtIn().first else { return false }
        let level = c.brightness(forKeyboard: id)
        if UserDefaults.standard.object(forKey: savedKey) == nil {
            UserDefaults.standard.set(Double(level), forKey: savedKey)
        }
        for k in builtIn() { _ = c.setBrightness(0, forKeyboard: k) }
        return true
    }

    static func restore() {
        guard let saved = UserDefaults.standard.object(forKey: savedKey) as? Double else { return }
        UserDefaults.standard.removeObject(forKey: savedKey)
        guard let c = client else { return }
        for k in builtIn() { _ = c.setBrightness(Float(saved), forKeyboard: k) }
    }
}

// MARK: - Dark mode (System Events; macOS asks once to let Awayke control it)

@MainActor
enum Appearance {
    private static let savedKey = "darkModeChangedByAwayke"

    static func isDark() -> Bool {
        CFPreferencesAppSynchronize("Apple Global Domain" as CFString)
        let v = CFPreferencesCopyAppValue("AppleInterfaceStyle" as CFString, "Apple Global Domain" as CFString) as? String
        return v == "Dark"
    }

    private static func set(dark: Bool) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "tell application \"System Events\" to tell appearance preferences to set dark mode to \(dark)"]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        do { try p.run(); p.waitUntilExit() } catch { return false }
        return p.terminationStatus == 0
    }

    /// Dark mode on. Only remembered (and later undone) if it was light before.
    static func goDark() -> Bool {
        guard !isDark() else { return true }
        guard set(dark: true) else { return false }
        UserDefaults.standard.set(true, forKey: savedKey)
        return true
    }

    static func restore() {
        guard UserDefaults.standard.bool(forKey: savedKey) else { return }
        UserDefaults.standard.removeObject(forKey: savedKey)
        _ = set(dark: false)
    }
}

// MARK: - Low Power Mode (pmset, through the one-time permission)

/// Why Low Power Mode is wanted. Awayke turns it off again only when no reason is left
/// and only if Awayke was the one that turned it on.
enum LowPowerReason: String { case lid = "lid closed", battery = "low battery", heat = "Mac is hot" }

@MainActor
enum LowPower {
    private static let ownedKey = "lowPowerTurnedOnByAwayke"
    private(set) static var reasons: Set<LowPowerReason> = []

    static func isOn() -> Bool {
        let out = run("/usr/bin/pmset", ["-g"])
        for line in out.split(separator: "\n") {
            let t = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if t.first == "lowpowermode" || t.first == "powermode" { return t.last == "1" }
        }
        return false
    }

    /// The one-time permission covers Low Power Mode without a password (lists the rules,
    /// never prompts). `sudo -l <cmd>` alone is not enough: it also succeeds for commands
    /// that would still ask for a password.
    static func allowed() -> Bool {
        let out = run("/usr/bin/sudo", ["-n", "-l"])
        return out.split(separator: "\n").contains { $0.contains("NOPASSWD") && $0.contains("lowpowermode 1") }
    }

    private static func set(_ on: Bool) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = ["-n", "/usr/bin/pmset", "-a", "lowpowermode", on ? "1" : "0"]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        do { try p.run(); p.waitUntilExit() } catch { return false }
        return p.terminationStatus == 0
    }

    /// Adds a reason. Returns false if Low Power Mode could not be switched on.
    @discardableResult
    static func want(_ r: LowPowerReason) -> Bool {
        let first = reasons.isEmpty
        reasons.insert(r)
        guard first else { return true }
        if isOn() { return true }   // already on: not ours, never turned off by Awayke
        guard set(true) else { reasons.remove(r); return false }
        UserDefaults.standard.set(true, forKey: ownedKey)
        ActivityLog.write("Low Power Mode on (\(r.rawValue)).")
        return true
    }

    static func drop(_ r: LowPowerReason) {
        guard reasons.remove(r) != nil, reasons.isEmpty else { return }
        restore()
    }

    /// Everything off: on switch-off, quit and next start after a crash.
    static func restore() {
        reasons.removeAll()
        guard UserDefaults.standard.bool(forKey: ownedKey) else { return }
        UserDefaults.standard.removeObject(forKey: ownedKey)
        if set(false) { ActivityLog.write("Low Power Mode back off.") }
    }

    private static func run(_ path: String, _ args: [String]) -> String {
        let p = Process(); let pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: path); p.arguments = args
        p.standardOutput = pipe; p.standardError = Pipe()
        do { try p.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Docker Desktop: pause it while the lid is closed if no container is running

enum Docker {
    static let bundleID = "com.docker.docker"
    private static let cli = ["/usr/local/bin/docker", "/opt/homebrew/bin/docker",
                              "/Applications/Docker.app/Contents/Resources/bin/docker"]

    static func isRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// true = Docker runs and no container is up. Unknown answers count as "busy" (never paused).
    static func isIdle() -> Bool {
        guard isRunning(), let path = cli.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return false }
        let p = Process(); let pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: path); p.arguments = ["ps", "-q"]
        p.standardOutput = pipe; p.standardError = Pipe()
        do { try p.run() } catch { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 && String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - Network watch: hotspot handoff and tmux nudge

@MainActor
final class NetworkWatch {
    static let outageSeconds: TimeInterval = 90
    private let monitor = NWPathMonitor()
    private var downSince: Date?
    private var hotspotTimer: Timer?
    private var tried = false
    var hotspotName: () -> String = { "" }
    var nudgeTargets: () -> [String] = { [] }
    var nudgeEnter: () -> Bool = { false }
    var hotspotOn: () -> Bool = { false }
    var nudgeOn: () -> Bool = { false }

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            let up = path.status == .satisfied
            Task { @MainActor in self?.changed(up: up) }
        }
        monitor.start(queue: .global(qos: .utility))
    }

    func stop() {
        monitor.cancel()
        hotspotTimer?.invalidate(); hotspotTimer = nil
    }

    private func changed(up: Bool) {
        if up {
            hotspotTimer?.invalidate(); hotspotTimer = nil
            if let since = downSince, Date().timeIntervalSince(since) >= Self.outageSeconds, nudgeOn() {
                let n = TmuxNudge.send(to: nudgeTargets(), enter: nudgeEnter())
                ActivityLog.write("Network back after \(Int(Date().timeIntervalSince(since))) s: nudged \(n) tmux pane(s).")
            }
            downSince = nil; tried = false
            return
        }
        guard downSince == nil else { return }
        downSince = Date()
        ActivityLog.write("Network lost.")
        guard hotspotOn(), !hotspotName().isEmpty else { return }
        let t = Timer(timeInterval: 15, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.joinHotspot() }
        }
        RunLoop.main.add(t, forMode: .common)
        hotspotTimer = t
    }

    private func joinHotspot() {
        guard downSince != nil, !tried else { return }
        tried = true
        let name = hotspotName()
        let ok = Hotspot.join(name)
        ActivityLog.write(ok ? "Joined hotspot \(name)." : "Could not join hotspot \(name).")
    }
}

enum Hotspot {
    private static let service = "awayke-hotspot"

    /// Asks macOS once for Location Services, which it needs before revealing network names.
    @MainActor static let location = CLLocationManager()
    @MainActor static func askLocationIfNeeded() {
        if location.authorizationStatus == .notDetermined { location.requestWhenInUseAuthorization() }
    }

    static func savePassword(_ pw: String, for ssid: String) -> Bool {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service, kSecAttrAccount as String: ssid]
        SecItemDelete(base as CFDictionary)
        guard !pw.isEmpty else { return true }
        var add = base
        add[kSecValueData as String] = Data(pw.utf8)
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func password(for ssid: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: ssid, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func hasPassword(for ssid: String) -> Bool { !ssid.isEmpty && password(for: ssid) != nil }

    /// Finds the hotspot and joins it. The password never appears in a process argument.
    static func join(_ ssid: String) -> Bool {
        guard let iface = CWWiFiClient.shared().interface(), let pw = password(for: ssid),
              let nets = try? iface.scanForNetworks(withName: ssid), let net = nets.first else { return false }
        do { try iface.associate(to: net, password: pw); return true } catch { return false }
    }
}

enum TmuxNudge {
    private static let paths = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]

    private static func tmux(_ args: [String]) -> (ok: Bool, out: String) {
        guard let path = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return (false, "") }
        let p = Process(); let pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: path); p.arguments = args
        p.standardOutput = pipe; p.standardError = Pipe()
        do { try p.run() } catch { return (false, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus == 0, String(decoding: data, as: UTF8.self))
    }

    /// Types "continue" into each listed pane the user marked with
    /// `tmux set-option -p -t <pane> @awayke-nudge on`. Returns how many panes got it.
    static func send(to targets: [String], enter: Bool) -> Int {
        var sent = 0
        for t in targets where !t.isEmpty {
            let mark = tmux(["show-options", "-p", "-v", "-t", t, "@awayke-nudge"])
            guard mark.ok, mark.out.trimmingCharacters(in: .whitespacesAndNewlines) == "on" else { continue }
            var args = ["send-keys", "-t", t, "-l", "continue"]
            guard tmux(args).ok else { continue }
            if enter { args = ["send-keys", "-t", t, "Enter"]; _ = tmux(args) }
            sent += 1
        }
        return sent
    }
}
