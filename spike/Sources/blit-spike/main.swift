// blit-spike — M1 throwaway: measure SwiftNIO SSH and a minimal pipelined
// SFTP v3 client against a real server. See spike/README.md and the repo README.

import CryptoKit
import Darwin
import Foundation
import NIOCore
import NIOPosix
import NIOSSH

// MARK: - Options

struct Options {
    var mode = ""
    var user = ""
    var host = ""
    var port = 22
    var path = ""
    var packetKB = 128      // SSH max packet; NIOSSH's channel window = 64 × this
    var rcvbufKB = 0        // 0 = macOS TCP autotuning (capped by net.inet.tcp.autorcvbufmax)
    var requests = 64       // SFTP reads in flight per connection
    var readKB = 32         // SFTP read request size
    var conns = 1           // connections; sftp mode splits the file across them
    var seconds = 20.0      // 0 = whole file
    var staggerMS = 250     // delay between opening connections
    var out: String?        // write to this file (sftp mode); otherwise discard
    var trust: String?      // also accept a host key with this SHA256 fingerprint
}

func usage() -> Never {
    print("""
    usage: blit-spike <raw|sftp|hash> user@host[:port] <remote-path> [options]

      raw    `cat` the file over one SSH exec channel (SSH throughput, no SFTP)
      sftp   pipelined SFTP reads, split across --conns connections
      hash   sha256sum on the server (path sent NUL-delimited over stdin)
      hostkey  show the server's host key and whether it's trusted (no login attempt)

    options:
      --packet KB     SSH max packet size (window = 64 × packet)   [128]
      --rcvbuf KB     TCP receive buffer; 0 = macOS autotuning       [0]
      --requests N    SFTP reads in flight per connection            [64]
      --read KB       SFTP read request size                         [32]
      --conns N       connections (sftp mode)                        [1]
      --seconds S     stop issuing reads after S seconds; 0 = all    [20]
      --stagger MS    delay between opening connections              [250]
      --out FILE      write data to FILE and verify it (sftp mode, --seconds 0)
      --trust SHA256:…  also accept the host key with this fingerprint

    Password comes from $BLIT_PASSWORD or a prompt. The host key must already be
    in ~/.ssh/known_hosts (connect once with ssh first).
    """)
    exit(2)
}

func parseOptions() -> Options {
    var o = Options()
    var args = Array(CommandLine.arguments.dropFirst())
    guard args.count >= 2 else { usage() }
    o.mode = args.removeFirst()
    guard ["raw", "sftp", "hash", "hostkey"].contains(o.mode) else { usage() }
    let target = args.removeFirst()
    guard let at = target.lastIndex(of: "@") else { usage() }
    o.user = String(target[..<at])
    var hostPart = String(target[target.index(after: at)...])
    if let colon = hostPart.lastIndex(of: ":"), let p = Int(hostPart[hostPart.index(after: colon)...]) {
        o.port = p
        hostPart = String(hostPart[..<colon])
    }
    o.host = hostPart
    o.path = (args.isEmpty || args[0].hasPrefix("--")) ? "" : args.removeFirst()
    while !args.isEmpty {
        let flag = args.removeFirst()
        guard !args.isEmpty else { usage() }
        let value = args.removeFirst()
        switch flag {
        case "--packet": o.packetKB = Int(value) ?? o.packetKB
        case "--rcvbuf": o.rcvbufKB = Int(value) ?? o.rcvbufKB
        case "--requests": o.requests = Int(value) ?? o.requests
        case "--read": o.readKB = Int(value) ?? o.readKB
        case "--conns": o.conns = max(1, Int(value) ?? o.conns)
        case "--seconds": o.seconds = Double(value) ?? o.seconds
        case "--stagger": o.staggerMS = Int(value) ?? o.staggerMS
        case "--out": o.out = value
        case "--trust": o.trust = value
        default: usage()
        }
    }
    return o
}

// MARK: - Helpers

struct SpikeError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

func mbps(_ bytes: Int, _ seconds: Double) -> String {
    seconds > 0 ? String(format: "%6.1f MB/s", Double(bytes) / seconds / 1e6) : "     n/a"
}

func readPassword(_ prompt: String) -> String {
    if let p = ProcessInfo.processInfo.environment["BLIT_PASSWORD"] { return p }
    var buf = [CChar](repeating: 0, count: 1024)
    guard let r = readpassphrase(prompt, &buf, buf.count, 0) else { exit(1) }
    return String(cString: r)
}

