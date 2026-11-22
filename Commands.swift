import SwiftUI
import UIKit
import Network
import CryptoKit
import Darwin

@MainActor
struct Ctx {
    let shell: Shell
    let args: [String]
    let stdin: String?
    let raw: String

    var fs: VirtualFS { shell.fs }
    var flags: Set<String> { Set(args.filter { $0.hasPrefix("/") || ($0.hasPrefix("-") && $0.count > 1) }.map { $0.lowercased() }) }
    var operands: [String] { args.filter { !$0.hasPrefix("/") } }
    func has(_ f: String) -> Bool { flags.contains { $0 == f || $0.hasPrefix(f + ":") } }

    /// Raw text after the command name with redirections removed (keeps punctuation and spacing).
    var rest: String {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("@") { s.removeFirst() }
        if let i = s.firstIndex(where: { $0 == " " || $0 == "." || $0 == "/" || $0 == "(" || $0 == ":" }) {
            s = String(s[i...])
            if s.hasPrefix(" ") { s.removeFirst() }
        } else { s = "" }
        return Ctx.stripRedirects(s)
    }

    static func stripRedirects(_ s: String) -> String {
        var out = ""; var q = false
        let c = Array(s); var i = 0
        while i < c.count {
            let ch = c[i]
            if ch == "\"" { q.toggle() }
            if !q && ch == "^" && i + 1 < c.count { out.append(c[i + 1]); i += 2; continue }
            if !q && (ch == ">" || ch == "<" || ((ch == "1" || ch == "2") && i + 1 < c.count && c[i + 1] == ">")) {
                if ch == "1" || ch == "2" { i += 1 }
                i += 1
                if i < c.count && c[i] == ">" { i += 1 }
                if i + 1 < c.count && c[i] == "&" { i += 2; continue }
                while i < c.count && c[i] == " " { i += 1 }
                var qq = false
                while i < c.count && (qq || c[i] != " ") { if c[i] == "\"" { qq.toggle() }; i += 1 }
                while out.hasSuffix(" ") { out.removeLast() }
                continue
            }
            out.append(ch); i += 1
        }
        return out
    }
}

typealias Cmd = @MainActor (Ctx) async -> CmdResult

@MainActor
enum Commands {
    static let table: [String: Cmd] = {
        var t: [String: Cmd] = [
            "help": help, "cls": { c in c.shell.clear(); return CmdResult() },
            "echo": echo, "set": set, "setx": setx, "cd": cd, "chdir": cd, "pushd": pushd, "popd": popd,
            "dir": dir, "ls": dir, "md": mkdir, "mkdir": mkdir, "rd": rmdir, "rmdir": rmdir,
            "del": del, "erase": del, "copy": copy, "xcopy": xcopy, "robocopy": xcopy, "move": move,
            "ren": ren, "rename": ren, "type": type, "more": more, "tree": tree, "attrib": attrib,
            "find": find, "findstr": findstr, "sort": sort, "where": whereCmd, "fc": fc, "comp": fc,
            "title": title, "color": color, "prompt": prompt, "ver": ver, "vol": vol, "date": date,
            "time": time, "whoami": whoami, "hostname": hostname, "systeminfo": systeminfo,
            "tasklist": tasklist, "taskkill": taskkill, "ipconfig": ipconfig, "ping": ping,
            "curl": curl, "wget": curl, "nslookup": nslookup, "netstat": netstat, "getmac": getmac,
            "exit": exit, "pause": pause, "timeout": timeout, "start": start, "doskey": doskey,
            "history": historyCmd, "if": ifCmd, "for": forCmd, "call": call, "rem": { _ in CmdResult() },
            "break": { _ in CmdResult() }, "cmd": cmd, "certutil": certutil, "clip": clip,
            "chcp": { _ in CmdResult(out: "Active code page: 65001") }, "path": path, "verify": verify,
            "fsutil": fsutil, "mklink": mklink, "replace": copy, "touch": touch, "cat": type,
            "pwd": { c in CmdResult(out: c.shell.cwdPath) }, "clear": { c in c.shell.clear(); return CmdResult() },
            "wmic": wmic, "shutdown": shutdown, "assoc": assoc, "ftype": { _ in CmdResult(out: "txtfile=%SystemRoot%\\system32\\NOTEPAD.EXE %1") },
            "label": { _ in CmdResult(out: "Volume label is T0RANT") }, "tar": tar, "powershell": powershell,
            "pwsh": powershell, "notepad": notepad, "edit": notepad, "calc": calc, "uptime": uptime,
            "tracert": tracert, "arp": { _ in CmdResult(out: "No ARP Entries Found.") },
            "route": { c in CmdResult(out: "IPv4 Route Table\n" + String(repeating: "=", count: 60) + "\n" + ipList().map { "  0.0.0.0  0.0.0.0  On-link  \($0.1)" }.joined(separator: "\n")) },
            "sfc": { _ in CmdResult(out: "Windows Resource Protection did not find any integrity violations.") },
            "chkdsk": chkdsk, "diskpart": { _ in .error("DiskPart requires direct disk access, which iOS does not allow.") },
            "reg": reg, "sc": { _ in CmdResult(out: "[SC] EnumQueryServicesStatus: 0 services (iOS sandbox).") },
            "net": net, "schtasks": { _ in CmdResult(out: "INFO: There are no scheduled tasks presently available.") },
            "driverquery": { _ in CmdResult(out: "Module Name  Display Name           Driver Type\n============ ====================== ===========\nt0rantfs     t0rant Virtual FS      File System") },
            "openfiles": { _ in CmdResult(out: "INFO: No shared open files found.") },
            "gpresult": { _ in CmdResult(out: "INFO: The user \"t0rant\" does not have RSOP data.") },
            "mode": { _ in CmdResult(out: "Status for device CON:\n----------------------\n    Lines:          9001\n    Columns:        80\n    Code page:      65001") },
            "subst": { _ in CmdResult() }, "endlocal": { _ in CmdResult() }, "setlocal": { _ in CmdResult() },
            "goto": { _ in CmdResult() }, "shift": { _ in CmdResult() }, "choice": choice,
            "base64": base64, "head": head, "tail": tail, "wc": wc, "grep": findstr, "cp": copy,
            "mv": move, "rm": del, "rev": { c in CmdResult(out: inputText(c).components(separatedBy: "\n").map { String($0.reversed()) }.joined(separator: "\n")) },
        ]
        t.merge(Tools.table) { a, _ in a }
        t.merge(PythonCommands.table) { _, b in b }
        t.merge(NodeCommands.table) { _, b in b }
        t.merge(Extra.table) { _, b in b }
        return t
    }()

    static let helpText: [String: String] = [
        "dir": "Displays a list of files and subdirectories in a directory.\n\nDIR [drive:][path][filename] [/A[[:]attributes]] [/B] [/S] [/W] [/O[[:]sortorder]]\n\n  /A  Displays files with specified attributes (D, H, -D).\n  /B  Uses bare format.\n  /S  Displays files in specified directory and all subdirectories.\n  /W  Uses wide list format.\n  /O  List by files in sorted order (N S D E, prefix - to reverse).",
        "cd": "Displays the name of or changes the current directory.\n\nCHDIR [/D] [drive:][path]\nCHDIR [..]\nCD [/D] [drive:][path]\nCD [..]",
        "echo": "Displays messages, or turns command-echoing on or off.\n\n  ECHO [ON | OFF]\n  ECHO [message]",
        "set": "Displays, sets, or removes cmd.exe environment variables.\n\nSET [variable=[string]]\nSET /A expression\nSET /P variable=[promptString]",
        "copy": "Copies one or more files to another location.\n\nCOPY [/Y] source [+ source2...] destination",
        "del": "Deletes one or more files.\n\nDEL [/P] [/F] [/S] [/Q] names",
        "for": "Runs a specified command for each file in a set of files.\n\nFOR %variable IN (set) DO command\nFOR /L %variable IN (start,step,end) DO command\nFOR /F [\"options\"] %variable IN (file-set | \"string\" | 'command') DO command\nFOR /D %variable IN (set) DO command\nFOR /R [path] %variable IN (set) DO command",
        "if": "Performs conditional processing in batch programs.\n\nIF [NOT] ERRORLEVEL number command\nIF [/I] [NOT] string1==string2 command\nIF [NOT] EXIST filename command\nIF [NOT] DEFINED variable command\nIF [/I] string1 EQU|NEQ|LSS|LEQ|GTR|GEQ string2 command\n  ... ( command ) ELSE ( command )",
        "ping": "Usage: ping [-n count] [-t] target_name\n\nNote: iOS does not allow raw ICMP, so t0rant measures TCP connect round-trip time (port 443, then 80).",
        "curl": "Usage: curl [options...] <url>\n  -o <file>   Write to file\n  -O          Write to file named like remote file\n  -I          Show headers only\n  -i          Include headers\n  -X <method> Request method\n  -d <data>   POST data\n  -H <header> Extra header\n  -s          Silent",
    ]

    // MARK: - helpers
    static func inputText(_ c: Ctx) -> String {
        let files = c.operands
        if files.isEmpty { return c.stdin ?? "" }
        return files.compactMap { c.fs.read(c.fs.resolve($0, cwd: c.shell.cwd)) }.joined(separator: "\n")
    }
    static func fmtNum(_ n: Int64) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal; f.groupingSeparator = ","
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
    static func dirDate(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "MM/dd/yyyy  hh:mm a"; return f.string(from: d)
    }
    static func notFound() -> CmdResult { .error("The system cannot find the file specified.") }
    static func pathNotFound() -> CmdResult { .error("The system cannot find the path specified.") }
    static func syntax() -> CmdResult { .error("The syntax of the command is incorrect.") }
    static func pad(_ s: String, _ n: Int, left: Bool = false) -> String {
        if s.count >= n { return s }
        let p = String(repeating: " ", count: n - s.count)
        return left ? p + s : s + p
    }

