import Foundation

/// Owns the embedded CPython interpreter. All calls run on one background queue.
final class PythonRuntime: @unchecked Sendable {
    static let shared = PythonRuntime()
    let version = "3.13"
    // Python runs on its own thread with a 16 MB stack: the default 512 KB background stack
    // overflows (and crashes the app) on deeply recursive code such as pip's resolver.
    private var jobs: [() -> Void] = []
    private let cond = NSCondition()
    private lazy var worker: Thread = {
        let t = Thread { [unowned self] in
            while true {
                self.cond.lock()
                while self.jobs.isEmpty { self.cond.wait() }
                let job = self.jobs.removeFirst()
                self.cond.unlock()
                job()
            }
        }
        t.stackSize = 16 * 1024 * 1024
        t.name = "t0rant.python"
        t.start()
        return t
    }()
    private func enqueue(_ job: @escaping () -> Void) {
        cond.lock()
        _ = worker
        jobs.append(job)
        cond.signal()
        cond.unlock()
    }
    private var started = false
    private var startError: String?

    var userSitePackages: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("C/Python/site-packages", isDirectory: true)
    }

    static let boot = #"""
import sys, io, os, code, runpy, traceback, site, builtins

class _T0:
    def __init__(self, user_site):
        self.user_site = user_site
        os.makedirs(user_site, exist_ok=True)
        site.addsitedir(user_site)
        self.console = code.InteractiveConsole({'__name__': '__console__'})
        builtins.input = self._no_input

    def _no_input(self, prompt=''):
        raise EOFError('interactive input() is not supported in t0rant scripts; pass values as arguments')

    def _capture(self, fn):
        out = io.StringIO()
        old = (sys.stdout, sys.stderr, sys.stdin)
        sys.stdout = sys.stderr = out
        sys.stdin = io.StringIO('')
        status = ''
        try:
            fn()
        except SystemExit as e:
            if e.code not in (None, 0):
                status = str(e.code)
            status = status or '0'
            out.write('\x02' + status)
        except BaseException:
            traceback.print_exc()
        finally:
            sys.stdout, sys.stderr, sys.stdin = old
        return out.getvalue()

    def chdir(self, path, _=''):
        try:
            os.chdir(path)
        except Exception:
            pass
        return ''

    def run_code(self, src, argv):
        def f():
            sys.argv = argv.split('\x1f') if argv else ['-c']
            exec(compile(src, '<string>', 'exec'), {'__name__': '__main__'})
        return self._capture(f)

    def run_file(self, path, argv):
        def f():
            sys.argv = [path] + (argv.split('\x1f') if argv else [])
            runpy.run_path(path, run_name='__main__')
        return self._capture(f)

    def run_module(self, name, argv):
        def f():
            sys.argv = [name] + (argv.split('\x1f') if argv else [])
            runpy.run_module(name, run_name='__main__', alter_sys=True)
        return self._capture(f)

    def push(self, line, _=''):
        more = [False]
        def f():
            more[0] = self.console.push(line)
        out = self._capture(f)
        return out + ('\x01' if more[0] else '')

    def reset(self, _a='', _b=''):
        self.console = code.InteractiveConsole({'__name__': '__console__'})
        return ''

    def packages(self, _a='', _b=''):
        import importlib.metadata as md
        names = sorted({(d.metadata['Name'] or '?') + '==' + d.version for d in md.distributions()}, key=str.lower)
        return '  '.join(names)

