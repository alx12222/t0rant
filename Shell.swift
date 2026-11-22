import SwiftUI
import UIKit

struct Line: Identifiable {
    let id = UUID()
    let text: String
    var color: Color? = nil
}

struct CmdResult {
    var out = ""
    var err = ""
    var code: Int32 = 0
    static func error(_ s: String, _ c: Int32 = 1) -> CmdResult { CmdResult(out: "", err: s, code: c) }
}

@MainActor
final class Shell: ObservableObject {
    @Published var lines: [Line] = []
    @Published var busy = false
    @Published var title = "t0rant — Command Prompt"
    @Published var fg = Color(white: 0.8)
    @Published var bg = Color.black
    @Published var pythonREPL = false
    @Published var replMore = false
    @Published var nodeREPL = false
    var replBuffer = ""
    struct Capture { var out = ""; var err = "" }
    var captures: [Capture] = []
    var nestedDepth = 0

    let fs = VirtualFS()
    var cwd: [String] = ["Users", "t0rant"]
    var env: [String: String] = [:]
    var history: [String] = []
    var historyIndex = 0
    var echoOn = true
    var promptFormat = "$P$G"
    var aliases: [String: String] = [:]
    var lastCode: Int32 = 0
    var dirStack: [[String]] = []
    private var currentTask: Task<Void, Never>?
    var cancelled = false

    init() {
        let name = UIDevice.current.name.uppercased().replacingOccurrences(of: " ", with: "-")
        env = [
            "USERNAME": "t0rant", "USERPROFILE": "C:\\Users\\t0rant", "HOMEDRIVE": "C:",
            "HOMEPATH": "\\Users\\t0rant", "COMPUTERNAME": name,
            "OS": "Windows_NT", "PATH": "C:\\Windows\\System32;C:\\Windows", "PATHEXT": ".COM;.EXE;.BAT;.CMD",
            "SYSTEMROOT": "C:\\Windows", "WINDIR": "C:\\Windows", "TEMP": "C:\\Users\\t0rant\\AppData\\Local\\Temp",
            "TMP": "C:\\Users\\t0rant\\AppData\\Local\\Temp", "PROMPT": "$P$G", "COMSPEC": "C:\\Windows\\System32\\cmd.exe",
            "PROCESSOR_ARCHITECTURE": "ARM64", "NUMBER_OF_PROCESSORS": "\(ProcessInfo.processInfo.processorCount)",
            "APPDATA": "C:\\Users\\t0rant\\AppData\\Roaming", "LOCALAPPDATA": "C:\\Users\\t0rant\\AppData\\Local",
            "PUBLIC": "C:\\Users\\Public", "PROGRAMFILES": "C:\\Program Files", "SYSTEMDRIVE": "C:"
        ]
        applySettings(moveHome: false)
        for (k, v) in (UserDefaults.standard.dictionary(forKey: "setx") as? [String: String] ?? [:]) { env[k] = v }
        Safety.raiseFileLimit()
        ExecBridge.shared.start(shell: self)
        Stability.observeMemoryWarnings(self)
        let safeMode = Stability.beginLaunch()
        if safeMode {
            // The last launch crashed during startup: set the saved session aside instead of loading it again.
            let broken = sessionURL.deletingPathExtension().appendingPathExtension("broken.json")
            try? fs.fm.removeItem(at: broken)
            try? fs.fm.moveItem(at: sessionURL, to: broken)
            try? fs.fm.removeItem(at: sessionURL.deletingPathExtension().appendingPathExtension("bak.json"))
        }
        if safeMode {
            print(Shell.banner)
            print("")
            print("[t0rant] Safe mode: the last launch failed, so the saved session was set aside (AppData\\Local\\t0rant\\session.broken.json).", .orange)
            print("")
        } else if !restoreSession() {
            print(Shell.banner)
            print("")
        }
        if let crashed = Safety.takeCrashedCommand() {
            print("t0rant closed unexpectedly while running: \(crashed)", .orange)
            if crashed.lowercased().contains("npm") {
                print("If a package folder is half-installed, run: npm install  (it repairs node_modules), or delete node_modules and retry.", .orange)
            }
            print("")
        }
    }

