// blit — command-line front end to BlitKit, for exercising the engine
// against real servers before the app exists.

import BlitLocal
import BlitRemote
import BlitSFTP
import Darwin
import Foundation
import Synchronization

struct Arguments {
    var command = ""
    var endpoint = SSHEndpoint(host: "", username: "")
    var positional: [String] = []
    var connections = 3
    var staggerMS = 250
    var trust: Set<String> = []
    var verify = true
    var overwrite = false
    var progressLines = false
}

func usage() -> Never {
    print("""
    usage:
      blit ls  user@host[:port] <remote-folder>
      blit get user@host[:port] <remote-path> <local-folder> [options]
      blit copy <source> <destination-folder> [--nas user@host[:port]] [options]
      blit hostkeys                      list host keys Blit trusts
      blit hostkeys forget host[:port]   forget them

    get options:
      --conns N          connections to open (default 3)
      --stagger MS       delay between opening connections (default 250)
      --trust SHA256:…   trust this host key fingerprint for this run (repeatable)
      --no-verify        skip server-side SHA-256 verification
      --overwrite        replace files that already exist locally
      --progress-lines   print progress as one line per second

    copy options:
      --nas user@host[:port]  verify each copy with sha256sum on the NAS (over SSH)
      --nas-root PATH    the share's path on the NAS (default: asks the NAS, e.g. /volume1/Media)
      --conns N          files copied at once (default 2)
      --no-verify / --overwrite / --trust SHA256:… / --progress-lines   as for get

    The password comes from $BLIT_PASSWORD or a prompt (NAS: $BLIT_NAS_PASSWORD). Host keys are checked
    against Blit's store and ~/.ssh/known_hosts; an unknown key (or a new key
    type) prompts before it's trusted and remembered. A changed key is refused.
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
        case "--progress-lines": a.progressLines = true
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

/// Connects once, asking before trusting an unknown host key (PRD R1.3).
func connectAskingTrust(_ endpoint: SSHEndpoint, credential: SSHCredential, verifier: BlitHostKeyVerifier) async throws -> SSHConnection {
    do {
        return try await SSHConnection.connect(to: endpoint, credential: credential, verifier: verifier)
    } catch let error as SSHError {
        guard case .hostKeyRejected(let host, let port, let presented, let known) = error else { throw error }
        if error.isChangedHostKey {
            print("""
            WARNING: the host key for \(host):\(port) has changed.
              server presented: \(presented)
              trusted:          \(known.filter { $0.type == presented.type }.map(\.description).joined(separator: ", "))
            This can mean someone is intercepting the connection. Blit won't connect.
            If the server's key really changed, run `blit hostkeys forget \(host):\(port)` and connect again.
            """)
            exit(1)
        }
        print("\(host):\(port) presented a host key Blit hasn't seen before:")
        print("  \(presented)")
        if !known.isEmpty {
            print("Keys of other types are already trusted for this server:")
            known.forEach { print("  \($0)") }
        }
        print("Check the fingerprint with your provider if you can. Trust and remember it? [y/N] ", terminator: "")
        fflush(stdout)
        guard isatty(STDIN_FILENO) != 0, readLine()?.lowercased() == "y" else {
            print("Not trusted.")
            exit(1)
        }
        try verifier.store.pin(presented, host: host, port: port)
        print("Remembered in \(verifier.store.path)")
        return try await SSHConnection.connect(to: endpoint, credential: credential, verifier: verifier)
    }
}

/// Opens `count` connections, each with an SFTP session. The first one settles
/// host-key trust; the rest follow `staggerMS` apart.
func openClients(_ a: Arguments, count: Int, credential: SSHCredential) async throws -> [SFTPClient] {
    let verifier = BlitHostKeyVerifier(knownHosts: KnownHostsVerifier(pinnedFingerprints: a.trust))
    let first = try await SFTPClient.open(on: try await connectAskingTrust(a.endpoint, credential: credential, verifier: verifier))
    guard count > 1 else { return [first] }
    return try await withThrowingTaskGroup(of: (Int, SFTPClient).self) { group in
        for i in 1..<count {
            group.addTask {
                try await Task.sleep(for: .milliseconds((i - 1) * a.staggerMS))
                let connection = try await SSHConnection.connect(to: a.endpoint, credential: credential, verifier: verifier)
                return (i, try await SFTPClient.open(on: connection))
            }
        }
        var clients: [(Int, SFTPClient)] = [(0, first)]
        for try await c in group { clients.append(c) }
        return clients.sorted { $0.0 < $1.0 }.map(\.1)
    }
}

/// `blit hostkeys [forget host[:port]]` needs no connection or password.
func hostKeysCommand(_ args: [String]) -> Never {
    let store = HostKeyStore()
    if args.first == "forget", args.count == 2 {
        var host = args[1]
        var port = 22
        if let colon = host.lastIndex(of: ":"), let p = Int(host[host.index(after: colon)...]) {
            port = p
            host = String(host[..<colon])
        }
        let removed = (try? store.forget(host: host, port: port)) ?? 0
        print(removed == 0 ? "No keys stored for \(host):\(port)." : "Forgot \(removed) key\(removed == 1 ? "" : "s") for \(host):\(port).")
        exit(0)
    }
    guard args.isEmpty else { usage() }
    let all = store.all()
    if all.isEmpty { print("No host keys stored yet (\(store.path)).") }
    for (server, entries) in all.sorted(by: { $0.key < $1.key }) {
        print(server)
        entries.forEach { print("  \($0.type) \($0.fingerprint)  (added \(formatDate(UInt32($0.added.timeIntervalSince1970))))") }
    }
    exit(0)
}

if CommandLine.arguments.dropFirst().first == "hostkeys" {
    hostKeysCommand(Array(CommandLine.arguments.dropFirst(2)))
}
if CommandLine.arguments.dropFirst().first == "copy" {
    await copyCommand(Array(CommandLine.arguments.dropFirst(2)))
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
        let progress = ProgressState()

        // Live progress line; ends quietly when cancelled.
        let ticker = Task {
            var last = (time: Date(), bytes: 0)
            while true {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                let now = Date()
                let bytes = counter.total
                let rate = Double(bytes - last.bytes) / now.timeIntervalSince(last.time)
                last = (now, bytes)
                let shown = bytes + Int(progress.resumedBytes)
                let verifying = progress.verifying
                let status = shown >= Int(totalBytes) && verifying > 0
                    ? "verifying \(verifying) file\(verifying == 1 ? "" : "s")…"
                    : String(format: "%.1f MB/s", rate / 1e6)
                if a.progressLines {
                    print(String(format: "  %5.0f s  %@ of %@ · %@", now.timeIntervalSince(start), formatBytes(Double(shown)),
                                 formatBytes(Double(totalBytes)), status))
                } else {
                    print("\r  \(formatBytes(Double(shown))) of \(formatBytes(Double(totalBytes))) · \(status)          ", terminator: "")
                }
                fflush(stdout)
            }
        }

        let summary = await download(files, into: localFolder, clients: clients, hasher: hasher,
                                     options: options, counter: counter) { event in
            switch event {
            case .fileResumed(let f, let bytes):
                progress.resumed(bytes)
                print("\r  resuming \(f.relativePath): \(formatBytes(Double(bytes))) already on disk")
            case .fileStarted: break
            case .fileDownloaded:
                progress.downloaded()
            case .fileFinished(let f, let v):
                progress.finished()
                let check: String
                switch v {
                case .sha256(_, let cached): check = cached ? "✓ sha256 (cached on server)" : "✓ sha256"
                case .sizeOnly(let why): check = "size only (\(why))"
                case .skipped: check = "not verified"
                case .alreadyPresent: check = "already present"
                }
                print("\r  \(f.relativePath)  \(formatBytes(Double(f.size)))  \(check)            ")
            case .fileFailed(let f, let reason):
                progress.finished()
                print("\r  ✗ \(f.relativePath): \(reason)            ")
            }
        }
        ticker.cancel()
        _ = await ticker.result
        let end = Date()
        let downloadSeconds = (progress.lastDownload ?? end).timeIntervalSince(start)
        let resumedNote = summary.resumedBytes > 0 ? " (+\(formatBytes(Double(summary.resumedBytes))) resumed)" : ""
        print(String(format: "\rdone: %d/%d files, %d verified · %@%@ downloaded in %.1f s (%.1f MB/s) · %.1f s total            ",
                     summary.finished.count, files.count, summary.verified, formatBytes(Double(counter.total)), resumedNote,
                     downloadSeconds, Double(counter.total) / downloadSeconds / 1e6, end.timeIntervalSince(start)))
        for c in clients { await c.connection.close() }
        if !summary.failed.isEmpty { exit(1) }

    default:
        usage()
    }
} catch {
    print("error: \(error)")
    exit(1)
}

/// Counts for the progress line, updated from transfer events.
final class ProgressState: Sendable {
    private let state = Mutex((verifying: 0, lastDownload: Date?.none, resumed: UInt64(0)))
    func resumed(_ bytes: UInt64) { state.withLock { $0.resumed += bytes } }
    var resumedBytes: UInt64 { state.withLock { $0.resumed } }
    func downloaded() { state.withLock { $0.verifying += 1; $0.lastDownload = Date() } }
    func finished() { state.withLock { $0.verifying = max(0, $0.verifying - 1) } }
    var verifying: Int { state.withLock { $0.verifying } }
    var lastDownload: Date? { state.withLock { $0.lastDownload } }
}

extension String {
    func leftPad(_ width: Int) -> String { count >= width ? self : String(repeating: " ", count: width - count) + self }
}

// MARK: - blit copy

func parseEndpoint(_ target: String) -> SSHEndpoint? {
    guard let at = target.lastIndex(of: "@") else { return nil }
    var host = String(target[target.index(after: at)...])
    var port = 22
    if let colon = host.lastIndex(of: ":"), let p = Int(host[host.index(after: colon)...]) {
        port = p
        host = String(host[..<colon])
    }
    return SSHEndpoint(host: host, port: port, username: String(target[..<at]))
}

/// The nearest existing folder at or above `path`.
func existingAncestor(_ path: String) -> String {
    var p = path
    while !FileManager.default.fileExists(atPath: p), p != "/" { p = (p as NSString).deletingLastPathComponent }
    return p
}

func copyCommand(_ raw: [String]) async -> Never {
    var args = raw
    var positional: [String] = []
    var nasTarget: String?
    var nasRoot: String?
    var trust: Set<String> = []
    var options = CopyOptions()
    var progressLines = false
    while !args.isEmpty {
        let arg = args.removeFirst()
        switch arg {
        case "--nas": nasTarget = args.isEmpty ? nil : args.removeFirst()
        case "--nas-root": nasRoot = args.isEmpty ? nil : args.removeFirst()
        case "--conns": options.concurrentFiles = max(1, Int(args.isEmpty ? "" : args.removeFirst()) ?? 2)
        case "--trust": if !args.isEmpty { trust.insert(args.removeFirst()) }
        case "--no-verify": options.verify = false
        case "--overwrite": options.overwrite = true
        case "--progress-lines": progressLines = true
        default:
            if arg.hasPrefix("--") { usage() }
            positional.append(arg)
        }
    }
    guard positional.count == 2 else { usage() }
    let source = (positional[0] as NSString).expandingTildeInPath
    let destination = (positional[1] as NSString).expandingTildeInPath

    do {
        let files = try localFiles(at: source)
        let total = files.reduce(UInt64(0)) { $0 + $1.size }
        let mount = MountInfo.of(existingAncestor(destination))

        // Where the traffic goes (PRD R1.7).
        var nasHost: String? = nasTarget.flatMap { parseEndpoint($0)?.host }
        if nasHost == nil, let mount, mount.isSMB, let server = mount.source.split(separator: "@").last?.split(separator: "/").first {
            nasHost = String(server).replacingOccurrences(of: "._smb._tcp", with: "")
        }
        if let nasHost, let path = NetworkPath.to(host: nasHost) {
            print("route to \(nasHost): \(path.interface) (\(path.localAddress))\(path.isWiFi ? ", Wi-Fi" : "")")
            if path.wifiDespiteWired {
                print("""
                WARNING: this copy would go over Wi-Fi even though a wired link is up (\(path.activeWired.joined(separator: ", "))).
                macOS picks Wi-Fi when it's on the NAS's subnet and the wired port isn't. Put the wired port on
                the NAS's network (or turn Wi-Fi off) and remount the share; existing mounts keep their interface.
                """)
            }
        }

        var nas: NASVerifier?
        if let nasTarget, options.verify {
            guard let endpoint = parseEndpoint(nasTarget), let mount else { usage() }
            let password = ProcessInfo.processInfo.environment["BLIT_NAS_PASSWORD"]
                ?? readPassword("NAS password for \(endpoint.username)@\(endpoint.host): ")
            let verifier = BlitHostKeyVerifier(knownHosts: KnownHostsVerifier(pinnedFingerprints: trust))
            let connection = try await connectAskingTrust(endpoint, credential: .password(password), verifier: verifier)
            var root = nasRoot
            if root == nil { root = try await NASVerifier.findShareRoot(mount.shareName, on: connection) }
            guard let root else {
                print("error: couldn't find share \"\(mount.shareName)\" on the NAS; pass --nas-root /volumeN/\(mount.shareName)")
                exit(1)
            }
            nas = NASVerifier(connection: connection, mountPoint: mount.mountPoint, nasRoot: root)
            print("verifying on the NAS: \(mount.mountPoint) = \(endpoint.host):\(root)")
        } else if options.verify {
            print("verifying by reading back through this Mac (pass --nas user@host to verify on the NAS)")
        }
        print(String(format: "%d file%@, %@ → %@", files.count, files.count == 1 ? "" : "s", formatBytes(Double(total)), destination))

        let counter = ByteCounter()
        let start = Date()
        let progress = ProgressState()
        let ticker = Task {
            var last = (time: Date(), bytes: 0)
            while true {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                let now = Date()
                let bytes = counter.total
                let rate = Double(bytes - last.bytes) / now.timeIntervalSince(last.time)
                last = (now, bytes)
                let verifying = progress.verifying
                let status = bytes >= Int(total) && verifying > 0
                    ? "verifying \(verifying) file\(verifying == 1 ? "" : "s")…" : String(format: "%.1f MB/s", rate / 1e6)
                if progressLines {
                    print(String(format: "  %5.0f s  %@ of %@ · %@", now.timeIntervalSince(start), formatBytes(Double(bytes)),
                                 formatBytes(Double(total)), status))
                } else {
                    print("\r  \(formatBytes(Double(bytes))) of \(formatBytes(Double(total))) · \(status)          ", terminator: "")
                    fflush(stdout)
                }
            }
        }

        let summary = try await copy(files, into: destination, nas: nas, options: options, counter: counter) { event in
            switch event {
            case .fileStarted: break
            case .fileCopied: progress.downloaded()
            case .fileFinished(let f, let v):
                progress.finished()
                let check: String
                switch v {
                case .nas: check = "✓ sha256 on NAS"
                case .readBack(_, let why): check = "✓ read-back" + (why.map { " (\($0))" } ?? "")
                case .cloned: check = "cloned (same volume)"
                case .skipped: check = "not verified"
                case .alreadyPresent: check = "already present"
                }
                print("\r  \(f.relativePath)  \(formatBytes(Double(f.size)))  \(check)            ")
            case .fileFailed(let f, let reason):
                progress.finished()
                print("\r  ✗ \(f.relativePath): \(reason)            ")
            }
        }
        ticker.cancel()
        _ = await ticker.result
        let end = Date()
        let copySeconds = (progress.lastDownload ?? end).timeIntervalSince(start)
        print(String(format: "\rdone: %d/%d files, %d verified on NAS · %@ copied in %.1f s (%.1f MB/s) · %.1f s total            ",
                     summary.finished.count, files.count, summary.verifiedOnNAS, formatBytes(Double(counter.total)),
                     copySeconds, Double(counter.total) / max(copySeconds, 0.001) / 1e6, end.timeIntervalSince(start)))
        await nas?.hasher.connection.close()
        exit(summary.failed.isEmpty ? 0 : 1)
    } catch {
        print("error: \(error)")
        exit(1)
    }
}
