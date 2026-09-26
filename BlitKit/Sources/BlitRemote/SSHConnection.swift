// One SSH connection, tuned per the M1 spike, with the failure handling
// SwiftNIO SSH leaves to its users (close on error, handshake timeout).

import NIOCore
import NIOPosix
import NIOSSH

public struct SSHEndpoint: Hashable, Sendable, CustomStringConvertible {
    public var host: String
    public var port: Int
    public var username: String

    public init(host: String, port: Int = 22, username: String) {
        self.host = host
        self.port = port
        self.username = username
    }

    public var description: String { "\(username)@\(host):\(port)" }
}

public enum SSHCredential: Sendable {
    case password(String)
    /// An SSH key (PRD R1.1); see SSHKeyFile.
    case privateKey(NIOSSHPrivateKey)
}

public struct SSHTuning: Sendable {
    /// Per-connection TCP receive buffer. macOS autotuning stops at 4 MB
    /// (net.inet.tcp.autorcvbufmax), which capped one connection at ~24.5 MB/s
    /// at 148 ms in M1; 7 MB fits under the default kern.ipc.maxsockbuf (8 MB).
    public var receiveBufferBytes = 7 * 1024 * 1024
    /// SSH maximum packet size; SwiftNIO SSH's channel window is 64× this (16 MB).
    public var maximumPacketSize = 256 * 1024
    public var connectTimeout: TimeAmount = .seconds(10)
    public var handshakeTimeout: TimeAmount = .seconds(30)
    /// TCP keepalive: probe after this much silence, then every `keepAliveInterval`,
    /// giving up after `keepAliveProbes` misses. Detects a dead link (Wi-Fi drop,
    /// router restart) in about a minute, even while waiting on a server hash.
    public var keepAliveIdle: Int32 = 30
    public var keepAliveInterval: Int32 = 10
    public var keepAliveProbes: Int32 = 3

    public init() {}
}

public enum SSHError: Error, CustomStringConvertible, Sendable {
    case hostKeyRejected(host: String, port: Int, presented: HostKeyIdentity, known: [HostKeyIdentity])
    case authenticationFailed
    case handshakeTimedOut
    case channelRequestRefused(String)
    case disconnected(String)

    public var description: String {
        switch self {
        case .hostKeyRejected(let host, let port, let presented, let known):
            let onFile = known.isEmpty ? "none" : known.map(\.description).joined(separator: ", ")
            return "host key for \(host):\(port) not trusted: server presented \(presented); on file: \(onFile)"
        case .authenticationFailed: return "authentication failed"
        case .handshakeTimedOut: return "timed out during SSH handshake or login"
        case .channelRequestRefused(let what): return "server refused \(what)"
        case .disconnected(let why): return "disconnected: \(why)"
        }
    }
}

public final class SSHConnection: Sendable {
    public let endpoint: SSHEndpoint
    let channel: Channel

    private init(endpoint: SSHEndpoint, channel: Channel) {
        self.endpoint = endpoint
        self.channel = channel
    }

