// An SFTP session over one SSH channel. Simple requests are answered through
// promises; bulk downloads run entirely on the channel's event loop, driven by
// ReadPlanner, with file writes on a thread pool.

import BlitSFTP
import NIOCore
import NIOSSH

public struct ReadStats: Sendable {
    public var bytes: UInt64
    public var shortReads: Int
    /// The file was shorter than expected (changed since it was listed).
    public var endedEarly: Bool
}

/// Read size and depth for a server. From M1: 255 KB × 32 where the server
/// states its read limit (OpenSSH), else 64 KB × 128 relying on short-read
/// handling (SFTPGo caps replies at 32 KB).
public struct ReadStrategy: Sendable, Equatable {
    public var readSize: UInt32
    public var maxInFlight: Int

    public static func `for`(limits: SFTPLimits?) -> ReadStrategy {
        if let limits, limits.maxReadLength > 0 {
            return ReadStrategy(readSize: UInt32(min(limits.maxReadLength, 256 * 1024)), maxInFlight: 32)
        }
        return ReadStrategy(readSize: 64 * 1024, maxInFlight: 128)
    }
}

public final class SFTPClient: Sendable {
    public let connection: SSHConnection
    public let extensions: [SFTPExtension]
    public let limits: SFTPLimits?
    let channel: Channel
    let handler: NIOLoopBound<SFTPChannelHandler>

    public var strategy: ReadStrategy { .for(limits: limits) }

    private init(connection: SSHConnection, channel: Channel, handler: NIOLoopBound<SFTPChannelHandler>,
                 extensions: [SFTPExtension], limits: SFTPLimits?) {
        self.connection = connection
        self.channel = channel
        self.handler = handler
        self.extensions = extensions
        self.limits = limits
    }

    /// Starts the `sftp` subsystem on a new channel of `connection`.
    public static func open(on connection: SSHConnection) async throws -> SFTPClient {
        let versionPromise = connection.channel.eventLoop.makePromise(of: [SFTPExtension].self)
        let channel = try await connection.openSessionChannel(halfClosure: false) { child in
            try child.pipeline.syncOperations.addHandler(SFTPChannelHandler(version: versionPromise))
        }
        let handler = try await channel.eventLoop.submit {
            NIOLoopBound(try channel.pipeline.syncOperations.handler(type: SFTPChannelHandler.self), eventLoop: channel.eventLoop)
        }.get()
        let extensions = try await versionPromise.futureResult.get()
        var limits: SFTPLimits?
        if extensions.contains(where: { $0.name == "limits@openssh.com" }) {
            let reply = try await Self.request(channel, handler) {
                .extended(id: $0, name: "limits@openssh.com", payload: ByteBuffer())
            }
            if case .extendedReply(_, let payload) = reply { limits = try? SFTPLimits(payload: payload) }
        }
        return SFTPClient(connection: connection, channel: channel, handler: handler, extensions: extensions, limits: limits)
    }

    private static func request(_ channel: Channel, _ handler: NIOLoopBound<SFTPChannelHandler>,
                                _ make: @escaping @Sendable (UInt32) -> SFTPRequest) async throws -> SFTPResponse {
        try await channel.eventLoop.flatSubmit { handler.value.send(make) }.get()
    }

    func request(_ make: @escaping @Sendable (UInt32) -> SFTPRequest) async throws -> SFTPResponse {
        try await Self.request(channel, handler, make)
    }

    // MARK: Operations

    public func stat(_ path: RemotePath) async throws -> SFTPAttributes {
        switch try await request({ .stat(id: $0, path: path) }) {
        case .attributes(_, let attributes): return attributes
        case let other: throw Self.failure(other, "stat \(path)")
        }
    }

    public func realpath(_ path: RemotePath) async throws -> RemotePath {
        switch try await request({ .realpath(id: $0, path: path) }) {
        case .name(_, let entries) where entries.count == 1: return entries[0].filename
        case let other: throw Self.failure(other, "realpath \(path)")
        }
    }

    // MARK: File management

    public func makeDirectory(_ path: RemotePath) async throws {
        try expectOK(try await request { .mkdir(id: $0, path: path, attributes: SFTPAttributes()) }, "create folder \(path)")
    }