"""#

    /// Starts the interpreter once. Returns an error string if Python is unavailable.
    private func ensureStarted() -> String? {
        if started { return startError }
        started = true
        guard let res = Bundle.main.resourcePath else { startError = "no bundle"; return startError }
        let home = res + "/python"
        let lib = home + "/lib/python3.13"
        guard FileManager.default.fileExists(atPath: lib) else {
            startError = "Python standard library not found in app bundle (\(lib))."
            return startError
        }
        let paths = [lib, lib + "/lib-dynload", res + "/app_packages", res + "/app", userSitePackages.path].joined(separator: "\n")
        setenv("HOME", FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("C/Users/" + (UserDefaults.standard.string(forKey: "username") ?? "t0rant")).path, 1)
        setenv("SSL_CERT_FILE", res + "/app_packages/certifi/cacert.pem", 1)
        setenv("PIP_DISABLE_PIP_VERSION_CHECK", "1", 1)
        setenv("PIP_NO_COMPILE", "1", 1)
        setenv("PIP_DEFAULT_TIMEOUT", "60", 1)
        setenv("PIP_RETRIES", "5", 1)
        setenv("PIP_PROGRESS_BAR", "off", 1)
        let pipCache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("pip")
        setenv("PIP_CACHE_DIR", pipCache.path, 1)
        setenv("PYTHONDONTWRITEBYTECODE", "1", 1)
        let site = userSitePackages.path.replacingOccurrences(of: "'", with: "\\'")
        let code = PythonRuntime.boot + "\n_t0 = _T0('\(site)')\n"
        let rc = t0_py_init(home, paths, code)
        if rc != 0 { startError = "Python failed to start (code \(rc))." }
        return startError
    }

    private func callSync(_ method: String, _ a: String, _ b: String) -> String {
        if let e = ensureStarted() { return e + "\n" }
        guard let p = t0_py_call(method, a, b) else { return "" }
        defer { free(p) }
        return String(cString: p)
    }

    func call(_ method: String, _ a: String = "", _ b: String = "", cwd: String? = nil) async -> String {
        await withCheckedContinuation { cont in
            enqueue {
                if let cwd { _ = self.callSync("chdir", cwd, "") }
                cont.resume(returning: self.callSync(method, a, b))
            }
        }
    }

    func listPackages() async -> String { await call("packages") }
}

/// Splits raw Python output into (text, exitCode, replNeedsMore).
struct PyOutput {
    var text: String
    var code: Int32 = 0
    var more = false
    init(_ raw: String) {
        var s = raw
        if s.hasSuffix("\u{01}") { more = true; s.removeLast() }
        if let r = s.range(of: "\u{02}", options: .backwards) {
            code = Int32(s[r.upperBound...]) ?? 1
            s = String(s[..<r.lowerBound])
        }
        if s.contains("Traceback (most recent call last)") && code == 0 { code = 1 }
        if s.hasSuffix("\n") { s.removeLast() }
        text = s
    }
}

@MainActor
enum PythonCommands {
    static let table: [String: Cmd] = ["python": python, "python3": python, "py": python, "pip": pip, "pip3": pip]

    static func realCwd(_ c: Ctx) -> String { c.fs.url(c.shell.cwd).path }

    static func python(_ c: Ctx) async -> CmdResult {
        let rt = PythonRuntime.shared
        let a = c.args
        if a.first == "--version" || a.first == "-V" { return CmdResult(out: "Python 3.13.18") }
        if a.isEmpty {
            if let input = c.stdin, !input.isEmpty {
                return result(await rt.call("run_code", input, "-", cwd: realCwd(c)))
            }
            c.shell.pythonREPL = true
            c.shell.replMore = false
            _ = await rt.call("reset")
            return CmdResult(out: "Python 3.13.18 (t0rant embedded) on ios\nType \"help\", \"copyright\", \"credits\" or \"license\" for more information.\nType exit() or press ^C to return to t0rant.")
        }
        if a[0] == "-c", a.count > 1 {
            return result(await rt.call("run_code", a[1], (["-c"] + a.dropFirst(2)).joined(separator: "\u{1f}"), cwd: realCwd(c)))
        }
        if a[0] == "-m", a.count > 1 {
            return result(await rt.call("run_module", a[1], a.dropFirst(2).joined(separator: "\u{1f}"), cwd: realCwd(c)))
        }
        let script = c.fs.resolve(a[0], cwd: c.shell.cwd)
        guard c.fs.exists(script) else {
            return .error("python: can't open file '\(c.fs.winPath(script))': [Errno 2] No such file or directory", 2)
        }
        return result(await rt.call("run_file", script.path, a.dropFirst().joined(separator: "\u{1f}"), cwd: realCwd(c)))
    }

    static func pip(_ c: Ctx) async -> CmdResult {
        var a = c.args
        if a.isEmpty { a = ["--help"] }
        let site = PythonRuntime.shared.userSitePackages.path
        switch a[0].lowercased() {
        case "install":
            if let low = Safety.lowSpace() { return .error(low) }
            a += ["--target", site, "--upgrade", "--no-compile", "--only-binary=:all:", "--use-deprecated=legacy-certs"]
            c.shell.print("Installing into C:\\Python\\site-packages (pure-Python wheels only on iOS)...")
        case "uninstall":
            // pip can't uninstall from --target dirs; remove the package folders directly.
            var removed: [String] = []
            for name in a.dropFirst() where !name.hasPrefix("-") {
                let norm = name.lowercased().replacingOccurrences(of: "-", with: "_")
                for e in (try? FileManager.default.contentsOfDirectory(atPath: site)) ?? [] {
                    let l = e.lowercased().replacingOccurrences(of: "-", with: "_")
                    if l == norm || l.hasPrefix(norm + "-") || l == norm + ".py" {
                        try? FileManager.default.removeItem(atPath: site + "/" + e); removed.append(e)
                    }
                }
            }
            return removed.isEmpty ? .error("WARNING: Skipping \(a.dropFirst().joined(separator: " ")) as it is not installed (or is a built-in package).")
                : CmdResult(out: "Successfully uninstalled \(removed.joined(separator: ", "))")
        case "list", "freeze":
            a += ["--path", site]
            let builtin = await PythonRuntime.shared.listPackages()
            let user = PyOutput(await PythonRuntime.shared.call("run_module", "pip", a.joined(separator: "\u{1f}"), cwd: realCwd(c)))
            return CmdResult(out: "Pre-installed:\n  \(builtin.replacingOccurrences(of: "  ", with: "\n  "))\n\nUser-installed (C:\\Python\\site-packages):\n\(user.text)")
        default: break
        }
        return result(await PythonRuntime.shared.call("run_module", "pip", a.joined(separator: "\u{1f}"), cwd: realCwd(c)))
    }

    static func result(_ raw: String) -> CmdResult {
        let o = PyOutput(raw)
        return CmdResult(out: o.text, err: "", code: o.code)
    }

    /// Handles one line typed while the Python REPL is active.
    static func replLine(_ shell: Shell, _ line: String) async {
        let raw = await PythonRuntime.shared.call("push", line)
        let o = PyOutput(raw)
        if !o.text.isEmpty { shell.print(o.text) }
        shell.replMore = o.more
        // exit()/quit() raise SystemExit, reported with the \u{02} marker.
        if raw.contains("\u{02}") { shell.pythonREPL = false; shell.replMore = false }
    }
}
