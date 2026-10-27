// Logic tests for Logic.swift. No window, no sound, nothing on the Mac changes.
// Run: ./tests/run.sh
import Foundation

var failures = 0
func check(_ ok: Bool, _ name: String, line: Int = #line) {
    if ok { print("ok   \(name)") } else { failures += 1; print("FAIL \(name) (line \(line))") }
}

@main
enum LogicTests {
    static func main() {
        // Timer labels with days
        check(timerLabel(0) == "Off", "label off")
        check(timerLabel(30) == "30m", "label minutes")
        check(timerLabel(90) == "1h30", "label hours and minutes")
        check(timerLabel(1440) == "1d", "label one day")
        check(timerLabel(1440 + 240) == "1d4h", "label day and hours")
        check(timerLabel(3 * 1440, long: true) == "3 days", "long label days")
        check(timerLabel(1440 + 60 + 5, long: true) == "1 day 1 hour 5 min", "long label mixed")
        check(timerLabel(45, long: true) == "45 minutes", "long label minutes")

        // Timer choices: 30 days allowed, longer dropped, at most five, sorted
        check(cleanTimerChoices([43200, 43201, 60, 60, 30]) == [30, 60, 43200], "choices clean up")
        check(cleanTimerChoices([1, 2, 3, 4, 5, 6]).count == 5, "choices capped at five")

        // Time left
        check(formatRemaining(65) == "1:05", "remaining minutes")
        check(formatRemaining(3723) == "1:02:03", "remaining hours")
        check(formatRemaining(90061) == "1d 1:01:01", "remaining days")
        check(menuBarRemaining(10) == "1m", "menu bar under a minute")
        check(menuBarRemaining(3 * 3600 + 300) == "3h 05m", "menu bar hours")
        check(menuBarRemaining(2 * 86400 + 4 * 3600) == "2d 4h", "menu bar days")

        // Adding time
        let start = Date(timeIntervalSince1970: 0)
        let now = start.addingTimeInterval(600)
        let end = start.addingTimeInterval(3600)
        let e1 = extendedEnd(end: end, start: start, addMinutes: 30, now: now)
        check(e1.end == start.addingTimeInterval(5400) && e1.total == 5400, "add 30 min")
        let nearCap = start.addingTimeInterval(TimeInterval(maxTimerMinutes * 60 - 60))
        let e2 = extendedEnd(end: nearCap, start: start, addMinutes: 30, now: now)
        check(e2.end == start.addingTimeInterval(TimeInterval(maxTimerMinutes * 60)), "add time capped at 30 days")

        // Reminder
        check(reminderDate(end: now.addingTimeInterval(600), now: now) == now.addingTimeInterval(300), "reminder 5 min before")
        check(reminderDate(end: now.addingTimeInterval(200), now: now) == nil, "no reminder when under 5 min")

        // Pausing apps
        let running: [(id: String, regular: Bool)] = [
            ("com.tinyspeck.slackmacgap", true), ("com.apple.Safari", true), ("com.google.Chrome", true),
            ("com.spotify.client", true), ("com.example.menubar", false), ("us.zoom.xos", true),
        ]
        check(appsToPause(running: running, chosen: defaultPauseList, everyOther: false, chosenOn: true) == ["com.tinyspeck.slackmacgap"], "pause chosen only")
        check(appsToPause(running: running, chosen: defaultPauseList, everyOther: false, chosenOn: false).isEmpty, "pause nothing when off")
        check(appsToPause(running: running, chosen: [], everyOther: true, chosenOn: false) == ["com.tinyspeck.slackmacgap", "com.spotify.client"], "pause every other skips protected")
        check(appsToPause(running: running, chosen: ["us.zoom.xos"], everyOther: false, chosenOn: true).isEmpty, "never pause meeting apps")
        check(isNeverPaused("com.aboudjem.Sleepless"), "never pause Awayke")
        check(shouldResume(PausedProcess(pid: 5, started: 100), currentStart: 100), "resume same process")
        check(!shouldResume(PausedProcess(pid: 5, started: 100), currentStart: 200), "skip reused pid")
        check(!shouldResume(PausedProcess(pid: 5, started: 100), currentStart: nil), "skip gone process")
        let journal = try! JSONDecoder().decode([PausedProcess].self, from: JSONEncoder().encode([PausedProcess(pid: 9, started: 7)]))
        check(journal == [PausedProcess(pid: 9, started: 7)], "journal round trip")

        // Browsers
        check(hasUnthrottleFlags(commandLine: "/App/Chrome --disable-renderer-backgrounding --disable-backgrounding-occluded-windows"), "flags found")
        check(!hasUnthrottleFlags(commandLine: "/App/Chrome --disable-renderer-backgrounding"), "one flag is not enough")
        check(!hasUnthrottleFlags(commandLine: "/App/Chrome --disable-renderer-backgrounding=0 --disable-backgrounding-occluded-windowsX"), "lookalike flags rejected")

        // Updates
        check(isNewerVersion("v1.5.0", than: "1.4.3"), "1.5.0 newer than 1.4.3")
        check(!isNewerVersion("v1.5.0", than: "1.5"), "1.5.0 equals 1.5")
        check(!isNewerVersion("v1.4.3", than: "1.5.0"), "older is not newer")
        check(isNewerVersion("1.10", than: "1.9"), "numbers compared as numbers")

        print(failures == 0 ? "All logic tests passed." : "\(failures) logic test(s) failed.")
        exit(failures == 0 ? 0 : 1)
    }
}