    /// Renames or moves within the server. Fails if `to` already exists.
    public func rename(_ from: RemotePath, to: RemotePath) async throws {
        try expectOK(try await request { .rename(id: $0, from: from, to: to) }, "rename \(from)")
    }

    /// Deletes a file. Something already gone counts as deleted.
    public func removeFile(_ path: RemotePath) async throws {
        try expectOK(try await request { .remove(id: $0, path: path) }, "delete \(path)", orGone: true)
    }

    /// Deletes an empty folder. Something already gone counts as deleted.
    public func removeDirectory(_ path: RemotePath) async throws {
        try expectOK(try await request { .rmdir(id: $0, path: path) }, "delete folder \(path)", orGone: true)
    }

    /// Deletes a file, or a folder and everything in it. Symlinks are removed,
    /// not followed. Anything that disappears meanwhile (another client, the
    /// torrent client moving a finished download) counts as deleted. `removed`
    /// is called for each file deleted.
    public func removeRecursively(_ path: RemotePath, removed: (@Sendable (RemotePath) -> Void)? = nil) async throws {
        switch try await request({ .lstat(id: $0, path: path) }) {
        case .attributes(_, let a) where a.isDirectory:
            try await removeTree(path, removed: removed)
        case .attributes:
            try await removeFile(path)
            removed?(path)
        case .status(_, let code, _) where code == SFTPStatusCode.noSuchFile.rawValue:
            return
        case let other:
            throw Self.failure(other, "stat \(path)")
        }
    }

    private func removeTree(_ folder: RemotePath, removed: (@Sendable (RemotePath) -> Void)?) async throws {
        // Wait for the listing's handle to close: some servers handle requests
        // concurrently, and the folder should be closed before it's removed.
        let entries: [SFTPNameEntry]
        do {
            entries = try await list(folder, closeInBackground: false)
        } catch SFTPError.status(let code, _) where code == SFTPStatusCode.noSuchFile.rawValue {
            return
        }
        for entry in entries {
            let path = folder.appending(entry.filename)
            // readdir attributes describe the entry itself (a symlink isn't followed).
            if entry.attributes.isDirectory {
                try await removeTree(path, removed: removed)
            } else {
                try await removeFile(path)
                removed?(path)
            }
        }
        try await removeDirectory(folder)
    }

    private func expectOK(_ response: SFTPResponse, _ what: String, orGone: Bool = false) throws {
        if case .status(_, let code, _) = response {
            if code == SFTPStatusCode.ok.rawValue { return }
            if orGone, code == SFTPStatusCode.noSuchFile.rawValue { return }
        }
        throw Self.failure(response, what)
    }

    /// Directory entries, excluding `.` and `..`.
    public func list(_ path: RemotePath, closeInBackground: Bool = true) async throws -> [SFTPNameEntry] {
        let handle = try await openHandle({ .opendir(id: $0, path: path) }, path)
        var entries: [SFTPNameEntry] = []
        do {
            reading: while true {
                switch try await request({ .readdir(id: $0, handle: handle) }) {
                case .name(_, let batch):
                    entries += batch.filter { $0.filename.bytes != [0x2E] && $0.filename.bytes != [0x2E, 0x2E] }
                case .status(_, let code, _) where code == SFTPStatusCode.eof.rawValue:
                    break reading
                case let other:
                    throw Self.failure(other, "list \(path)")
                }
            }
        } catch {
            closeHandleInBackground(handle)
            throw error
        }
        if closeInBackground { closeHandleInBackground(handle) } else { try await closeHandle(handle) }
        return entries
    }

    /// Downloads `range` of `path` into `file` at the same offsets.
    public func download(
        _ path: RemotePath,
        range: Range<UInt64>,
        into file: PartFile,
        strategy: ReadStrategy? = nil,
        progress: @escaping @Sendable (Int) -> Void
    ) async throws -> ReadStats {
        let handle = try await openHandle({ .open(id: $0, path: path, flags: .read, attributes: SFTPAttributes()) }, path)
        let s = strategy ?? self.strategy
        let handler = self.handler
        defer { closeHandleInBackground(handle) }
        return try await channel.eventLoop.flatSubmit {
            handler.value.download(handle: handle, planner: ReadPlanner(range: range, readSize: s.readSize, maxInFlight: s.maxInFlight),
                                   file: file, progress: progress)
        }.get()
    }

