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