    /// Connects, verifies the host key, and authenticates. Returns only once
    /// login succeeded; any failure closes the TCP connection.
    public static func connect(
        to endpoint: SSHEndpoint,
        credential: SSHCredential,
        verifier: any HostKeyVerifier,
        tuning: SSHTuning = SSHTuning(),
        group: EventLoopGroup = MultiThreadedEventLoopGroup.singleton
    ) async throws -> SSHConnection {
        let loop = group.next()
        let ready = loop.makePromise(of: Void.self)
        let bootstrap = ClientBootstrap(group: loop)
            .connectTimeout(tuning.connectTimeout)
            .channelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
            // Set before connect so TCP window scaling is negotiated for it.
            .channelOption(ChannelOptions.socketOption(.so_rcvbuf), value: SocketOptionValue(tuning.receiveBufferBytes))
            .channelOption(ChannelOptions.socketOption(.so_keepalive), value: 1)
            .channelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_KEEPALIVE), value: tuning.keepAliveIdle)
            .channelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_KEEPINTVL), value: tuning.keepAliveInterval)
            .channelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_KEEPCNT), value: tuning.keepAliveProbes)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let watcher = ConnectionWatcher(ready: ready)
                    let offer: NIOSSHUserAuthenticationOffer.Offer
                    let method: NIOSSHAvailableUserAuthenticationMethods
                    switch credential {
                    case .password(let p):
                        offer = .password(.init(password: p))
                        method = .password
                    case .privateKey(let key):
                        offer = .privateKey(.init(privateKey: key))
                        method = .publicKey
                    }
                    var config = SSHClientConfiguration(
                        userAuthDelegate: PasswordAuthDelegate(username: endpoint.username, offer: offer, method: method,
                                                               watcher: watcher),
                        serverAuthDelegate: VerifierDelegate(endpoint: endpoint, verifier: verifier, watcher: watcher)
                    )
                    config.maximumPacketSize = tuning.maximumPacketSize
                    // Bundled order is AES-256-GCM then AES-128-GCM; prefer 128.
                    config.transportProtectionSchemes = Array(Constants.bundledTransportProtectionSchemes.reversed())
                    try channel.pipeline.syncOperations.addHandlers([
                        NIOSSHHandler(role: .client(config), allocator: channel.allocator, inboundChildChannelInitializer: nil),
                        watcher,
                    ])
                    let bound = NIOLoopBound(watcher, eventLoop: channel.eventLoop)
                    channel.eventLoop.scheduleTask(in: tuning.handshakeTimeout) {
                        bound.value.handshakeTimedOut(channel: channel)
                    }
                }
            }
        let channel: Channel
        do {
            channel = try await bootstrap.connect(host: endpoint.host, port: endpoint.port).get()
        } catch {
            // No channel was made (DNS failure, refused): complete `ready` so the
            // promise isn't leaked (a debug-build crash in NIO).
            ready.fail(error)
            throw error
        }
        do {
            try await ready.futureResult.get()
        } catch {
            channel.close(promise: nil)
            throw error
        }
        return SSHConnection(endpoint: endpoint, channel: channel)
    }

    public var isActive: Bool { channel.isActive }

    public func close() async {
        try? await channel.close()
    }

    /// Opens a session channel with the given handlers.
    func openSessionChannel(
        halfClosure: Bool,
        _ addHandlers: @escaping @Sendable (Channel) throws -> Void
    ) async throws -> Channel {
        let promise = channel.eventLoop.makePromise(of: Channel.self)
        let parent = channel
        channel.eventLoop.execute {
            do {
                let ssh = try parent.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
                ssh.createChannel(promise, channelType: .session) { child, _ in
                    child.setOption(ChannelOptions.allowRemoteHalfClosure, value: halfClosure).flatMapThrowing {
                        try addHandlers(child)
                    }
                }
            } catch {
                promise.fail(error)
            }
        }
        return try await promise.futureResult.get()
    }

    public struct CommandResult: Sendable {
        public var stdout: [UInt8]
        public var stderr: [UInt8]
        public var exitStatus: Int?
    }

    /// Runs a command, sends `stdin` followed by EOF, and collects its output.
    /// `onStderr` sees stderr as it arrives (e.g. progress lines).
    public func run(_ command: String, stdin: [UInt8] = [],
                    onStderr: (@Sendable ([UInt8]) -> Void)? = nil) async throws -> CommandResult {
        let done = channel.eventLoop.makePromise(of: CommandResult.self)
        _ = try await openSessionChannel(halfClosure: true) { child in
            try child.pipeline.syncOperations.addHandler(ExecHandler(command: command, stdin: stdin, done: done,
                                                                     onStderr: onStderr))
        }
        return try await done.futureResult.get()
    }
}

// MARK: - Handlers

/// Completes `ready` exactly once: on login success, or with the first failure.
final class ConnectionWatcher: ChannelInboundHandler {
    typealias InboundIn = Any
    private let ready: EventLoopPromise<Void>
    private var completed = false
    private var reason: Error?
    private var channel: Channel?

    init(ready: EventLoopPromise<Void>) { self.ready = ready }

    func handlerAdded(context: ChannelHandlerContext) { channel = context.channel }

    /// Sign-in was refused and there's nothing left to offer: NIOSSH would
    /// leave the connection idle until the handshake timeout, so fail now.
    func authenticationFailed() {
        note(SSHError.authenticationFailed)
        guard let channel else { return }
        channel.eventLoop.execute { self.fail(SSHError.authenticationFailed, channel: channel) }
    }

    /// Records why the connection is about to fail (host key, auth), before NIOSSH closes it.
    func note(_ error: Error) {
        if reason == nil { reason = error }
    }

    /// Fails `ready` if login hasn't completed, and closes the connection either way.
    func fail(_ error: Error, channel: Channel) {
        if !completed {
            completed = true
            ready.fail(reason ?? error)
        }
        channel.close(promise: nil)
    }

    /// Only acts while the handshake is still in progress.
    func handshakeTimedOut(channel: Channel) {
        guard !completed else { return }
        fail(SSHError.handshakeTimedOut, channel: channel)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent, !completed {
            completed = true
            ready.succeed(())
        }
        context.fireUserInboundEventTriggered(event)
    }

    // NIOSSH reports failures as errors but leaves the TCP connection open.
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        fail(error, channel: context.channel)
    }

    func channelInactive(context: ChannelHandlerContext) {
        fail(SSHError.disconnected("connection closed"), channel: context.channel)
        context.fireChannelInactive()
    }
}

final class VerifierDelegate: NIOSSHClientServerAuthenticationDelegate {
    let endpoint: SSHEndpoint
    let verifier: any HostKeyVerifier
    let watcher: ConnectionWatcher

    init(endpoint: SSHEndpoint, verifier: any HostKeyVerifier, watcher: ConnectionWatcher) {
        self.endpoint = endpoint
        self.verifier = verifier
        self.watcher = watcher
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        switch verifier.verify(host: endpoint.host, port: endpoint.port, key: hostKey) {
        case .trusted:
            validationCompletePromise.succeed(())
        case .rejected(let presented, let known):
            let error = SSHError.hostKeyRejected(host: endpoint.host, port: endpoint.port, presented: presented, known: known)
            watcher.note(error)
            validationCompletePromise.fail(error)
        }
    }
}