    /// Sends CLOSE without waiting a round trip for the reply.
    private func closeHandleInBackground(_ handle: ByteBuffer) {
        let handler = self.handler
        channel.eventLoop.execute { _ = handler.value.send { .close(id: $0, handle: handle) } }
    }

    public func close() async {
        try? await channel.close()
    }

    // MARK: Helpers

    private func openHandle(_ make: @escaping @Sendable (UInt32) -> SFTPRequest, _ path: RemotePath) async throws -> ByteBuffer {
        switch try await request(make) {
        case .handle(_, let handle): return handle
        case let other: throw Self.failure(other, "open \(path)")
        }
    }

    private func closeHandle(_ handle: ByteBuffer) async throws {
        _ = try await request { .close(id: $0, handle: handle) }
    }

    static func failure(_ response: SFTPResponse, _ what: String) -> Error {
        if case .status(_, let code, let message) = response {
            return SFTPError.status(code: code, message: "\(what): \(message.isEmpty ? "status \(code)" : message)")
        }
        return SFTPError.unexpected("\(what): unexpected \(response)")
    }
}

// MARK: - Channel handler

final class SFTPChannelHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    final class DownloadJob {
        var planner: ReadPlanner
        let handle: ByteBuffer
        let file: PartFile
        let progress: @Sendable (Int) -> Void
        let promise: EventLoopPromise<ReadStats>
        var pendingWrites = 0
        var finished = false