    // MARK: - basic
    static func help(_ c: Ctx) -> CmdResult {
        if let n = c.operands.first { return CmdResult(out: helpText[n.lowercased()] ?? "This command is not supported by the help utility.  Try \"\(n) /?\".") }
        let list: [(String, String)] = [
            ("ATTRIB", "Displays or changes file attributes."), ("CALL", "Calls one batch program from another."),
            ("CD", "Displays the name of or changes the current directory."), ("CERTUTIL", "Hashes files (-hashfile) and base64 encodes/decodes."),
            ("CHCP", "Displays the active code page number."), ("CHKDSK", "Checks a disk and displays a status report."),
            ("CHOICE", "Prompts the user to select one item from a list."), ("CLIP", "Copies input to the iOS clipboard."),
            ("CLS", "Clears the screen."), ("CMD", "Starts a new instance of the command interpreter."),
            ("COLOR", "Sets the default console foreground and background colors."), ("COPY", "Copies one or more files to another location."),
            ("CURL", "Transfers data from or to a server (real HTTP/HTTPS)."), ("DATE", "Displays the date."),
            ("DEL", "Deletes one or more files."), ("DIR", "Displays a list of files and subdirectories in a directory."),
            ("DOSKEY", "Edits command lines, recalls commands, and creates macros."), ("ECHO", "Displays messages, or turns command echoing on or off."),
            ("EXIT", "Quits the current batch script or clears the session."), ("FC", "Compares two files and displays the differences."),
            ("FIND", "Searches for a text string in a file or files."), ("FINDSTR", "Searches for strings (with regex) in files."),
            ("FOR", "Runs a specified command for each file in a set of files."), ("GETMAC", "Displays network adapter information."),
            ("GOTO", "Directs the command interpreter to a labeled line in a batch program."), ("HOSTNAME", "Prints the name of the current host."),
            ("IF", "Performs conditional processing in batch programs."), ("IPCONFIG", "Displays real network interface configuration."),
            ("MD", "Creates a directory."), ("MORE", "Displays output."), ("MOVE", "Moves one or more files from one directory to another."),
            ("NET", "Network and user information."), ("NETSTAT", "Displays network statistics."), ("NOTEPAD", "Writes text to a file: NOTEPAD file text..."),
            ("NSLOOKUP", "Resolves host names using real DNS."), ("PATH", "Displays or sets a search path."),
            ("PAUSE", "Suspends processing of a batch file."), ("PING", "Measures round-trip time to a host."),
            ("POPD", "Restores the previous directory saved by PUSHD."), ("POWERSHELL", "Runs a small subset of PowerShell cmdlets."),
            ("PROMPT", "Changes the command prompt."), ("PUSHD", "Saves the current directory then changes it."),
            ("RD", "Removes a directory."), ("REG", "Registry operations (virtual)."), ("REM", "Records comments in batch files."),
            ("REN", "Renames a file or files."), ("SET", "Displays, sets, or removes environment variables (/A, /P)."),
            ("SETX", "Sets environment variables permanently."), ("SORT", "Sorts input."), ("START", "Opens a URL or file."),
            ("SYSTEMINFO", "Displays machine specific properties and configuration."), ("TAR", "Lists or creates zip archives."),
            ("TASKLIST", "Displays all currently running tasks."), ("TIME", "Displays the system time."),
            ("TIMEOUT", "Pauses the command processor for the specified number of seconds."), ("TITLE", "Sets the window title."),
            ("TRACERT", "Traces route to a host (TCP based)."), ("TREE", "Graphically displays the directory structure."),
            ("TYPE", "Displays the contents of a text file."), ("VER", "Displays the version."), ("VERIFY", "Tells cmd whether to verify writes."),
            ("VOL", "Displays a disk volume label and serial number."), ("WHERE", "Displays the location of files that match a pattern."),
            ("WHOAMI", "Displays user information."), ("WMIC", "Basic WMI queries (os, cpu, logicaldisk)."),
            ("XCOPY", "Copies files and directory trees."),
            ("PYTHON", "Embedded Python 3.13 (REPL, -c, -m, script.py)."), ("PIP", "Installs pure-Python packages."),
            ("PKG", "Lists pre-installed tools and Python packages."),
            ("NODE", "Embedded Node.js 18 (REPL, -e, -p, script.js)."), ("NPM", "Node package manager (install, run, init, ls...)."),
            ("NPX", "Runs a package binary, installing it if needed."),
            ("PORTSCAN", "TCP connect port scanner (alias NMAP)."), ("NC", "Netcat: send/receive over TCP or TLS."),
            ("WHOIS", "Domain/IP registration lookup."), ("DIG", "DNS records via DNS-over-HTTPS."),
            ("SUBENUM", "Passive subdomain enumeration (crt.sh)."), ("HEADERS", "HTTP headers + security audit."),
            ("SSLCHECK", "TLS certificate chain check."), ("DIRBUST", "Common web path discovery."),
            ("TECHDETECT", "Guess a site's technologies."), ("BANNER", "Grab a service banner."),
            ("GEOIP / MYIP", "IP geolocation / your public IP."), ("HASH / HASHID", "Hash text or files / identify hash types."),
            ("JWT", "Decode JSON Web Tokens."), ("HEX / ROT13 / URLENCODE / URLDECODE / PASSGEN", "Encoding helpers."),
        ]
        return CmdResult(out: "For more information on a specific command, type HELP command-name\n" +
                         list.map { pad($0.0, 15) + $0.1 }.joined(separator: "\n") +
                         "\n\nAlso: cat ls ll cp mv rm pwd grep head tail wc touch base64 rev clear which alias env export du df stat file\n      uniq cut tr seq sleep tee nl fold column upper lower json jq zip unzip cal weather speedtest battery screen\n      uuid random epoch bin ascii md5sum sha256sum diff nano vim backup trash history replace-text lines du-top\nOperators: |  >  >>  <  2>nul  2>&1  &  &&  ||  ( )   Variables: %VAR%  %VAR:~0,3%  %VAR:a=b%")
    }

    static func echo(_ c: Ctx) -> CmdResult {
        let r = c.rest
        let t = r.trimmingCharacters(in: .whitespaces).lowercased()
        if r.isEmpty { return CmdResult(out: "ECHO is \(c.shell.echoOn ? "on" : "off").") }
        if t == "off" { c.shell.echoOn = false; return CmdResult() }
        if t == "on" { c.shell.echoOn = true; return CmdResult() }
        if let f = r.first, ".:(/".contains(f), raw0(c) { return CmdResult(out: String(r.dropFirst())) }
        return CmdResult(out: r)
    }
    private static func raw0(_ c: Ctx) -> Bool {
        var s = c.raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("@") { s.removeFirst() }
        guard s.count > 4 else { return false }
        return s[s.index(s.startIndex, offsetBy: 4)] != " "
    }

    static func set(_ c: Ctx) async -> CmdResult {
        let r = c.rest
        let low = r.lowercased()
        if low.hasPrefix("/a") {
            let expr = String(r.dropFirst(2)).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\"", with: "")
            do {
                var last: Int64 = 0
                for part in expr.split(separator: ",") {
                    var ar = Arith(shell: c.shell)
                    last = try ar.evaluate(String(part))
                }
                let interactive = !c.shell.busy || true
                return CmdResult(out: interactive && !expr.contains("=") ? String(last) : "")
            } catch {
                return .error("Missing operand.")
            }
        }
        if low.hasPrefix("/p") {
            let body = String(r.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            guard let eq = body.firstIndex(of: "=") else { return syntax() }
            let name = String(body[..<eq]).uppercased()
            let promptStr = String(body[body.index(after: eq)...])
            let val = await InputPrompt.ask(promptStr)
            c.shell.env[name] = val
            return CmdResult()
        }
        var body = r.trimmingCharacters(in: .whitespaces)
        if body.hasPrefix("\"") && body.hasSuffix("\"") && body.count >= 2 { body = String(body.dropFirst().dropLast()) }
        if body.isEmpty || !body.contains("=") {
            let pre = body.uppercased()
            let items = c.shell.env.filter { pre.isEmpty || $0.key.hasPrefix(pre) }.sorted { $0.key < $1.key }
            if items.isEmpty { return .error("Environment variable \(body) not defined") }
            return CmdResult(out: items.map { "\($0.key)=\($0.value)" }.joined(separator: "\n"))
        }
        let eq = body.firstIndex(of: "=")!
        let name = String(body[..<eq]).trimmingCharacters(in: .whitespaces).uppercased()
        let val = String(body[body.index(after: eq)...])
        if val.isEmpty { c.shell.env.removeValue(forKey: name) } else { c.shell.env[name] = val }
        if name == "PROMPT" { c.shell.promptFormat = val.isEmpty ? "$P$G" : val }
        return CmdResult()
    }

    static func setx(_ c: Ctx) -> CmdResult {
        let o = c.operands
        guard o.count >= 2 else { return .error("ERROR: Invalid syntax. Default option is not allowed more than '2' time(s).") }
        var saved = UserDefaults.standard.dictionary(forKey: "setx") as? [String: String] ?? [:]
        saved[o[0].uppercased()] = o[1]
        UserDefaults.standard.set(saved, forKey: "setx")
        c.shell.env[o[0].uppercased()] = o[1]
        return CmdResult(out: "\nSUCCESS: Specified value was saved.")
    }

