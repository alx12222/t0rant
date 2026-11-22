import Foundation

/// Hosts the single embedded Node.js instance (nodejs-mobile) and talks to it over a local socket.
final class NodeRuntime: @unchecked Sendable {
    static let shared = NodeRuntime()
    private var started = false
    private var port: UInt16?
    private let lock = NSLock()

    private var portFile: URL { FileManager.default.temporaryDirectory.appendingPathComponent("t0rant-node.port") }

    private func start() {
        lock.lock(); defer { lock.unlock() }
        if started { return }
        started = true
        try? FileManager.default.removeItem(at: portFile)
        guard let script = Bundle.main.path(forResource: "main", ofType: "js", inDirectory: "nodejs-project") else { return }
        let pf = portFile.path
        let t = Thread {
            // Size the JS heap from the device's RAM: big npm trees need ~1 GB, but going past iOS's
            // per-app limit gets the whole app killed. ~28% of RAM stays well under that limit.
            let ramMB = Int(ProcessInfo.processInfo.physicalMemory / 1_048_576)
            let heap = min(1536, max(512, ramMB * 28 / 100))
            var args = ["node", "--max-old-space-size=\(heap)", "--max-semi-space-size=16", "--stack-size=4000",
                        "--expose-gc", script, pf]
            var cargs = args.map { strdup($0) }
            cargs.append(nil)
            _ = node_start(Int32(args.count), &cargs)
            args.removeAll()
        }
        t.stackSize = 16 * 1024 * 1024
        t.name = "t0rant.node"
        t.start()
    }

