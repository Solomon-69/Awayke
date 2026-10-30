// Updater.swift. The "Update now" button: downloads the newest release from GitHub, checks it,
// replaces this app and opens the new one. Shared by Awayke and Ludus (same file, own settings).
//
// What it does, in order (any failure stops here and leaves the installed app untouched):
//   1. Asks GitHub for the latest release and picks the Mac zip and its SHA256SUMS file.
//   2. Downloads the zip, and checks its SHA-256 against the release's SHA256SUMS.
//   3. Unzips it, and checks the app inside: same bundle id, the version it promised, valid signature.
//   4. Starts a tiny helper that waits for this app to quit, swaps the new app in (keeping the old one
//      until the new one is in place, and putting it back if anything fails) and opens the new app.
import AppKit
import CryptoKit

enum SelfUpdate {
    struct Config {
        let owner: String
        let repo: String
        let appName: String          // "Awayke": the .app is named <appName>.app
        let zipName: String          // "Awayke-mac.zip"
        var apiBase = "https://api.github.com"   // tests point this at a local server
        var releasesPage: URL { URL(string: "https://github.com/\(owner)/\(repo)/releases/latest")! }
    }

    struct Offer {
        let tag: String
        let version: String
        let zip: URL
        let sums: URL?
    }

    struct Failure: Error { let message: String }

    // MARK: 1. Ask GitHub

