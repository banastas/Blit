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
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let watcher = ConnectionWatcher(ready: ready)
                    let username: String
                    let password: String
                    switch credential {
                    case .password(let p):
                        username = endpoint.username
                        password = p
                    }
                    var config = SSHClientConfiguration(
                        userAuthDelegate: PasswordAuthDelegate(username: username, password: password, watcher: watcher),
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
        let channel = try await bootstrap.connect(host: endpoint.host, port: endpoint.port).get()
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
    public func run(_ command: String, stdin: [UInt8] = []) async throws -> CommandResult {
        let done = channel.eventLoop.makePromise(of: CommandResult.self)
        _ = try await openSessionChannel(halfClosure: true) { child in
            try child.pipeline.syncOperations.addHandler(ExecHandler(command: command, stdin: stdin, done: done))
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

    init(ready: EventLoopPromise<Void>) { self.ready = ready }

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

final class PasswordAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    private var offer: NIOSSHUserAuthenticationOffer?
    private let watcher: ConnectionWatcher

    init(username: String, password: String, watcher: ConnectionWatcher) {
        offer = NIOSSHUserAuthenticationOffer(username: username, serviceName: "", offer: .password(.init(password: password)))
        self.watcher = watcher
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        if let offer, availableMethods.contains(.password) {
            self.offer = nil
            nextChallengePromise.succeed(offer)
        } else {
            // Out of methods: the password was rejected (or never allowed).
            watcher.note(SSHError.authenticationFailed)
            nextChallengePromise.succeed(nil)
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

    init(command: String, stdin: [UInt8], done: EventLoopPromise<SSHConnection.CommandResult>) {
        self.command = command
        self.stdin = stdin
        self.done = done
    }

    func channelActive(context: ChannelHandlerContext) {
        context.triggerUserOutboundEvent(SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true), promise: nil)
        context.fireChannelActive()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelSuccessEvent:
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
            finish(context, .success(result))
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard case .byteBuffer(let buffer) = message.data else { return }
        if message.type == .channel {
            result.stdout.append(contentsOf: buffer.readableBytesView)
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
        done.completeWith(outcome)
        context.close(promise: nil)
    }
}
