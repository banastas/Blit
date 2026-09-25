// blit — command-line front end to BlitKit, for exercising the engine
// against real servers before the app exists.

import BlitRemote
import BlitSFTP
import Darwin
import Foundation

struct Arguments {
    var command = ""
    var endpoint = SSHEndpoint(host: "", username: "")
    var positional: [String] = []
    var connections = 3
    var staggerMS = 250
    var trust: Set<String> = []
    var verify = true
    var overwrite = false
}

func usage() -> Never {
    print("""
    usage:
      blit ls  user@host[:port] <remote-folder>
      blit get user@host[:port] <remote-path> <local-folder> [options]

    get options:
      --conns N          connections to open (default 3)
      --stagger MS       delay between opening connections (default 250)
      --trust SHA256:…   also trust this host key fingerprint (repeatable)
      --no-verify        skip server-side SHA-256 verification
      --overwrite        replace files that already exist locally

    The password comes from $BLIT_PASSWORD or a prompt. Host keys are checked
    against ~/.ssh/known_hosts plus any --trust fingerprints.
    """)
    exit(2)
}

func parseArguments() -> Arguments {
    var a = Arguments()
    var args = Array(CommandLine.arguments.dropFirst())
    guard args.count >= 2 else { usage() }
    a.command = args.removeFirst()
    let target = args.removeFirst()
    guard let at = target.lastIndex(of: "@") else { usage() }
    var host = String(target[target.index(after: at)...])
    var port = 22
    if let colon = host.lastIndex(of: ":"), let p = Int(host[host.index(after: colon)...]) {
        port = p
        host = String(host[..<colon])
    }
    a.endpoint = SSHEndpoint(host: host, port: port, username: String(target[..<at]))
    while !args.isEmpty {
        let arg = args.removeFirst()
        switch arg {
        case "--conns": a.connections = max(1, Int(args.isEmpty ? "" : args.removeFirst()) ?? 3)
        case "--stagger": a.staggerMS = Int(args.isEmpty ? "" : args.removeFirst()) ?? 250
        case "--trust": if !args.isEmpty { a.trust.insert(args.removeFirst()) }
        case "--no-verify": a.verify = false
        case "--overwrite": a.overwrite = true
        default:
            if arg.hasPrefix("--") { usage() }
            a.positional.append(arg)
        }
    }
    return a
}

func readPassword(_ prompt: String) -> String {
    if let p = ProcessInfo.processInfo.environment["BLIT_PASSWORD"] { return p }
    var buffer = [CChar](repeating: 0, count: 1024)
    guard let r = readpassphrase(prompt, &buffer, buffer.count, 0) else { exit(1) }
    return String(cString: r)
}

func formatBytes(_ n: Double) -> String {
    n >= 1e9 ? String(format: "%.2f GB", n / 1e9) : String(format: "%.1f MB", n / 1e6)
}

func formatDate(_ seconds: UInt32?) -> String {
    guard let seconds else { return "                " }
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm"
    return f.string(from: Date(timeIntervalSince1970: TimeInterval(seconds)))
}

/// Opens `count` connections, `staggerMS` apart, each with an SFTP session.
func openClients(_ a: Arguments, count: Int, credential: SSHCredential) async throws -> [SFTPClient] {
    let verifier = KnownHostsVerifier(pinnedFingerprints: a.trust)
    return try await withThrowingTaskGroup(of: (Int, SFTPClient).self) { group in
        for i in 0..<count {
            group.addTask {
                try await Task.sleep(for: .milliseconds(i * a.staggerMS))
                let connection = try await SSHConnection.connect(to: a.endpoint, credential: credential, verifier: verifier)
                return (i, try await SFTPClient.open(on: connection))
            }
        }
        var clients: [(Int, SFTPClient)] = []
        for try await c in group { clients.append(c) }
        return clients.sorted { $0.0 < $1.0 }.map(\.1)
    }
}

let a = parseArguments()
let credential = SSHCredential.password(readPassword("Password for \(a.endpoint.username)@\(a.endpoint.host): "))

do {
    switch a.command {
    case "ls":
        guard a.positional.count == 1 else { usage() }
        let client = try await openClients(a, count: 1, credential: credential)[0]
        // Newest first (PRD R2.4).
        let entries = try await client.list(RemotePath(a.positional[0]))
            .sorted { ($0.attributes.modificationTime ?? 0) > ($1.attributes.modificationTime ?? 0) }
        for e in entries {
            let size = e.attributes.isDirectory ? "       —" : formatBytes(Double(e.attributes.size ?? 0)).leftPad(10)
            print("\(formatDate(e.attributes.modificationTime))  \(size)  \(e.filename)\(e.attributes.isDirectory ? "/" : "")")
        }
        await client.connection.close()

    case "get":
        guard a.positional.count == 2 else { usage() }
        let remote = RemotePath(a.positional[0])
        let localFolder = (a.positional[1] as NSString).expandingTildeInPath

        let t0 = Date()
        let clients = try await openClients(a, count: a.connections, credential: credential)
        let setup = Date().timeIntervalSince(t0)
        let files = try await remoteFiles(at: remote, using: clients[0])
        let totalBytes = files.reduce(0) { $0 + $1.size }
        let strategy = clients[0].strategy
        print(String(format: "%d connection%@ ready in %.1f s · reads %d KB × %d · %d file%@, %@",
                     clients.count, clients.count == 1 ? "" : "s", setup, strategy.readSize / 1024, strategy.maxInFlight,
                     files.count, files.count == 1 ? "" : "s", formatBytes(Double(totalBytes))))

        var options = TransferOptions()
        options.verify = a.verify
        options.overwrite = a.overwrite
        let hasher = a.verify ? RemoteHasher(connection: clients[0].connection) : nil
        let counter = ByteCounter()
        let start = Date()

        // Live progress line.
        let ticker = Task {
            var last = (time: Date(), bytes: 0)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                let now = Date()
                let bytes = counter.total
                let rate = Double(bytes - last.bytes) / now.timeIntervalSince(last.time)
                last = (now, bytes)
                print(String(format: "\r  %@ of %@ · %.1f MB/s   ", formatBytes(Double(bytes)), formatBytes(Double(totalBytes)), rate / 1e6),
                      terminator: "")
                fflush(stdout)
            }
        }

        let summary = await download(files, into: localFolder, clients: clients, hasher: hasher,
                                     options: options, counter: counter) { event in
            switch event {
            case .fileStarted: break
            case .fileFinished(let f, let v):
                let check: String
                switch v {
                case .sha256: check = "✓ sha256"
                case .sizeOnly(let why): check = "size only (\(why))"
                case .skipped: check = "not verified"
                }
                print("\r  \(f.relativePath)  \(formatBytes(Double(f.size)))  \(check)            ")
            case .fileFailed(let f, let reason):
                print("\r  ✗ \(f.relativePath): \(reason)            ")
            }
        }
        ticker.cancel()
        let seconds = Date().timeIntervalSince(start)
        print(String(format: "\rdone: %d/%d files, %d verified, %@ in %.1f s (%.1f MB/s)            ",
                     summary.finished.count, files.count, summary.verified, formatBytes(Double(counter.total)), seconds,
                     Double(counter.total) / seconds / 1e6))
        for c in clients { await c.connection.close() }
        if !summary.failed.isEmpty { exit(1) }

    default:
        usage()
    }
} catch {
    print("error: \(error)")
    exit(1)
}

extension String {
    func leftPad(_ width: Int) -> String { count >= width ? self : String(repeating: " ", count: width - count) + self }
}
