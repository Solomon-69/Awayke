// ShareFriend.swift. "Share with a friend": zips a fresh copy of this app's own bundle
// (the bundle never holds user data, so the friend gets a clean new copy) and opens the
// macOS share picker with AirDrop first. Nothing is sent until the user picks someone.
import AppKit
import SwiftUI

enum ShareFriend {
    static let hint = "Friend: right-click the app and choose Open the first time."
    static let title = "Share with a friend"

    private static var appName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? ((Bundle.main.bundlePath as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    /// Zips the running app into a fresh temp folder. Calls back on the main thread.
    static func makeZip(_ done: @escaping (Result<URL, Error>) -> Void) {
        let src = Bundle.main.bundlePath
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(appName)-share", isDirectory: true)
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            try? fm.removeItem(at: base)   // drop any older copy
            let out = base.appendingPathComponent("\(appName).zip")
            let result: Result<URL, Error>
            do {
                try fm.createDirectory(at: base, withIntermediateDirectories: true)
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                p.arguments = ["-c", "-k", "--keepParent", src, out.path]
                let err = Pipe(); p.standardError = err; p.standardOutput = Pipe()
                try p.run(); p.waitUntilExit()
                guard p.terminationStatus == 0, fm.fileExists(atPath: out.path) else {
                    throw NSError(domain: "ShareFriend", code: Int(p.terminationStatus))
                }
                result = .success(out)
            } catch { result = .failure(error) }
            DispatchQueue.main.async { done(result) }
        }
    }

    /// Zips, then opens the share picker anchored to `view`. `onError` gets a short plain message.
    static func share(from view: NSView?, rect: NSRect? = nil, onError: @escaping (String) -> Void) {
        makeZip { result in
            switch result {
            case .failure:
                onError("Couldn't prepare the copy. Please try again.")
            case .success(let url):
                guard let view, view.window != nil else { onError("Couldn't open sharing."); return }
                let picker = NSSharingServicePicker(items: [url])
                picker.delegate = AirDropFirst.shared
                picker.show(relativeTo: rect ?? view.bounds, of: view, preferredEdge: .minY)
            }
        }
    }

    /// Puts AirDrop at the top of the picker.
    private final class AirDropFirst: NSObject, NSSharingServicePickerDelegate {
        static let shared = AirDropFirst()
        func sharingServicePicker(_ picker: NSSharingServicePicker, sharingServicesForItems items: [Any],
                                  proposedSharingServices proposed: [NSSharingService]) -> [NSSharingService] {
            guard let air = NSSharingService(named: .sendViaAirDrop) else { return proposed }
            return [air] + proposed.filter { $0.title != air.title }
        }
    }

    /// Test hook: zips and writes the result to a text file; never opens the picker.
    static func selfTest(report path: String) {
        makeZip { result in
            var text: String
            switch result {
            case .success(let u):
                let size = (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int) ?? 0
                text = "OK \(u.path) \(size) bytes"
            case .failure(let e): text = "FAIL \(e)"
            }
            try? text.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}

/// Gives SwiftUI a handle on a real NSView so the picker can anchor to a row.
final class ShareAnchorBox { weak var view: NSView? }
struct ShareAnchor: NSViewRepresentable {
    let box: ShareAnchorBox
    func makeNSView(context: Context) -> NSView { let v = NSView(); box.view = v; return v }
    func updateNSView(_ v: NSView, context: Context) { box.view = v }
}

/// Popover dismissal helpers: clicks inside the menu bar strip (other menu bar icons) never close the panel,
/// and Esc closes it while it is the key window.
enum MenuBarStrip {
    static func contains(_ p: NSPoint = NSEvent.mouseLocation) -> Bool {
        guard let s = NSScreen.screens.first(where: { $0.frame.contains(p) }) else { return false }
        let h = max(24, s.frame.maxY - s.visibleFrame.maxY)
        return p.y >= s.frame.maxY - h
    }
    private static var esc: Any?
    static func startEsc(window: @escaping () -> NSWindow?, close: @escaping () -> Void) {
        stopEsc()
        esc = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53, let w = window(), e.window === w { close(); return nil }
            return e
        }
    }
    static func stopEsc() { if let m = esc { NSEvent.removeMonitor(m); esc = nil } }
}

/// One panel at a time across Solomon's menu bar apps (Nox, Memo, Awayke, Ludus). An app says
/// "my panel is opening" (com.solomon.menubar.panelWillOpen, userInfo ["sender": bundle id]) and the
/// others close theirs. Any other click outside the panel (desktop, other apps, any menu bar item)
/// closes it too, except a click on Nox's quick dark-mode switch, which never closes a panel.
enum PanelGroup {
    static let willOpen = Notification.Name("com.solomon.menubar.panelWillOpen")
    private static let noxID = "com.solomon.DarkSwitch"
    private static var me: String { Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName }
    private static var token: NSObjectProtocol?

    /// Call once at launch. `close` closes this app's panel.
    static func listen(close: @escaping () -> Void) {
        guard token == nil else { return }
        token = DistributedNotificationCenter.default().addObserver(forName: willOpen, object: nil, queue: .main) { n in
            let sender = (n.userInfo?["sender"] as? String) ?? (n.object as? String) ?? ""
            if sender != me { close() }
        }
    }

    /// Call right before this app shows its panel.
    static func announceOpen() {
        DistributedNotificationCenter.default().postNotificationName(
            willOpen, object: me, userInfo: ["sender": me], deliverImmediately: true)
    }

    /// Where Nox's quick dark-mode switch sits (screen points, bottom-left origin, like NSEvent.mouseLocation).
    /// Nox writes it; every app reads it so a click on that switch never closes an open panel.
    static let noxFrameFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/com.solomon.menubar/nox-toggle-frame.json")
    static let noxFrameChanged = Notification.Name("com.solomon.nox.toggleFrame")

    /// Nox only: publish the switch's screen rectangle (call at launch and whenever it moves).
    static func publishNoxFrame(_ r: NSRect) {
        let json = "{\"x\":\(r.minX),\"y\":\(r.minY),\"w\":\(r.width),\"h\":\(r.height)}"
        try? FileManager.default.createDirectory(at: noxFrameFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? json.write(to: noxFrameFile, atomically: true, encoding: .utf8)
        DistributedNotificationCenter.default().postNotificationName(noxFrameChanged, object: nil,
            userInfo: ["x": Double(r.minX), "y": Double(r.minY), "w": Double(r.width), "h": Double(r.height)], deliverImmediately: true)
    }

    /// True when the point is on Nox's quick switch (only while Nox is running).
    static func isOnNoxSwitch(_ p: NSPoint = NSEvent.mouseLocation) -> Bool {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: noxID).isEmpty,
              let data = try? Data(contentsOf: noxFrameFile),
              let d = try? JSONSerialization.jsonObject(with: data) as? [String: Double],
              let x = d["x"], let y = d["y"], let w = d["w"], let h = d["h"] else { return false }
        return NSRect(x: x, y: y, width: w, height: h).insetBy(dx: -1, dy: -1).contains(p)
    }
}