extension ByteBuffer {
    mutating func writeSSHString(_ s: String) {
        writeInteger(UInt32(s.utf8.count))
        writeString(s)
    }
    mutating func writeSSHString(_ b: ByteBuffer) {
        writeInteger(UInt32(b.readableBytes))
        writeImmutableBuffer(b)
    }
    mutating func readSSHText() -> String {
        guard var s = readSSHString() else { return "" }
        return s.readString(length: s.readableBytes) ?? ""
    }
    mutating func readSSHString() -> ByteBuffer? {
        guard let n = readInteger(as: UInt32.self) else { return nil }
        return readSlice(length: Int(n))
    }
}

// MARK: - Host keys (plain ~/.ssh/known_hosts entries only)

/// Last connection-level failure, so a disconnect can report its real cause.
final class LastError: @unchecked Sendable {
    static let shared = LastError()
    private let lock = NSLock()
    private var value: String?
    func set(_ s: String) { lock.lock(); value = s; lock.unlock() }
    func take() -> String? { lock.lock(); defer { value = nil; lock.unlock() }; return value }
    func setIfEmpty(_ s: String) { lock.lock(); if value == nil || value!.hasPrefix("host key trusted") { value = s }; lock.unlock() }
}

/// Channels whose SSH session has started (so the handshake watchdog leaves them alone).
enum SessionStarted {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var ids = Set<ObjectIdentifier>()
    static func mark(_ ch: Channel) { lock.lock(); ids.insert(ObjectIdentifier(ch)); lock.unlock() }
    static func isSet(_ ch: Channel) -> Bool { lock.lock(); defer { lock.unlock() }; return ids.contains(ObjectIdentifier(ch)) }
}

/// "ssh-ed25519 SHA256:…" in OpenSSH's fingerprint format.
func describe(_ key: NIOSSHPublicKey) -> String {
    let parts = String(openSSHPublicKey: key).split(separator: " ")
    guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else { return "unknown key" }
    let fp = Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
    return "\(parts[0]) SHA256:\(fp)"
}

/// Offers no authentication at all: used to inspect the host key without a login attempt.
final class NoAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods,
                                nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        nextChallengePromise.succeed(nil)
    }
}

final class KnownHostsDelegate: NIOSSHClientServerAuthenticationDelegate {
    let pattern: String
    let keys: [NIOSSHPublicKey]

    let trust: String?

    init(host: String, port: Int, trust: String?) {
        self.trust = trust
        let pattern = port == 22 ? host : "[\(host)]:\(port)"
        self.pattern = pattern
        let text = (try? String(contentsOfFile: NSHomeDirectory() + "/.ssh/known_hosts", encoding: .utf8)) ?? ""
        var found: [NIOSSHPublicKey] = []
        for line in text.split(separator: "\n") where !line.hasPrefix("#") && !line.hasPrefix("|") {
            let f = line.split(separator: " ")
            guard f.count >= 3, f[0].split(separator: ",").contains(where: { $0 == pattern }) else { continue }
            if let k = try? NIOSSHPublicKey(openSSHPublicKey: "\(f[1]) \(f[2])") { found.append(k) }
        }
        keys = found
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        if keys.contains(hostKey) || (trust != nil && describe(hostKey).hasSuffix(" " + trust!)) {
            LastError.shared.set("host key trusted: \(describe(hostKey))")
            validationCompletePromise.succeed(())
        } else {
            let known = keys.map(describe).joined(separator: ", ")
            LastError.shared.set("host key for \(pattern) not trusted: server presented \(describe(hostKey)); known_hosts has \(known.isEmpty ? "none" : known)")
            validationCompletePromise.fail(SpikeError("untrusted host key"))
        }
    }
}

// MARK: - Channel plumbing

/// Unwraps SSH channel data to plain ByteBuffers (stderr goes to our stderr).
final class SSHDataCodec: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let d = unwrapInboundIn(data)
        guard case .byteBuffer(let bb) = d.data else { return }
        if d.type == .channel {
            context.fireChannelRead(wrapInboundOut(bb))
        } else {
            FileHandle.standardError.write(Data(bb.readableBytesView))
        }
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let bb = unwrapOutboundIn(data)
        context.write(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(bb))), promise: promise)
    }
}