/// Offers one credential (a password or a key) once.
final class PasswordAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    private var offer: NIOSSHUserAuthenticationOffer?
    private let method: NIOSSHAvailableUserAuthenticationMethods
    private let watcher: ConnectionWatcher

    init(username: String, offer: NIOSSHUserAuthenticationOffer.Offer, method: NIOSSHAvailableUserAuthenticationMethods,
         watcher: ConnectionWatcher) {
        self.offer = NIOSSHUserAuthenticationOffer(username: username, serviceName: "", offer: offer)
        self.method = method
        self.watcher = watcher
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        if let offer, availableMethods.contains(method) {
            self.offer = nil
            nextChallengePromise.succeed(offer)
        } else {
            // Out of methods: the credential was rejected (or never allowed).
            nextChallengePromise.succeed(nil)
            watcher.authenticationFailed()
        }
    }
}

final class ExecHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    private let command: String
    private let stdin: [UInt8]
    private let done: EventLoopPromise<SSHConnection.CommandResult>
    private var result = SSHConnection.CommandResult(stdout: [], stderr: [], exitStatus: nil)
    private var completed = false
    private let onStderr: (@Sendable ([UInt8]) -> Void)?
    private var started = false
    private var sawProgress = false
    private let created = NIODeadline.now()
    private var lastActivity = NIODeadline.now()
    private var watchdog: RepeatedTask?

    /// The server must start the command within this long.
    static let startTimeout: TimeAmount = .seconds(60)
    /// Once the command has reported progress (dd status=progress, about once a
    /// second), this much silence means it's stuck (e.g. a hung mount).
    static let progressTimeout: TimeAmount = .seconds(120)

    init(command: String, stdin: [UInt8], done: EventLoopPromise<SSHConnection.CommandResult>,
         onStderr: (@Sendable ([UInt8]) -> Void)? = nil) {
        self.command = command
        self.stdin = stdin
        self.done = done
        self.onStderr = onStderr
    }

    func handlerAdded(context: ChannelHandlerContext) {
        let bound = NIOLoopBound((self, context), eventLoop: context.eventLoop)
        watchdog = context.eventLoop.scheduleRepeatedTask(initialDelay: .seconds(10), delay: .seconds(10)) { _ in
            let (handler, context) = bound.value
            handler.checkForStall(context)
        }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        watchdog?.cancel()
        watchdog = nil
    }

    private func checkForStall(_ context: ChannelHandlerContext) {
        let now = NIODeadline.now()
        if !started, now - created > Self.startTimeout {
            finish(context, .failure(SSHError.disconnected("the server didn't start the command")))
        } else if sawProgress, now - lastActivity > Self.progressTimeout {
            finish(context, .failure(SSHError.disconnected("no progress from the server for \(Self.progressTimeout.nanoseconds / 1_000_000_000) s")))
        }
    }

    func channelActive(context: ChannelHandlerContext) {
        context.triggerUserOutboundEvent(SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true), promise: nil)
        context.fireChannelActive()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelSuccessEvent:
            started = true
            lastActivity = .now()
            if !stdin.isEmpty {
                let buffer = context.channel.allocator.buffer(bytes: stdin)
                context.write(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer))), promise: nil)
            }
            context.flush()
            context.close(mode: .output, promise: nil)   // EOF on the command's stdin
        case is ChannelFailureEvent:
            finish(context, .failure(SSHError.channelRequestRefused("exec (no shell access?)")))
        case let status as SSHChannelRequestEvent.ExitStatus:
            result.exitStatus = status.exitStatus
        case ChannelEvent.inputClosed:
            // EOF can arrive before the exit status (RFC 4254 doesn't fix the
            // order). Finish when the channel closes; if a server never closes
            // it, finish shortly after EOF anyway.
            let bound = NIOLoopBound((self, context), eventLoop: context.eventLoop)
            context.eventLoop.scheduleTask(in: .seconds(2)) {
                let (handler, context) = bound.value
                handler.finish(context, .success(handler.result))
            }
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard case .byteBuffer(let buffer) = message.data else { return }
        lastActivity = .now()
        if message.type != .channel, onStderr != nil { sawProgress = true }
        if message.type == .channel {
            result.stdout.append(contentsOf: buffer.readableBytesView)
        } else if let onStderr {
            onStderr(Array(buffer.readableBytesView))
        } else {
            result.stderr.append(contentsOf: buffer.readableBytesView)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        finish(context, .success(result))
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        finish(context, .failure(error))
    }

    private func finish(_ context: ChannelHandlerContext, _ outcome: Result<SSHConnection.CommandResult, Error>) {
        guard !completed else { return }
        completed = true
        watchdog?.cancel()
        watchdog = nil
        done.completeWith(outcome)
        context.close(promise: nil)
    }
}