    static func fetchLatest(_ c: Config, done: @escaping @MainActor @Sendable (Result<Offer, Failure>) -> Void) {
        func main(_ r: Result<Offer, Failure>) { DispatchQueue.main.async { MainActor.assumeIsolated { done(r) } } }
        guard let url = URL(string: "\(c.apiBase)/repos/\(c.owner)/\(c.repo)/releases/latest") else {
            return main(.failure(Failure(message: "Bad update address.")))
        }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err { return main(.failure(Failure(message: err.localizedDescription))) }
            guard (resp as? HTTPURLResponse)?.statusCode == 200, let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = obj["tag_name"] as? String else {
                return main(.failure(Failure(message: "GitHub did not answer.")))
            }
            let assets = (obj["assets"] as? [[String: Any]]) ?? []
            func link(_ name: String) -> URL? {
                assets.first { ($0["name"] as? String) == name }.flatMap { ($0["browser_download_url"] as? String).flatMap(URL.init) }
            }
            // The Mac zip: the stable name first, then any other zip that is not the Windows one.
            let zip = link(c.zipName) ?? assets.compactMap { a -> URL? in
                guard let n = a["name"] as? String, n.hasSuffix(".zip"), !n.lowercased().contains("windows") else { return nil }
                return (a["browser_download_url"] as? String).flatMap(URL.init)
            }.first
            let sums = assets.compactMap { a -> URL? in
                guard let n = a["name"] as? String, n.uppercased().contains("SHA256SUMS") else { return nil }
                return (a["browser_download_url"] as? String).flatMap(URL.init)
            }.first
            guard let zip else { return main(.failure(Failure(message: "This release has no Mac download yet."))) }
            main(.success(Offer(tag: tag, version: tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV")), zip: zip, sums: sums)))
        }.resume()
    }

    // MARK: 2-4. Download, check, hand over

    /// Runs on a background queue. `progress` (0...1) and `done` are called on the main queue.
    /// On success the helper is already waiting: the caller must now quit the app (after saving its own state).
    static func install(_ offer: Offer, _ c: Config, bundle: URL = Bundle.main.bundleURL,
                        bundleID: String = Bundle.main.bundleIdentifier ?? "",
                        progress: @escaping @MainActor @Sendable (Double) -> Void,
                        done: @escaping @MainActor @Sendable (Result<Void, Failure>) -> Void) {
        let appName = c.appName
        let currentPid = ProcessInfo.processInfo.processIdentifier
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            var workDir: URL?   // thrown away again if anything goes wrong
            func finish(_ r: Result<Void, Failure>) { DispatchQueue.main.async { MainActor.assumeIsolated { done(r) } } }
            func report(_ f: Double) { DispatchQueue.main.async { MainActor.assumeIsolated { progress(f) } } }
            func fail(_ m: String) {
                if let workDir { try? fm.removeItem(at: workDir) }
                finish(.failure(Failure(message: m)))
            }
            // Where the app lives must be replaceable (not a read-only disk image, not a locked folder).
            let parent = bundle.deletingLastPathComponent()
            guard bundle.pathExtension == "app", fm.isWritableFile(atPath: parent.path) else {
                return fail("This copy of \(appName) can't replace itself here. Use the download page instead.")
            }
            let work = fm.temporaryDirectory.appendingPathComponent("\(appName)-update-\(UUID().uuidString.prefix(8))")
            do { try fm.createDirectory(at: work, withIntermediateDirectories: true) }
            catch { return fail("Could not make a temporary folder.") }
            workDir = work

            // Download the zip (with progress).
            let zipFile = work.appendingPathComponent(offer.zip.lastPathComponent)
            let sem = DispatchSemaphore(value: 0)
            var dlError: String?
            let task = URLSession.shared.downloadTask(with: offer.zip) { tmp, resp, err in
                defer { sem.signal() }
                if let err { dlError = err.localizedDescription; return }
                guard (resp as? HTTPURLResponse)?.statusCode == 200, let tmp else { dlError = "The download did not finish."; return }
                do { try fm.moveItem(at: tmp, to: zipFile) } catch { dlError = "Could not save the download." }
            }
            let obs = task.progress.observe(\.fractionCompleted) { p, _ in
                let f = p.fractionCompleted * 0.85
                report(f)
            }
            task.resume(); sem.wait(); obs.invalidate()
            if let dlError { return fail(dlError) }
            report(0.88)

            // Check the fingerprint against the release's SHA256SUMS.
            guard let sumsURL = offer.sums, let sumsData = try? Data(contentsOf: sumsURL),
                  let sumsText = String(data: sumsData, encoding: .utf8) else {
                return fail("The release has no checksum file, so the download was not trusted.")
            }
            let assetName = offer.zip.lastPathComponent
            let wanted = sumsText.split(separator: "\n").compactMap { line -> String? in
                let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                guard parts.count >= 2, String(parts[1]).trimmingCharacters(in: CharacterSet(charactersIn: "*")) == assetName else { return nil }
                return String(parts[0])
            }.first
            guard let wanted else { return fail("The checksum file does not list the download.") }
            guard let got = sha256(of: zipFile), got.lowercased() == wanted.lowercased() else {
                return fail("The download did not match its checksum, so it was thrown away.")
            }
            report(0.92)

            // Unzip and check the app inside.
            let out = work.appendingPathComponent("new")
            guard run("/usr/bin/ditto", ["-x", "-k", zipFile.path, out.path]).status == 0 else { return fail("Could not open the download.") }
            guard let newApp = findApp(named: appName, in: out) else { return fail("The download had no \(appName) inside.") }
            _ = run("/usr/bin/xattr", ["-cr", newApp.path])
            guard let info = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist")) else {
                return fail("The new \(appName) looks damaged.")
            }
            guard (info["CFBundleIdentifier"] as? String) == bundleID else { return fail("The download is not \(appName).") }
            guard (info["CFBundleShortVersionString"] as? String) == offer.version else { return fail("The download's version does not match the release.") }
            guard run("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path]).status == 0 else {
                return fail("The new \(appName) failed its signature check, so it was not installed.")
            }
            report(0.96)

            // Hand over to the helper that swaps the app after we quit.
            let script = work.appendingPathComponent("swap.sh")
            let sh = """
            #!/bin/sh
            PID="$1"; NEW="$2"; DEST="$3"; WORK="$4"
            i=0
            while kill -0 "$PID" 2>/dev/null && [ "$i" -lt 150 ]; do sleep 0.2; i=$((i+1)); done
            OLD="$DEST.old-$$"
            if mv "$DEST" "$OLD"; then
              if /usr/bin/ditto "$NEW" "$DEST" && /usr/bin/xattr -dr com.apple.quarantine "$DEST" 2>/dev/null; then
                rm -rf "$OLD"
              else
                rm -rf "$DEST"; mv "$OLD" "$DEST"
              fi
            fi
            /usr/bin/open -g "$DEST"
            rm -rf "$WORK"
            """
            do { try sh.write(to: script, atomically: true, encoding: .utf8) } catch { return fail("Could not prepare the update.") }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", "nohup /bin/sh \"$0\" \"$1\" \"$2\" \"$3\" \"$4\" >/dev/null 2>&1 &",
                           script.path, String(currentPid), newApp.path, bundle.path, work.path]
            do { try p.run(); p.waitUntilExit() } catch { return fail("Could not start the update.") }
            report(1)
            finish(.success(()))
        }
    }

    // MARK: Helpers (public so the tests can use them)

    static func sha256(of file: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try? h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func findApp(named name: String, in dir: URL) -> URL? {
        let fm = FileManager.default
        let top = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        if let a = top.first(where: { $0.lastPathComponent == "\(name).app" }) { return a }
        for sub in top where (try? sub.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && sub.pathExtension != "app" {
            let inner = (try? fm.contentsOfDirectory(at: sub, includingPropertiesForKeys: nil)) ?? []
            if let a = inner.first(where: { $0.lastPathComponent == "\(name).app" }) { return a }
        }
        return nil
    }

    @discardableResult
    static func run(_ path: String, _ args: [String]) -> (status: Int32, out: String) {
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: path); p.arguments = args
        p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
