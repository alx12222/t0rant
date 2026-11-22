import SwiftUI
import UIKit

/// Asks iOS for extra time when the app is backgrounded mid-command, and always releases it,
/// so a long install isn't frozen halfway (and the app isn't killed for overrunning).
@MainActor
final class BackgroundGuard {
    private var id: UIBackgroundTaskIdentifier = .invalid
    init(shell: Shell) {
        id = UIApplication.shared.beginBackgroundTask(withName: "t0rant-command") { [weak self, weak shell] in
            Task { @MainActor in
                shell?.saveSession()
                self?.end()
            }
        }
    }
    func end() {
        if id != .invalid { UIApplication.shared.endBackgroundTask(id); id = .invalid }
    }
}

/// Everything the terminal needs to come back exactly as you left it.
struct SessionState: Codable {
    var history: [String]
    var cwd: [String]
    var env: [String: String]
    var aliases: [String: String]
    var promptFormat: String
    var title: String
    var lines: [SavedLine]
    var savedAt: Date

    struct SavedLine: Codable { var text: String; var error: Bool }
}

extension Shell {
    var sessionURL: URL {
        fs.url(["Users", fs.user, "AppData", "Local", "t0rant"]).appendingPathComponent("session.json")
    }

    /// Writes the session atomically (temp file + rename) so a crash can't leave a half-written file.
    func saveSession() {
        let state = SessionState(
            history: Array(history.suffix(1000)), cwd: cwd, env: env, aliases: aliases,
            promptFormat: promptFormat, title: title,
            lines: lines.suffix(400).map { SessionState.SavedLine(text: $0.text, error: $0.color == .red) },
            savedAt: Date())
        guard let data = try? JSONEncoder().encode(state) else { return }
        let url = sessionURL
        try? fs.fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic])
        // Keep one previous copy in case the latest is ever unreadable.
        let backup = url.deletingPathExtension().appendingPathExtension("bak.json")
        try? fs.fm.removeItem(at: backup)
        try? fs.fm.copyItem(at: url, to: backup)
    }

    /// Restores the last session. Returns false on first launch.
    @discardableResult
    func restoreSession() -> Bool {
        let url = sessionURL
        let backup = url.deletingPathExtension().appendingPathExtension("bak.json")
        let decoded = [url, backup].lazy.compactMap { u -> SessionState? in
            guard let d = try? Data(contentsOf: u) else { return nil }
            return try? JSONDecoder().decode(SessionState.self, from: d)
        }.first
        guard let s = decoded else { return false }
        history = s.history
        historyIndex = history.count
        if fs.isDir(fs.url(s.cwd)) { cwd = s.cwd }
        for (k, v) in s.env where !["USERNAME", "USERPROFILE", "HOMEPATH", "TEMP", "TMP", "APPDATA", "LOCALAPPDATA", "COMPUTERNAME"].contains(k) {
            env[k] = v
        }
        aliases = s.aliases
        promptFormat = s.promptFormat
        title = s.title
        lines = s.lines.map { Line(text: $0.text, color: $0.error ? .red : nil) }
        let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .short
        print("── session restored (\(f.string(from: s.savedAt))) ──", .gray)
        print("")
        return true
    }
}

enum Safety {
    /// Refuse big writes when the phone is nearly full: running out of space mid-install
    /// leaves half-written packages and can get the app terminated.
    static func lowSpace(minimumMB: Int64 = 200) -> String? {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        guard let v = try? docs.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let free = v.volumeAvailableCapacityForImportantUsage else { return nil }
        let mb = free / 1_048_576
        return mb < minimumMB ? "Not enough free storage to install safely (\(mb) MB free, need \(minimumMB) MB). Free up space and try again." : nil
    }
}

extension Safety {
    /// npm opens thousands of files during a big install; the iOS default of 256 open files
    /// makes it fail mid-install. Raise the soft limit as far as the system allows.
    static func raiseFileLimit() {
        var rl = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &rl) == 0 else { return }
        let target: rlim_t = 10240
        rl.rlim_cur = min(target, rl.rlim_max)
        _ = setrlimit(RLIMIT_NOFILE, &rl)
    }

    static var markerURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("t0rant-running.txt")
    }
    /// Written when a command starts and removed when it ends. If it's still there on the
    /// next launch, the app was killed during that command.
    static func markRunning(_ command: String) {
        try? FileManager.default.createDirectory(at: markerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? command.write(to: markerURL, atomically: true, encoding: .utf8)
    }
    static func clearRunning() { try? FileManager.default.removeItem(at: markerURL) }
    static func takeCrashedCommand() -> String? {
        guard let s = try? String(contentsOf: markerURL, encoding: .utf8) else { return nil }
        clearRunning()
        return s
    }
}

/// Startup protection and low-memory handling.
@MainActor
enum Stability {
    static var launchMarker: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("t0rant-launching.txt")
    }

    /// Returns true when the previous launch died during startup (e.g. a corrupt saved session).
    /// The marker is removed once the app has stayed up for a few seconds.
    static func beginLaunch() -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(at: launchMarker.deletingLastPathComponent(), withIntermediateDirectories: true)
        let crashedLastTime = fm.fileExists(atPath: launchMarker.path)
        try? "launching".write(to: launchMarker, atomically: true, encoding: .utf8)
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { try? FileManager.default.removeItem(at: launchMarker) }
        return crashedLastTime
    }

    /// Frees memory when iOS warns the app, before iOS has to kill it.
    static func observeMemoryWarnings(_ shell: Shell) {
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak shell] _ in
            Task { @MainActor in
                guard let shell else { return }
                URLCache.shared.removeAllCachedResponses()
                if shell.lines.count > 300 { shell.lines.removeFirst(shell.lines.count - 300) }
                shell.saveSession()
                shell.print("[t0rant] Low memory: cleared caches and older output to keep running.", .orange)
            }
        }
    }
}