    /// Applies the Settings tab (user name, colours) to the shell.
    func applySettings(moveHome: Bool = true) {
        let s = AppSettings.shared
        let oldUser = fs.user
        let u = s.username
        fs.user = u
        fs.bootstrap()
        let home = "C:\\Users\\" + u
        env["USERNAME"] = u
        env["USERPROFILE"] = home
        env["HOMEPATH"] = "\\Users\\" + u
        env["TEMP"] = home + "\\AppData\\Local\\Temp"
        env["TMP"] = env["TEMP"]
        env["APPDATA"] = home + "\\AppData\\Roaming"
        env["LOCALAPPDATA"] = home + "\\AppData\\Local"
        if !moveHome { cwd = ["Users", u] }
        if moveHome, oldUser != u, cwd.count >= 2, cwd[0] == "Users", cwd[1] == oldUser { cwd[1] = u }
        fg = s.fgColor
        bg = s.bgColor
    }

    static let banner = "t0rant [Version 10.0.26200.1]\n(c) t0rant. All rights reserved.\nType HELP for a list of commands."

    // MARK: output
    func print(_ s: String, _ color: Color? = nil) {
        if !captures.isEmpty {
            let text = s.hasSuffix("\n") || s.isEmpty ? s : s + "\n"
            if color == .red { captures[captures.count - 1].err += text } else { captures[captures.count - 1].out += text }
            return
        }
        var parts = s.components(separatedBy: "\n")
        if s.hasSuffix("\n") { parts.removeLast() }
        // Huge outputs (e.g. a big install log) would freeze the UI; keep the tail.
        if parts.count > 4000 {
            let dropped = parts.count - 4000
            parts = ["... (\(dropped) earlier lines hidden; redirect with > file.txt to keep everything)"] + parts.suffix(4000)
        }
        for p in parts { lines.append(Line(text: p.replacingOccurrences(of: "\r", with: ""), color: color)) }
        if lines.count > 5000 { lines.removeFirst(lines.count - 5000) }
    }
    func clear() { lines.removeAll() }

    var cwdPath: String { "C:\\" + cwd.joined(separator: "\\") }
    var promptText: String {
        if pythonREPL { return replMore ? "... " : ">>> " }
        if nodeREPL { return replMore ? "... " : "> " }
        var r = ""
        var it = promptFormat.makeIterator()
        while let c = it.next() {
            if c == "$", let n = it.next() {
                switch n.uppercased() {
                case "P": r += cwdPath
                case "G": r += ">"
                case "L": r += "<"
                case "N": r += "C"
                case "D": r += Shell.dateString()
                case "T": r += Shell.timeString()
                case "_": r += "\n"
                case "$": r += "$"
                case "S": r += " "
                case "Q": r += "="
                case "B": r += "|"
                case "E": r += "\u{1B}"
                default: r.append(n)
                }
            } else { r.append(c) }
        }
        return r
    }

    // MARK: input handling
    func submit(_ raw: String) {
        print(promptText + raw)
        if nodeREPL {
            if !raw.trimmingCharacters(in: .whitespaces).isEmpty { history.append(raw) }
            historyIndex = history.count
            busy = true
            currentTask = Task { [weak self] in
                guard let self else { return }
                await NodeCommands.replLine(self, raw)
                self.busy = false
            }
            return
        }
        if pythonREPL {
            if !raw.trimmingCharacters(in: .whitespaces).isEmpty { history.append(raw) }
            historyIndex = history.count
            busy = true
            currentTask = Task { [weak self] in
                guard let self else { return }
                await PythonCommands.replLine(self, raw)
                self.busy = false
            }
            return
        }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty && history.last != trimmed { history.append(trimmed) }
        historyIndex = history.count
        guard !trimmed.isEmpty else { return }
        busy = true
        cancelled = false
        // Keep running for a while if the app goes to the background (e.g. during a long install),
        // so iOS doesn't suspend it halfway through writing files.
        let bg = BackgroundGuard(shell: self)
        saveSession()
        Safety.markRunning(trimmed)
        currentTask = Task { [weak self] in
            guard let self else { return }
            await self.runLine(trimmed)
            Safety.clearRunning()
            self.print("")
            self.busy = false
            self.saveSession()
            bg.end()
        }
    }

