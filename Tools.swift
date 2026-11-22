import Foundation
import Network
import CryptoKit

/// Built-in network / security toolkit (all TCP/HTTP based — iOS forbids raw sockets).
@MainActor
enum Tools {
    static let table: [String: Cmd] = [
        "portscan": portscan, "nmap": portscan, "whois": whois, "dig": dig, "host": dig,
        "subenum": subenum, "subfinder": subenum, "headers": headers, "sslcheck": sslcheck,
        "geoip": geoip, "myip": myip, "nc": nc, "ncat": nc, "netcat": nc, "hash": hash,
        "hashid": hashid, "jwt": jwt, "urlencode": urlencode, "urldecode": urldecode, "hex": hex,
        "rot13": rot13, "dirbust": dirbust, "gobuster": dirbust, "pkg": pkg, "techdetect": techdetect,
        "passgen": passgen, "banner": banner,
    ]

    static func arg(_ c: Ctx, _ names: [String]) -> String? {
        guard let i = c.args.firstIndex(where: { names.contains($0.lowercased()) }), i + 1 < c.args.count else { return nil }
        return c.args[i + 1]
    }
    static func positional(_ c: Ctx) -> [String] {
        var out: [String] = []; var skip = false
        for a in c.args {
            if skip { skip = false; continue }
            if a.hasPrefix("-") { skip = ["-p", "-t", "-w", "-c", "-a", "--timeout", "-n"].contains(a.lowercased()); continue }
            out.append(a)
        }
        return out
    }
    static func fetch(_ url: String, method: String = "GET", headers: [String: String] = [:]) async -> (Data, HTTPURLResponse)? {
        guard let u = URL(string: url) else { return nil }
        var r = URLRequest(url: u, timeoutInterval: 20)
        r.httpMethod = method
        r.setValue("t0rant/1.0", forHTTPHeaderField: "User-Agent")
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        guard let (d, resp) = try? await URLSession.shared.data(for: r), let h = resp as? HTTPURLResponse else { return nil }
        return (d, h)
    }
    static func json(_ d: Data) -> Any? { try? JSONSerialization.jsonObject(with: d) }

    // MARK: port scanning
    static func parsePorts(_ s: String) -> [UInt16] {
        if s == "top" || s.isEmpty {
            return [21, 22, 23, 25, 53, 80, 110, 111, 135, 139, 143, 389, 443, 445, 465, 587, 993, 995, 1433, 1521, 1723,
                    2049, 2375, 3000, 3306, 3389, 5000, 5432, 5900, 5985, 6379, 8000, 8008, 8080, 8443, 8888, 9000, 9200, 11211, 27017]
        }
        var r: [UInt16] = []
        for part in s.split(separator: ",") {
            let b = part.split(separator: "-").compactMap { UInt16($0) }
            if b.count == 2, b[0] <= b[1] { r += Array(b[0]...b[1]) } else if let p = b.first { r.append(p) }
        }
        return r
    }
    static let services: [UInt16: String] = [21: "ftp", 22: "ssh", 23: "telnet", 25: "smtp", 53: "domain", 80: "http", 110: "pop3",
        111: "rpcbind", 135: "msrpc", 139: "netbios-ssn", 143: "imap", 389: "ldap", 443: "https", 445: "microsoft-ds", 465: "smtps",
        587: "submission", 993: "imaps", 995: "pop3s", 1433: "ms-sql", 1521: "oracle", 1723: "pptp", 2049: "nfs", 2375: "docker",
        3000: "ppp/dev", 3306: "mysql", 3389: "ms-wbt-server", 5000: "upnp", 5432: "postgresql", 5900: "vnc", 5985: "winrm",
        6379: "redis", 8000: "http-alt", 8008: "http", 8080: "http-proxy", 8443: "https-alt", 8888: "sun-answerbook",
        9000: "cslistener", 9200: "elasticsearch", 11211: "memcache", 27017: "mongodb"]

