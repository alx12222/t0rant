import Foundation
import UIKit

/// Extra everyday commands (Unix-style helpers, text tools, archives, info).
@MainActor
enum Extra {
    static let table: [String: Cmd] = [
        "which": which, "alias": alias, "unalias": unalias, "env": env, "printenv": env, "export": export,
        "du": du, "df": df, "stat": stat, "file": file, "uniq": uniq, "cut": cut, "tr": tr, "seq": seq,
        "sleep": sleep, "uuidgen": uuid, "uuid": uuid, "json": json, "jq": json, "zip": zip, "unzip": unzip,
        "cal": cal, "weather": weather, "md5sum": { c in sum(c, "md5") }, "sha1sum": { c in sum(c, "sha1") },
        "sha256sum": { c in sum(c, "sha256") }, "sha512sum": { c in sum(c, "sha512") }, "diff": Commands.fc,
        "nano": Commands.notepad, "vim": Commands.notepad, "vi": Commands.notepad, "code": Commands.notepad,
        "open": Commands.start, "man": Commands.help, "ps": Commands.tasklist, "kill": Commands.taskkill,
        "basename": basename, "dirname": dirname, "realpath": realpath, "ln": Commands.mklink,
        "chmod": chmod, "nl": nl, "tee": tee, "yes": yes, "fold": fold, "column": column, "lower": lower, "upper": upper,
        "count": wc2, "random": random, "speedtest": speedtest, "battery": battery, "screen": screen,
        "echoerr": { c in CmdResult(out: "", err: c.rest, code: 1) }, "true": { _ in CmdResult() },
        "false": { _ in CmdResult(out: "", err: "", code: 1) }, "history": history, "ll": { c in await Commands.dir(c) },
        "backup": backup, "trash": trash, "du-top": duTop, "replace-text": replaceText, "lines": lines,
        "now": { _ in CmdResult(out: ISO8601DateFormatter().string(from: Date())) },
        "epoch": epoch, "bin": binary, "ascii": ascii, "qrtext": { c in CmdResult(out: c.rest) },
    ]

    static func text(_ c: Ctx) -> String { Commands.inputText(c) }
    static func splitLines(_ s: String) -> [String] {
        var l = s.components(separatedBy: "\n"); if l.last == "" { l.removeLast() }; return l
    }

    static func which(_ c: Ctx) -> CmdResult {
        var out: [String] = []
        for n in c.operands {
            let l = n.lowercased()
            if let bin = NodeCommands.binPath(l, shell: c.shell) { out.append(c.fs.winPath(bin) + "  (npm)") }
            else if Commands.table[l] != nil { out.append("C:\\Windows\\System32\\\(l).exe  (built-in)") }
            else if c.shell.aliases[l] != nil { out.append("\(l): aliased to \(c.shell.aliases[l]!)") }
            else { return CmdResult(out: out.joined(separator: "\n"), err: "which: no \(n) in (PATH)", code: 1) }
        }
        return CmdResult(out: out.joined(separator: "\n"))
    }