    func cancel() {
        cancelled = true
        InputPrompt.shared.cancelAll()
        currentTask?.cancel()
        print(pythonREPL ? "KeyboardInterrupt" : "^C")
        pythonREPL = false
        nodeREPL = false
        replBuffer = ""
        replMore = false
        busy = false
    }

    func historyStep(_ d: Int) -> String? {
        guard !history.isEmpty else { return nil }
        historyIndex = max(0, min(history.count, historyIndex + d))
        return historyIndex < history.count ? history[historyIndex] : ""
    }

    func complete(_ input: String) -> String {
        var tokens = input.components(separatedBy: " ")
        let last = tokens.last ?? ""
        let unq = last.replacingOccurrences(of: "\"", with: "")
        var dirPart = ""
        var prefix = unq
        if let r = unq.lastIndex(where: { $0 == "\\" || $0 == "/" }) {
            dirPart = String(unq[...r])
            prefix = String(unq[unq.index(after: r)...])
        }
        let dir = fs.resolve(dirPart.isEmpty ? "." : dirPart, cwd: cwd)
        let names = (fs.list(dir) ?? []).map { $0.name }.sorted()
        guard let m = names.first(where: { $0.lowercased().hasPrefix(prefix.lowercased()) }) else { return input }
        var full = dirPart + m
        if full.contains(" ") { full = "\"" + full + "\"" }
        tokens[tokens.count - 1] = full
        return tokens.joined(separator: " ")
    }

    // MARK: variable expansion
    func expand(_ s: String) -> String {
        var out = ""
        let c = Array(s)
        var i = 0
        while i < c.count {
            if c[i] == "%" {
                if i + 1 < c.count, c[i + 1] == "%" { out.append("%"); i += 2; continue }
                if let close = c[(i + 1)...].firstIndex(of: "%") {
                    let name = String(c[(i + 1)..<close])
                    if !name.isEmpty, !name.contains(" "), let v = lookupVar(name) {
                        out += v; i = close + 1; continue
                    }
                }
            }
            out.append(c[i]); i += 1
        }
        return out
    }

    func lookupVar(_ name: String) -> String? {
        if let r = name.range(of: ":~") {
            let base = String(name[..<r.lowerBound])
            guard let v = lookupVar(base) else { return nil }
            let spec = name[r.upperBound...].split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            let arr = Array(v)
            var start = spec.first ?? 0
            if start < 0 { start = max(0, arr.count + start) }
            start = min(start, arr.count)
            var end = arr.count
            if spec.count > 1 { end = spec[1] < 0 ? max(start, arr.count + spec[1]) : min(arr.count, start + spec[1]) }
            return String(arr[start..<max(start, end)])
        }
        if let r = name.range(of: ":"), let eq = name.range(of: "=", range: r.upperBound..<name.endIndex) {
            let base = String(name[..<r.lowerBound])
            guard let v = lookupVar(base) else { return nil }
            let from = String(name[r.upperBound..<eq.lowerBound])
            let to = String(name[eq.upperBound...])
            if from.isEmpty { return v }
            return v.replacingOccurrences(of: from, with: to, options: .caseInsensitive)
        }
        switch name.uppercased() {
        case "CD": return cwdPath
        case "DATE": return Shell.dateString()
        case "TIME": return Shell.timeString()
        case "RANDOM": return String(Int.random(in: 0...32767))
        case "ERRORLEVEL": return String(lastCode)
        case "CMDCMDLINE": return "C:\\Windows\\System32\\cmd.exe"
        default: return env[name.uppercased()]
        }
    }

