// Bookkeeping for pipelined SFTP reads of one byte range. Pure logic, no I/O:
// the connection asks it which READs to send and reports what came back.

public struct ReadPlanner: Sendable {
    public struct Request: Equatable, Sendable {
        public let id: UInt32
        public let offset: UInt64
        public let length: UInt32
    }

    public let range: Range<UInt64>
    public var readSize: UInt32
    public var maxInFlight: Int

    public private(set) var inFlight: [UInt32: Request] = [:]
    public private(set) var bytesReceived: UInt64 = 0
    public private(set) var shortReads = 0
    /// The server reported EOF before `range.upperBound`: the file is shorter
    /// than expected (changed since listing, PRD R3.9).
    public private(set) var endedEarly = false

    private var nextOffset: UInt64
    /// Remainders of short reads, sent before any new offsets.
    private var remainders: [(offset: UInt64, length: UInt32)] = []

    public init(range: Range<UInt64>, readSize: UInt32, maxInFlight: Int) {
        precondition(readSize > 0 && maxInFlight > 0)
        self.range = range
        self.readSize = readSize
        self.maxInFlight = maxInFlight
        self.nextOffset = range.lowerBound
    }

    /// True once every byte in the range has arrived (or EOF ended it) and nothing is in flight.
    public var isComplete: Bool {
        inFlight.isEmpty && remainders.isEmpty && (nextOffset >= range.upperBound || endedEarly)
    }

    /// READs to send now, up to `maxInFlight`. With `stopIssuing`, only short-read
    /// remainders are re-requested so outstanding work can drain.
    public mutating func nextRequests(stopIssuing: Bool = false, allocateID: () -> UInt32) -> [Request] {
        var out: [Request] = []
        while inFlight.count < maxInFlight, !remainders.isEmpty {
            let r = remainders.removeFirst()
            out.append(issue(allocateID(), r.offset, r.length))
        }
        guard !stopIssuing, !endedEarly else { return out }
        while inFlight.count < maxInFlight, nextOffset < range.upperBound {
            let length = UInt32(min(UInt64(readSize), range.upperBound - nextOffset))
            out.append(issue(allocateID(), nextOffset, length))
            nextOffset += UInt64(length)
        }
        return out
    }

    /// Records a DATA reply. Returns the request it answers, so the caller knows
    /// where to write the bytes. A short reply queues the remainder (legal in
    /// SFTP; SFTPGo caps replies at 32 KB).
    public mutating func received(id: UInt32, byteCount: Int) throws -> Request {
        guard let request = inFlight.removeValue(forKey: id) else {
            throw SFTPError.unexpected("DATA for unknown request \(id)")
        }
        guard byteCount > 0, byteCount <= Int(request.length) else {
            throw SFTPError.malformedPacket("DATA of \(byteCount) bytes for a \(request.length)-byte read")
        }
        bytesReceived += UInt64(byteCount)
        if byteCount < Int(request.length) {
            shortReads += 1
            remainders.append((request.offset + UInt64(byteCount), request.length - UInt32(byteCount)))
        }
        return request
    }

    /// Records an EOF status for a READ.
    public mutating func receivedEOF(id: UInt32) throws {
        guard let request = inFlight.removeValue(forKey: id) else {
            throw SFTPError.unexpected("EOF for unknown request \(id)")
        }
        if request.offset < range.upperBound {
            endedEarly = true
            // Anything past EOF will also come back EOF; stop asking for it.
            remainders.removeAll { $0.offset >= request.offset }
        }
    }

    private mutating func issue(_ id: UInt32, _ offset: UInt64, _ length: UInt32) -> Request {
        let request = Request(id: id, offset: offset, length: length)
        inFlight[id] = request
        return request
    }
}