    static func portscan(_ c: Ctx) async -> CmdResult {
        guard let host = positional(c).first else {
            return CmdResult(out: "Usage: portscan <host> [-p 1-1024|22,80,443|top] [-t timeoutSec]\nTCP connect scan. Only scan hosts you own or are authorized to test.")
        }
        let ports = parsePorts(arg(c, ["-p"]) ?? "top")
        let timeout = Double(arg(c, ["-t", "--timeout"]) ?? "") ?? 1.5
        guard ports.count <= 65535 else { return .error("Too many ports") }
        c.shell.print("Starting t0rant scan of \(host) (\(ports.count) TCP ports)")
        let start = Date()
        var open: [(UInt16, Double)] = []
        let batch = 64
        var idx = 0
        while idx < ports.count {
            if c.shell.cancelled { break }
            let chunk = Array(ports[idx..<min(idx + batch, ports.count)])
            let results = await withTaskGroup(of: (UInt16, Double?).self) { g -> [(UInt16, Double?)] in
                for p in chunk { g.addTask { (p, await Commands.tcpPing(host, port: p, timeout: timeout)) } }
                var r: [(UInt16, Double?)] = []
                for await x in g { r.append(x) }
                return r
            }
            for (p, t) in results { if let t { open.append((p, t)) } }
            idx += batch
        }
        open.sort { $0.0 < $1.0 }
        var out = ["PORT      STATE  SERVICE         RTT"]
        for (p, t) in open {
            out.append(Commands.pad("\(p)/tcp", 10) + "open   " + Commands.pad(services[p] ?? "unknown", 16) + "\(Int(t))ms")
        }
        out.append("\nNot shown: \(ports.count - open.count) closed/filtered ports")
        out.append("Scan done: 1 host scanned in \(String(format: "%.2f", Date().timeIntervalSince(start))) seconds")
        return CmdResult(out: out.joined(separator: "\n"))
    }