    /// Ensures Node is running and returns its port (waits up to 15 s on first start).
    func ready() async -> UInt16? {
        if let p = port { return p }
        start()
        for _ in 0..<300 {
            if let s = try? String(contentsOf: portFile, encoding: .utf8), let p = UInt16(s.trimmingCharacters(in: .whitespacesAndNewlines)) {
                port = p
                return p
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return nil
    }

    func request(_ op: String, _ args: [String] = [], cwd: String, env: [String: String] = [:], print: Bool = false) async -> (String, Int32, Bool) {
        guard let p = await ready() else { return ("Node.js failed to start.", 1, false) }
        var job: [String: Any] = ["op": op, "args": args, "cwd": cwd, "env": env]
        if print { job["print"] = true }
        guard let body = try? JSONSerialization.data(withJSONObject: job) else { return ("bad request", 1, false) }
        let data = await Tools.tcpExchange("127.0.0.1", port: p, send: body + Data("\n".utf8), timeout: 3600)
        var s = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        var code: Int32 = 0
        if let r = s.range(of: "\u{02}", options: .backwards) {
            code = Int32(s[r.upperBound...]) ?? 0
            s = String(s[..<r.lowerBound])
        } else if data == nil {
            return ("(no response from Node.js)", 1, false)
        }
        var more = false
        if s.hasSuffix("\u{01}") { more = true; s.removeLast() }
        if s.hasSuffix("\n") { s.removeLast() }
        return (s, code, more)
    }
}

@MainActor
enum NodeCommands {
    static let table: [String: Cmd] = ["node": node, "npm": npm, "npx": npx]

    static func paths(_ c: Ctx) -> (cwd: String, env: [String: String]) {
        let fs = c.fs
        let home = fs.url(["Users", fs.user])
        let roaming = home.appendingPathComponent("AppData/Roaming/npm")
        let cache = home.appendingPathComponent("AppData/Local/npm-cache")
        try? fs.fm.createDirectory(at: roaming, withIntermediateDirectories: true)
        try? fs.fm.createDirectory(at: cache, withIntermediateDirectories: true)
        let env = [
            "HOME": home.path, "USERPROFILE": home.path,
            "npm_config_prefix": roaming.path, "npm_config_cache": cache.path,
            "npm_config_ignore_scripts": "true", "npm_config_update_notifier": "false",
            "npm_config_fund": "false", "npm_config_audit": "false", "npm_config_progress": "false",
            "npm_config_bin_links": "true", "npm_config_color": "false", "npm_config_unicode": "true",
            "T0RANT_EXEC_PORT": String(ExecBridge.shared.port), "npm_config_maxsockets": "6", "npm_config_fetch_retries": "4", "npm_config_fetch_retry_maxtimeout": "120000",
            "npm_config_fetch_timeout": "300000", "npm_config_loglevel": "warn",
            "NODE_PATH": roaming.appendingPathComponent("lib/node_modules").path,
        ]
        return (fs.url(c.shell.cwd).path, env)
    }

    static func result(_ r: (String, Int32, Bool)) -> CmdResult { CmdResult(out: r.0, err: "", code: r.1) }

    /// Node is busy running the package that asked for this command, so it can't start another job.
    static func nestedError(_ c: Ctx) -> CmdResult? {
        c.shell.nestedDepth > 0 ? .error("[t0rant] node/npm inside a piped or redirected command started by a Node package isn't supported; run it without | or >.", 1) : nil
    }

    static func node(_ c: Ctx) async -> CmdResult {
        if let e = nestedError(c) { return e }
        let a = c.args
        let (cwd, env) = paths(c)
        let rt = NodeRuntime.shared
        if a.first == "-v" || a.first == "--version" { return result(await rt.request("version", cwd: cwd, env: env)) }
        if a.isEmpty {
            if let input = c.stdin, !input.isEmpty { return result(await rt.request("eval", [input], cwd: cwd, env: env)) }
            _ = await rt.request("repl-reset", cwd: cwd, env: env)
            c.shell.nodeREPL = true
            c.shell.replMore = false
            let v = await rt.request("version", cwd: cwd, env: env).0
            return CmdResult(out: "Welcome to Node.js \(v) (t0rant embedded).\nType .exit or press ^C to return to t0rant.")
        }
        if (a[0] == "-e" || a[0] == "-p" || a[0] == "--eval" || a[0] == "--print"), a.count > 1 {
            return result(await rt.request("eval", [a[1]], cwd: cwd, env: env, print: a[0] == "-p" || a[0] == "--print"))
        }
        var file = c.fs.resolve(a[0], cwd: c.shell.cwd)
        if !c.fs.exists(file), c.fs.exists(file.appendingPathExtension("js")) { file = file.appendingPathExtension("js") }
        guard c.fs.exists(file) else { return .error("node: Cannot find module '\(c.fs.winPath(file))'", 1) }
        return result(await rt.request("script", [file.path] + a.dropFirst(), cwd: cwd, env: env))
    }

    static func npm(_ c: Ctx) async -> CmdResult {
        if let e = nestedError(c) { return e }
        var a = c.args
        let (cwd, env) = paths(c)
        if a.isEmpty { a = ["help"] }
        // npm can't spawn a shell on iOS, so package.json scripts are run by t0rant itself.
        let sub = a[0].lowercased()
        if ["run", "run-script", "start", "test", "t"].contains(sub) {
            return await runScript(c, sub == "start" ? "start" : (sub == "test" || sub == "t") ? "test" : (a.count > 1 ? a[1] : ""), extra: Array(a.dropFirst(sub == "run" || sub == "run-script" ? 2 : 1)))
        }
        if ["install", "i", "add", "update", "up", "ci"].contains(sub), let low = Safety.lowSpace() { return .error(low) }
        if sub == "exec" || sub == "x" { return await npx(Ctx(shell: c.shell, args: Array(a.dropFirst()), stdin: c.stdin, raw: c.raw)) }
        return result(await NodeRuntime.shared.request("npm", a, cwd: cwd, env: env))
    }

    static func runScript(_ c: Ctx, _ name: String, extra: [String]) async -> CmdResult {
        let pkgURL = c.fs.url(c.shell.cwd).appendingPathComponent("package.json")
        guard let d = c.fs.readData(pkgURL), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            return .error("npm ERR! enoent Could not read package.json in \(c.shell.cwdPath)", 254)
        }
        let scripts = j["scripts"] as? [String: String] ?? [:]
        guard !name.isEmpty else {
            return CmdResult(out: "Scripts available in \(j["name"] as? String ?? "package"):\n" + scripts.sorted { $0.key < $1.key }.map { "  \($0.key)\n    \($0.value)" }.joined(separator: "\n"))
        }
        guard var cmd = scripts[name] ?? (name == "start" ? "node server.js" : nil) else {
            return .error("npm ERR! Missing script: \"\(name)\"", 1)
        }
        if !extra.isEmpty { cmd += " " + extra.joined(separator: " ") }
        c.shell.print("\n> \(j["name"] as? String ?? "")@\(j["version"] as? String ?? "") \(name)\n> \(cmd)\n")
        // Each && / ; separated part goes through t0rant (node, npx, echo, ...).
        let code = await c.shell.runLine(cmd.replacingOccurrences(of: ";", with: "&"))
        return CmdResult(out: "", err: "", code: code)
    }

    /// Runs a package binary: local node_modules/.bin, then the global prefix, installing globally if needed.
    static func npx(_ c: Ctx) async -> CmdResult {
        if let e = nestedError(c) { return e }
        var a = c.args.filter { $0 != "-y" && $0 != "--yes" }
        if a.first == "--" { a.removeFirst() }
        guard let spec = a.first else { return CmdResult(out: "Usage: npx <package[@version]> [args]") }
        let (cwd, env) = paths(c)
        let name = spec.hasPrefix("@") ? "@" + (spec.dropFirst().split(separator: "@").first.map(String.init) ?? "") : (spec.split(separator: "@").first.map(String.init) ?? spec)
        let globalRoot = URL(fileURLWithPath: env["npm_config_prefix"]!).appendingPathComponent("lib/node_modules")
        let roots = [c.fs.url(c.shell.cwd).appendingPathComponent("node_modules"), globalRoot]
        func findBin() -> URL? {
            for r in roots {
                let pkgDir = r.appendingPathComponent(name)
                guard let d = try? Data(contentsOf: pkgDir.appendingPathComponent("package.json")),
                      let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
                if let s = j["bin"] as? String { return pkgDir.appendingPathComponent(s) }
                if let m = j["bin"] as? [String: String] {
                    let short = name.split(separator: "/").last.map(String.init) ?? name
                    if let s = m[short] ?? m.values.first { return pkgDir.appendingPathComponent(s) }
                }
                if let main = j["main"] as? String { return pkgDir.appendingPathComponent(main) }
            }
            return nil
        }
        var bin = findBin()
        if bin == nil {
            c.shell.print("Need to install the following packages:\n  \(spec)\nInstalling globally...")
            let r = await NodeRuntime.shared.request("npm", ["install", "-g", spec], cwd: cwd, env: env)
            if !r.0.isEmpty { c.shell.print(r.0) }
            bin = findBin()
        }
        guard let b = bin else { return .error("npx: could not find an executable for \(spec)", 1) }
        return result(await NodeRuntime.shared.request("script", [b.path] + a.dropFirst(), cwd: cwd, env: env))
    }

    /// Global npm prefix (`npm config get prefix`): C:\Users\<you>\AppData\Roaming\npm
    static func globalPrefix(_ shell: Shell) -> URL {
        shell.fs.url(["Users", shell.fs.user, "AppData", "Roaming", "npm"])
    }

    /// Finds an executable installed by npm: ./node_modules/.bin first, then the global bin folder.
    static func binPath(_ name: String, shell: Shell) -> URL? {
        guard !name.isEmpty, !name.contains("\\"), !name.contains("/") else { return nil }
        let dirs = [shell.fs.url(shell.cwd).appendingPathComponent("node_modules/.bin"), globalPrefix(shell).appendingPathComponent("bin")]
        let fm = FileManager.default
        for d in dirs {
            guard let entries = try? fm.contentsOfDirectory(atPath: d.path) else { continue }
            if let m = entries.first(where: { $0.lowercased() == name }) {
                let target = d.appendingPathComponent(m).resolvingSymlinksInPath()
                if fm.fileExists(atPath: target.path) { return target }
            }
        }
        return nil
    }

    static func runBin(_ bin: URL, args: [String], shell: Shell, stdin: String?, raw: String) async -> CmdResult {
        let ctx = Ctx(shell: shell, args: args, stdin: stdin, raw: raw)
        if let e = nestedError(ctx) { return e }
        let (cwd, env) = paths(ctx)
        return result(await NodeRuntime.shared.request("script", [bin.path] + args, cwd: cwd, env: env))
    }

    static func replLine(_ shell: Shell, _ line: String) async {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t == ".exit" { shell.nodeREPL = false; shell.replMore = false; return }
        let cwd = shell.fs.url(shell.cwd).path
        let src = shell.replBuffer.isEmpty ? line : shell.replBuffer + "\n" + line
        let (out, _, more) = await NodeRuntime.shared.request("repl", [src], cwd: cwd)
        if more { shell.replBuffer = src; shell.replMore = true; return }
        shell.replBuffer = ""
        shell.replMore = false
        if !out.isEmpty { shell.print(out) }
    }
}