    static func alias(_ c: Ctx) -> CmdResult {
        let r = c.rest
        guard let eq = r.firstIndex(of: "=") else {
            return CmdResult(out: c.shell.aliases.sorted { $0.key < $1.key }.map { "alias \($0.key)='\($0.value)'" }.joined(separator: "\n"))
        }
        let k = String(r[..<eq]).trimmingCharacters(in: .whitespaces).lowercased()
        var v = String(r[r.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        if (v.hasPrefix("'") && v.hasSuffix("'")) || (v.hasPrefix("\"") && v.hasSuffix("\"")), v.count >= 2 { v = String(v.dropFirst().dropLast()) }
        c.shell.aliases[k] = v
        c.shell.saveSession()
        return CmdResult()
    }
    static func unalias(_ c: Ctx) -> CmdResult {
        for n in c.operands { c.shell.aliases.removeValue(forKey: n.lowercased()) }
        c.shell.saveSession()
        return CmdResult()
    }
    static func env(_ c: Ctx) -> CmdResult {
        CmdResult(out: c.shell.env.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n"))
    }
    static func export(_ c: Ctx) -> CmdResult {
        for a in c.operands {
            guard let eq = a.firstIndex(of: "=") else { continue }
            c.shell.env[String(a[..<eq]).uppercased()] = String(a[a.index(after: eq)...])
        }
        return CmdResult()
    }

    static func size(_ u: URL, _ fs: VirtualFS) -> Int64 {
        guard fs.isDir(u) else { return Int64(fs.entry(u)?.size ?? 0) }
        var t: Int64 = 0
        if let en = fs.fm.enumerator(at: u, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let f as URL in en { t += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
        }
        return t
    }
    static func human(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }

    static func du(_ c: Ctx) -> CmdResult {
        let targets = c.operands.isEmpty ? ["."] : c.operands
        var out: [String] = []
        for t in targets {
            let u = c.fs.resolve(t, cwd: c.shell.cwd)
            guard c.fs.exists(u) else { return Commands.notFound() }
            if c.has("-s") || c.has("/s") || !c.fs.isDir(u) { out.append(Commands.pad(human(size(u, c.fs)), 10) + " " + c.fs.winPath(u)); continue }
            for e in (c.fs.list(u) ?? []).sorted(by: { $0.name.lowercased() < $1.name.lowercased() }) {
                out.append(Commands.pad(human(size(e.url, c.fs)), 10) + " " + e.name + (e.isDir ? "\\" : ""))
            }
            out.append(Commands.pad(human(size(u, c.fs)), 10) + " total")
        }
        return CmdResult(out: out.joined(separator: "\n"))
    }
    static func duTop(_ c: Ctx) -> CmdResult {
        let u = c.fs.resolve(c.operands.first ?? ".", cwd: c.shell.cwd)
        let items = (c.fs.list(u) ?? []).map { ($0.name, size($0.url, c.fs)) }.sorted { $0.1 > $1.1 }.prefix(15)
        return CmdResult(out: items.map { Commands.pad(human($0.1), 10) + " " + $0.0 }.joined(separator: "\n"))
    }
    static func df(_ c: Ctx) -> CmdResult {
        let total = c.fs.totalSpace(), free = c.fs.freeSpace()
        let used = total - free
        let pct = total > 0 ? Int(Double(used) / Double(total) * 100) : 0
        return CmdResult(out: "Filesystem   Size       Used       Avail      Use%  Mounted on\nT0RANT       \(Commands.pad(human(total), 10)) \(Commands.pad(human(used), 10)) \(Commands.pad(human(free), 10)) \(pct)%   C:\\\n\nt0rant data: \(human(size(c.fs.root, c.fs)))")
    }
    static func stat(_ c: Ctx) -> CmdResult {
        guard let p = c.operands.first, let e = c.fs.entry(c.fs.resolve(p, cwd: c.shell.cwd)) else { return Commands.notFound() }
        let a = (try? c.fs.fm.attributesOfItem(atPath: e.url.path)) ?? [:]
        return CmdResult(out: """
          File: \(c.fs.winPath(e.url))
          Size: \(e.size) bytes (\(human(Int64(e.size))))   Type: \(e.isDir ? "directory" : "regular file")
        Access: \(String(format: "%o", (a[.posixPermissions] as? Int) ?? 0))   ReadOnly: \(e.readOnly)
        Created: \((a[.creationDate] as? Date).map { "\($0)" } ?? "?")
        Modify: \(e.modified)
        """)
    }
    static func file(_ c: Ctx) -> CmdResult {
        var out: [String] = []
        for p in c.operands {
            let u = c.fs.resolve(p, cwd: c.shell.cwd)
            if c.fs.isDir(u) { out.append("\(p): directory"); continue }
            guard let d = c.fs.readData(u) else { out.append("\(p): cannot open"); continue }
            let b = [UInt8](d.prefix(16))
            let kind: String
            if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) { kind = "PNG image data" }
            else if b.starts(with: [0xFF, 0xD8, 0xFF]) { kind = "JPEG image data" }
            else if b.starts(with: [0x47, 0x49, 0x46]) { kind = "GIF image data" }
            else if b.starts(with: [0x25, 0x50, 0x44, 0x46]) { kind = "PDF document" }
            else if b.starts(with: [0x50, 0x4B, 0x03, 0x04]) { kind = "Zip archive data" }
            else if b.starts(with: [0x1F, 0x8B]) { kind = "gzip compressed data" }
            else if b.starts(with: [0x7F, 0x45, 0x4C, 0x46]) { kind = "ELF executable" }
            else if b.starts(with: [0x4D, 0x5A]) { kind = "PE32 executable (MS Windows)" }
            else if b.starts(with: [0xCF, 0xFA, 0xED, 0xFE]) || b.starts(with: [0xCA, 0xFE, 0xBA, 0xBE]) { kind = "Mach-O binary" }
            else if d.isEmpty { kind = "empty" }
            else if String(data: d.prefix(4096), encoding: .utf8) != nil {
                let s = String(decoding: d.prefix(200), as: UTF8.self)
                kind = s.hasPrefix("#!") ? "script text (\(s.prefix(while: { $0 != "\n" })))" : s.trimmingCharacters(in: .whitespaces).hasPrefix("{") ? "JSON text" : "ASCII/UTF-8 text"
            } else { kind = "data" }
            out.append("\(p): \(kind)")
        }
        return CmdResult(out: out.joined(separator: "\n"))
    }

    static func uniq(_ c: Ctx) -> CmdResult {
        var out: [String] = []; var counts: [Int] = []
        for l in splitLines(text(Ctx(shell: c.shell, args: c.operands.filter { !$0.hasPrefix("-") }, stdin: c.stdin, raw: c.raw))) {
            if out.last == l { counts[counts.count - 1] += 1 } else { out.append(l); counts.append(1) }
        }
        if c.args.contains("-c") { return CmdResult(out: Swift.zip(counts, out).map { Commands.pad(String($0.0), 7, left: true) + " " + $0.1 }.joined(separator: "\n")) }
        if c.args.contains("-d") { return CmdResult(out: Swift.zip(counts, out).filter { $0.0 > 1 }.map { $0.1 }.joined(separator: "\n")) }
        return CmdResult(out: out.joined(separator: "\n"))
    }
    static func cut(_ c: Ctx) -> CmdResult {
        var delim = "\t"; var fields: [Int] = []; var chars: ClosedRange<Int>?
        var i = 0; var files: [String] = []
        while i < c.args.count {
            let a = c.args[i]
            func val() -> String { if a.count > 2 { return String(a.dropFirst(2)) }; i += 1; return i < c.args.count ? c.args[i] : "" }
            if a.hasPrefix("-d") { delim = val() }
            else if a.hasPrefix("-f") { fields = val().split(separator: ",").flatMap { p -> [Int] in let r = p.split(separator: "-").compactMap { Int($0) }; return r.count == 2 ? Array(r[0]...r[1]) : r } }
            else if a.hasPrefix("-c") { let r = val().split(separator: "-").compactMap { Int($0) }; if let f = r.first { let lo = max(1, f); chars = lo...max(lo, r.count > 1 ? r[1] : lo) } }
            else { files.append(a) }
            i += 1
        }
        let input = text(Ctx(shell: c.shell, args: files, stdin: c.stdin, raw: c.raw))
        return CmdResult(out: splitLines(input).map { l in
            if let r = chars { let a = Array(l); return String(a[min(a.count, r.lowerBound - 1)..<min(a.count, r.upperBound)]) }
            let parts = l.components(separatedBy: delim)
            return fields.compactMap { $0 - 1 < parts.count && $0 > 0 ? parts[$0 - 1] : nil }.joined(separator: delim)
        }.joined(separator: "\n"))
    }
    static func tr(_ c: Ctx) -> CmdResult {
        let ops = c.args.filter { !$0.hasPrefix("-") }
        var s = c.stdin ?? ""
        func expand(_ x: String) -> [Character] {
            switch x {
            case "a-z", "[:lower:]": return Array("abcdefghijklmnopqrstuvwxyz")
            case "A-Z", "[:upper:]": return Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
            case "0-9", "[:digit:]": return Array("0123456789")
            default: return Array(x.replacingOccurrences(of: "\\n", with: "\n"))
            }
        }
        if c.args.contains("-d"), let set = ops.first { let d = Set(expand(set)); s.removeAll { d.contains($0) }; return CmdResult(out: s) }
        guard ops.count >= 2 else { return .error("usage: tr [-d] set1 [set2]") }
        let a = expand(ops[0]), b = expand(ops[1])
        var map: [Character: Character] = [:]
        for (i, ch) in a.enumerated() { map[ch] = b.isEmpty ? ch : b[min(i, b.count - 1)] }
        return CmdResult(out: String(s.map { map[$0] ?? $0 }))
    }
    static func seq(_ c: Ctx) -> CmdResult {
        let n = c.operands.compactMap { Int($0) }
        let (start, step, end): (Int, Int, Int) = n.count >= 3 ? (n[0], n[1], n[2]) : n.count == 2 ? (n[0], 1, n[1]) : (1, 1, n.first ?? 1)
        guard step != 0 else { return .error("seq: step can't be zero") }
        var out: [String] = []; var v = start
        while (step > 0 ? v <= end : v >= end) && out.count < 100_000 { out.append(String(v)); v += step }
        return CmdResult(out: out.joined(separator: "\n"))
    }
    static func sleep(_ c: Ctx) async -> CmdResult {
        let s = Double(c.operands.first ?? "1") ?? 1
        var left = s
        while left > 0 && !c.shell.cancelled { try? await Task.sleep(nanoseconds: UInt64(min(left, 0.25) * 1e9)); left -= 0.25 }
        return CmdResult()
    }
    static func uuid(_ c: Ctx) -> CmdResult { CmdResult(out: UUID().uuidString.lowercased()) }

    static func json(_ c: Ctx) -> CmdResult {
        var ops = c.operands
        var path = "."
        if let f = ops.first, f.hasPrefix(".") { path = f; ops.removeFirst() }
        let raw = text(Ctx(shell: c.shell, args: ops, stdin: c.stdin, raw: c.raw))
        guard let d = raw.data(using: .utf8), var obj = try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed]) else {
            return .error("json: input is not valid JSON")
        }
        for key in path.split(separator: ".").map(String.init) where !key.isEmpty {
            if key.hasSuffix("]"), let lb = key.firstIndex(of: "[") {
                let name = String(key[..<lb]); let idx = Int(key[key.index(after: lb)..<key.index(before: key.endIndex)]) ?? 0
                if !name.isEmpty { obj = (obj as? [String: Any])?[name] ?? NSNull() }
                let arr = obj as? [Any] ?? []
                obj = idx < arr.count ? arr[idx] : NSNull()
            } else { obj = (obj as? [String: Any])?[key] ?? NSNull() }
        }
        if let s = obj as? String { return CmdResult(out: s) }
        if obj is NSNull { return CmdResult(out: "null") }
        guard JSONSerialization.isValidJSONObject(obj),
              let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { return CmdResult(out: "\(obj)") }
        return CmdResult(out: String(decoding: out, as: UTF8.self))
    }

    // Archives use Python's zipfile/tarfile (bundled), so every format Python supports works.
    static func zip(_ c: Ctx) async -> CmdResult {
        let o = c.operands.filter { !$0.hasPrefix("-") }
        guard o.count >= 2 else { return CmdResult(out: "Usage: zip archive.zip file_or_folder [...]") }
        let paths = o.map { c.fs.resolve($0, cwd: c.shell.cwd).path }
        let code = """
        import zipfile, os, sys
        out, srcs = sys.argv[1], sys.argv[2:]
        n = 0
        with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
            for s in srcs:
                base = os.path.dirname(s.rstrip('/'))
                if os.path.isdir(s):
                    for root, _, files in os.walk(s):
                        for f in files:
                            p = os.path.join(root, f); z.write(p, os.path.relpath(p, base)); n += 1
                else:
                    z.write(s, os.path.basename(s)); n += 1
        print(f"  adding {n} file(s) -> {os.path.basename(out)}")
        """
        return PythonCommands.result(await PythonRuntime.shared.call("run_code", code, (["zip"] + paths).joined(separator: "\u{1f}"), cwd: c.fs.url(c.shell.cwd).path))
    }
    static func unzip(_ c: Ctx) async -> CmdResult {
        let o = c.operands.filter { !$0.hasPrefix("-") }
        guard let a = o.first else { return CmdResult(out: "Usage: unzip archive.(zip|tar|tar.gz|tgz) [-d folder]  |  unzip -l archive") }
        let archive = c.fs.resolve(a, cwd: c.shell.cwd)
        guard c.fs.exists(archive) else { return Commands.notFound() }
        var dest = archive.deletingPathExtension()
        if let i = c.args.firstIndex(of: "-d"), i + 1 < c.args.count { dest = c.fs.resolve(c.args[i + 1], cwd: c.shell.cwd) }
        if dest.pathExtension == "tar" { dest = dest.deletingPathExtension() }
        let list = c.args.contains("-l") ? "1" : "0"
        let code = """
        import zipfile, tarfile, sys, os
        src, dst, listing = sys.argv[1], sys.argv[2], sys.argv[3] == '1'
        if zipfile.is_zipfile(src):
            with zipfile.ZipFile(src) as z:
                if listing:
                    for i in z.infolist(): print(f"{i.file_size:>10}  {i.filename}")
                else:
                    z.extractall(dst); print(f"Extracted {len(z.namelist())} entries to {os.path.basename(dst)}")
        elif tarfile.is_tarfile(src):
            with tarfile.open(src) as t:
                if listing:
                    for m in t.getmembers(): print(f"{m.size:>10}  {m.name}")
                else:
                    t.extractall(dst, filter='data'); print(f"Extracted {len(t.getmembers())} entries to {os.path.basename(dst)}")
        else:
            print("unzip: not a zip or tar archive"); sys.exit(1)
        """
        return PythonCommands.result(await PythonRuntime.shared.call("run_code", code, ["unzip", archive.path, dest.path, list].joined(separator: "\u{1f}"), cwd: c.fs.url(c.shell.cwd).path))
    }

    static func cal(_ c: Ctx) -> CmdResult {
        let cal = Calendar(identifier: .gregorian)
        let now = Date()
        var comps = cal.dateComponents([.year, .month], from: now)
        let n = c.operands.compactMap { Int($0) }
        if n.count == 2 { comps.month = n[0]; comps.year = n[1] } else if n.count == 1 { comps.month = n[0] }
        guard let first = cal.date(from: comps), let range = cal.range(of: .day, in: .month, for: first) else { return Commands.syntax() }
        let f = DateFormatter(); f.dateFormat = "MMMM yyyy"
        let title = f.string(from: first)
        var out = [String(repeating: " ", count: max(0, (20 - title.count) / 2)) + title, "Su Mo Tu We Th Fr Sa"]
        var row = String(repeating: "   ", count: cal.component(.weekday, from: first) - 1)
        let today = cal.isDate(first, equalTo: now, toGranularity: .month) ? cal.component(.day, from: now) : -1
        for d in range {
            row += (d == today ? "[\(d)]".padding(toLength: 3, withPad: " ", startingAt: 0) : Commands.pad(String(d), 2, left: true) + " ")
            if (row.count / 3) % 7 == 0 { out.append(row); row = "" }
        }
        if !row.isEmpty { out.append(row) }
        return CmdResult(out: out.joined(separator: "\n"))
    }
    static func weather(_ c: Ctx) async -> CmdResult {
        let place = c.operands.joined(separator: "+").addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
        guard let (d, _) = await Tools.fetch("https://wttr.in/\(place)?T&n&0", headers: ["User-Agent": "curl/8"]) else { return .error("weather: service unavailable") }
        return CmdResult(out: String(decoding: d, as: UTF8.self))
    }
    static func sum(_ c: Ctx, _ alg: String) -> CmdResult {
        var out: [String] = []
        for f in c.operands {
            let r = Tools.hash(Ctx(shell: c.shell, args: [f, "-a", alg], stdin: nil, raw: ""))
            out.append("\(r.out)  \(f)")
        }
        if c.operands.isEmpty { return Tools.hash(Ctx(shell: c.shell, args: ["-a", alg], stdin: c.stdin, raw: "")) }
        return CmdResult(out: out.joined(separator: "\n"))
    }
    static func basename(_ c: Ctx) -> CmdResult {
        CmdResult(out: (c.operands.first ?? "").replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? "")
    }
    static func dirname(_ c: Ctx) -> CmdResult {
        let p = (c.operands.first ?? "").replacingOccurrences(of: "/", with: "\\")
        guard let i = p.lastIndex(of: "\\") else { return CmdResult(out: ".") }
        return CmdResult(out: String(p[..<i]))
    }
    static func realpath(_ c: Ctx) -> CmdResult {
        CmdResult(out: c.operands.map { c.fs.winPath(c.fs.resolve($0, cwd: c.shell.cwd)) }.joined(separator: "\n"))
    }
    static func chmod(_ c: Ctx) -> CmdResult {
        let o = c.operands
        guard o.count >= 2 else { return .error("usage: chmod MODE FILE...") }
        let mode: Int
        if let m = Int(o[0], radix: 8) { mode = m } else if o[0].contains("+w") { mode = 0o644 } else if o[0].contains("-w") { mode = 0o444 } else { mode = 0o644 }
        for f in o.dropFirst() { try? c.fs.fm.setAttributes([.posixPermissions: mode], ofItemAtPath: c.fs.resolve(f, cwd: c.shell.cwd).path) }
        return CmdResult()
    }
    static func nl(_ c: Ctx) -> CmdResult {
        CmdResult(out: splitLines(text(c)).enumerated().map { Commands.pad(String($0.offset + 1), 6, left: true) + "  " + $0.element }.joined(separator: "\n"))
    }
    static func tee(_ c: Ctx) -> CmdResult {
        let s = c.stdin ?? ""
        let append = c.args.contains("-a")
        for f in c.operands where !f.hasPrefix("-") {
            let u = c.fs.resolve(f, cwd: c.shell.cwd)
            c.fs.write(u, (append ? (c.fs.read(u) ?? "") : "") + s + (s.hasSuffix("\n") ? "" : "\n"))
        }
        return CmdResult(out: s)
    }
    static func yes(_ c: Ctx) -> CmdResult {
        CmdResult(out: Array(repeating: c.operands.first ?? "y", count: 100).joined(separator: "\n"))
    }
    static func fold(_ c: Ctx) -> CmdResult {
        let w = Int(c.args.first { $0.hasPrefix("-w") }.map { String($0.dropFirst(2)) } ?? "") ?? 80
        var out: [String] = []
        for l in splitLines(c.stdin ?? text(c)) {
            var a = Array(l)
            if a.isEmpty { out.append("") }
            while !a.isEmpty { out.append(String(a.prefix(max(1, w)))); a.removeFirst(min(a.count, max(1, w))) }
        }
        return CmdResult(out: out.joined(separator: "\n"))
    }
    static func column(_ c: Ctx) -> CmdResult {
        let rows = splitLines(text(c)).map { $0.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "," }).map(String.init) }
        let widths = (0..<(rows.map { $0.count }.max() ?? 0)).map { i in rows.map { i < $0.count ? $0[i].count : 0 }.max() ?? 0 }
        return CmdResult(out: rows.map { r in r.enumerated().map { Commands.pad($0.element, widths[$0.offset] + 2) }.joined() }.joined(separator: "\n"))
    }
    static func lower(_ c: Ctx) -> CmdResult { CmdResult(out: (c.stdin ?? c.args.joined(separator: " ")).lowercased()) }
    static func upper(_ c: Ctx) -> CmdResult { CmdResult(out: (c.stdin ?? c.args.joined(separator: " ")).uppercased()) }
    static func wc2(_ c: Ctx) -> CmdResult { Commands.wc(c) }
    static func random(_ c: Ctx) -> CmdResult {
        let n = c.operands.compactMap { Int($0) }
        let lo = n.count >= 2 ? n[0] : 1, hi = n.count >= 2 ? n[1] : (n.first ?? 100)
        return CmdResult(out: String(Int.random(in: min(lo, hi)...max(lo, hi))))
    }
    static func speedtest(_ c: Ctx) async -> CmdResult {
        c.shell.print("Testing download speed (25 MB from speed.cloudflare.com)...")
        let start = Date()
        guard let (d, _) = await Tools.fetch("https://speed.cloudflare.com/__down?bytes=25000000") else { return .error("speedtest: failed") }
        let secs = Date().timeIntervalSince(start)
        let mbps = Double(d.count) * 8 / secs / 1_000_000
        let pingStart = Date()
        _ = await Tools.fetch("https://speed.cloudflare.com/__down?bytes=0")
        return CmdResult(out: String(format: "Download: %.1f Mbit/s (%@ in %.1fs)\nLatency:  %.0f ms", mbps, human(Int64(d.count)), secs, Date().timeIntervalSince(pingStart) * 1000))
    }
    static func battery(_ c: Ctx) -> CmdResult {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let lvl = UIDevice.current.batteryLevel
        let st = ["unknown", "unplugged", "charging", "full"][min(3, UIDevice.current.batteryState.rawValue)]
        return CmdResult(out: lvl < 0 ? "Battery: unknown" : "Battery: \(Int(lvl * 100))% (\(st))\nLow Power Mode: \(ProcessInfo.processInfo.isLowPowerModeEnabled ? "on" : "off")")
    }
    static func screen(_ c: Ctx) -> CmdResult {
        let s = UIScreen.main
        return CmdResult(out: "Resolution: \(Int(s.nativeBounds.width))x\(Int(s.nativeBounds.height)) @\(Int(s.nativeScale))x\nBrightness: \(Int(s.brightness * 100))%\nMax FPS: \(s.maximumFramesPerSecond)")
    }
    static func history(_ c: Ctx) -> CmdResult {
        if c.args.contains("-c") { c.shell.history.removeAll(); c.shell.saveSession(); return CmdResult(out: "History cleared.") }
        let h = c.shell.history
        let n = Int(c.operands.first ?? "") ?? h.count
        return CmdResult(out: h.enumerated().suffix(n).map { Commands.pad(String($0.offset + 1), 5, left: true) + "  " + $0.element }.joined(separator: "\n"))
    }
    /// backup <path>: timestamped copy into C:\Users\<you>\Backups
    static func backup(_ c: Ctx) -> CmdResult {
        guard let p = c.operands.first else { return CmdResult(out: "Usage: backup <file|folder>   (copies to C:\\Users\\<you>\\Backups with a timestamp)") }
        let src = c.fs.resolve(p, cwd: c.shell.cwd)
        guard c.fs.exists(src) else { return Commands.notFound() }
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        let dest = c.fs.url(["Users", c.fs.user, "Backups"]).appendingPathComponent("\(src.lastPathComponent)-\(f.string(from: Date()))")
        try? c.fs.fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        do { try c.fs.fm.copyItem(at: src, to: dest) } catch { return .error("backup: \(error.localizedDescription)") }
        return CmdResult(out: "Backed up to \(c.fs.winPath(dest))")
    }
    /// trash <path>: recoverable delete into C:\Users\<you>\Trash
    static func trash(_ c: Ctx) -> CmdResult {
        let bin = c.fs.url(["Users", c.fs.user, "Trash"])
        if c.operands.isEmpty || c.args.contains("-l") {
            return CmdResult(out: (c.fs.list(bin) ?? []).map { $0.name }.sorted().joined(separator: "\n").ifEmpty("Trash is empty."))
        }
        if c.args.contains("--empty") { try? c.fs.fm.removeItem(at: bin); return CmdResult(out: "Trash emptied.") }
        try? c.fs.fm.createDirectory(at: bin, withIntermediateDirectories: true)
        for p in c.operands {
            let u = c.fs.resolve(p, cwd: c.shell.cwd)
            guard c.fs.exists(u) else { return Commands.notFound() }
            var dest = bin.appendingPathComponent(u.lastPathComponent)
            if c.fs.exists(dest) { dest = bin.appendingPathComponent("\(Int(Date().timeIntervalSince1970))-\(u.lastPathComponent)") }
            try? c.fs.fm.moveItem(at: u, to: dest)
        }
        return CmdResult(out: "Moved to trash (C:\\Users\\\(c.fs.user)\\Trash). Restore with: move <name> <dest>")
    }
    static func replaceText(_ c: Ctx) -> CmdResult {
        let o = c.operands
        guard o.count == 3 else { return CmdResult(out: "Usage: replace-text <file> <find> <replace>") }
        let u = c.fs.resolve(o[0], cwd: c.shell.cwd)
        guard let t = c.fs.read(u) else { return Commands.notFound() }
        let count = t.components(separatedBy: o[1]).count - 1
        c.fs.write(u, t.replacingOccurrences(of: o[1], with: o[2]))
        return CmdResult(out: "Replaced \(count) occurrence(s).")
    }
    static func lines(_ c: Ctx) -> CmdResult {
        let o = c.operands
        guard o.count >= 2, let a = Int(o[1]) else { return CmdResult(out: "Usage: lines <file> <from> [to]") }
        let b = o.count > 2 ? Int(o[2]) ?? a : a
        let all = splitLines(c.fs.read(c.fs.resolve(o[0], cwd: c.shell.cwd)) ?? "")
        guard a >= 1, a <= all.count else { return CmdResult(out: "") }
        return CmdResult(out: all[(a - 1)..<min(all.count, max(a, b))].joined(separator: "\n"))
    }
    static func epoch(_ c: Ctx) -> CmdResult {
        if let t = c.operands.first.flatMap(Double.init) { return CmdResult(out: "\(Date(timeIntervalSince1970: t > 1e12 ? t / 1000 : t))") }
        return CmdResult(out: String(Int(Date().timeIntervalSince1970)))
    }
    static func binary(_ c: Ctx) -> CmdResult {
        guard let n = c.operands.first.flatMap({ Int($0) }) else { return CmdResult(out: "Usage: bin <number>   (shows binary, octal, hex)") }
        return CmdResult(out: "dec \(n)\nbin \(String(n, radix: 2))\noct \(String(n, radix: 8))\nhex \(String(n, radix: 16).uppercased())")
    }
    static func ascii(_ c: Ctx) -> CmdResult {
        CmdResult(out: (32..<127).map { i in Commands.pad("\(i)", 4, left: true) + " " + String(UnicodeScalar(UInt8(i))) }.chunked(6).map { $0.joined(separator: "   ") }.joined(separator: "\n"))
    }
}

extension String {
    func ifEmpty(_ s: String) -> String { isEmpty ? s : self }
}
extension Array {
    func chunked(_ n: Int) -> [[Element]] { stride(from: 0, to: count, by: n).map { Array(self[$0..<Swift.min($0 + n, count)]) } }
}
