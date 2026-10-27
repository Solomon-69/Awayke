// LidActions.swift. What Awayke does while the lid is closed (only while Awayke is on),
// plus a few small helpers: the activity log, App Nap, browser slowdowns and update checks.
// Ideas adapted from Insomnia by Krish Garg (MIT licence, see THIRD_PARTY.md); the code is Awayke's own.
import AppKit
import CoreAudio
import Darwin
import IOKit

// MARK: - Activity log (~/Library/Logs/Awayke/awayke.log, readable only by you)

enum ActivityLog {
    static let folder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Awayke", isDirectory: true)
    static let file = folder.appendingPathComponent("awayke.log")
    private static let maxBytes = 512 * 1024

    static func write(_ line: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let size = (try? fm.attributesOfItem(atPath: file.path))?[.size] as? Int, size > maxBytes {
            try? fm.removeItem(at: folder.appendingPathComponent("awayke.old.log"))
            try? fm.moveItem(at: file, to: folder.appendingPathComponent("awayke.old.log"))
        }
        if !fm.fileExists(atPath: file.path) {
            fm.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let stamp = ISO8601DateFormatter().string(from: Date())
        guard let h = try? FileHandle(forWritingTo: file) else { return }
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: Data("\(stamp) \(line)\n".utf8))
    }
}

// MARK: - Lid state

enum Lid {
    /// true = closed, false = open, nil = no lid (desktop Mac) or unreadable.
    static func isClosed() -> Bool? {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }
        guard let v = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool else { return nil }
        return v
    }
}

// MARK: - Sound (mute the speakers on lid close, unmute on open)

enum Sound {
    private static func defaultOutput() -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        let r = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return r == noErr && id != 0 ? id : nil
    }

    private static func muteAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                   mScope: kAudioDevicePropertyScopeOutput,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func isMuted(_ dev: AudioDeviceID) -> Bool? {
        var addr = muteAddress()
        guard AudioObjectHasProperty(dev, &addr) else { return nil }
        var v = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &v) == noErr ? v != 0 : nil
    }

    private static func setMuted(_ dev: AudioDeviceID, _ on: Bool) -> Bool {
        var addr = muteAddress()
        var v = UInt32(on ? 1 : 0)
        return AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v) == noErr
    }

    /// Mutes the current output if it is not muted already. Returns the device Awayke muted, if any.
    static func muteOutput() -> AudioDeviceID? {
        guard let dev = defaultOutput(), isMuted(dev) == false, setMuted(dev, true) else { return nil }
        return dev
    }

    /// Unmutes a device Awayke muted earlier (even if you switched to another output since).
    static func unmute(_ dev: AudioDeviceID) {
        if isMuted(dev) == true { _ = setMuted(dev, false) }
    }
}

// MARK: - Pausing apps (SIGSTOP on lid close, SIGCONT on open, after quitting, or at the next start)

enum AppPauser {
    private static let journalKey = "pausedProcesses"

    /// Start time of a process (seconds since 1970), or nil if it is gone.
    static func startTime(_ pid: pid_t) -> UInt64? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbi_start_tvsec
    }

    /// Every process whose program lives inside one of these app bundles (the app and its helpers).
    static func processes(inBundles bundles: [URL]) -> [pid_t] {
        let paths = bundles.map { $0.standardizedFileURL.path + "/" }
        guard !paths.isEmpty else { return [] }
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(n) + 64)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        var out: [pid_t] = []
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        for pid in pids.prefix(Int(max(0, got))) where pid > 1 && pid != getpid() {
            guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { continue }
            let path = String(cString: buf)
            if paths.contains(where: { path.hasPrefix($0) }) { out.append(pid) }
        }
        return out
    }

    static var journal: [PausedProcess] {
        get {
            guard let d = UserDefaults.standard.data(forKey: journalKey) else { return [] }
            return (try? JSONDecoder().decode([PausedProcess].self, from: d)) ?? []
        }
        set {
            if newValue.isEmpty { UserDefaults.standard.removeObject(forKey: journalKey) }
            else { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: journalKey) }
            writeWatchdogList(newValue)
        }
    }

    /// The crash watchdog reads this file to resume paused apps if Awayke dies.
    static let watchdogFile = FileManager.default.temporaryDirectory.appendingPathComponent("awayke-paused-pids")

    private static func writeWatchdogList(_ list: [PausedProcess]) {
        let text = list.map { String($0.pid) }.joined(separator: " ")
        try? text.write(to: watchdogFile, atomically: true, encoding: .utf8)
    }

    /// Pauses the apps with these bundle ids. Each pause is written down BEFORE it happens.
    static func pause(bundleIDs: [String]) -> [String] {
        var named: [String] = []
        for id in bundleIDs {
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: id).filter { !$0.isTerminated }
            let bundles = apps.compactMap(\.bundleURL)
            let pids = Set(processes(inBundles: bundles) + apps.map(\.processIdentifier))
            var list = journal
            for pid in pids {
                guard let started = startTime(pid), !list.contains(where: { $0.pid == pid }) else { continue }
                list.append(PausedProcess(pid: pid, started: started))
                journal = list
                if kill(pid, SIGSTOP) != 0 { list.removeAll { $0.pid == pid }; journal = list }
            }
            if !pids.isEmpty { named.append(apps.first?.localizedName ?? id) }
        }
        return named
    }

    /// Resumes everything Awayke paused that is provably the same process.
    @discardableResult
    static func resumeAll() -> Int {
        var count = 0
        for p in journal where shouldResume(p, currentStart: startTime(p.pid)) {
            if kill(p.pid, SIGCONT) == 0 { count += 1 }
        }
        journal = []
        return count
    }
}

