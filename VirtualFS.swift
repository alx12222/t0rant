import Foundation

struct Entry {
    let name: String
    let url: URL
    let isDir: Bool
    let size: Int
    let modified: Date
    let hidden: Bool
    let readOnly: Bool
}

/// Sandboxed C: drive stored in the app's Documents folder (visible in the Files app).
final class VirtualFS {
    let fm = FileManager.default
    let root: URL
    var user = "t0rant"

    init() {
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        root = docs.appendingPathComponent("C", isDirectory: true)
    }

    func bootstrap() {
        let h = "Users/\(user)"
        let dirs = ["\(h)/Desktop", "\(h)/Documents", "\(h)/Downloads",
                    "\(h)/AppData/Local/Temp", "\(h)/AppData/Roaming", "Users/Public", "Python/site-packages",
                    "Windows/System32/drivers/etc", "Program Files", "Program Files (x86)", "ProgramData"]
        for d in dirs { try? fm.createDirectory(at: root.appendingPathComponent(d), withIntermediateDirectories: true) }
        let hosts = root.appendingPathComponent("Windows/System32/drivers/etc/hosts")
        if !fm.fileExists(atPath: hosts.path) {
            write(hosts, "# Copyright (c) 1993-2009 Microsoft Corp.\n#\n127.0.0.1       localhost\n::1             localhost\n")
        }
        let readme = root.appendingPathComponent("\(h)/Desktop/readme.txt")
        if !fm.fileExists(atPath: readme.path) {
            write(readme, "Welcome to t0rant!\nYour C: drive lives in the Files app under On My iPhone > t0rant > C.\nTry: dir, tree, type readme.txt, ping google.com, curl https://example.com, help\n")
        }
        let demo = root.appendingPathComponent("\(h)/Desktop/hello.bat")
        if !fm.fileExists(atPath: demo.path) {
            write(demo, "@echo off\nsetlocal\nset /a n=0\n:loop\nset /a n+=1\necho Hello #%n% from a batch file, args: %*\nif %n% LSS 3 goto loop\necho Done.\nendlocal\n")
        }
    }

    /// Converts a Windows path (absolute or relative) into a URL inside the sandbox.
    func components(_ path: String, cwd: [String]) -> [String] {
        var p = path.replacingOccurrences(of: "/", with: "\\").replacingOccurrences(of: "\"", with: "")
        var comps: [String]
        if p.lowercased().hasPrefix("c:") {
            p = String(p.dropFirst(2))
            comps = p.hasPrefix("\\") ? [] : cwd
        } else if p.hasPrefix("\\") {
            comps = []
        } else {
            comps = cwd
        }
        if p.hasPrefix("~") { comps = ["Users", user]; p = String(p.dropFirst()) }
        for part in p.split(separator: "\\") {
            switch part {
            case ".": continue
            case "..": if !comps.isEmpty { comps.removeLast() }
            case "...": if comps.count >= 2 { comps.removeLast(2) } else { comps.removeAll() }
            default: comps.append(matchCase(String(part), in: comps))
            }
        }
        return comps
    }

    /// Case-insensitive lookup to mirror NTFS behaviour.
    private func matchCase(_ name: String, in comps: [String]) -> String {
        let dir = url(comps)
        if let items = try? fm.contentsOfDirectory(atPath: dir.path),
           let m = items.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            return m
        }
        return name
    }

    func url(_ comps: [String]) -> URL {
        comps.reduce(root) { $0.appendingPathComponent($1) }
    }

    func resolve(_ path: String, cwd: [String]) -> URL { url(components(path, cwd: cwd)) }

    func winPath(_ u: URL) -> String {
        let rel = u.standardizedFileURL.path.replacingOccurrences(of: root.standardizedFileURL.path, with: "")
        let w = rel.replacingOccurrences(of: "/", with: "\\")
        return "C:" + (w.isEmpty ? "\\" : w)
    }

    func exists(_ u: URL) -> Bool { fm.fileExists(atPath: u.path) }
    func isDir(_ u: URL) -> Bool {
        var d: ObjCBool = false
        return fm.fileExists(atPath: u.path, isDirectory: &d) && d.boolValue
    }

    func entry(_ u: URL) -> Entry? {
        guard let a = try? fm.attributesOfItem(atPath: u.path) else { return nil }
        let dir = (a[.type] as? FileAttributeType) == .typeDirectory
        let perms = (a[.posixPermissions] as? Int) ?? 0o644
        return Entry(name: u.lastPathComponent, url: u, isDir: dir, size: (a[.size] as? Int) ?? 0,
                     modified: (a[.modificationDate] as? Date) ?? Date(),
                     hidden: u.lastPathComponent.hasPrefix("."), readOnly: perms & 0o200 == 0)
    }

    func list(_ u: URL) -> [Entry]? {
        guard isDir(u), let items = try? fm.contentsOfDirectory(atPath: u.path) else { return nil }
        return items.compactMap { entry(u.appendingPathComponent($0)) }
    }

    /// Expands wildcards (* and ?) in the final path component.
    func glob(_ path: String, cwd: [String]) -> [URL] {
        let u = resolve(path, cwd: cwd)
        let name = u.lastPathComponent
        guard name.contains("*") || name.contains("?") else { return exists(u) ? [u] : [] }
        let parent = u.deletingLastPathComponent()
        let pattern = name == "*.*" ? "*" : name
        return (list(parent) ?? []).filter { VirtualFS.wildcard(pattern, $0.name) }.map { $0.url }
            .sorted { $0.lastPathComponent.lowercased() < $1.lastPathComponent.lowercased() }
    }

    static func wildcard(_ pattern: String, _ s: String) -> Bool {
        let p = Array(pattern.lowercased()), t = Array(s.lowercased())
        var memo = [[Bool?]](repeating: [Bool?](repeating: nil, count: t.count + 1), count: p.count + 1)
        func m(_ i: Int, _ j: Int) -> Bool {
            if let v = memo[i][j] { return v }
            var r: Bool
            if i == p.count { r = j == t.count }
            else if p[i] == "*" { r = m(i + 1, j) || (j < t.count && m(i, j + 1)) }
            else if j < t.count && (p[i] == "?" || p[i] == t[j]) { r = m(i + 1, j + 1) }
            else { r = false }
            memo[i][j] = r
            return r
        }
        return m(0, 0)
    }

    func read(_ u: URL) -> String? {
        guard !isDir(u), let d = try? Data(contentsOf: u) else { return nil }
        return String(data: d, encoding: .utf8) ?? String(data: d, encoding: .isoLatin1)
    }
    func readData(_ u: URL) -> Data? { try? Data(contentsOf: u) }

    @discardableResult
    func write(_ u: URL, _ s: String) -> Bool {
        try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? s.data(using: .utf8)?.write(to: u)) != nil
    }
    @discardableResult
    func writeData(_ u: URL, _ d: Data) -> Bool {
        try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? d.write(to: u)) != nil
    }

    func freeSpace() -> Int64 {
        let v = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return v?.volumeAvailableCapacityForImportantUsage ?? 0
    }
    func totalSpace() -> Int64 {
        let v = try? root.resourceValues(forKeys: [.volumeTotalCapacityKey])
        return Int64(v?.volumeTotalCapacity ?? 0)
    }
}