    // MARK: execution
    @discardableResult
    func runLine(_ line: String, batchArgs: [String] = []) async -> Int32 {
        var src = line
        if !batchArgs.isEmpty {
            src = src.replacingOccurrences(of: "%*", with: batchArgs.dropFirst().joined(separator: " "))
            for i in stride(from: 9, through: 0, by: -1) {
                let v = i < batchArgs.count ? batchArgs[i] : ""
                src = src.replacingOccurrences(of: "%~\(i)", with: v.replacingOccurrences(of: "\"", with: ""))
                src = src.replacingOccurrences(of: "%\(i)", with: v)
            }
        }
        let expanded = expand(src)
        let chain = Parser.splitChain(expanded)
        var code: Int32 = 0
        var skip = false
        for (seg, op) in chain {
            if cancelled { return 130 }
            if !skip { code = await runPipeline(seg); lastCode = code }
            switch op {
            case "&&": skip = code != 0
            case "||": skip = code == 0
            default: skip = false
            }
        }
        return code
    }

    /// Runs a raw command segment and returns captured output (used by FOR /F and IF blocks).
    func capture(_ line: String) async -> CmdResult {
        let stages = Parser.splitPipes(expand(line))
        var stdin: String? = nil
        var res = CmdResult()
        for stage in stages {
            let (tokens, _) = Parser.tokenize(stage)
            if tokens.isEmpty { continue }
            res = await exec(tokens, stdin: stdin)
            stdin = res.out
        }
        return res
    }

    func runPipeline(_ seg: String) async -> Int32 {
        var s = seg
        // parenthesised block: ( a & b )
        if s.hasPrefix("(") && s.hasSuffix(")") {
            s = String(s.dropFirst().dropLast())
            return await runLine(s)
        }
        if s.hasPrefix("@") { s = String(s.dropFirst()) }
        let stages = Parser.splitPipes(s)
        var stdin: String? = nil
        var res = CmdResult()
        for (idx, stage) in stages.enumerated() {
            var (tokens, redir) = Parser.tokenize(stage)
            if tokens.isEmpty { continue }
            if let inFile = redir.input {
                guard let data = fs.read(fs.resolve(inFile, cwd: cwd)) else {
                    print("The system cannot find the file specified.", .red); return 1
                }
                stdin = data
            }
            if let a = aliases[tokens[0].lowercased()] {
                tokens = Parser.tokenize(a).0 + tokens.dropFirst()
            }
            res = await exec(tokens, stdin: stdin, raw: stage)
            let isLast = idx == stages.count - 1
            if redir.errToOut { res.out += res.err; res.err = "" }
            if redir.errToNull { res.err = "" }
            if let target = redir.output {
                if target.lowercased() != "nul" {
                    let url = fs.resolve(target, cwd: cwd)
                    let existing = redir.append ? (fs.read(url) ?? "") : ""
                    var data = res.out
                    if !data.isEmpty && !data.hasSuffix("\n") { data += "\n" }
                    fs.write(url, existing + data)
                }
                res.out = ""
            }
            if !res.err.isEmpty { print(res.err.hasSuffix("\n") ? String(res.err.dropLast()) : res.err, .red) }
            if isLast {
                if !res.out.isEmpty { print(res.out) }
            } else {
                stdin = res.out
            }
        }
        return res.code
    }

    func exec(_ t: [String], stdin: String?, raw: String = "") async -> CmdResult {
        var name = t[0]
        var args = Array(t.dropFirst())
        // "cd..", "dir/w", "echo." style
        let lowName = name.lowercased()
        if !lowName.hasSuffix(".exe"), !lowName.hasSuffix(".com"),
           let r = name.firstIndex(where: { $0 == "/" || $0 == "." || $0 == "\\" }), r != name.startIndex,
           Commands.table[String(name[..<r]).lowercased()] != nil {
            let rest = String(name[r...])
            name = String(name[..<r])
            if name.lowercased() == "echo" { return CmdResult(out: String(rest.dropFirst()) + (args.isEmpty ? "" : " " + args.joined(separator: " "))) }
            args.insert(rest, at: 0)
        }
        if name.count == 2, name.hasSuffix(":") {
            return name.uppercased() == "C:" ? CmdResult() : .error("The system cannot find the drive specified.")
        }
        var lower = name.lowercased()
        for ext in [".exe", ".com"] where lower.hasSuffix(ext) { lower = String(lower.dropLast(ext.count)) }
        if args.first == "/?" { return CmdResult(out: Commands.helpText[lower] ?? "Displays help for \(name.uppercased()). See HELP.") }
        if let f = Commands.table[lower] {
            let ctx = Ctx(shell: self, args: args, stdin: stdin, raw: raw)
            return await f(ctx)
        }
        // Commands installed with `npm install -g` (and local node_modules/.bin)
        if let bin = NodeCommands.binPath(lower, shell: self) {
            return await NodeCommands.runBin(bin, args: args, shell: self, stdin: stdin, raw: raw)
        }
        // .bat / .cmd scripts
        for c in [name, name + ".bat", name + ".cmd"] {
            let url = fs.resolve(c, cwd: cwd)
            let ext = url.pathExtension.lowercased()
            if ext == "bat" || ext == "cmd", let src = fs.read(url) {
                return await runBatch(src, args: [name] + args)
            }
        }
        return .error("'\(name)' is not recognized as an internal or external command,\noperable program or batch file.", 9009)
    }