struct Stats {
    var index = 0
    var tStart = 0.0      // TCP connect started
    var tReady = 0.0      // authenticated, channel/subsystem ready
    var tFirst = 0.0      // first payload byte
    var tLast = 0.0       // last payload byte
    var bytes = 0
    var shortReads = 0
    var rcvbuf = 0
    var notes: [String] = []
}

/// NIOSSH reports failures (host key rejected, auth exhausted) as errors but leaves
/// the TCP connection open; close it so nothing waits forever.
final class CloseOnError: ChannelInboundHandler {
    typealias InboundIn = Any
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        LastError.shared.setIfEmpty("\(error)")
        context.close(promise: nil)
    }
}

func connect(_ o: Options, password: String, group: EventLoopGroup) -> EventLoopFuture<Channel> {
    var bootstrap = ClientBootstrap(group: group)
        .connectTimeout(.seconds(10))
        .channelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
        .channelInitializer { ch in
            ch.eventLoop.makeCompletedFuture(withResultOf: {
                var cfg = SSHClientConfiguration(
                    userAuthDelegate: o.mode == "hostkey"
                        ? NoAuthDelegate() : SimplePasswordDelegate(username: o.user, password: password),
                    serverAuthDelegate: KnownHostsDelegate(host: o.host, port: o.port, trust: o.trust)
                )
                cfg.maximumPacketSize = o.packetKB * 1024
                // Bundled order is AES-256-GCM, AES-128-GCM; prefer 128 (a little faster, same hardware path).
                cfg.transportProtectionSchemes = Array(Constants.bundledTransportProtectionSchemes.reversed())
                try ch.pipeline.syncOperations.addHandlers([
                    NIOSSHHandler(role: .client(cfg), allocator: ch.allocator, inboundChildChannelInitializer: nil),
                    CloseOnError(),
                ])
                // Handshake watchdog: give up if login hasn't produced a session in 30 s.
                ch.eventLoop.scheduleTask(in: .seconds(30)) {
                    if ch.isActive, !SessionStarted.isSet(ch) {
                        LastError.shared.setIfEmpty("timed out during SSH handshake or login")
                        ch.close(promise: nil)
                    }
                }
            })
        }
    if o.rcvbufKB > 0 {
        // Set before connect so TCP window scaling is negotiated for it.
        bootstrap = bootstrap.channelOption(ChannelOptions.socketOption(.so_rcvbuf), value: SocketOptionValue(o.rcvbufKB * 1024))
    }
    return bootstrap.connect(host: o.host, port: o.port)
}

func openSession(_ parent: Channel, _ handler: ChannelHandler, halfClosure: Bool) -> EventLoopFuture<Channel> {
    let promise = parent.eventLoop.makePromise(of: Channel.self)
    parent.pipeline.handler(type: NIOSSHHandler.self).whenComplete { result in
        switch result {
        case .failure(let e):
            promise.fail(e)
        case .success(let ssh):
            ssh.createChannel(promise, channelType: .session) { child, _ in
                child.setOption(ChannelOptions.allowRemoteHalfClosure, value: halfClosure).flatMap {
                    child.eventLoop.makeCompletedFuture(withResultOf: {
                        try child.pipeline.syncOperations.addHandlers([SSHDataCodec(), handler])
                    })
                }
            }
        }
    }
    return promise.futureResult
}

/// Connects, creates a session channel with `makeHandler`, and returns its result.
func run<T>(_ o: Options, password: String, group: EventLoopGroup, halfClosure: Bool,
            makeHandler: @escaping (EventLoopPromise<T>, Int, Double) -> ChannelHandler) -> EventLoopFuture<T> {
    let tStart = now()
    return connect(o, password: password, group: group).flatMap { parent -> EventLoopFuture<T> in
        parent.getOption(ChannelOptions.socketOption(.so_rcvbuf)).flatMap { rcvbuf -> EventLoopFuture<T> in
            let p = parent.eventLoop.makePromise(of: T.self)
            // Surface connection-level failures (auth, host key) instead of hanging.
            parent.closeFuture.whenComplete { _ in
                p.fail(SpikeError("connection closed: \(LastError.shared.take() ?? "auth failure or server disconnect")"))
            }
            return openSession(parent, makeHandler(p, Int(rcvbuf), tStart), halfClosure: halfClosure)
                .flatMap { _ in SessionStarted.mark(parent); return p.futureResult }
                .always { _ in parent.close(promise: nil) }
        }
    }
}