// MARK: - App Nap (keep chosen apps out of App Nap during a session, put the old value back after)

enum AppNap {
    private static let savedKey = "appNapSaved"   // bundle id -> previous value ("" = was not set)
    private static let key = "NSAppSleepDisabled" as CFString

    static func disable(for apps: [String]) {
        var saved = UserDefaults.standard.dictionary(forKey: savedKey) as? [String: String] ?? [:]
        for id in apps where saved[id] == nil {
            let old = CFPreferencesCopyAppValue(key, id as CFString) as? Bool
            saved[id] = old.map { $0 ? "1" : "0" } ?? ""
            UserDefaults.standard.set(saved, forKey: savedKey)   // written down first
            CFPreferencesSetAppValue(key, kCFBooleanTrue, id as CFString)
            CFPreferencesAppSynchronize(id as CFString)
        }
    }

    static func restore() {
        let saved = UserDefaults.standard.dictionary(forKey: savedKey) as? [String: String] ?? [:]
        for (id, old) in saved {
            let value: CFPropertyList? = old.isEmpty ? nil : (old == "1" ? kCFBooleanTrue : kCFBooleanFalse)
            CFPreferencesSetAppValue(key, value, id as CFString)
            CFPreferencesAppSynchronize(id as CFString)
        }
        UserDefaults.standard.removeObject(forKey: savedKey)
    }
}

// MARK: - Browsers that slow down hidden windows (all of them while the lid is closed)

struct SlowedBrowser: Identifiable, Equatable {
    let id: String     // bundle id
    let name: String
}

@MainActor
enum BrowserSpeed {
    static func commandLine(_ pid: pid_t) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-ww", "-o", "args=", "-p", String(pid)]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Running Chromium browsers started without the two "keep working when hidden" flags.
    static func slowed() -> [SlowedBrowser] {
        chromiumBrowsers.compactMap { id in
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first(where: { !$0.isTerminated })
            else { return nil }
            return hasUnthrottleFlags(commandLine: commandLine(app.processIdentifier))
                ? nil : SlowedBrowser(id: id, name: app.localizedName ?? id)
        }
    }

    /// Quits the browser normally, waits for it to close, then opens it again with the flags.
    static func relaunch(_ id: String, done: @escaping @MainActor (Bool) -> Void) {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: id)
        guard let url = apps.first?.bundleURL else { done(false); return }
        apps.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(20)
        func check() {
            let alive = NSRunningApplication.runningApplications(withBundleIdentifier: id).contains { !$0.isTerminated }
            if alive {
                if Date() > deadline { done(false); return }   // it did not quit (maybe asked to save): leave it
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { check() }
                return
            }
            let config = NSWorkspace.OpenConfiguration()
            config.arguments = unthrottleFlags
            config.activates = false
            NSWorkspace.shared.openApplication(at: url, configuration: config) { app, _ in
                DispatchQueue.main.async { done(app != nil) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { check() }
    }
}

// MARK: - Update check (asks GitHub only when you click; installs nothing)

enum UpdateCheck {
    static let releasesPage = URL(string: "https://github.com/Solomon-69/Awayke/releases/latest")!
    private static let api = URL(string: "https://api.github.com/repos/Solomon-69/Awayke/releases/latest")!

    /// Calls back with the latest version tag, or nil and a plain reason.
    static func latest(done: @escaping @MainActor (String?, String?) -> Void) {
        var req = URLRequest(url: api, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { data, resp, err in
            var tag: String?, why: String?
            if let err { why = err.localizedDescription }
            else if (resp as? HTTPURLResponse)?.statusCode != 200 { why = "GitHub did not answer." }
            else if let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                tag = obj["tag_name"] as? String
                if tag == nil { why = "GitHub's answer had no version." }
            }
            DispatchQueue.main.async { done(tag, why) }
        }.resume()
    }
}