    // MARK: batch interpreter
    func runBatch(_ src: String, args: [String]) async -> CmdResult {
        let lines = src.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var labels: [String: Int] = [:]
        for (i, l) in lines.enumerated() {
            let t = l.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix(":") && !t.hasPrefix("::") {
                let key = String(t.dropFirst()).split(separator: " ").first.map { $0.lowercased() } ?? ""
                labels[key] = i
            }
        }
        let savedEcho = echoOn
        let savedEnv = env
        var local = false
        var argv = args
        var pc = 0
        var steps = 0
        while pc < lines.count {
            if cancelled { break }
            steps += 1
            if steps > 200_000 { print("Batch aborted: too many steps.", .red); break }
            if steps % 200 == 0 { await Task.yield() }
            var l = lines[pc].trimmingCharacters(in: .whitespaces)
            pc += 1
            // join multi-line parenthesised blocks
            var depth = Parser.parenDepth(l)
            while depth > 0 && pc < lines.count {
                l += " & " + lines[pc].trimmingCharacters(in: .whitespaces)
                pc += 1
                depth = Parser.parenDepth(l)
            }
            l = l.replacingOccurrences(of: "( &", with: "(").replacingOccurrences(of: "& )", with: ")")
            let lowRaw = l.lowercased()
            if l.isEmpty || l.hasPrefix("::") || l.hasPrefix(":") || lowRaw.hasPrefix("rem ") || lowRaw == "rem" || lowRaw.hasPrefix("@rem") { continue }
            var silent = false
            if l.hasPrefix("@") { silent = true; l = String(l.dropFirst()) }
            let low = l.lowercased()
            if low.hasPrefix("goto ") || low.hasPrefix("goto:") {
                let target = l.dropFirst(4).trimmingCharacters(in: CharacterSet(charactersIn: " :")).lowercased()
                if target == "eof" { break }
                if let p = labels[target] { pc = p + 1; continue }
                print("The system cannot find the batch label specified - \(target)", .red); break
            }
            if low == "setlocal" || low.hasPrefix("setlocal ") { local = true; continue }
            if low == "endlocal" { if local { env = savedEnv }; continue }
            if low == "shift" { if argv.count > 1 { argv.remove(at: 1) }; continue }
            if low == "exit /b" || low.hasPrefix("exit /b ") {
                lastCode = Int32(l.dropFirst(7).trimmingCharacters(in: .whitespaces)) ?? lastCode
                break
            }
            if low.hasPrefix("call :") {
                let parts = Parser.tokenize(String(l.dropFirst(6))).0
                if let lbl = parts.first, let p = labels[lbl.lowercased()] {
                    let sub = lines[(p + 1)...].joined(separator: "\n")
                    let wasEcho = echoOn
                    _ = await runBatch(sub, args: [argv.first ?? ""] + parts.dropFirst())
                    echoOn = wasEcho
                }
                continue
            }
            if echoOn && !silent { print(promptText + l) }
            await runLine(l, batchArgs: argv)
        }
        echoOn = savedEcho
        if local { env = savedEnv }
        return CmdResult(out: "", err: "", code: lastCode)
    }