        init(planner: ReadPlanner, handle: ByteBuffer, file: PartFile,
             progress: @escaping @Sendable (Int) -> Void, promise: EventLoopPromise<ReadStats>) {
            self.planner = planner
            self.handle = handle
            self.file = file
            self.progress = progress
            self.promise = promise
        }
    }

    /// Stop issuing reads while this many writes are waiting for the disk.
    static let maxPendingWrites = 32
    /// With requests outstanding and nothing received for this long, the link is
    /// treated as dead so the transfer fails (and can retry) instead of hanging.
    static let stallTimeout: TimeAmount = .seconds(60)

    private let version: EventLoopPromise<[SFTPExtension]>
    private var context: ChannelHandlerContext?
    private var framer = SFTPFramer()
    private var nextID: UInt32 = 1
    private var pending: [UInt32: EventLoopPromise<SFTPResponse>] = [:]
    private var jobsByRead: [UInt32: DownloadJob] = [:]
    private var closedError: Error?
    private var versionReceived = false
    private var lastActivity = NIODeadline.now()
    private var watchdog: RepeatedTask?

    init(version: EventLoopPromise<[SFTPExtension]>) { self.version = version }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
        let bound = NIOLoopBound(self, eventLoop: context.eventLoop)
        watchdog = context.eventLoop.scheduleRepeatedTask(initialDelay: .seconds(10), delay: .seconds(10)) { _ in
            bound.value.checkForStall()
        }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        watchdog?.cancel()
        watchdog = nil
        self.context = nil
    }

    private func checkForStall() {
        let waiting = !pending.isEmpty || !jobsByRead.isEmpty
        guard waiting, closedError == nil, NIODeadline.now() - lastActivity > Self.stallTimeout else { return }
        shutDown(SSHError.disconnected("no data from the server for \(Self.stallTimeout.nanoseconds / 1_000_000_000) s"))
    }

    private func takeID() -> UInt32 {
        defer { nextID &+= 1 }
        return nextID
    }

    private func write(_ request: SFTPRequest, flush: Bool) {
        guard let context else { return }
        var buffer = context.channel.allocator.buffer(capacity: 64)
        request.encode(into: &buffer)
        context.write(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer))), promise: nil)
        if flush { context.flush() }
    }

    // MARK: Requests

    func send(_ make: (UInt32) -> SFTPRequest) -> EventLoopFuture<SFTPResponse> {
        guard let context else {
            return version.futureResult.eventLoop.makeFailedFuture(SSHError.disconnected("sftp channel closed"))
        }
        if let closedError { return context.eventLoop.makeFailedFuture(closedError) }
        let id = takeID()
        let promise = context.eventLoop.makePromise(of: SFTPResponse.self)
        if pending.isEmpty, jobsByRead.isEmpty { lastActivity = .now() }   // idle until now: start the clock fresh
        pending[id] = promise
        write(make(id), flush: true)
        return promise.futureResult
    }

    func download(handle: ByteBuffer, planner: ReadPlanner, file: PartFile,
                  progress: @escaping @Sendable (Int) -> Void) -> EventLoopFuture<ReadStats> {
        let loop = version.futureResult.eventLoop
        if let closedError { return loop.makeFailedFuture(closedError) }
        let job = DownloadJob(planner: planner, handle: handle, file: file, progress: progress, promise: loop.makePromise())
        if pending.isEmpty, jobsByRead.isEmpty { lastActivity = .now() }
        pump(job)
        return job.promise.futureResult
    }

    private func pump(_ job: DownloadJob) {
        guard !job.finished else { return }
        if job.pendingWrites < Self.maxPendingWrites {
            let requests = job.planner.nextRequests(allocateID: takeID)
            for r in requests {
                jobsByRead[r.id] = job
                write(.read(id: r.id, handle: job.handle, offset: r.offset, length: r.length), flush: false)
            }
            if !requests.isEmpty { context?.flush() }
        }
        if job.planner.isComplete, job.pendingWrites == 0 {
            job.finished = true
            job.promise.succeed(ReadStats(bytes: job.planner.bytesReceived, shortReads: job.planner.shortReads,
                                          endedEarly: job.planner.endedEarly))
        }
    }

    private func fail(_ job: DownloadJob, _ error: Error) {
        guard !job.finished else { return }
        job.finished = true
        job.promise.fail(error)
    }

    // MARK: Inbound

    func channelActive(context: ChannelHandlerContext) {
        context.triggerUserOutboundEvent(SSHChannelRequestEvent.SubsystemRequest(subsystem: "sftp", wantReply: true), promise: nil)
        context.fireChannelActive()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is ChannelSuccessEvent, !versionReceived {
            write(.initialize(version: 3), flush: true)
        } else if event is ChannelFailureEvent {
            shutDown(SSHError.channelRequestRefused("the sftp subsystem"))
        } else {
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard message.type == .channel, case .byteBuffer(let bytes) = message.data else { return }
        lastActivity = .now()
        framer.append(bytes)
        do {
            while let (type, body) = try framer.next() {
                handle(try SFTPResponse(type: type, body: body))
            }
        } catch {
            shutDown(error)
        }
    }

    private func handle(_ response: SFTPResponse) {
        if case .version(let v, let extensions) = response {
            guard !versionReceived else { return shutDown(SFTPError.unexpected("second VERSION")) }
            versionReceived = true
            if v == 3 {
                version.succeed(extensions)
            } else {
                shutDown(SFTPError.unexpected("server speaks SFTP version \(v), not 3"))
            }
            return
        }
        guard let id = response.id else { return }

        if let job = jobsByRead.removeValue(forKey: id) {
            guard !job.finished else { return }   // a failed job's stragglers
            do {
                switch response {
                case .data(_, let data):
                    let request = try job.planner.received(id: id, byteCount: data.readableBytes)
                    job.progress(data.readableBytes)
                    job.pendingWrites += 1
                    job.file.write(data, at: request.offset, on: version.futureResult.eventLoop)
                        .assumeIsolated()
                        .whenComplete { [self] result in
                            job.pendingWrites -= 1
                            if case .failure(let error) = result { fail(job, error) } else { pump(job) }
                        }
                case .status(_, let code, _) where code == SFTPStatusCode.eof.rawValue:
                    try job.planner.receivedEOF(id: id)
                case let other:
                    throw SFTPClient.failure(other, "read")
                }
                pump(job)
            } catch {
                fail(job, error)
            }
            return
        }

        if let promise = pending.removeValue(forKey: id) {
            promise.succeed(response)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        shutDown(SSHError.disconnected("sftp channel closed"))
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        shutDown(error)
        context.close(promise: nil)
    }

    /// Fails everything outstanding; later requests fail immediately.
    private func shutDown(_ error: Error) {
        if closedError == nil { closedError = error }
        if !versionReceived {
            versionReceived = true
            version.fail(error)
        }
        let promises = pending.values
        pending.removeAll()
        promises.forEach { $0.fail(error) }
        for job in jobsByRead.values { fail(job, error) }   // idempotent per job
        jobsByRead.removeAll()
        context?.close(promise: nil)
    }
}