func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

// MARK: - raw: cat over an exec channel

final class RawReader: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    let path: String
    let seconds: Double
    let done: EventLoopPromise<Stats>
    var stats = Stats()
    var finished = false

    init(path: String, seconds: Double, done: EventLoopPromise<Stats>, rcvbuf: Int, tStart: Double) {
        self.path = path
        self.seconds = seconds
        self.done = done
        stats.rcvbuf = rcvbuf
        stats.tStart = tStart
    }

    func channelActive(context: ChannelHandlerContext) {
        let req = SSHChannelRequestEvent.ExecRequest(command: "cat -- \(shellQuote(path))", wantReply: true)
        context.triggerUserOutboundEvent(req, promise: nil)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is ChannelSuccessEvent {
            stats.tReady = now()
        } else if event is ChannelFailureEvent {
            fail(context, SpikeError("exec request refused"))
        } else if case ChannelEvent.inputClosed = event {
            finish(context)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let bb = unwrapInboundIn(data)
        let t = now()
        if stats.tFirst == 0 { stats.tFirst = t }
        stats.tLast = t
        stats.bytes += bb.readableBytes
        if seconds > 0, t - stats.tFirst >= seconds { finish(context) }
    }

    func channelInactive(context: ChannelHandlerContext) { finish(context) }

    func errorCaught(context: ChannelHandlerContext, error: Error) { fail(context, error) }

    func finish(_ context: ChannelHandlerContext) {
        guard !finished else { return }
        finished = true
        done.succeed(stats)
        context.close(promise: nil)
    }

    func fail(_ context: ChannelHandlerContext, _ error: Error) {
        guard !finished else { return }
        finished = true
        done.fail(error)
        context.close(promise: nil)
    }
}

// MARK: - hash: sha256sum with the path on stdin

final class RemoteHasher: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    let path: String
    let done: EventLoopPromise<(String, Double)>
    var output = ""
    var t0 = 0.0
    var finished = false

    init(path: String, done: EventLoopPromise<(String, Double)>) {
        self.path = path
        self.done = done
    }

    func channelActive(context: ChannelHandlerContext) {
        // The filename never touches the shell command line.
        let req = SSHChannelRequestEvent.ExecRequest(command: "xargs -0 sha256sum --", wantReply: true)
        context.triggerUserOutboundEvent(req, promise: nil)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is ChannelSuccessEvent {
            t0 = now()
            var b = context.channel.allocator.buffer(capacity: path.utf8.count + 1)
            b.writeString(path)
            b.writeInteger(UInt8(0))
            context.writeAndFlush(wrapOutboundOut(b), promise: nil)
            context.close(mode: .output, promise: nil)   // EOF on the remote stdin
        } else if event is ChannelFailureEvent {
            finish(context, .failure(SpikeError("exec request refused (no shell access?)")))
        } else if case ChannelEvent.inputClosed = event {
            finishWithOutput(context)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var bb = unwrapInboundIn(data)
        output += bb.readString(length: bb.readableBytes) ?? ""
    }

    func channelInactive(context: ChannelHandlerContext) { finishWithOutput(context) }

    func finishWithOutput(_ context: ChannelHandlerContext) {
        let hash = output.split(separator: " ").first.map(String.init) ?? ""
        if hash.count == 64 {
            finish(context, .success((hash, now() - t0)))
        } else {
            finish(context, .failure(SpikeError("unexpected sha256sum output: \(output.prefix(200))")))
        }
    }

    func finish(_ context: ChannelHandlerContext, _ result: Result<(String, Double), Error>) {
        guard !finished else { return }
        finished = true
        done.completeWith(result)
        context.close(promise: nil)
    }
}

// MARK: - sftp: minimal pipelined SFTP v3 reader

enum FXP {
    static let initPkt: UInt8 = 1, version: UInt8 = 2, open: UInt8 = 3, close: UInt8 = 4, read: UInt8 = 5
    static let stat: UInt8 = 17, status: UInt8 = 101, handle: UInt8 = 102, data: UInt8 = 103, attrs: UInt8 = 105
    static let extended: UInt8 = 200, extendedReply: UInt8 = 201
}