    static func cd(_ c: Ctx) -> CmdResult {
        var target = c.rest.trimmingCharacters(in: .whitespaces)
        if target.lowercased().hasPrefix("/d") { target = String(target.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
        target = target.replacingOccurrences(of: "\"", with: "")
        if target.isEmpty { return CmdResult(out: c.shell.cwdPath) }
        if target.lowercased() == "c:" { return CmdResult(out: c.shell.cwdPath) }
        let comps = c.fs.components(target, cwd: c.shell.cwd)
        guard c.fs.isDir(c.fs.url(comps)) else { return pathNotFound() }
        c.shell.cwd = comps
        return CmdResult()
    }

    static func pushd(_ c: Ctx) -> CmdResult {
        let saved = c.shell.cwd
        let r = cd(c)
        if r.code == 0 && !c.operands.isEmpty { c.shell.dirStack.append(saved) }
        return r.out.isEmpty || !c.operands.isEmpty ? r : CmdResult()
    }
    static func popd(_ c: Ctx) -> CmdResult {
        if let d = c.shell.dirStack.popLast() { c.shell.cwd = d }
        return CmdResult()
    }

    // MARK: - files
    static func dir(_ c: Ctx) -> CmdResult {
        let bare = c.has("/b"), wide = c.has("/w"), recurse = c.has("/s")
        var showHidden = false, onlyDirs = false, onlyFiles = false
        if let a = c.flags.first(where: { $0.hasPrefix("/a") }) {
            let v = a.dropFirst(2).replacingOccurrences(of: ":", with: "")
            showHidden = true
            if v == "d" { onlyDirs = true } else if v == "-d" { onlyFiles = true } else if v == "h" { showHidden = true }
        }
        let order = c.flags.first(where: { $0.hasPrefix("/o") }).map { String($0.dropFirst(2)).replacingOccurrences(of: ":", with: "") } ?? "n"
        let target = c.operands.first ?? "."
        var base = c.fs.resolve(target, cwd: c.shell.cwd)
        var pattern = "*"
        if !c.fs.isDir(base) {
            pattern = base.lastPathComponent
            base = base.deletingLastPathComponent()
            if !(pattern.contains("*") || pattern.contains("?")) && !c.fs.exists(base.appendingPathComponent(pattern)) {
                return CmdResult(out: bare ? "" : " Volume in drive C is T0RANT\n Volume Serial Number is 7072-414E\n\n Directory of \(c.fs.winPath(base))\n", err: "File Not Found", code: 1)
            }
        }
        if pattern == "*.*" { pattern = "*" }
        var out: [String] = []
        if !bare { out += [" Volume in drive C is T0RANT", " Volume Serial Number is 7072-414E"] }
        var totalFiles = 0, totalDirs = 0
        var totalBytes: Int64 = 0

        func walk(_ dir: URL) {
            // Very large trees would freeze the screen long enough for iOS to kill the app.
            if totalFiles + totalDirs > 50_000 || c.shell.cancelled { return }
            guard var items = c.fs.list(dir) else { return }
            items = items.filter { VirtualFS.wildcard(pattern, $0.name) && (showHidden || !$0.hidden) }
            if onlyDirs { items = items.filter { $0.isDir } }
            if onlyFiles { items = items.filter { !$0.isDir } }
            let rev = order.hasPrefix("-")
            let key = order.replacingOccurrences(of: "-", with: "")
            items.sort { a, b in
                var r: Bool
                switch key.first {
                case "s": r = a.size < b.size
                case "d": r = a.modified < b.modified
                case "e": r = a.url.pathExtension.lowercased() < b.url.pathExtension.lowercased()
                case "g": r = a.isDir && !b.isDir
                default: r = (a.isDir != b.isDir) ? a.isDir : a.name.lowercased() < b.name.lowercased()
                }
                return rev ? !r : r
            }
            var files = 0, dirs = 0
            var bytes: Int64 = 0
            if bare {
                for e in items { out.append(recurse ? c.fs.winPath(e.url) : e.name) }
            } else {
                out += ["", " Directory of \(c.fs.winPath(dir))", ""]
                let isRoot = dir.standardizedFileURL.path == c.fs.root.standardizedFileURL.path
                if !isRoot && pattern == "*" && !onlyFiles {
                    let d = c.fs.entry(dir)?.modified ?? Date()
                    out.append("\(dirDate(d))    <DIR>          .")
                    out.append("\(dirDate(d))    <DIR>          ..")
                    dirs += 2
                }
                if wide {
                    let names = items.map { $0.isDir ? "[\($0.name)]" : $0.name }
                    var row = ""
                    for (i, n) in names.enumerated() {
                        row += pad(n, 18)
                        if i % 4 == 3 { out.append(row); row = "" }
                    }
                    if !row.isEmpty { out.append(row) }
                } else {
                    for e in items {
                        if e.isDir { out.append("\(dirDate(e.modified))    <DIR>          \(e.name)") }
                        else { out.append("\(dirDate(e.modified)) \(pad(fmtNum(Int64(e.size)), 17, left: true)) \(e.name)") }
                    }
                }
                for e in items { if e.isDir { dirs += 1 } else { files += 1; bytes += Int64(e.size) } }
                out.append("\(pad(String(files), 16, left: true)) File(s) \(pad(fmtNum(bytes), 14, left: true)) bytes")
                if !recurse { out.append("\(pad(String(dirs), 16, left: true)) Dir(s)  \(pad(fmtNum(c.fs.freeSpace()), 14, left: true)) bytes free") }
            }
            totalFiles += files; totalDirs += dirs; totalBytes += bytes
            if recurse {
                for sub in (c.fs.list(dir) ?? []).filter({ $0.isDir }).sorted(by: { $0.name.lowercased() < $1.name.lowercased() }) {
                    walk(sub.url)
                }
            }
        }
        walk(base)
        if recurse && !bare {
            out += ["", "     Total Files Listed:", "\(pad(String(totalFiles), 16, left: true)) File(s) \(pad(fmtNum(totalBytes), 14, left: true)) bytes",
                    "\(pad(String(totalDirs), 16, left: true)) Dir(s)  \(pad(fmtNum(c.fs.freeSpace()), 14, left: true)) bytes free"]
        }
        return CmdResult(out: out.joined(separator: "\n"))
    }

    static func mkdir(_ c: Ctx) -> CmdResult {
        let dirs = c.operands.filter { !$0.hasPrefix("-") }
        guard !dirs.isEmpty else { return syntax() }
        let quietExisting = c.args.contains("-p")
        var err = ""
        for p in dirs {
            let u = c.fs.resolve(p, cwd: c.shell.cwd)
            if c.fs.exists(u) { if quietExisting { continue }; err += "A subdirectory or file \(p) already exists.\n"; continue }
            do { try c.fs.fm.createDirectory(at: u, withIntermediateDirectories: true) }
            catch { err += "Access is denied.\n" }
        }
        return CmdResult(out: "", err: err, code: err.isEmpty ? 0 : 1)
    }

    static func rmdir(_ c: Ctx) async -> CmdResult {
        guard !c.operands.isEmpty else { return syntax() }
        let recursive = c.has("/s"), quiet = c.has("/q")
        for p in c.operands {
            let u = c.fs.resolve(p, cwd: c.shell.cwd)
            guard c.fs.isDir(u) else { return pathNotFound() }
            if u.standardizedFileURL.path == c.fs.root.standardizedFileURL.path { return .error("Access is denied.") }
            if !recursive, let items = c.fs.list(u), !items.isEmpty { return .error("The directory is not empty.") }
            if recursive && !quiet {
                let a = await InputPrompt.ask("\(p), Are you sure (Y/N)? ")
                if !a.lowercased().hasPrefix("y") { continue }
            }
            do { try c.fs.fm.removeItem(at: u) } catch { return .error("Access is denied.") }
            if c.fs.components(p, cwd: c.shell.cwd).starts(with: c.shell.cwd) && c.shell.cwd.count >= c.fs.components(p, cwd: c.shell.cwd).count {
                c.shell.cwd = Array(c.fs.components(p, cwd: c.shell.cwd).dropLast())
            }
        }
        return CmdResult()
    }

    static func del(_ c: Ctx) async -> CmdResult {
        guard !c.operands.isEmpty else { return syntax() }
        let recurse = c.has("/s"), quiet = c.has("/q")
        let unixRecursive = c.args.contains { $0 == "-r" || $0 == "-rf" || $0 == "-fr" }
        var out: [String] = []
        for p in c.operands where !p.hasPrefix("-") {
            var targets = c.fs.glob(p, cwd: c.shell.cwd)
            let u = c.fs.resolve(p, cwd: c.shell.cwd)
            if targets.isEmpty { return CmdResult(out: "", err: "Could Not Find \(c.fs.winPath(u))", code: 1) }
            if targets.count == 1, c.fs.isDir(targets[0]) {
                if unixRecursive { try? c.fs.fm.removeItem(at: targets[0]); continue }
                if !quiet {
                    let a = await InputPrompt.ask("\(c.fs.winPath(targets[0]))\\*, Are you sure (Y/N)? ")
                    if !a.lowercased().hasPrefix("y") { continue }
                }
                targets = (c.fs.list(targets[0]) ?? []).filter { !$0.isDir }.map { $0.url }
            }
            if recurse {
                let pat = u.lastPathComponent
                if let en = c.fs.fm.enumerator(at: u.deletingLastPathComponent(), includingPropertiesForKeys: nil) {
                    for case let f as URL in en where !c.fs.isDir(f) && VirtualFS.wildcard(pat, f.lastPathComponent) {
                        targets.append(f)
                    }
                }
            }
            for t in Set(targets) where !c.fs.isDir(t) {
                do { try c.fs.fm.removeItem(at: t); if recurse { out.append("Deleted file - \(c.fs.winPath(t))") } }
                catch { out.append("Access is denied - \(c.fs.winPath(t))") }
            }
        }
        return CmdResult(out: out.joined(separator: "\n"))
    }

    static func copyItem(_ c: Ctx, _ src: URL, _ dst: URL) -> Bool {
        if c.fs.exists(dst) { try? c.fs.fm.removeItem(at: dst) }
        try? c.fs.fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? c.fs.fm.copyItem(at: src, to: dst)) != nil
    }

    static func copy(_ c: Ctx) -> CmdResult {
        let ops = c.operands.filter { !$0.hasPrefix("-") }
        guard let first = ops.first else { return syntax() }
        // COPY a+b dest  (concatenate)
        if first.contains("+") || (ops.count > 2 && ops.dropLast().contains("+")) {
            let joined = ops.dropLast().joined(separator: " ")
            let srcs = joined.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard let firstSrc = srcs.first else { return syntax() }
            let dest = ops.count > 1 ? (ops.last ?? firstSrc) : firstSrc
            let data = srcs.compactMap { c.fs.read(c.fs.resolve($0, cwd: c.shell.cwd)) }.joined()
            c.fs.write(c.fs.resolve(dest, cwd: c.shell.cwd), data)
            return CmdResult(out: srcs.joined(separator: "\n") + "\n        1 file(s) copied.")
        }
        if first.lowercased() == "con" {
            return CmdResult(out: "", err: "Interactive COPY CON is not supported; use NOTEPAD file text or ECHO text > file.", code: 1)
        }
        let srcs = c.fs.glob(first, cwd: c.shell.cwd).filter { !c.fs.isDir($0) || ops.count < 2 }
        let expanded: [URL] = srcs.flatMap { u -> [URL] in
            c.fs.isDir(u) ? (c.fs.list(u) ?? []).filter { !$0.isDir }.map { $0.url } : [u]
        }
        guard !expanded.isEmpty else { return notFound() }
        let destArg = ops.count > 1 ? ops[1] : "."
        let dest = c.fs.resolve(destArg, cwd: c.shell.cwd)
        var n = 0
        for s in expanded {
            let d = c.fs.isDir(dest) ? dest.appendingPathComponent(s.lastPathComponent) : dest
            if d.standardizedFileURL == s.standardizedFileURL { return .error("The file cannot be copied onto itself.\n        0 file(s) copied.") }
            if copyItem(c, s, d) { n += 1 }
        }
        let names = expanded.count > 1 ? expanded.map { c.fs.winPath($0) }.joined(separator: "\n") + "\n" : ""
        return CmdResult(out: names + "        \(n) file(s) copied.")
    }

    static func xcopy(_ c: Ctx) -> CmdResult {
        let ops = c.operands
        guard ops.count >= 1 else { return .error("Invalid number of parameters") }
        let src = c.fs.resolve(ops[0], cwd: c.shell.cwd)
        let dst = c.fs.resolve(ops.count > 1 ? ops[1] : ".", cwd: c.shell.cwd)
        guard c.fs.exists(src) else { return notFound() }
        var n = 0
        var lines: [String] = []
        if c.fs.isDir(src) {
            let withSubs = c.has("/s") || c.has("/e") || c.has("/mir")
            try? c.fs.fm.createDirectory(at: dst, withIntermediateDirectories: true)
            if let en = c.fs.fm.enumerator(at: src, includingPropertiesForKeys: nil) {
                for case let f as URL in en {
                    let rel = f.standardizedFileURL.path.replacingOccurrences(of: src.standardizedFileURL.path + "/", with: "")
                    if !withSubs && rel.contains("/") { continue }
                    let target = dst.appendingPathComponent(rel)
                    if c.fs.isDir(f) { try? c.fs.fm.createDirectory(at: target, withIntermediateDirectories: true); continue }
                    if copyItem(c, f, target) { n += 1; lines.append(c.fs.winPath(f)) }
                }
            }
        } else {
            let t = c.fs.isDir(dst) ? dst.appendingPathComponent(src.lastPathComponent) : dst
            if copyItem(c, src, t) { n = 1; lines.append(c.fs.winPath(src)) }
        }
        lines.append("\(n) File(s) copied")
        return CmdResult(out: lines.joined(separator: "\n"))
    }

    static func move(_ c: Ctx) -> CmdResult {
        let ops = c.operands.filter { !$0.hasPrefix("-") }
        guard ops.count >= 2 else { return syntax() }
        let srcs = c.fs.glob(ops[0], cwd: c.shell.cwd)
        guard !srcs.isEmpty else { return notFound() }
        let dest = c.fs.resolve(ops[1], cwd: c.shell.cwd)
        var n = 0
        for s in srcs {
            let d = c.fs.isDir(dest) ? dest.appendingPathComponent(s.lastPathComponent) : dest
            if c.fs.exists(d) && d.standardizedFileURL != s.standardizedFileURL { try? c.fs.fm.removeItem(at: d) }
            if (try? c.fs.fm.moveItem(at: s, to: d)) != nil { n += 1 }
        }
        let wasDir = srcs.count == 1 && c.fs.isDir(dest.appendingPathComponent(srcs[0].lastPathComponent)) == false && c.fs.isDir(dest)
        return CmdResult(out: wasDir ? "        1 dir(s) moved." : "        \(n) file(s) moved.")
    }

    static func ren(_ c: Ctx) -> CmdResult {
        let ops = c.operands
        guard ops.count == 2 else { return syntax() }
        let srcs = c.fs.glob(ops[0], cwd: c.shell.cwd)
        guard !srcs.isEmpty else { return notFound() }
        for s in srcs {
            var newName = ops[1]
            if newName.contains("*") {
                // e.g. ren *.txt *.bak
                let base = s.deletingPathExtension().lastPathComponent
                let ext = s.pathExtension
                newName = newName.replacingOccurrences(of: "*.", with: base + ".").replacingOccurrences(of: ".*", with: "." + ext)
                newName = newName.replacingOccurrences(of: "*", with: base)
            }
            let d = s.deletingLastPathComponent().appendingPathComponent(newName)
            if c.fs.exists(d) && d.path.lowercased() != s.path.lowercased() { return .error("A duplicate file name exists, or the file\ncannot be found.") }
            do { try c.fs.fm.moveItem(at: s, to: d) } catch { return .error("Access is denied.") }
        }
        return CmdResult()
    }

    static func type(_ c: Ctx) -> CmdResult {
        guard !c.operands.isEmpty else { return c.stdin.map { CmdResult(out: $0) } ?? syntax() }
        var out: [String] = []
        var err = ""
        let multi = c.operands.count > 1 || c.operands.contains { $0.contains("*") }
        for p in c.operands {
            let files = c.fs.glob(p, cwd: c.shell.cwd)
            if files.isEmpty { err += "The system cannot find the file specified.\n"; continue }
            for f in files {
                if c.fs.isDir(f) { err += "Access is denied.\n"; continue }
                if multi { out.append("\n\(p)\n\n") }
                out.append(c.fs.read(f) ?? "")
            }
        }
        var s = out.joined()
        if s.hasSuffix("\n") { s.removeLast() }
        return CmdResult(out: s, err: err, code: err.isEmpty ? 0 : 1)
    }

    static func more(_ c: Ctx) -> CmdResult { CmdResult(out: inputText(c)) }

    static func tree(_ c: Ctx) -> CmdResult {
        let showFiles = c.has("/f"), ascii = c.has("/a")
        let start = c.fs.resolve(c.operands.first ?? ".", cwd: c.shell.cwd)
        guard c.fs.isDir(start) else { return .error("Invalid path - \(c.operands.first ?? "")\nNo subfolders exist") }
        var out = ["Folder PATH listing for volume T0RANT", "Volume serial number is 7072-414E", c.fs.winPath(start)]
        let (tee, last, bar, sp) = ascii ? ("+---", "\\---", "|   ", "    ") : ("├───", "└───", "│   ", "    ")
        var count = 0
        func walk(_ u: URL, _ prefix: String) {
            count += 1; if count > 5000 { return }
            let items = (c.fs.list(u) ?? []).filter { !$0.hidden }.sorted { $0.name.lowercased() < $1.name.lowercased() }
            let dirs = items.filter { $0.isDir }
            if showFiles {
                for f in items where !f.isDir { out.append(prefix + (dirs.isEmpty ? sp : bar) + f.name) }
                if items.contains(where: { !$0.isDir }) { out.append(prefix + (dirs.isEmpty ? "" : bar)) }
            }
            for (i, d) in dirs.enumerated() {
                let isLast = i == dirs.count - 1
                out.append(prefix + (isLast ? last : tee) + d.name)
                walk(d.url, prefix + (isLast ? sp : bar))
            }
        }
        walk(start, "")
        if out.count == 3 { out.append("No subfolders exist") }
        return CmdResult(out: out.joined(separator: "\n"))
    }

    static func attrib(_ c: Ctx) -> CmdResult {
        let target = c.operands.first ?? "*"
        let files = c.fs.glob(target.contains("*") || c.fs.isDir(c.fs.resolve(target, cwd: c.shell.cwd)) == false ? target : target + "\\*", cwd: c.shell.cwd)
        if c.args.contains(where: { $0 == "+r" || $0 == "+R" || $0 == "-r" || $0 == "-R" }) {
            let ro = c.args.contains { $0.lowercased() == "+r" }
            for f in files { try? c.fs.fm.setAttributes([.posixPermissions: ro ? 0o444 : 0o644], ofItemAtPath: f.path) }
            return CmdResult()
        }
        let out = files.compactMap { c.fs.entry($0) }.map { e in
            "\(e.isDir ? " " : "A")   \(e.hidden ? "H" : " ")\(e.readOnly ? "R" : " ")        \(c.fs.winPath(e.url))"
        }
        return files.isEmpty ? CmdResult(out: "File not found - \(target)") : CmdResult(out: out.joined(separator: "\n"))
    }

    static func find(_ c: Ctx) -> CmdResult {
        let ops = c.operands
        guard let needle = ops.first else { return .error("FIND: Parameter format not correct") }
        let ci = c.has("/i"), invert = c.has("/v"), count = c.has("/c"), num = c.has("/n")
        var out: [String] = []
        func scan(_ text: String, header: String?) {
            let lines = text.components(separatedBy: "\n")
            var hits = 0
            var hitLines: [String] = []
            for (i, l) in lines.enumerated() {
                let m = ci ? l.lowercased().contains(needle.lowercased()) : l.contains(needle)
                if m != invert { hits += 1; hitLines.append(num ? "[\(i + 1)]\(l)" : l) }
            }
            if let h = header { out.append(count ? "---------- \(h.uppercased()): \(hits)" : "\n---------- \(h.uppercased())") }
            else if count { out.append(String(hits)) }
            if !count { out += hitLines }
        }
        let files = Array(ops.dropFirst())
        if files.isEmpty { scan(c.stdin ?? "", header: nil) }
        else {
            for f in files {
                for u in c.fs.glob(f, cwd: c.shell.cwd) { scan(c.fs.read(u) ?? "", header: u.lastPathComponent) }
            }
        }
        var res = CmdResult(out: out.joined(separator: "\n"))
        if out.isEmpty || (!count && out.allSatisfy { $0.hasPrefix("\n----") }) { res.code = 1 }
        return res
    }

    static func findstr(_ c: Ctx) -> CmdResult {
        let ci = c.has("/i") || c.args.contains("-i"), invert = c.has("/v") || c.args.contains("-v")
        let num = c.has("/n") || c.args.contains("-n"), literal = c.has("/l"), recurse = c.has("/s")
        let onlyNames = c.has("/m"), exact = c.has("/x")
        var ops = c.operands.filter { !$0.hasPrefix("-") }
        var patterns: [String] = []
        if let cflag = c.args.first(where: { $0.lowercased().hasPrefix("/c:") }) { patterns = [String(cflag.dropFirst(3))] }
        else if !ops.isEmpty { patterns = ops.removeFirst().components(separatedBy: " ") }
        guard !patterns.isEmpty else { return .error("FINDSTR: Bad command line") }
        let regs: [NSRegularExpression] = patterns.compactMap {
            let p = literal ? NSRegularExpression.escapedPattern(for: $0) : $0
            return try? NSRegularExpression(pattern: exact ? "^(?:\(p))$" : p, options: ci ? [.caseInsensitive] : [])
        }
        var out: [String] = []
        func scan(_ text: String, name: String?) {
            for (i, l) in text.components(separatedBy: "\n").enumerated() {
                let r = NSRange(l.startIndex..., in: l)
                let m = regs.contains { $0.firstMatch(in: l, range: r) != nil }
                if m != invert {
                    if onlyNames, let n = name { out.append(n); return }
                    out.append((name.map { $0 + ":" } ?? "") + (num ? "\(i + 1):" : "") + l)
                }
            }
        }
        if ops.isEmpty { scan(c.stdin ?? "", name: nil) }
        else {
            var files: [URL] = []
            for f in ops {
                if recurse {
                    let u = c.fs.resolve(f, cwd: c.shell.cwd)
                    let pat = u.lastPathComponent
                    if let en = c.fs.fm.enumerator(at: u.deletingLastPathComponent(), includingPropertiesForKeys: nil) {
                        for case let x as URL in en where !c.fs.isDir(x) && VirtualFS.wildcard(pat, x.lastPathComponent) { files.append(x) }
                    }
                } else { files += c.fs.glob(f, cwd: c.shell.cwd) }
            }
            let multi = files.count > 1 || recurse
            for f in files where !c.fs.isDir(f) {
                scan(c.fs.read(f) ?? "", name: multi || onlyNames ? (recurse ? c.fs.winPath(f) : f.lastPathComponent) : nil)
            }
        }
        return CmdResult(out: out.joined(separator: "\n"), err: "", code: out.isEmpty ? 1 : 0)
    }

    static func sort(_ c: Ctx) -> CmdResult {
        var lines = inputText(c).components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        lines.sort { $0.lowercased() < $1.lowercased() }
        if c.has("/r") { lines.reverse() }
        if c.has("/unique") { var seen = Set<String>(); lines = lines.filter { seen.insert($0.lowercased()).inserted } }
        if let o = c.flags.first(where: { $0.hasPrefix("/o") }), o.count == 2, let f = c.args.last {
            c.fs.write(c.fs.resolve(f, cwd: c.shell.cwd), lines.joined(separator: "\n")); return CmdResult()
        }
        return CmdResult(out: lines.joined(separator: "\n"))
    }

    static func whereCmd(_ c: Ctx) -> CmdResult {
        guard let pat = c.operands.first else { return .error("ERROR: A search pattern must be specified.") }
        if table[pat.lowercased()] != nil {
            return CmdResult(out: "C:\\Windows\\System32\\\(pat.lowercased()).exe  (t0rant built-in)")
        }
        var hits: [String] = []
        let start = c.has("/r") ? c.fs.resolve(c.args[c.args.firstIndex { $0.lowercased() == "/r" }! + 1 < c.args.count ? c.args.firstIndex { $0.lowercased() == "/r" }! + 1 : 0], cwd: c.shell.cwd) : c.fs.url(c.shell.cwd)
        let p = pat.contains(".") || pat.contains("*") ? pat : pat + ".*"
        if c.has("/r"), let en = c.fs.fm.enumerator(at: start, includingPropertiesForKeys: nil) {
            for case let f as URL in en where VirtualFS.wildcard(p, f.lastPathComponent) { hits.append(c.fs.winPath(f)) }
        } else {
            hits = (c.fs.list(start) ?? []).filter { VirtualFS.wildcard(p, $0.name) }.map { c.fs.winPath($0.url) }
        }
        return hits.isEmpty ? CmdResult(out: "", err: "INFO: Could not find files for the given pattern(s).", code: 1) : CmdResult(out: hits.joined(separator: "\n"))
    }

    static func fc(_ c: Ctx) -> CmdResult {
        let o = c.operands
        guard o.count == 2 else { return .error("FC: Insufficient number of file specifications") }
        guard let a = c.fs.read(c.fs.resolve(o[0], cwd: c.shell.cwd)) else { return .error("FC: cannot open \(o[0].uppercased()) - No such file or folder") }
        guard let b = c.fs.read(c.fs.resolve(o[1], cwd: c.shell.cwd)) else { return .error("FC: cannot open \(o[1].uppercased()) - No such file or folder") }
        var out = ["Comparing files \(o[0].uppercased()) and \(o[1].uppercased())"]
        let ci = c.has("/c")
        let la = a.components(separatedBy: "\n"), lb = b.components(separatedBy: "\n")
        let diff = lb.difference(from: la) { ci ? $0.lowercased() == $1.lowercased() : $0 == $1 }
        if diff.isEmpty { out.append("FC: no differences encountered"); return CmdResult(out: out.joined(separator: "\n")) }
        for ch in diff {
            switch ch {
            case let .remove(off, el, _): out.append("***** \(o[0].uppercased()) line \(off + 1)\n- \(el)")
            case let .insert(off, el, _): out.append("***** \(o[1].uppercased()) line \(off + 1)\n+ \(el)")
            }
        }
        out.append("*****")
        return CmdResult(out: out.joined(separator: "\n"), err: "", code: 1)
    }

    static func touch(_ c: Ctx) -> CmdResult {
        for p in c.operands {
            let u = c.fs.resolve(p, cwd: c.shell.cwd)
            if c.fs.exists(u) { try? c.fs.fm.setAttributes([.modificationDate: Date()], ofItemAtPath: u.path) }
            else { c.fs.write(u, "") }
        }
        return CmdResult()
    }

    static func mklink(_ c: Ctx) -> CmdResult {
        let o = c.operands
        guard o.count == 2 else { return syntax() }
        let link = c.fs.resolve(o[0], cwd: c.shell.cwd), target = c.fs.resolve(o[1], cwd: c.shell.cwd)
        do {
            if c.has("/h") { try c.fs.fm.linkItem(at: target, to: link) } else { try c.fs.fm.createSymbolicLink(at: link, withDestinationURL: target) }
        } catch { return .error("Cannot create a file when that file already exists.") }
        return CmdResult(out: "\(c.has("/h") ? "Hardlink" : "symbolic link") created for \(o[0]) <<===>> \(o[1])")
    }

    static func notepad(_ c: Ctx) async -> CmdResult {
        guard let f = c.operands.first else { return .error("Usage: NOTEPAD filename [text]   (opens an editor for the file)") }
        let u = c.fs.resolve(f, cwd: c.shell.cwd)
        let initial = c.fs.read(u) ?? ""
        if let edited = await InputPrompt.edit(title: c.fs.winPath(u), text: initial) {
            c.fs.write(u, edited)
            return CmdResult(out: "Saved \(c.fs.winPath(u))")
        }
        return CmdResult()
    }

    static func head(_ c: Ctx) -> CmdResult {
        let n = Int(c.args.first { $0.hasPrefix("-") }?.dropFirst().replacingOccurrences(of: "n", with: "") ?? "") ?? 10
        return CmdResult(out: inputText(Ctx(shell: c.shell, args: c.args.filter { !$0.hasPrefix("-") }, stdin: c.stdin, raw: c.raw)).components(separatedBy: "\n").prefix(n).joined(separator: "\n"))
    }
    static func tail(_ c: Ctx) -> CmdResult {
        let n = Int(c.args.first { $0.hasPrefix("-") }?.dropFirst().replacingOccurrences(of: "n", with: "") ?? "") ?? 10
        var l = inputText(Ctx(shell: c.shell, args: c.args.filter { !$0.hasPrefix("-") }, stdin: c.stdin, raw: c.raw)).components(separatedBy: "\n")
        if l.last == "" { l.removeLast() }
        return CmdResult(out: l.suffix(n).joined(separator: "\n"))
    }
    static func wc(_ c: Ctx) -> CmdResult {
        let t = inputText(Ctx(shell: c.shell, args: c.args.filter { !$0.hasPrefix("-") }, stdin: c.stdin, raw: c.raw))
        let l = t.filter { $0 == "\n" }.count, w = t.split { $0 == " " || $0 == "\n" || $0 == "\t" }.count
        return CmdResult(out: "  \(l)  \(w)  \(t.utf8.count)")
    }

    // MARK: - console
    static func title(_ c: Ctx) -> CmdResult { c.shell.title = c.rest.isEmpty ? "t0rant" : c.rest; return CmdResult() }

    static let palette: [Character: Color] = [
        "0": .black, "1": Color(red: 0, green: 0.22, blue: 0.85), "2": Color(red: 0.07, green: 0.63, blue: 0.05),
        "3": Color(red: 0.23, green: 0.59, blue: 0.87), "4": Color(red: 0.77, green: 0.06, blue: 0.12),
        "5": Color(red: 0.53, green: 0.09, blue: 0.6), "6": Color(red: 0.76, green: 0.61, blue: 0),
        "7": Color(white: 0.8), "8": Color(white: 0.46), "9": Color(red: 0.23, green: 0.47, blue: 1),
        "a": Color(red: 0.09, green: 0.78, blue: 0.05), "b": Color(red: 0.38, green: 0.84, blue: 0.84),
        "c": Color(red: 0.91, green: 0.28, blue: 0.34), "d": Color(red: 0.71, green: 0, blue: 0.62),
        "e": Color(red: 0.98, green: 0.95, blue: 0.65), "f": .white,
    ]
    static func color(_ c: Ctx) -> CmdResult {
        let v = (c.operands.first ?? "07").lowercased()
        let chars = Array(v.count == 1 ? "0" + v : v)
        guard chars.count == 2, let b = palette[chars[0]], let f = palette[chars[1]], chars[0] != chars[1] else {
            return CmdResult(out: "", err: "", code: 1)
        }
        c.shell.bg = b; c.shell.fg = f
        return CmdResult()
    }
    static func prompt(_ c: Ctx) -> CmdResult {
        c.shell.promptFormat = c.rest.isEmpty ? "$P$G" : c.rest
        c.shell.env["PROMPT"] = c.shell.promptFormat
        return CmdResult()
    }
    static func ver(_ c: Ctx) -> CmdResult {
        CmdResult(out: "\nt0rant [Version 10.0.26200.1]  (iOS \(UIDevice.current.systemVersion))")
    }
    static func vol(_ c: Ctx) -> CmdResult { CmdResult(out: " Volume in drive C is T0RANT\n Volume Serial Number is 7072-414E") }
    static func date(_ c: Ctx) -> CmdResult {
        c.has("/t") ? CmdResult(out: Shell.dateString()) : CmdResult(out: "The current date is: \(Shell.dateString())\nSetting the system date requires administrator rights not available on iOS.")
    }
    static func time(_ c: Ctx) -> CmdResult {
        let f = DateFormatter(); f.dateFormat = "hh:mm a"
        return c.has("/t") ? CmdResult(out: f.string(from: Date())) : CmdResult(out: "The current time is: \(Shell.timeString())")
    }
    static func whoami(_ c: Ctx) -> CmdResult {
        let base = "\((c.shell.env["COMPUTERNAME"] ?? "t0rant").lowercased())\\\(c.shell.fs.user.lowercased())"
        if c.has("/all") || c.has("/user") {
            return CmdResult(out: "USER INFORMATION\n----------------\n\nUser Name\(pad("", 12))SID\n\(pad(base, 21))S-1-5-21-7072-414E-1001\n\nGROUP INFORMATION\n-----------------\nBUILTIN\\Users  Mandatory group, Enabled by default")
        }
        return CmdResult(out: base)
    }
    static func hostname(_ c: Ctx) -> CmdResult { CmdResult(out: c.shell.env["COMPUTERNAME"] ?? "T0RANT") }

    static func machineModel() -> String {
        var s = utsname(); uname(&s)
        return withUnsafePointer(to: s.machine) { $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) } }
    }

    static func systeminfo(_ c: Ctx) -> CmdResult {
        let p = ProcessInfo.processInfo
        let boot = Date(timeIntervalSinceNow: -p.systemUptime)
        let f = DateFormatter(); f.dateFormat = "M/d/yyyy, h:mm:ss a"
        let mem = p.physicalMemory / 1_048_576
        let rows: [(String, String)] = [
            ("Host Name", c.shell.env["COMPUTERNAME"] ?? ""), ("OS Name", "t0rant on \(UIDevice.current.systemName)"),
            ("OS Version", "\(UIDevice.current.systemVersion) Build 26200"), ("OS Manufacturer", "t0rant"),
            ("OS Configuration", "Standalone Workstation"), ("Registered Owner", c.shell.fs.user),
            ("System Boot Time", f.string(from: boot)), ("System Manufacturer", "Apple Inc."),
            ("System Model", machineModel()), ("System Type", "ARM64-based PC"),
            ("Processor(s)", "\(p.processorCount) Processor(s) Installed. (\(p.activeProcessorCount) active)"),
            ("Windows Directory", "C:\\Windows"), ("System Directory", "C:\\Windows\\system32"),
            ("System Locale", Locale.current.identifier), ("Time Zone", TimeZone.current.identifier),
            ("Total Physical Memory", "\(fmtNum(Int64(mem))) MB"),
            ("Battery", UIDevice.current.batteryLevel >= 0 ? "\(Int(UIDevice.current.batteryLevel * 100))%" : "Unknown"),
            ("Thermal State", ["Nominal", "Fair", "Serious", "Critical"][min(3, p.thermalState.rawValue)]),
            ("Low Power Mode", p.isLowPowerModeEnabled ? "On" : "Off"),
            ("Network Card(s)", ipList().map { "\($0.0): \($0.1)" }.joined(separator: ", ")),
        ]
        return CmdResult(out: "\n" + rows.map { pad($0.0 + ":", 27) + $0.1 }.joined(separator: "\n"))
    }

    static func tasklist(_ c: Ctx) -> CmdResult {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        let memK = kr == KERN_SUCCESS ? Int64(info.resident_size / 1024) : 0
        let pid = ProcessInfo.processInfo.processIdentifier
        let rows = [("System Idle Process", 0, 8), ("System", 4, 144), ("t0rant.exe", Int(pid), Int(memK)), ("cmd.exe", Int(pid) + 1, 4210), ("conhost.exe", Int(pid) + 2, 7012)]
        var out = ["", "Image Name                     PID Session Name        Session#    Mem Usage", "========================= ======== ================ =========== ============"]
        for r in rows {
            out.append(pad(r.0, 25) + pad(String(r.1), 9, left: true) + " Console" + pad("1", 21, left: true) + pad(fmtNum(Int64(r.2)) + " K", 13, left: true))
        }
        out.append("\nNote: iOS sandboxing only exposes this app's own process.")
        return CmdResult(out: out.joined(separator: "\n"))
    }
    static func taskkill(_ c: Ctx) -> CmdResult {
        if c.args.contains(where: { $0.lowercased().contains("t0rant") }) { return .error("ERROR: The process \"t0rant.exe\" cannot be terminated from within itself.") }
        return .error("ERROR: The process not found. iOS does not allow terminating other apps.", 128)
    }

    static func exit(_ c: Ctx) -> CmdResult {
        c.shell.clear()
        c.shell.cwd = ["Users", c.shell.fs.user]
        c.shell.echoOn = true
        c.shell.print(Shell.banner + "\n")
        return CmdResult()
    }
    static func pause(_ c: Ctx) async -> CmdResult {
        _ = await InputPrompt.ask("Press any key to continue . . . ")
        return CmdResult()
    }
    static func timeout(_ c: Ctx) async -> CmdResult {
        let numArg = c.args.first(where: { Int($0) != nil })
        let n = max(-1, Int(numArg ?? "1") ?? 1)
        let quiet = c.args.contains { $0.lowercased() == "/nobreak" } && false
        if n < 0 { _ = await InputPrompt.ask("Press any key to continue ..."); return CmdResult() }
        if !quiet { c.shell.print("Waiting for \(n) seconds, press ^C to quit ...") }
        for _ in 0..<n {
            if c.shell.cancelled { break }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return CmdResult()
    }
    static func start(_ c: Ctx) -> CmdResult {
        var ops = c.operands
        if let f = ops.first, f.isEmpty || f.hasPrefix("\"") { ops.removeFirst() }
        guard let t = ops.first else { c.shell.print("(new windows are not available — continuing in this one)"); return CmdResult() }
        if let u = URL(string: t), u.scheme != nil {
            UIApplication.shared.open(u); return CmdResult()
        }
        if let u = URL(string: "https://" + t), t.contains("."), !c.fs.exists(c.fs.resolve(t, cwd: c.shell.cwd)) {
            UIApplication.shared.open(u); return CmdResult()
        }
        let f = c.fs.resolve(t, cwd: c.shell.cwd)
        guard c.fs.exists(f) else { return .error("The system cannot find the file \(t).") }
        if ["bat", "cmd"].contains(f.pathExtension.lowercased()) {
            Task { _ = await c.shell.runBatch(c.fs.read(f) ?? "", args: [t]) }
            return CmdResult()
        }
        ShareSheet.present(f)
        return CmdResult()
    }
    static func doskey(_ c: Ctx) -> CmdResult {
        if c.has("/history") { return historyCmd(c) }
        if c.has("/macros") { return CmdResult(out: c.shell.aliases.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "\n")) }
        let r = c.rest
        guard let eq = r.firstIndex(of: "=") else { return CmdResult() }
        let k = String(r[..<eq]).lowercased().trimmingCharacters(in: .whitespaces)
        let v = String(r[r.index(after: eq)...]).replacingOccurrences(of: "$*", with: "")
        if v.isEmpty { c.shell.aliases.removeValue(forKey: k) } else { c.shell.aliases[k] = v }
        return CmdResult()
    }
    static func historyCmd(_ c: Ctx) -> CmdResult { CmdResult(out: c.shell.history.joined(separator: "\n")) }
    static func cmd(_ c: Ctx) async -> CmdResult {
        if let i = c.args.firstIndex(where: { $0.lowercased() == "/c" || $0.lowercased() == "/k" }) {
            let line = c.args[(i + 1)...].joined(separator: " ")
            let code = await c.shell.runLine(line)
            return CmdResult(out: "", err: "", code: code)
        }
        return CmdResult(out: Shell.banner)
    }
    static func call(_ c: Ctx) async -> CmdResult {
        let line = c.rest
        guard !line.isEmpty else { return CmdResult() }
        let code = await c.shell.runLine(line)
        return CmdResult(out: "", err: "", code: code)
    }
    static func path(_ c: Ctx) -> CmdResult {
        if c.rest.isEmpty { return CmdResult(out: "PATH=" + (c.shell.env["PATH"] ?? "")) }
        c.shell.env["PATH"] = c.rest.hasPrefix("=") ? String(c.rest.dropFirst()) : c.rest
        return CmdResult()
    }
    static func verify(_ c: Ctx) -> CmdResult { CmdResult(out: c.operands.isEmpty ? "VERIFY is on." : "") }
    static func choice(_ c: Ctx) async -> CmdResult {
        var opts = "YN"
        if let i = c.args.firstIndex(where: { $0.lowercased() == "/c" }), i + 1 < c.args.count { opts = c.args[i + 1].uppercased() }
        var msg = ""
        if let i = c.args.firstIndex(where: { $0.lowercased() == "/m" }), i + 1 < c.args.count { msg = c.args[i + 1] + " " }
        let ans = await InputPrompt.ask("\(msg)[\(opts.map(String.init).joined(separator: ","))]?")
        if opts.isEmpty { opts = "YN" }
        let ch = ans.uppercased().first ?? opts.first ?? "Y"
        let idx = Array(opts).firstIndex(of: ch).map { Int32($0 + 1) } ?? 0
        return CmdResult(out: String(ch), err: "", code: idx)
    }
    static func shutdown(_ c: Ctx) -> CmdResult {
        .error("iOS does not allow apps to shut down or restart the device.")
    }
    static func calc(_ c: Ctx) -> CmdResult {
        let expr = c.rest
        guard !expr.isEmpty else { return CmdResult(out: "Usage: CALC expression   e.g. calc (2+3)*4/7") }
        var ar = Arith(shell: c.shell)
        if let v = try? ar.evaluate(expr) { return CmdResult(out: String(v)) }
        return .error("Invalid expression")
    }
    static func uptime(_ c: Ctx) -> CmdResult {
        let s = Int(ProcessInfo.processInfo.systemUptime)
        return CmdResult(out: "Up \(s / 86400) days, \(s % 86400 / 3600) hours, \(s % 3600 / 60) minutes")
    }
    static func clip(_ c: Ctx) -> CmdResult {
        UIPasteboard.general.string = c.stdin ?? ""
        return CmdResult()
    }
    static func assoc(_ c: Ctx) -> CmdResult {
        CmdResult(out: ".bat=batfile\n.cmd=cmdfile\n.txt=txtfile\n.log=txtfile\n.zip=CompressedFolder\n.html=htmlfile")
    }
    static func chkdsk(_ c: Ctx) -> CmdResult {
        var files = 0, dirs = 0
        var bytes: Int64 = 0
        if let en = c.fs.fm.enumerator(at: c.fs.root, includingPropertiesForKeys: nil) {
            for case let f as URL in en { if c.fs.isDir(f) { dirs += 1 } else { files += 1; bytes += Int64(c.fs.entry(f)?.size ?? 0) } }
        }
        return CmdResult(out: "The type of the file system is T0FS.\nVolume label is T0RANT.\n\nStage 1: Examining basic file system structure ...\n  \(files) file records processed.\nStage 2: Examining file name linkage ...\n  \(dirs) index entries processed.\nStage 3: Examining security descriptors ...\n\nWindows has scanned the file system and found no problems.\nNo further action is required.\n\n\(pad(fmtNum(c.fs.totalSpace() / 1024), 15, left: true)) KB total disk space.\n\(pad(fmtNum(bytes / 1024), 15, left: true)) KB in \(files) files.\n\(pad(fmtNum(c.fs.freeSpace() / 1024), 15, left: true)) KB available on disk.")
    }
    static func fsutil(_ c: Ctx) -> CmdResult {
        let a = c.args.map { $0.lowercased() }
        if a.starts(with: ["file", "createnew"]), a.count >= 4, let n = Int(a[3]) {
            c.fs.writeData(c.fs.resolve(c.args[2], cwd: c.shell.cwd), Data(count: min(n, 512_000_000)))
            return CmdResult(out: "File \(c.fs.winPath(c.fs.resolve(c.args[2], cwd: c.shell.cwd))) is created")
        }
        if a.starts(with: ["volume", "diskfree"]) {
            return CmdResult(out: "Total free bytes        : \(fmtNum(c.fs.freeSpace()))\nTotal bytes             : \(fmtNum(c.fs.totalSpace()))")
        }
        return CmdResult(out: "---- Commands Supported ----\nfile createnew <file> <length>\nvolume diskfree c:")
    }
    static func reg(_ c: Ctx) -> CmdResult {
        var store = UserDefaults.standard.dictionary(forKey: "registry") as? [String: String] ?? [:]
        let a = c.args
        guard let op = a.first?.lowercased(), a.count >= 2 else { return .error("ERROR: Invalid syntax.\nType \"REG /?\" for usage.") }
        let key = a[1].uppercased()
        func arg(_ f: String) -> String? { a.firstIndex { $0.lowercased() == f }.flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil } }
        switch op {
        case "add":
            store[key + "\\" + (arg("/v") ?? "(Default)")] = arg("/d") ?? ""
            UserDefaults.standard.set(store, forKey: "registry")
            return CmdResult(out: "The operation completed successfully.")
        case "query":
            let hits = store.filter { $0.key.hasPrefix(key + "\\") }.sorted { $0.key < $1.key }
            if hits.isEmpty { return .error("ERROR: The system was unable to find the specified registry key or value.") }
            return CmdResult(out: "\n" + key + "\n" + hits.map { "    \($0.key.dropFirst(key.count + 1))    REG_SZ    \($0.value)" }.joined(separator: "\n"))
        case "delete":
            store = store.filter { !$0.key.hasPrefix(key) }
            UserDefaults.standard.set(store, forKey: "registry")
            return CmdResult(out: "The operation completed successfully.")
        default: return .error("ERROR: Invalid syntax.")
        }
    }
    static func net(_ c: Ctx) -> CmdResult {
        switch c.operands.first?.lowercased() {
        case "user": return CmdResult(out: "\nUser accounts for \\\\\(c.shell.env["COMPUTERNAME"] ?? "")\n\n-------------------------------------------------------------------------------\nAdministrator            Guest                    t0rant\nThe command completed successfully.")
        case "view", "share", "use": return CmdResult(out: "There are no entries in the list.")
        case "time": return CmdResult(out: "Current time at \\\\\(c.shell.env["COMPUTERNAME"] ?? "") is \(Date())")
        default: return CmdResult(out: "The syntax of this command is:\n\nNET\n    [ SHARE | TIME | USE | USER | VIEW ]")
        }
    }
    static func wmic(_ c: Ctx) -> CmdResult {
        let p = ProcessInfo.processInfo
        switch c.operands.first?.lowercased() {
        case "os": return CmdResult(out: "Caption                 Version   OSArchitecture\nt0rant (iOS \(UIDevice.current.systemVersion))   10.0.26200  ARM64")
        case "cpu": return CmdResult(out: "Name                 NumberOfCores  NumberOfLogicalProcessors\nApple \(machineModel())  \(p.processorCount)              \(p.activeProcessorCount)")
        case "logicaldisk": return CmdResult(out: "Caption  FreeSpace      Size\nC:       \(c.fs.freeSpace())  \(c.fs.totalSpace())")
        case "memorychip", "computersystem": return CmdResult(out: "TotalPhysicalMemory\n\(p.physicalMemory)")
        default: return CmdResult(out: "wmic:root\\cli>  supported aliases: os, cpu, logicaldisk, computersystem")
        }
    }

    // MARK: - hashing / encoding / archives
    static func certutil(_ c: Ctx) -> CmdResult {
        let a = c.args
        guard let op = a.first?.lowercased() else { return CmdResult(out: "Usage: certutil -hashfile file [MD5|SHA1|SHA256|SHA384|SHA512] | -encode in out | -decode in out") }
        switch op {
        case "-hashfile":
            guard a.count >= 2, let d = c.fs.readData(c.fs.resolve(a[1], cwd: c.shell.cwd)) else { return notFound() }
            let alg = (a.count > 2 ? a[2] : "SHA1").uppercased()
            let hex: String
            switch alg {
            case "MD5": hex = Insecure.MD5.hash(data: d).map { String(format: "%02x", $0) }.joined()
            case "SHA256": hex = SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
            case "SHA384": hex = SHA384.hash(data: d).map { String(format: "%02x", $0) }.joined()
            case "SHA512": hex = SHA512.hash(data: d).map { String(format: "%02x", $0) }.joined()
            default: hex = Insecure.SHA1.hash(data: d).map { String(format: "%02x", $0) }.joined()
            }
            return CmdResult(out: "\(alg) hash of \(a[1]):\n\(hex)\nCertUtil: -hashfile command completed successfully.")
        case "-encode", "-decode":
            guard a.count >= 3, let d = c.fs.readData(c.fs.resolve(a[1], cwd: c.shell.cwd)) else { return notFound() }
            let out = c.fs.resolve(a[2], cwd: c.shell.cwd)
            if op == "-encode" {
                let b = d.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
                c.fs.write(out, "-----BEGIN CERTIFICATE-----\n\(b)\n-----END CERTIFICATE-----\n")
            } else {
                let s = (String(data: d, encoding: .utf8) ?? "").components(separatedBy: "\n").filter { !$0.hasPrefix("-----") }.joined()
                guard let raw = Data(base64Encoded: s, options: .ignoreUnknownCharacters) else { return .error("DecodeFile returned The data is invalid.") }
                c.fs.writeData(out, raw)
            }
            return CmdResult(out: "Input Length = \(d.count)\nCertUtil: \(op) command completed successfully.")
        case "-urlcache":
            return .error("Use CURL -o file url to download files.")
        default: return .error("CertUtil: Unknown arg: \(op)")
        }
    }
    static func base64(_ c: Ctx) -> CmdResult {
        let t = inputText(Ctx(shell: c.shell, args: c.args.filter { !$0.hasPrefix("-") }, stdin: c.stdin, raw: c.raw))
        if c.args.contains("-d") {
            return CmdResult(out: Data(base64Encoded: t.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { String(data: $0, encoding: .utf8) } ?? "")
        }
        return CmdResult(out: Data(t.utf8).base64EncodedString())
    }
    static func tar(_ c: Ctx) -> CmdResult {
        let a = c.args
        guard let mode = a.first?.lowercased() else { return CmdResult(out: "Usage: tar -tf archive.zip | tar -cf archive.zip folder | tar -xf archive.zip") }
        guard let fi = a.firstIndex(where: { $0.lowercased().contains("f") && $0.hasPrefix("-") }), fi + 1 < a.count else { return syntax() }
        let archive = c.fs.resolve(a[fi + 1], cwd: c.shell.cwd)
        if mode.contains("c") {
            guard fi + 2 < a.count else { return syntax() }
            let src = c.fs.resolve(a[fi + 2], cwd: c.shell.cwd)
            var err: NSError?
            var ok = false
            NSFileCoordinator().coordinate(readingItemAt: src, options: .forUploading, error: &err) { zipURL in
                try? c.fs.fm.removeItem(at: archive)
                ok = (try? c.fs.fm.copyItem(at: zipURL, to: archive)) != nil
            }
            return ok ? CmdResult() : .error("tar: could not create archive")
        }
        return .error("tar: only -c (create zip) is supported on iOS.")
    }

    // MARK: - networking (real)
    static func ipList() -> [(String, String, String)] {
        var res: [(String, String, String)] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return res }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let i = ptr.pointee
            guard let sa = i.ifa_addr else { continue }
            let fam = sa.pointee.sa_family
            guard fam == UInt8(AF_INET) || fam == UInt8(AF_INET6) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            var mask = ""
            if let m = i.ifa_netmask, fam == UInt8(AF_INET) {
                var mh = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(m, socklen_t(m.pointee.sa_len), &mh, socklen_t(mh.count), nil, 0, NI_NUMERICHOST)
                mask = String(cString: mh)
            }
            res.append((String(cString: i.ifa_name), String(cString: host), mask))
        }
        return res
    }

    static func ipconfig(_ c: Ctx) -> CmdResult {
        let all = c.has("/all")
        let names = ["en0": "Wireless LAN adapter Wi-Fi", "pdp_ip0": "Mobile Broadband adapter Cellular", "lo0": "Loopback adapter",
                     "utun0": "Tunnel adapter utun0", "utun1": "Tunnel adapter utun1", "utun2": "VPN adapter utun2", "bridge100": "Ethernet adapter Hotspot"]
        var out = ["", "t0rant IP Configuration", ""]
        if all {
            out += ["   Host Name . . . . . . . . . . . . : \(c.shell.env["COMPUTERNAME"] ?? "")",
                    "   Node Type . . . . . . . . . . . . : Hybrid", "   IP Routing Enabled. . . . . . . . : No", ""]
        }
        let grouped = Dictionary(grouping: ipList(), by: { $0.0 })
        for k in grouped.keys.sorted() {
            guard let v = grouped[k], all || k == "en0" || k.hasPrefix("pdp_ip") || k.hasPrefix("bridge") else { continue }
            out.append("\(names[k] ?? "Adapter \(k)"):")
            out.append("")
            out.append("   Connection-specific DNS Suffix  . : ")
            for a in v {
                if a.1.contains(":") { out.append("   \(a.1.hasPrefix("fe80") ? "Link-local IPv6 Address" : "IPv6 Address. . . . . . . . . . .") . . . . . : \(a.1)") }
                else { out.append("   IPv4 Address. . . . . . . . . . . : \(a.1)"); out.append("   Subnet Mask . . . . . . . . . . . : \(a.2)") }
            }
            out.append("")
        }
        if c.has("/flushdns") { return CmdResult(out: "\nt0rant IP Configuration\n\nSuccessfully flushed the DNS Resolver Cache.") }
        return CmdResult(out: out.joined(separator: "\n"))
    }

    static func resolve(_ host: String) async -> [String] {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
                var res: UnsafeMutablePointer<addrinfo>?
                var out: [String] = []
                if getaddrinfo(host, nil, &hints, &res) == 0, let first = res {
                    for p in sequence(first: first, next: { $0.pointee.ai_next }) {
                        var h = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        getnameinfo(p.pointee.ai_addr, p.pointee.ai_addrlen, &h, socklen_t(h.count), nil, 0, NI_NUMERICHOST)
                        let s = String(cString: h)
                        if !out.contains(s) { out.append(s) }
                    }
                    freeaddrinfo(res)
                }
                cont.resume(returning: out)
            }
        }
    }

    static func nslookup(_ c: Ctx) async -> CmdResult {
        guard let h = c.operands.first else { return CmdResult(out: "Default Server:  system resolver\nAddress:  (iOS managed)") }
        let ips = await resolve(h)
        if ips.isEmpty { return CmdResult(out: "Server:  system resolver\n", err: "*** system resolver can't find \(h): Non-existent domain", code: 1) }
        return CmdResult(out: "Server:  system resolver\nAddress:  (iOS managed)\n\nNon-authoritative answer:\nName:    \(h)\nAddresses:  " + ips.joined(separator: "\n          "))
    }

    /// TCP connect time in ms, or nil on failure.
    static func tcpPing(_ host: String, port: UInt16, timeout: Double = 3) async -> Double? {
        await withCheckedContinuation { cont in
            let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            let start = DispatchTime.now()
            var done = false
            let lock = NSLock()
            func finish(_ v: Double?) {
                lock.lock(); defer { lock.unlock() }
                if done { return }
                done = true
                conn.cancel()
                cont.resume(returning: v)
            }
            conn.stateUpdateHandler = { st in
                switch st {
                case .ready: finish(Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
                case .failed, .cancelled: finish(nil)
                case .waiting: finish(nil)
                default: break
                }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(nil) }
        }
    }

    static func ping(_ c: Ctx) async -> CmdResult {
        var count = 4
        var forever = false
        var host: String?
        var i = 0
        while i < c.args.count {
            let a = c.args[i].lowercased()
            if (a == "-n" || a == "/n" || a == "-c"), i + 1 < c.args.count { count = Int(c.args[i + 1]) ?? 4; i += 2; continue }
            if a == "-t" || a == "/t" { forever = true; i += 1; continue }
            if !a.hasPrefix("-") && !a.hasPrefix("/") { host = c.args[i] }
            i += 1
        }
        guard let h = host else { return CmdResult(out: helpText["ping"]!) }
        let ips = await resolve(h)
        guard let ip = ips.first(where: { !$0.contains(":") }) ?? ips.first else {
            return .error("Ping request could not find host \(h). Please check the name and try again.")
        }
        var port: UInt16 = 443
        if await tcpPing(ip, port: 443, timeout: 2) == nil { port = 80 }
        c.shell.print("\nPinging \(h) [\(ip)] (TCP/\(port)) with 32 bytes of data:")
        var times: [Double] = []
        var sent = 0
        while forever || sent < count {
            if c.shell.cancelled || Task.isCancelled { c.shell.print("Control-C"); break }
            sent += 1
            if let t = await tcpPing(ip, port: port) {
                times.append(t)
                c.shell.print("Reply from \(ip): bytes=32 time=\(Int(t.rounded()))ms TTL=64")
            } else {
                c.shell.print("Request timed out.")
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        let lost = sent - times.count
        var out = "\nPing statistics for \(ip):\n    Packets: Sent = \(sent), Received = \(times.count), Lost = \(lost) (\(sent > 0 ? lost * 100 / sent : 0)% loss),"
        if !times.isEmpty {
            out += "\nApproximate round trip times in milli-seconds:\n    Minimum = \(Int(times.min()!))ms, Maximum = \(Int(times.max()!))ms, Average = \(Int(times.reduce(0, +) / Double(times.count)))ms"
        }
        return CmdResult(out: out, err: "", code: times.isEmpty ? 1 : 0)
    }

    static func tracert(_ c: Ctx) async -> CmdResult {
        guard let h = c.operands.first else { return .error("Usage: tracert target_name") }
        let ips = await resolve(h)
        guard let ip = ips.first else { return .error("Unable to resolve target system name \(h).") }
        let t = await tcpPing(ip, port: 443)
        let ms = t.map { "\(Int($0)) ms" } ?? "*"
        return CmdResult(out: "\nTracing route to \(h) [\(ip)]\nover a maximum of 30 hops:\n\n  1   \(pad(ms, 8, left: true))  \(pad(ms, 8, left: true))  \(pad(ms, 8, left: true))  \(ip)\n\nTrace complete. (iOS hides intermediate hops; showing end-to-end TCP time)")
    }

    static func netstat(_ c: Ctx) -> CmdResult {
        var out = ["", "Active Connections", "", "  Proto  Local Address          Foreign Address        State"]
        for a in ipList() where !a.1.hasPrefix("fe80") && !a.1.contains(":") {
            out.append("  TCP    \(pad(a.1 + ":0", 22)) 0.0.0.0:0              LISTENING")
        }
        out.append("\n(iOS does not expose other apps' sockets.)")
        return CmdResult(out: out.joined(separator: "\n"))
    }
    static func getmac(_ c: Ctx) -> CmdResult {
        CmdResult(out: "\nPhysical Address    Transport Name\n=================== ==========================================================\n02-00-00-00-00-00   \\Device\\Tcpip_en0  (iOS privacy: real MAC is hidden)")
    }

    static func curl(_ c: Ctx) async -> CmdResult {
        var method: String? = nil
        var headers: [String: String] = [:]
        var body: String? = nil
        var output: String? = nil
        var remoteName = false, headOnly = false, include = false, silent = false, follow = true, verbose = false
        var urlStr: String?
        let a = c.args
        var i = 0
        while i < a.count {
            let x = a[i]
            func next() -> String? { i += 1; return i < a.count ? a[i] : nil }
            switch x {
            case "-X", "--request": method = next()
            case "-H", "--header":
                if let h = next(), let r = h.firstIndex(of: ":") { headers[String(h[..<r])] = h[h.index(after: r)...].trimmingCharacters(in: .whitespaces) }
            case "-d", "--data", "--data-raw":
                if let d = next() { body = d.hasPrefix("@") ? c.fs.read(c.fs.resolve(String(d.dropFirst()), cwd: c.shell.cwd)) : d }
            case "-o", "--output": output = next()
            case "-O", "--remote-name": remoteName = true
            case "-I", "--head": headOnly = true
            case "-i", "--include": include = true
            case "-s", "--silent": silent = true
            case "-L", "--location": follow = true
            case "-v", "--verbose": verbose = true
            case "-A", "--user-agent": if let u = next() { headers["User-Agent"] = u }
            case "-k", "--insecure", "-S", "-sS", "-fsSL", "-sL", "-f": if x.contains("s") { silent = true }
            default: if !x.hasPrefix("-") { urlStr = x }
            }
            i += 1
        }
        _ = follow
        guard var s = urlStr else { return .error("curl: try 'curl --help' or 'curl /?' for more information") }
        if !s.contains("://") { s = "http://" + s }
        guard let url = URL(string: s) else { return .error("curl: (3) URL using bad/illegal format or missing URL", 3) }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = method ?? (headOnly ? "HEAD" : (body != nil ? "POST" : "GET"))
        if req.value(forHTTPHeaderField: "User-Agent") == nil { req.setValue("curl/8.9.1", forHTTPHeaderField: "User-Agent") }
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let b = body {
            req.httpBody = b.data(using: .utf8)
            if headers["Content-Type"] == nil { req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type") }
        }
        if verbose { c.shell.print("> \(req.httpMethod!) \(url.path.isEmpty ? "/" : url.path) HTTP/1.1\n> Host: \(url.host ?? "")\n>") }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return CmdResult(out: String(data: data, encoding: .utf8) ?? "") }
            var hdr = "HTTP/1.1 \(http.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: http.statusCode).capitalized)\n"
            for (k, v) in http.allHeaderFields { hdr += "\(k): \(v)\n" }
            if headOnly { return CmdResult(out: hdr) }
            if remoteName { output = url.lastPathComponent.isEmpty ? "index.html" : url.lastPathComponent }
            if let o = output {
                c.fs.writeData(c.fs.resolve(o, cwd: c.shell.cwd), data)
                if silent { return CmdResult() }
                return CmdResult(out: "  % Total    % Received   Time\n100 \(pad(fmtNum(Int64(data.count)), 8, left: true))  100 \(pad(fmtNum(Int64(data.count)), 8, left: true))   done\nSaved to \(c.fs.winPath(c.fs.resolve(o, cwd: c.shell.cwd)))")
            }
            let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? "<\(data.count) bytes of binary data>"
            return CmdResult(out: (include || verbose ? hdr + "\n" : "") + text)
        } catch {
            return .error("curl: (6) \(error.localizedDescription)", 6)
        }
    }

    // MARK: - PowerShell subset
    static func powershell(_ c: Ctx) async -> CmdResult {
        var a = c.args
        if let i = a.firstIndex(where: { $0.lowercased() == "-command" || $0.lowercased() == "-c" }) { a = Array(a[(i + 1)...]) }
        a = a.filter { !["-noprofile", "-nologo", "-executionpolicy", "bypass"].contains($0.lowercased()) }
        guard !a.isEmpty else { return CmdResult(out: "Windows PowerShell subset (t0rant)\nUsage: powershell -c \"Get-Date\" | Get-ChildItem | Get-Location | Write-Output x | Get-Content f | Test-Connection host | Invoke-WebRequest url") }
        let cmdName = a[0].lowercased()
        let rest = Array(a.dropFirst())
        let map: [String: String] = [
            "get-childitem": "dir", "gci": "dir", "get-location": "cd", "gl": "cd", "set-location": "cd", "sl": "cd",
            "get-content": "type", "gc": "type", "write-output": "echo", "write-host": "echo", "echo": "echo",
            "remove-item": "del", "ri": "del", "copy-item": "copy", "move-item": "move", "rename-item": "ren",
            "new-item": "touch", "clear-host": "cls", "invoke-webrequest": "curl", "iwr": "curl", "invoke-restmethod": "curl",
            "irm": "curl", "test-connection": "ping", "get-process": "tasklist", "get-history": "history",
            "resolve-dnsname": "nslookup", "get-computerinfo": "systeminfo", "select-string": "findstr", "sort-object": "sort",
        ]
        if cmdName == "get-date" { return CmdResult(out: "\n\(DateFormatter.localizedString(from: Date(), dateStyle: .full, timeStyle: .medium))\n") }
        if cmdName == "$psversiontable" { return CmdResult(out: "\nName                           Value\n----                           -----\nPSVersion                      5.1.26200.1\nPSEdition                      Desktop (t0rant subset)") }
        if cmdName == "get-filehash", let f = rest.first(where: { !$0.hasPrefix("-") }) {
            let alg = rest.firstIndex(where: { $0.lowercased() == "-algorithm" }).flatMap { $0 + 1 < rest.count ? rest[$0 + 1] : nil } ?? "SHA256"
            let r = certutil(Ctx(shell: c.shell, args: ["-hashfile", f, alg], stdin: nil, raw: ""))
            let hash = r.out.components(separatedBy: "\n").dropFirst().first?.uppercased() ?? ""
            return CmdResult(out: "\nAlgorithm       Hash\n---------       ----\n\(pad(alg.uppercased(), 16))\(hash)")
        }
        guard let mapped = map[cmdName] else {
            return .error("\(a[0]) : The term '\(a[0])' is not recognized as the name of a cmdlet in the t0rant PowerShell subset.")
        }
        let args = rest.filter { !["-path", "-literalpath", "-uri", "-computername", "-name", "-pattern", "-object", "-itemtype"].contains($0.lowercased()) && $0.lowercased() != "file" }
        let line = ([mapped] + args.map { $0.contains(" ") ? "\"\($0)\"" : $0 }).joined(separator: " ")
        return await c.shell.exec(Parser.tokenize(line).0, stdin: c.stdin, raw: line)
    }

    // MARK: - IF / FOR
    static func ifCmd(_ c: Ctx) async -> CmdResult {
        var s = c.raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("@") { s.removeFirst() }
        s = String(s.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        var words = Lexer(s)
        var ci = false, negate = false
        var tok = words.next()
        if tok?.lowercased() == "/i" { ci = true; tok = words.next() }
        if tok?.lowercased() == "not" { negate = true; tok = words.next() }
        guard let t = tok else { return syntax() }
        var cond = false
        switch t.lowercased() {
        case "exist":
            guard let p = words.next() else { return syntax() }
            cond = !c.fs.glob(p.replacingOccurrences(of: "\"", with: ""), cwd: c.shell.cwd).isEmpty
        case "defined":
            guard let v = words.next() else { return syntax() }
            cond = c.shell.env[v.uppercased()] != nil
        case "errorlevel":
            guard let n = words.next().flatMap({ Int32($0) }) else { return syntax() }
            cond = c.shell.lastCode >= n
        default:
            var lhs = t, op = "", rhs = ""
            if let r = t.range(of: "==") {
                lhs = String(t[..<r.lowerBound]); rhs = String(t[r.upperBound...]); op = "=="
                if rhs.isEmpty { rhs = words.next() ?? "" }
            } else {
                guard let o = words.next() else { return syntax() }
                if o.hasPrefix("==") { op = "=="; rhs = o.count > 2 ? String(o.dropFirst(2)) : (words.next() ?? "") }
                else { op = o.uppercased(); rhs = words.next() ?? "" }
            }
            func unq(_ x: String) -> String { x.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            var l = unq(lhs), r = unq(rhs)
            if ci { l = l.lowercased(); r = r.lowercased() }
            let cmp: Int
            if let li = Int(l), let ri = Int(r) { cmp = li < ri ? -1 : (li > ri ? 1 : 0) }
            else { cmp = l < r ? -1 : (l > r ? 1 : 0) }
            switch op {
            case "==", "EQU": cond = cmp == 0
            case "NEQ": cond = cmp != 0
            case "LSS": cond = cmp < 0
            case "LEQ": cond = cmp <= 0
            case "GTR": cond = cmp > 0
            case "GEQ": cond = cmp >= 0
            default: return .error("\(op) was unexpected at this time.")
            }
        }
        if negate { cond.toggle() }
        let remainder = words.remainder
        let (thenPart, elsePart) = splitElse(remainder)
        let chosen = cond ? thenPart : elsePart
        guard let body = chosen, !body.isEmpty else { return CmdResult(out: "", err: "", code: c.shell.lastCode) }
        let code = await c.shell.runLine(unwrap(body))
        return CmdResult(out: "", err: "", code: code)
    }

    static func unwrap(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("(") && t.hasSuffix(")") && Parser.parenDepth(String(t.dropLast())) == 1 {
            t = String(t.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        return t
    }

    static func splitElse(_ s: String) -> (String, String?) {
        let c = Array(s); var depth = 0; var q = false
        var i = 0
        while i < c.count {
            if c[i] == "\"" { q.toggle() }
            if !q {
                if c[i] == "(" { depth += 1 } else if c[i] == ")" { depth -= 1 }
                if depth == 0 && i + 6 <= c.count && String(c[i..<i + 6]).lowercased() == " else " {
                    return (String(c[..<i]), String(c[(i + 6)...]))
                }
            }
            i += 1
        }
        return (s, nil)
    }

    static func forCmd(_ c: Ctx) async -> CmdResult {
        var s = c.raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("@") { s.removeFirst() }
        s = String(s.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        var lx = Lexer(s)
        var mode = ""
        var opts = ""
        var root = c.fs.url(c.shell.cwd)
        var tok = lx.next() ?? ""
        while tok.hasPrefix("/") {
            mode = tok.lowercased()
            tok = lx.next() ?? ""
            if mode == "/f" && tok.hasPrefix("\"") { opts = tok.trimmingCharacters(in: CharacterSet(charactersIn: "\"")); tok = lx.next() ?? "" }
            if mode == "/r" && !tok.hasPrefix("%") { root = c.fs.resolve(tok, cwd: c.shell.cwd); tok = lx.next() ?? "" }
        }
        guard tok.hasPrefix("%") else { return .error("\(tok) was unexpected at this time.") }
        let varName = String(tok.drop { $0 == "%" })
        guard lx.next()?.lowercased() == "in" else { return syntax() }
        let rem = lx.remainder.trimmingCharacters(in: .whitespaces)
        guard rem.hasPrefix("("), let close = matchingParen(rem) else { return syntax() }
        let setText = String(rem[rem.index(after: rem.startIndex)..<close])
        var after = String(rem[rem.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        guard after.lowercased().hasPrefix("do") else { return syntax() }
        after = unwrap(String(after.dropFirst(2)))

        var items: [[String]] = []
        switch mode {
        case "/l":
            let n = setText.split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { Int($0) }
            guard n.count == 3, n[1] != 0 else { return syntax() }
            var v = n[0]
            while (n[1] > 0 ? v <= n[2] : v >= n[2]) && items.count < 100_000 { items.append([String(v)]); v += n[1] }
        case "/f":
            var text = ""
            let st = setText.trimmingCharacters(in: .whitespaces)
            if st.hasPrefix("'") || st.hasPrefix("`") {
                text = await c.shell.capture(String(st.dropFirst().dropLast())).out
            } else if st.hasPrefix("\"") {
                text = String(st.dropFirst().dropLast())
            } else {
                text = st.split(separator: " ").compactMap { c.fs.read(c.fs.resolve(String($0), cwd: c.shell.cwd)) }.joined(separator: "\n")
            }
            var delims: Set<Character> = [" ", "\t"]
            var tokens: [Int] = [1]
            var star = false
            var skip = 0
            var eol: Character = ";"
            for part in opts.components(separatedBy: " ") where !part.isEmpty {
                let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
                guard kv.count >= 1 else { continue }
                let key = kv[0].lowercased(), val = kv.count > 1 ? kv[1] : ""
                switch key {
                case "delims": delims = Set(val)
                case "skip": skip = Int(val) ?? 0
                case "eol": eol = val.first ?? ";"
                case "tokens":
                    star = val.hasSuffix("*")
                    tokens = []
                    for t in val.replacingOccurrences(of: "*", with: "").split(separator: ",") {
                        let r = t.split(separator: "-").compactMap { Int($0) }
                        if r.count == 2 { tokens += Array(r[0]...r[1]) } else if let one = r.first { tokens.append(one) }
                    }
                    if tokens.isEmpty { tokens = [1] }
                default: break
                }
            }
            // a "delims=" at the end of the options string with nothing after means no delimiters
            if opts.lowercased().hasSuffix("delims=") { delims = [] }
            for line in text.components(separatedBy: "\n").dropFirst(skip) {
                let l = line.replacingOccurrences(of: "\r", with: "")
                if l.isEmpty || l.first == eol { continue }
                let parts = delims.isEmpty ? [l] : l.split(whereSeparator: { delims.contains($0) }).map(String.init)
                var row: [String] = tokens.map { $0 - 1 < parts.count ? parts[$0 - 1] : "" }
                if star {
                    let from = (tokens.max() ?? 0)
                    row.append(from < parts.count ? parts[from...].joined(separator: delims.first.map { String($0) } ?? " ") : "")
                }
                items.append(row)
            }
        default:
            for e in Lexer.split(setText) {
                let p = e.replacingOccurrences(of: "\"", with: "")
                if p.contains("*") || p.contains("?") {
                    if mode == "/r" {
                        if let en = c.fs.fm.enumerator(at: root, includingPropertiesForKeys: nil) {
                            for case let f as URL in en where !c.fs.isDir(f) && VirtualFS.wildcard(p, f.lastPathComponent) { items.append([c.fs.winPath(f)]) }
                        }
                    } else {
                        for u in c.fs.glob(p, cwd: c.shell.cwd) where (mode == "/d") == c.fs.isDir(u) { items.append([u.lastPathComponent]) }
                    }
                } else {
                    items.append([e])
                }
            }
        }

        var code: Int32 = 0
        let letters = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        let startIdx = varName.first.flatMap { letters.firstIndex(of: $0) } ?? 0
        for row in items {
            if c.shell.cancelled { break }
            var line = after
            for (k, v) in row.enumerated() where startIdx + k < letters.count {
                let n = String(letters[startIdx + k])
                line = line.replacingOccurrences(of: "%%~" + n, with: v.replacingOccurrences(of: "\"", with: ""))
                line = line.replacingOccurrences(of: "%~" + n, with: v.replacingOccurrences(of: "\"", with: ""))
                line = line.replacingOccurrences(of: "%%" + n, with: v)
                line = line.replacingOccurrences(of: "%" + n, with: v)
            }
            code = await c.shell.runLine(line)
            await Task.yield()
        }
        return CmdResult(out: "", err: "", code: code)
    }

    static func matchingParen(_ s: String) -> String.Index? {
        var d = 0; var q = false
        for i in s.indices {
            let ch = s[i]
            if ch == "\"" || ch == "'" { q.toggle() }
            if q { continue }
            if ch == "(" { d += 1 } else if ch == ")" { d -= 1; if d == 0 { return i } }
        }
        return nil
    }
}

/// Simple word lexer that respects quotes and lets you grab the unparsed remainder.
struct Lexer {
    private let chars: [Character]
    private var pos = 0
    init(_ s: String) { chars = Array(s) }

    mutating func next() -> String? {
        while pos < chars.count && chars[pos] == " " { pos += 1 }
        guard pos < chars.count else { return nil }
        var out = ""; var q = false
        while pos < chars.count {
            let ch = chars[pos]
            if ch == "\"" { q.toggle() }
            if ch == " " && !q { break }
            out.append(ch); pos += 1
        }
        return out
    }
    var remainder: String { pos < chars.count ? String(chars[pos...]).trimmingCharacters(in: .whitespaces) : "" }

    static func split(_ s: String) -> [String] {
        var l = Lexer(s); var r: [String] = []
        while let w = l.next() { r += w.split(separator: ",").map(String.init) }
        return r
    }
}

/// SET /A arithmetic evaluator supporting + - * / % << >> & | ^ ! ~ ( ) and assignment ops.
@MainActor
struct Arith {
    let shell: Shell
    struct Err: Error {}
    private var toks: [String] = []
    private var i = 0

    init(shell: Shell) { self.shell = shell }

    mutating func evaluate(_ expr: String) throws -> Int64 {
        toks = Arith.lex(expr); i = 0
        let v = try assignment()
        return v
    }

    static func lex(_ s: String) -> [String] {
        var out: [String] = []
        let c = Array(s); var i = 0
        let multi = ["<<=", ">>=", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "<<", ">>"]
        while i < c.count {
            if c[i] == " " { i += 1; continue }
            if c[i].isNumber {
                var n = ""
                while i < c.count && (c[i].isHexDigit || c[i] == "x" || c[i] == "X") { n.append(c[i]); i += 1 }
                out.append(n); continue
            }
            if c[i].isLetter || c[i] == "_" {
                var n = ""
                while i < c.count && (c[i].isLetter || c[i].isNumber || c[i] == "_") { n.append(c[i]); i += 1 }
                out.append(n); continue
            }
            if let m = multi.first(where: { i + $0.count <= c.count && String(c[i..<i + $0.count]) == $0 }) {
                out.append(m); i += m.count; continue
            }
            out.append(String(c[i])); i += 1
        }
        return out
    }

    private var peek: String? { i < toks.count ? toks[i] : nil }
    private mutating func take() -> String? { defer { i += 1 }; return peek }

    private func value(of name: String) -> Int64 {
        let v = shell.env[name.uppercased()] ?? "0"
        return Arith.number(v) ?? 0
    }
    static func number(_ s: String) -> Int64? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.lowercased().hasPrefix("0x") { return Int64(t.dropFirst(2), radix: 16) }
        if t.count > 1 && t.hasPrefix("0") { return Int64(t.dropFirst(), radix: 8) }
        return Int64(t)
    }

    private mutating func assignment() throws -> Int64 {
        if i + 1 < toks.count, let first = toks[i].first, first.isLetter || first == "_" {
            let name = toks[i], op = toks[i + 1]
            let ops = ["=", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "<<=", ">>="]
            if ops.contains(op) {
                i += 2
                let rhs = try assignment()
                let cur = value(of: name)
                var v: Int64
                switch op {
                case "+=": v = cur &+ rhs
                case "-=": v = cur &- rhs
                case "*=": v = cur &* rhs
                case "/=": guard rhs != 0 else { throw Err() }; v = cur.dividedReportingOverflow(by: rhs).partialValue
                case "%=": guard rhs != 0 else { throw Err() }; v = cur.remainderReportingOverflow(dividingBy: rhs).partialValue
                case "&=": v = cur & rhs
                case "|=": v = cur | rhs
                case "^=": v = cur ^ rhs
                case "<<=": v = cur << rhs
                case ">>=": v = cur >> rhs
                default: v = rhs
                }
                shell.env[name.uppercased()] = String(v)
                return v
            }
        }
        return try bitOr()
    }
    private mutating func bitOr() throws -> Int64 { var l = try bitXor(); while peek == "|" { _ = take(); l |= try bitXor() }; return l }
    private mutating func bitXor() throws -> Int64 { var l = try bitAnd(); while peek == "^" { _ = take(); l ^= try bitAnd() }; return l }
    private mutating func bitAnd() throws -> Int64 { var l = try shift(); while peek == "&" { _ = take(); l &= try shift() }; return l }
    private mutating func shift() throws -> Int64 {
        var l = try add()
        while peek == "<<" || peek == ">>" { let o = take()!; let r = try add(); l = o == "<<" ? l << r : l >> r }
        return l
    }
    private mutating func add() throws -> Int64 {
        var l = try mul()
        while peek == "+" || peek == "-" { let o = take()!; let r = try mul(); l = o == "+" ? l &+ r : l &- r }
        return l
    }
    private mutating func mul() throws -> Int64 {
        var l = try unary()
        while peek == "*" || peek == "/" || peek == "%" {
            let o = take()!; let r = try unary()
            if o == "*" { l = l &* r } else { guard r != 0 else { throw Err() }; l = o == "/" ? l.dividedReportingOverflow(by: r).partialValue : l.remainderReportingOverflow(dividingBy: r).partialValue }
        }
        return l
    }
    private mutating func unary() throws -> Int64 {
        switch peek {
        case "-": _ = take(); return try 0 &- unary()
        case "+": _ = take(); return try unary()
        case "!": _ = take(); return try unary() == 0 ? 1 : 0
        case "~": _ = take(); return try ~unary()
        default: return try primary()
        }
    }
    private mutating func primary() throws -> Int64 {
        guard let t = take() else { throw Err() }
        if t == "(" { let v = try assignment(); guard take() == ")" else { throw Err() }; return v }
        if let n = Arith.number(t) { return n }
        if let f = t.first, f.isLetter || f == "_" { return value(of: t) }
        throw Err()
    }
}