    // MARK: raw TCP helpers
    static func tcpExchange(_ host: String, port: UInt16, send: Data?, tls: Bool = false, timeout: Double = 8) async -> Data? {
        await withCheckedContinuation { cont in
            let params: NWParameters = tls ? .tls : .tcp
            let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: params)
            var buffer = Data()
            var done = false
            let lock = NSLock()
            func finish() {
                lock.lock(); defer { lock.unlock() }
                if done { return }
                done = true
                conn.cancel()
                cont.resume(returning: buffer.isEmpty ? nil : buffer)
            }
            func receive() {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { d, _, complete, err in
                    if let d { lock.lock(); buffer.append(d); lock.unlock() }
                    if complete || err != nil { finish() } else { receive() }
                }
            }
            conn.stateUpdateHandler = { st in
                switch st {
                case .ready:
                    if let s = send { conn.send(content: s, completion: .contentProcessed { _ in }) }
                    receive()
                case .failed, .cancelled: finish()
                default: break
                }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish() }
        }
    }

    static func nc(_ c: Ctx) async -> CmdResult {
        let p = positional(c)
        guard p.count >= 2, let port = UInt16(p[1]) else {
            return CmdResult(out: "Usage: nc <host> <port> [text to send]   (pipe input: echo GET / | nc host 80)\n  -z  only test whether the port is open\n  --ssl  use TLS")
        }
        if c.args.contains("-z") {
            let t = await Commands.tcpPing(p[0], port: port)
            return t != nil ? CmdResult(out: "Connection to \(p[0]) \(port) port [tcp] succeeded!") : .error("nc: connect to \(p[0]) port \(port) (tcp) failed")
        }
        var payload = p.count > 2 ? p[2...].joined(separator: " ") + "\r\n" : (c.stdin ?? "")
        payload = payload.replacingOccurrences(of: "\\r\\n", with: "\r\n").replacingOccurrences(of: "\\n", with: "\n")
        let data = await tcpExchange(p[0], port: port, send: payload.isEmpty ? nil : Data(payload.utf8), tls: c.args.contains("--ssl"), timeout: 6)
        guard let d = data else { return CmdResult(out: "(connected, no data received)") }
        return CmdResult(out: String(data: d, encoding: .utf8) ?? String(data: d, encoding: .isoLatin1) ?? "\(d.count) bytes")
    }

    static func banner(_ c: Ctx) async -> CmdResult {
        let p = positional(c)
        guard p.count >= 2, let port = UInt16(p[1]) else { return CmdResult(out: "Usage: banner <host> <port>   (grabs a service banner)") }
        let probe: Data? = [80, 8080, 8000, 8008].contains(port) ? Data("HEAD / HTTP/1.0\r\nHost: \(p[0])\r\n\r\n".utf8) : nil
        let d = await tcpExchange(p[0], port: port, send: probe, timeout: 4)
        return CmdResult(out: d.flatMap { String(data: $0, encoding: .utf8) } ?? "No banner received.")
    }

    static func whois(_ c: Ctx) async -> CmdResult {
        guard let q = positional(c).first else { return CmdResult(out: "Usage: whois <domain|ip>") }
        guard let iana = await tcpExchange("whois.iana.org", port: 43, send: Data("\(q)\r\n".utf8)),
              let text = String(data: iana, encoding: .utf8) else { return .error("whois: lookup failed") }
        if let refer = text.components(separatedBy: "\n").first(where: { $0.lowercased().hasPrefix("refer:") || $0.lowercased().hasPrefix("whois:") }) {
            let server = refer.split(separator: ":", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            if !server.isEmpty, let d = await tcpExchange(server, port: 43, send: Data("\(q)\r\n".utf8)), let s = String(data: d, encoding: .utf8) {
                return CmdResult(out: "[Querying \(server)]\n" + s)
            }
        }
        return CmdResult(out: text)
    }

    // MARK: DNS / recon over HTTPS
    static func dig(_ c: Ctx) async -> CmdResult {
        let p = positional(c)
        guard let name = p.first else { return CmdResult(out: "Usage: dig <name> [A|AAAA|MX|TXT|NS|CNAME|SOA|CAA|ANY]") }
        let types = p.count > 1 ? [p[1].uppercased()] : ["A"]
        let all = types == ["ANY"] ? ["A", "AAAA", "CNAME", "MX", "NS", "TXT", "SOA", "CAA"] : types
        var out = ["; <<>> t0rant dig <<>> \(name) \(all.joined(separator: " "))", ";; ANSWER SECTION:"]
        for t in all {
            let enc = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
            guard let (d, _) = await fetch("https://cloudflare-dns.com/dns-query?name=\(enc)&type=\(t)", headers: ["Accept": "application/dns-json"]),
                  let j = json(d) as? [String: Any] else { continue }
            for a in (j["Answer"] as? [[String: Any]]) ?? [] {
                out.append("\(Commands.pad(a["name"] as? String ?? "", 32)) \(Commands.pad(String(a["TTL"] as? Int ?? 0), 6)) IN \(Commands.pad(t, 6)) \(a["data"] as? String ?? "")")
            }
        }
        out.append(";; SERVER: 1.1.1.1 (DNS-over-HTTPS)")
        return CmdResult(out: out.joined(separator: "\n"))
    }

    static func subenum(_ c: Ctx) async -> CmdResult {
        guard let domain = positional(c).first else { return CmdResult(out: "Usage: subenum <domain>   (passive, via certificate transparency logs)") }
        c.shell.print("Querying certificate transparency logs for \(domain) ...")
        guard let (d, _) = await fetch("https://crt.sh/?q=%25.\(domain)&output=json"), let arr = json(d) as? [[String: Any]] else {
            return .error("subenum: crt.sh did not respond (try again later)")
        }
        var subs = Set<String>()
        for e in arr {
            for n in (e["name_value"] as? String ?? "").components(separatedBy: "\n") {
                let s = n.lowercased().replacingOccurrences(of: "*.", with: "")
                if s.hasSuffix(domain.lowercased()) { subs.insert(s) }
            }
        }
        return CmdResult(out: subs.sorted().joined(separator: "\n") + "\n\n\(subs.count) unique subdomains found")
    }

    static func headers(_ c: Ctx) async -> CmdResult {
        guard var u = positional(c).first else { return CmdResult(out: "Usage: headers <url>   (shows response headers + security header audit)") }
        if !u.contains("://") { u = "https://" + u }
        guard let (_, h) = await fetch(u, method: "GET") else { return .error("headers: request failed") }
        var out = ["HTTP \(h.statusCode)"]
        let hdrs = h.allHeaderFields.map { ("\($0.key)", "\($0.value)") }.sorted { $0.0.lowercased() < $1.0.lowercased() }
        for (k, v) in hdrs { out.append("\(k): \(v)") }
        out.append("\nSecurity header audit:")
        let keys = Set(hdrs.map { $0.0.lowercased() })
        for s in ["strict-transport-security", "content-security-policy", "x-frame-options", "x-content-type-options", "referrer-policy", "permissions-policy"] {
            out.append("  [\(keys.contains(s) ? "OK " : "MISSING")] \(s)")
        }
        if let srv = hdrs.first(where: { $0.0.lowercased() == "server" || $0.0.lowercased() == "x-powered-by" }) { out.append("  [INFO] discloses \(srv.0): \(srv.1)") }
        return CmdResult(out: out.joined(separator: "\n"))
    }

    static func techdetect(_ c: Ctx) async -> CmdResult {
        guard var u = positional(c).first else { return CmdResult(out: "Usage: techdetect <url>") }
        if !u.contains("://") { u = "https://" + u }
        guard let (d, h) = await fetch(u) else { return .error("techdetect: request failed") }
        let body = (String(data: d, encoding: .utf8) ?? "").lowercased()
        let hdr = h.allHeaderFields.map { "\($0.key): \($0.value)" }.joined(separator: "\n").lowercased()
        let sigs: [(String, String)] = [("WordPress", "wp-content"), ("Drupal", "drupal"), ("Joomla", "joomla"), ("Shopify", "cdn.shopify"),
            ("React", "react"), ("Next.js", "__next"), ("Vue.js", "vue"), ("Angular", "ng-version"), ("jQuery", "jquery"),
            ("Bootstrap", "bootstrap"), ("Cloudflare", "cloudflare"), ("nginx", "nginx"), ("Apache", "apache"), ("IIS", "microsoft-iis"),
            ("PHP", "php"), ("ASP.NET", "asp.net"), ("Google Analytics", "googletagmanager"), ("Express", "express"), ("Wix", "wix.com")]
        let found = sigs.filter { body.contains($0.1) || hdr.contains($0.1) }.map { $0.0 }
        return CmdResult(out: found.isEmpty ? "No known technologies detected." : "Detected:\n  " + found.joined(separator: "\n  "))
    }

    static func sslcheck(_ c: Ctx) async -> CmdResult {
        guard let host = positional(c).first else { return CmdResult(out: "Usage: sslcheck <host>") }
        let probe = CertProbe()
        let session = URLSession(configuration: .ephemeral, delegate: probe, delegateQueue: nil)
        guard let url = URL(string: "https://\(host)") else { return .error("sslcheck: invalid host") }
        _ = try? await session.data(from: url)
        session.invalidateAndCancel()
        guard !probe.chain.isEmpty else { return .error("sslcheck: could not complete TLS handshake with \(host)") }
        var out = ["TLS certificate chain for \(host):"]
        for (i, s) in probe.chain.enumerated() { out.append("  [\(i)] \(s)") }
        out.append("Trust evaluation: \(probe.trusted ? "VALID" : "NOT TRUSTED")")
        return CmdResult(out: out.joined(separator: "\n"))
    }

    static func geoip(_ c: Ctx) async -> CmdResult {
        let q = positional(c).first ?? ""
        guard let (d, _) = await fetch("http://ip-api.com/json/\(q)"), let j = json(d) as? [String: Any] else { return .error("geoip: lookup failed") }
        let keys = ["query", "status", "country", "regionName", "city", "zip", "lat", "lon", "timezone", "isp", "org", "as"]
        return CmdResult(out: keys.compactMap { k in j[k].map { Commands.pad(k, 12) + ": \($0)" } }.joined(separator: "\n"))
    }

    static func myip(_ c: Ctx) async -> CmdResult {
        guard let (d, _) = await fetch("https://api.ipify.org") else { return .error("myip: lookup failed") }
        return CmdResult(out: "Public IP: \(String(data: d, encoding: .utf8) ?? "?")\nLocal: " + Commands.ipList().filter { $0.0 == "en0" || $0.0.hasPrefix("pdp") }.map { $0.1 }.joined(separator: ", "))
    }

    static let wordlist = ["admin", "login", "wp-admin", "wp-login.php", "administrator", "dashboard", "api", "api/v1", "graphql",
        "robots.txt", "sitemap.xml", ".git/HEAD", ".env", "backup", "backup.zip", "config", "config.php", "phpinfo.php", "server-status",
        "uploads", "images", "static", "assets", "js", "css", "test", "dev", "staging", "old", "tmp", "private", "secret", "console",
        ".well-known/security.txt", "swagger", "swagger.json", "openapi.json", "docs", "cgi-bin", "phpmyadmin", "user", "users", "register",
        "signup", "logout", "search", "health", "status", "metrics", "debug", "actuator", "actuator/health", ".DS_Store", "crossdomain.xml"]

    static func dirbust(_ c: Ctx) async -> CmdResult {
        guard var base = positional(c).first else {
            return CmdResult(out: "Usage: dirbust <url> [-w wordlist.txt]\nChecks common paths. Only test sites you own or are authorized to test.")
        }
        if !base.contains("://") { base = "https://" + base }
        if !base.hasSuffix("/") { base += "/" }
        var words = wordlist
        if let wf = arg(c, ["-w"]), let t = c.fs.read(c.fs.resolve(wf, cwd: c.shell.cwd)) {
            words = t.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
        }
        c.shell.print("Scanning \(base) with \(words.count) words ...")
        var hits: [String] = []
        var i = 0
        while i < words.count {
            if c.shell.cancelled { break }
            let chunk = Array(words[i..<min(i + 16, words.count)])
            let res = await withTaskGroup(of: (String, Int, Int)?.self) { g -> [(String, Int, Int)] in
                for w in chunk {
                    g.addTask {
                        guard let (d, h) = await Tools.fetch(base + w) else { return nil }
                        return (w, h.statusCode, d.count)
                    }
                }
                var r: [(String, Int, Int)] = []
                for await x in g { if let x { r.append(x) } }
                return r
            }
            for (w, code, size) in res.sorted(by: { $0.0 < $1.0 }) where code != 404 {
                hits.append("/\(Commands.pad(w, 28)) (Status: \(code)) [Size: \(size)]")
            }
            i += 16
        }
        return CmdResult(out: hits.isEmpty ? "No interesting paths found." : hits.joined(separator: "\n"))
    }

    // MARK: crypto / encoding
    static func hash(_ c: Ctx) -> CmdResult {
        let p = positional(c)
        let alg = (arg(c, ["-a"]) ?? "sha256").lowercased()
        let data: Data
        if let f = p.first, let d = c.fs.readData(c.fs.resolve(f, cwd: c.shell.cwd)), c.fs.exists(c.fs.resolve(f, cwd: c.shell.cwd)) { data = d }
        else if !p.isEmpty { data = Data(p.joined(separator: " ").utf8) }
        else if let s = c.stdin { data = Data(s.utf8) }
        else { return CmdResult(out: "Usage: hash <text|file> [-a md5|sha1|sha256|sha384|sha512|all]") }
        func h(_ a: String) -> String {
            switch a {
            case "md5": return Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
            case "sha1": return Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
            case "sha384": return SHA384.hash(data: data).map { String(format: "%02x", $0) }.joined()
            case "sha512": return SHA512.hash(data: data).map { String(format: "%02x", $0) }.joined()
            default: return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            }
        }
        if alg == "all" { return CmdResult(out: ["md5", "sha1", "sha256", "sha384", "sha512"].map { Commands.pad($0.uppercased(), 8) + h($0) }.joined(separator: "\n")) }
        return CmdResult(out: h(alg))
    }

    static func hashid(_ c: Ctx) -> CmdResult {
        guard let h = positional(c).first ?? c.stdin?.trimmingCharacters(in: .whitespacesAndNewlines) else { return CmdResult(out: "Usage: hashid <hash>") }
        let isHex = h.allSatisfy { $0.isHexDigit }
        var guesses: [String] = []
        if h.hasPrefix("$2a$") || h.hasPrefix("$2b$") || h.hasPrefix("$2y$") { guesses = ["bcrypt"] }
        else if h.hasPrefix("$argon2") { guesses = ["Argon2"] }
        else if h.hasPrefix("$6$") { guesses = ["SHA-512 Crypt"] }
        else if h.hasPrefix("$5$") { guesses = ["SHA-256 Crypt"] }
        else if h.hasPrefix("$1$") { guesses = ["MD5 Crypt"] }
        else if h.hasPrefix("$apr1$") { guesses = ["Apache MD5"] }
        else if h.hasPrefix("pbkdf2_sha256$") { guesses = ["Django PBKDF2-SHA256"] }
        else if isHex {
            switch h.count {
            case 32: guesses = ["MD5", "NTLM", "MD4", "LM"]
            case 40: guesses = ["SHA-1", "RIPEMD-160", "MySQL5 (without *)"]
            case 56: guesses = ["SHA-224", "SHA3-224"]
            case 64: guesses = ["SHA-256", "SHA3-256", "BLAKE2s"]
            case 96: guesses = ["SHA-384", "SHA3-384"]
            case 128: guesses = ["SHA-512", "SHA3-512", "Whirlpool", "BLAKE2b"]
            case 8: guesses = ["CRC32", "Adler-32"]
            case 16: guesses = ["MySQL323", "Half MD5"]
            default: break
            }
        } else if h.hasPrefix("*"), h.count == 41 { guesses = ["MySQL 4.1+"] }
        return CmdResult(out: guesses.isEmpty ? "Unknown hash type." : "Possible hashes:\n" + guesses.map { "[+] \($0)" }.joined(separator: "\n"))
    }

    static func b64url(_ s: Substring) -> String? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t).flatMap { String(data: $0, encoding: .utf8) }
    }
    static func jwt(_ c: Ctx) -> CmdResult {
        guard let tok = positional(c).first ?? c.stdin?.trimmingCharacters(in: .whitespacesAndNewlines) else { return CmdResult(out: "Usage: jwt <token>   (decodes header and payload, no verification)") }
        let parts = tok.split(separator: ".")
        guard parts.count >= 2 else { return .error("jwt: not a JWT") }
        var out = "Header:\n\(b64url(parts[0]) ?? "?")\n\nPayload:\n\(b64url(parts[1]) ?? "?")"
        if let p = b64url(parts[1]).flatMap({ $0.data(using: .utf8) }).flatMap(json) as? [String: Any], let exp = p["exp"] as? Double {
            let d = Date(timeIntervalSince1970: exp)
            out += "\n\nExpires: \(d)  (\(d < Date() ? "EXPIRED" : "valid"))"
        }
        if parts.count < 3 || parts[2].isEmpty { out += "\n\n[!] Unsigned token (alg none?)" }
        return CmdResult(out: out)
    }
    static func text(_ c: Ctx) -> String { c.args.isEmpty ? (c.stdin ?? "") : c.args.joined(separator: " ") }
    static func urlencode(_ c: Ctx) -> CmdResult {
        CmdResult(out: text(c).addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? "")
    }
    static func urldecode(_ c: Ctx) -> CmdResult { CmdResult(out: text(c).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? "") }
    static func hex(_ c: Ctx) -> CmdResult {
        if c.args.first == "-d" {
            let s = c.args.dropFirst().joined().filter { $0.isHexDigit }
            var bytes: [UInt8] = []
            var i = s.startIndex
            while i < s.endIndex, let j = s.index(i, offsetBy: 2, limitedBy: s.endIndex) { if let b = UInt8(s[i..<j], radix: 16) { bytes.append(b) }; i = j }
            return CmdResult(out: String(decoding: bytes, as: UTF8.self))
        }
        return CmdResult(out: Data(text(c).utf8).map { String(format: "%02x", $0) }.joined())
    }
    static func rot13(_ c: Ctx) -> CmdResult {
        CmdResult(out: String(text(c).map { ch -> Character in
            guard let a = ch.asciiValue, ch.isLetter else { return ch }
            let base: UInt8 = ch.isUppercase ? 65 : 97
            return Character(UnicodeScalar((a - base + 13) % 26 + base))
        }))
    }
    static func passgen(_ c: Ctx) -> CmdResult {
        let n = Int(positional(c).first ?? "") ?? 20
        let chars = Array("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!@#$%^&*-_=+")
        var rng = SystemRandomNumberGenerator()
        return CmdResult(out: String((0..<max(4, min(n, 256))).map { _ in chars[Int(rng.next() % UInt64(chars.count))] }))
    }

    static func pkg(_ c: Ctx) async -> CmdResult {
        let sub = c.args.first?.lowercased() ?? "list"
        switch sub {
        case "install", "uninstall", "show", "freeze":
            return await PythonCommands.pip(Ctx(shell: c.shell, args: c.args, stdin: c.stdin, raw: c.raw))
        default:
            let native = table.keys.sorted().joined(separator: " ")
            let py = await PythonRuntime.shared.listPackages()
            return CmdResult(out: "Native tools:\n  \(native)\n\nPython \(PythonRuntime.shared.version) packages:\n  \(py)\n\nInstall more pure-Python packages with: pip install <name>")
        }
    }
}

final class CertProbe: NSObject, URLSessionDelegate, @unchecked Sendable {
    var chain: [String] = []
    var trusted = false
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if let trust = challenge.protectionSpace.serverTrust {
            trusted = SecTrustEvaluateWithError(trust, nil)
            if let certs = SecTrustCopyCertificateChain(trust) as? [SecCertificate] {
                chain = certs.map { (SecCertificateCopySubjectSummary($0) as String?) ?? "?" }
            }
        }
        completionHandler(.performDefaultHandling, nil)
    }
}