final class SFTPReader: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    enum State { case subsystem, version, limits, stat, open, reading, closing, done }

    let o: Options
    let index: Int
    let done: EventLoopPromise<Stats>
    var stats = Stats()
    var state = State.subsystem
    var inbound: ByteBuffer?
    var nextID: UInt32 = 1
    var handle: ByteBuffer?
    var readSize: UInt32
    var rangeEnd: UInt64 = 0
    var nextOffset: UInt64 = 0
    var outstanding: [UInt32: (offset: UInt64, length: UInt32)] = [:]
    var deadline = Double.infinity
    var fd: Int32 = -1

    init(_ o: Options, index: Int, done: EventLoopPromise<Stats>, rcvbuf: Int, tStart: Double) {
        self.o = o
        self.index = index
        self.done = done
        readSize = UInt32(o.readKB * 1024)
        stats.index = index
        stats.rcvbuf = rcvbuf
        stats.tStart = tStart
    }

    // Outgoing packets: uint32 length, byte type, body.
    func send(_ context: ChannelHandlerContext, _ type: UInt8, flush: Bool = true, _ body: (inout ByteBuffer) -> Void) {
        var b = context.channel.allocator.buffer(capacity: 64)
        b.writeInteger(UInt32(0))
        b.writeInteger(type)
        body(&b)
        b.setInteger(UInt32(b.readableBytes - 4), at: 0)
        context.write(wrapOutboundOut(b), promise: nil)
        if flush { context.flush() }
    }

    func takeID() -> UInt32 {
        defer { nextID &+= 1 }
        return nextID
    }

    func channelActive(context: ChannelHandlerContext) {
        context.triggerUserOutboundEvent(SSHChannelRequestEvent.SubsystemRequest(subsystem: "sftp", wantReply: true), promise: nil)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is ChannelSuccessEvent, state == .subsystem {
            stats.tReady = now()
            state = .version
            send(context, FXP.initPkt) { $0.writeInteger(UInt32(3)) }
        } else if event is ChannelFailureEvent {
            fail(context, SpikeError("sftp subsystem refused"))
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var bb = unwrapInboundIn(data)
        if inbound == nil { inbound = bb } else { inbound!.writeBuffer(&bb) }
        while let length = inbound!.getInteger(at: inbound!.readerIndex, as: UInt32.self),
              inbound!.readableBytes >= 4 + Int(length) {
            inbound!.moveReaderIndex(forwardBy: 4)
            var packet = inbound!.readSlice(length: Int(length))!
            let type: UInt8 = packet.readInteger()!
            handle(context, type, &packet)
            if state == .done { return }
        }
        inbound!.discardReadBytes()
    }

    func handle(_ context: ChannelHandlerContext, _ type: UInt8, _ p: inout ByteBuffer) {
        switch (state, type) {
        case (.version, FXP.version):
            _ = p.readInteger(as: UInt32.self)
            var names: [String] = []
            while var name = p.readSSHString(), p.readSSHString() != nil {
                names.append(name.readString(length: name.readableBytes) ?? "?")
            }
            if index == 0 { stats.notes.append("extensions: \(names.isEmpty ? "none" : names.joined(separator: ", "))") }
            if names.contains("limits@openssh.com") {
                state = .limits
                send(context, FXP.extended) { $0.writeInteger(self.takeID()); $0.writeSSHString("limits@openssh.com") }
            } else {
                sendStat(context)
            }

        case (.limits, FXP.extendedReply):
            _ = p.readInteger(as: UInt32.self)
            let maxPacket = p.readInteger(as: UInt64.self) ?? 0
            let maxRead = p.readInteger(as: UInt64.self) ?? 0
            if index == 0 { stats.notes.append("limits@openssh.com: max-packet \(maxPacket), max-read \(maxRead)") }
            if maxRead > 0, UInt64(readSize) > maxRead { readSize = UInt32(maxRead) }
            sendStat(context)

        case (.limits, FXP.status):
            sendStat(context)

        case (.stat, FXP.attrs):
            _ = p.readInteger(as: UInt32.self)
            let flags = p.readInteger(as: UInt32.self) ?? 0
            guard flags & 1 != 0, let size = p.readInteger(as: UInt64.self) else {
                return fail(context, SpikeError("server did not report a file size"))
            }
            let n = UInt64(o.conns)
            let chunk = (size + n - 1) / n
            nextOffset = min(size, UInt64(index) * chunk)
            rangeEnd = min(size, nextOffset + chunk)
            state = .open
            send(context, FXP.open) {
                $0.writeInteger(self.takeID())
                $0.writeSSHString(self.o.path)
                $0.writeInteger(UInt32(1))   // SSH_FXF_READ
                $0.writeInteger(UInt32(0))   // no attrs
            }

        case (.open, FXP.handle):
            _ = p.readInteger(as: UInt32.self)
            handle = p.readSSHString()
            if let out = o.out {
                fd = Darwin.open(out, O_WRONLY | O_CREAT, 0o644)
                if fd < 0 { return fail(context, SpikeError("cannot open \(out)")) }
            }
            if o.seconds > 0 { deadline = now() + o.seconds }
            state = .reading
            fill(context)
            finishIfDone(context)

        case (.reading, FXP.data):
            let id = p.readInteger(as: UInt32.self) ?? 0
            guard let req = outstanding.removeValue(forKey: id), var payload = p.readSSHString() else { return }
            let got = payload.readableBytes
            let t = now()
            if stats.tFirst == 0 { stats.tFirst = t }
            stats.tLast = t
            stats.bytes += got
            if fd >= 0 {
                payload.withUnsafeReadableBytes { raw in
                    _ = pwrite(fd, raw.baseAddress, raw.count, off_t(req.offset))
                }
            }
            if got > 0, UInt32(got) < req.length {
                // Short read: legal in SFTP (SFTPGo caps replies at 32 KB). Ask for the rest.
                stats.shortReads += 1
                request(context, req.offset + UInt64(got), req.length - UInt32(got))
            }
            fill(context)
            finishIfDone(context)

        case (.reading, FXP.status):
            let id = p.readInteger(as: UInt32.self) ?? 0
            let code = p.readInteger(as: UInt32.self) ?? 0
            outstanding.removeValue(forKey: id)
            if code == 1 {
                nextOffset = rangeEnd   // EOF: stop issuing reads
            } else {
                return fail(context, SpikeError("read failed: status \(code) \(p.readSSHText())"))
            }
            finishIfDone(context)

        case (.closing, FXP.status):
            state = .done
            if fd >= 0 { Darwin.close(fd) }
            done.succeed(stats)
            context.close(promise: nil)

        case (_, FXP.status):
            _ = p.readInteger(as: UInt32.self)
            let code = p.readInteger(as: UInt32.self) ?? 0
            fail(context, SpikeError("server error in state \(state): status \(code) \(p.readSSHText())"))

        default:
            fail(context, SpikeError("unexpected packet type \(type) in state \(state)"))
        }
    }

    func sendStat(_ context: ChannelHandlerContext) {
        state = .stat
        send(context, FXP.stat) { $0.writeInteger(self.takeID()); $0.writeSSHString(self.o.path) }
    }

    func request(_ context: ChannelHandlerContext, _ offset: UInt64, _ length: UInt32) {
        let id = takeID()
        outstanding[id] = (offset, length)
        send(context, FXP.read, flush: false) {
            $0.writeInteger(id)
            $0.writeSSHString(self.handle!)
            $0.writeInteger(offset)
            $0.writeInteger(length)
        }
    }

    func fill(_ context: ChannelHandlerContext) {
        let t = now()
        while outstanding.count < o.requests, nextOffset < rangeEnd, t < deadline {
            let length = UInt32(min(UInt64(readSize), rangeEnd - nextOffset))
            request(context, nextOffset, length)
            nextOffset += UInt64(length)
        }
        context.flush()
    }

    func finishIfDone(_ context: ChannelHandlerContext) {
        guard state == .reading, outstanding.isEmpty, nextOffset >= rangeEnd || now() >= deadline else { return }
        state = .closing
        send(context, FXP.close) { $0.writeInteger(self.takeID()); $0.writeSSHString(self.handle!) }
    }

    func channelInactive(context: ChannelHandlerContext) {
        if state != .done { fail(context, SpikeError("channel closed in state \(state)")) }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) { fail(context, error) }

    func fail(_ context: ChannelHandlerContext, _ error: Error) {
        guard state != .done else { return }
        state = .done
        if fd >= 0 { Darwin.close(fd) }
        done.fail(error)
        context.close(promise: nil)
    }
}

