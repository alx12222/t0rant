import Foundation
import Network

/// Local socket that lets Node packages "spawn" t0rant shell commands.
/// Node's child_process emulation (compat.js) sends {line, cwd, env}; the line runs in the
/// t0rant shell with output captured, and {stdout, stderr, code} is sent back.
final class ExecBridge: @unchecked Sendable {
    static let shared = ExecBridge()
    private var listener: NWListener?
    private(set) var port: UInt16 = 0
    private weak var shell: Shell?

    @MainActor func start(shell: Shell) {
        self.shell = shell
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        params.allowLocalEndpointReuse = true
        guard let l = try? NWListener(using: params, on: .any) else { return }
        l.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        l.stateUpdateHandler = { [weak self] st in
            if case .ready = st, let p = l.port?.rawValue { self?.port = p }
        }
        l.start(queue: .global())
        listener = l
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .global())
        var buffer = Data()
        func read() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, complete, error in
                if let d = data { buffer.append(d) }
                if let nl = buffer.firstIndex(of: 0x0A) {
                    self?.run(Data(buffer[..<nl]), conn)
                } else if complete || error != nil {
                    if buffer.isEmpty { conn.cancel() } else { self?.run(buffer, conn) }
                } else {
                    read()
                }
            }
        }
        read()
    }

    private func run(_ request: Data, _ conn: NWConnection) {
        guard let j = try? JSONSerialization.jsonObject(with: request) as? [String: Any],
              let line = j["line"] as? String else { reply(conn, "", "bad request\n", 1); return }
        let cwd = j["cwd"] as? String ?? ""
        let env = j["env"] as? [String: String] ?? [:]
        Task { @MainActor [weak self] in
            guard let shell = self?.shell else { self?.reply(conn, "", "t0rant shell unavailable\n", 1); return }
            let r = await shell.runCaptured(line, realCwd: cwd, env: env)
            self?.reply(conn, r.out, r.err, r.code)
        }
    }

    private func reply(_ conn: NWConnection, _ out: String, _ err: String, _ code: Int32) {
        let obj: [String: Any] = ["stdout": out.isEmpty ? "" : out + (out.hasSuffix("\n") ? "" : "\n"),
                                  "stderr": err.isEmpty ? "" : err + (err.hasSuffix("\n") ? "" : "\n"),
                                  "code": Int(code)]
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        conn.send(content: data, completion: .contentProcessed { _ in conn.cancel() })
    }
}

extension Shell {
    /// Runs a command line on behalf of a Node "child process": output is captured instead of shown,
    /// and the working directory / variables are restored afterwards (a child can't change its parent).
    func runCaptured(_ line: String, realCwd: String, env extra: [String: String]) async -> (out: String, err: String, code: Int32) {
        let savedCwd = cwd, savedEnv = env, savedEcho = echoOn
        let root = fs.root.standardizedFileURL.path
        let real = URL(fileURLWithPath: realCwd).standardizedFileURL.path
        if real.hasPrefix(root) {
            let rel = String(real.dropFirst(root.count)).split(separator: "/").map(String.init)
            if fs.isDir(fs.url(rel)) { cwd = rel }
        }
        for (k, v) in extra where k.uppercased() == k && !k.hasPrefix("npm_") { env[k] = v }
        echoOn = false
        captures.append(Capture())
        nestedDepth += 1
        let code = await runLine(line)
        nestedDepth -= 1
        let cap = captures.removeLast()
        cwd = savedCwd; env = savedEnv; echoOn = savedEcho
        return (cap.out, cap.err, code)
    }
}