    static func dateString() -> String {
        let f = DateFormatter(); f.dateFormat = "EEE MM/dd/yyyy"; return f.string(from: Date())
    }
    static func timeString() -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SS"; return f.string(from: Date())
    }
}

enum Parser {
    static func parenDepth(_ s: String) -> Int {
        var d = 0; var q = false
        for ch in s {
            if ch == "\"" { q.toggle() }
            if q { continue }
            if ch == "(" { d += 1 } else if ch == ")" { d -= 1 }
        }
        return d
    }

    /// Split by &&, ||, & respecting quotes, carets and parentheses.
    static func splitChain(_ s: String) -> [(String, String)] {
        var res: [(String, String)] = []
        var cur = ""; var q = false; var depth = 0
        let c = Array(s); var i = 0
        while i < c.count {
            let ch = c[i]
            if ch == "\"" { q.toggle() }
            if !q {
                if ch == "^", i + 1 < c.count { cur.append("^"); cur.append(c[i + 1]); i += 2; continue }
                if ch == "(" { depth += 1 } else if ch == ")" { depth = max(0, depth - 1) }
                if depth == 0 {
                    if ch == "&" && i + 1 < c.count && c[i + 1] == "&" { res.append((cur, "&&")); cur = ""; i += 2; continue }
                    if ch == "|" && i + 1 < c.count && c[i + 1] == "|" { res.append((cur, "||")); cur = ""; i += 2; continue }
                    if ch == "&" { res.append((cur, "&")); cur = ""; i += 1; continue }
                }
            }
            cur.append(ch); i += 1
        }
        res.append((cur, ""))
        return res.map { ($0.0.trimmingCharacters(in: .whitespaces), $0.1) }.filter { !$0.0.isEmpty }
    }

    static func splitPipes(_ s: String) -> [String] {
        var res: [String] = []; var cur = ""; var q = false; var depth = 0
        let c = Array(s); var i = 0
        while i < c.count {
            let ch = c[i]
            if ch == "\"" { q.toggle() }
            if !q {
                if ch == "^", i + 1 < c.count { cur.append("^"); cur.append(c[i + 1]); i += 2; continue }
                if ch == "(" { depth += 1 } else if ch == ")" { depth = max(0, depth - 1) }
                if ch == "|" && depth == 0 { res.append(cur); cur = ""; i += 1; continue }
            }
            cur.append(ch); i += 1
        }
        res.append(cur)
        return res.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    struct Redir { var output: String?; var append = false; var input: String?; var errToNull = false; var errToOut = false }

    static func tokenize(_ s: String) -> ([String], Redir) {
        var tokens: [String] = []; var r = Redir()
        var cur = ""; var q = false; var has = false
        var pending: String? = nil
        let c = Array(s); var i = 0
        func flush() {
            guard has else { return }
            switch pending {
            case ">": r.output = cur; r.append = false
            case ">>": r.output = cur; r.append = true
            case "<": r.input = cur
            case "2>": if cur.lowercased() == "nul" { r.errToNull = true }
            default: tokens.append(cur)
            }
            pending = nil; cur = ""; has = false
        }
        while i < c.count {
            let ch = c[i]
            if ch == "\"" { q.toggle(); has = true; i += 1; continue }
            if !q {
                if ch == "^", i + 1 < c.count { cur.append(c[i + 1]); has = true; i += 2; continue }
                if ch == " " || ch == "\t" { flush(); i += 1; continue }
                if ch == "2" && !has && i + 1 < c.count && c[i + 1] == ">" {
                    if i + 3 < c.count && c[i + 2] == "&" && c[i + 3] == "1" { r.errToOut = true; i += 4; continue }
                    flush(); pending = "2>"; i += 2; continue
                }
                if ch == "1" && !has && i + 1 < c.count && c[i + 1] == ">" { i += 1; continue }
                if ch == ">" {
                    flush()
                    if i + 1 < c.count && c[i + 1] == ">" { pending = ">>"; i += 2 } else { pending = ">"; i += 1 }
                    continue
                }
                if ch == "<" { flush(); pending = "<"; i += 1; continue }
            }
            cur.append(ch); has = true; i += 1
        }
        flush()
        return (tokens, r)
    }
}