// MARK: - Main

func localSHA256(_ path: String) throws -> String {
    guard let h = FileHandle(forReadingAtPath: path) else { throw SpikeError("cannot read \(path)") }
    defer { try? h.close() }
    var hasher = SHA256()
    while let chunk = try h.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

let o = parseOptions()
let password = o.mode == "hostkey" ? "" : readPassword("Password for \(o.user)@\(o.host): ")
let group = MultiThreadedEventLoopGroup(numberOfThreads: max(2, o.conns))
defer { try? group.syncShutdownGracefully() }

func remoteHash() throws -> (String, Double) {
    try run(o, password: password, group: group, halfClosure: true) { (p: EventLoopPromise<(String, Double)>, _, _) in
        RemoteHasher(path: o.path, done: p)
    }.wait()
}

do {
    let window = o.packetKB * 64
    switch o.mode {
    case "hostkey":
        let ch = try connect(o, password: "", group: group).wait()
        ch.eventLoop.scheduleTask(in: .seconds(15)) { ch.close(promise: nil) }
        try? ch.closeFuture.wait()
        print(LastError.shared.take() ?? "no host key exchange happened")

    case "hash":
        let (hash, secs) = try remoteHash()
        print(String(format: "sha256 %@  (%.1f s on the server)", hash, secs))

    case "raw":
        print("raw: cat over SSH · packet \(o.packetKB) KB · window \(window / 1024) MB · rcvbuf \(o.rcvbufKB == 0 ? "auto" : "\(o.rcvbufKB) KB")")
        let s = try run(o, password: password, group: group, halfClosure: true) { (p: EventLoopPromise<Stats>, rcvbuf, t0) in
            RawReader(path: o.path, seconds: o.seconds, done: p, rcvbuf: rcvbuf, tStart: t0)
        }.wait()
        print(String(format: "  setup %.2f s · %@ · %.0f MB in %.1f s · SO_RCVBUF %d KB",
                     s.tReady - s.tStart, mbps(s.bytes, s.tLast - s.tFirst), Double(s.bytes) / 1e6,
                     s.tLast - s.tFirst, s.rcvbuf / 1024))

    default:   // sftp
        print("sftp: \(o.conns) conn · \(o.requests) × \(o.readKB) KB in flight · packet \(o.packetKB) KB · window \(window / 1024) MB · rcvbuf \(o.rcvbufKB == 0 ? "auto" : "\(o.rcvbufKB) KB")")
        if let out = o.out {
            let fd = Darwin.open(out, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
            guard fd >= 0 else { throw SpikeError("cannot create \(out)") }
            Darwin.close(fd)
        }
        var futures: [EventLoopFuture<Stats>] = []
        for i in 0..<o.conns {
            if i > 0 { usleep(useconds_t(o.staggerMS * 1000)) }
            futures.append(run(o, password: password, group: group, halfClosure: false) { (p: EventLoopPromise<Stats>, rcvbuf, t0) in
                SFTPReader(o, index: i, done: p, rcvbuf: rcvbuf, tStart: t0)
            })
        }
        let results = try EventLoopFuture.whenAllComplete(futures, on: group.next()).wait()
        var all: [Stats] = []
        for (i, r) in results.enumerated() {
            switch r {
            case .success(let s):
                all.append(s)
                print(String(format: "  conn %2d  setup %.2f s · %@ · %4.0f MB · short reads %d · SO_RCVBUF %d KB",
                             i, s.tReady - s.tStart, mbps(s.bytes, s.tLast - s.tFirst), Double(s.bytes) / 1e6,
                             s.shortReads, s.rcvbuf / 1024))
                s.notes.forEach { print("           \($0)") }
            case .failure(let e):
                print("  conn \(i)  FAILED: \(e)")
            }
        }
        let active = all.filter { $0.bytes > 0 }
        if let first = active.map(\.tFirst).min(), let last = active.map(\.tLast).max() {
            let bytes = active.reduce(0) { $0 + $1.bytes }
            print("  total    \(mbps(bytes, last - first)) · \(String(format: "%.0f", Double(bytes) / 1e6)) MB in \(String(format: "%.1f", last - first)) s (first byte to last)")
        }
        if let out = o.out, o.seconds == 0, all.count == o.conns {
            print("verifying…")
            let local = try localSHA256(out)
            let (remote, secs) = try remoteHash()
            print("  local  \(local)")
            print(String(format: "  server %@  (%.1f s)", remote, secs))
            print(local == remote ? "  ✓ match" : "  ✗ MISMATCH")
        }
    }
} catch {
    if let why = LastError.shared.take(), !why.hasPrefix("host key trusted") {
        print("error: \(error) (\(why))")
    } else {
        print("error: \(error)")
    }
    exit(1)
}
