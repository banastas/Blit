import Testing

@testable import BlitSFTP

@Suite struct ReadPlannerTests {
    final class IDs {
        var next: UInt32 = 1
        func take() -> UInt32 {
            defer { next += 1 }
            return next
        }
    }

    @Test func exactReadsCoverTheRangeInOrder() throws {
        let ids = IDs()
        var p = ReadPlanner(range: 100..<400, readSize: 128, maxInFlight: 8)
        let reqs = p.nextRequests(allocateID: ids.take)
        #expect(reqs.map(\.offset) == [100, 228, 356])
        #expect(reqs.map(\.length) == [128, 128, 44])
        for r in reqs { _ = try p.received(id: r.id, byteCount: Int(r.length)) }
        #expect(p.nextRequests(allocateID: ids.take).isEmpty)
        #expect(p.isComplete)
        #expect(p.bytesReceived == 300)
        #expect(p.shortReads == 0)
    }

    @Test func respectsMaxInFlight() throws {
        let ids = IDs()
        var p = ReadPlanner(range: 0..<1000, readSize: 10, maxInFlight: 4)
        let first = p.nextRequests(allocateID: ids.take)
        #expect(first.count == 4)
        #expect(p.nextRequests(allocateID: ids.take).isEmpty)
        _ = try p.received(id: first[0].id, byteCount: 10)
        let refill = p.nextRequests(allocateID: ids.take)
        #expect(refill.count == 1)
        #expect(refill[0].offset == 40)
    }

    @Test func shortReadRequeuesTheRemainderFirst() throws {
        // SFTPGo answers 64 KB requests with 32 KB.
        let ids = IDs()
        var p = ReadPlanner(range: 0..<131_072, readSize: 65_536, maxInFlight: 2)
        let reqs = p.nextRequests(allocateID: ids.take)
        #expect(reqs.count == 2)
        let answered = try p.received(id: reqs[0].id, byteCount: 32_768)
        #expect(answered.offset == 0)
        let next = p.nextRequests(allocateID: ids.take)
        #expect(next == [ReadPlanner.Request(id: 3, offset: 32_768, length: 32_768)])
        #expect(p.shortReads == 1)
        #expect(!p.isComplete)
        _ = try p.received(id: 3, byteCount: 32_768)
        _ = try p.received(id: reqs[1].id, byteCount: 65_536)
        #expect(p.isComplete)
        #expect(p.bytesReceived == 131_072)
    }

    @Test func earlyEOFMarksTheFileShorterThanExpected() throws {
        let ids = IDs()
        var p = ReadPlanner(range: 0..<300, readSize: 100, maxInFlight: 3)
        let reqs = p.nextRequests(allocateID: ids.take)
        _ = try p.received(id: reqs[0].id, byteCount: 100)
        _ = try p.received(id: reqs[1].id, byteCount: 50)     // short: remainder 150..<200 queued
        try p.receivedEOF(id: reqs[2].id)                      // EOF at 200
        #expect(p.endedEarly)
        // The remainder at 150 is before EOF, so it's still requested.
        let more = p.nextRequests(allocateID: ids.take)
        #expect(more.map(\.offset) == [150])
        try p.receivedEOF(id: more[0].id)
        #expect(p.isComplete)
        #expect(p.nextRequests(allocateID: ids.take).isEmpty)
    }

    @Test func stopIssuingDrainsWithoutNewOffsets() throws {
        let ids = IDs()
        var p = ReadPlanner(range: 0..<1000, readSize: 100, maxInFlight: 2)
        let reqs = p.nextRequests(allocateID: ids.take)
        _ = try p.received(id: reqs[0].id, byteCount: 60)
        let drain = p.nextRequests(stopIssuing: true, allocateID: ids.take)
        #expect(drain.map(\.offset) == [60])                   // remainder only
        _ = try p.received(id: drain[0].id, byteCount: 40)
        _ = try p.received(id: reqs[1].id, byteCount: 100)
        #expect(p.nextRequests(stopIssuing: true, allocateID: ids.take).isEmpty)
        #expect(p.inFlight.isEmpty)
        #expect(!p.isComplete)                                 // stopped, not finished
    }

    @Test func rejectsUnknownIDsAndOversizedData() throws {
        let ids = IDs()
        var p = ReadPlanner(range: 0..<100, readSize: 100, maxInFlight: 1)
        let r = p.nextRequests(allocateID: ids.take)[0]
        #expect(throws: SFTPError.self) { try p.received(id: 999, byteCount: 10) }
        #expect(throws: SFTPError.self) { try p.receivedEOF(id: 999) }
        #expect(throws: SFTPError.self) { try p.received(id: r.id, byteCount: 101) }
    }

    @Test func zeroLengthDataIsAProtocolError() throws {
        let ids = IDs()
        var p = ReadPlanner(range: 0..<100, readSize: 100, maxInFlight: 1)
        let r = p.nextRequests(allocateID: ids.take)[0]
        #expect(throws: SFTPError.self) { try p.received(id: r.id, byteCount: 0) }
    }

    @Test func emptyRangeIsImmediatelyComplete() {
        let ids = IDs()
        var p = ReadPlanner(range: 50..<50, readSize: 100, maxInFlight: 4)
        #expect(p.nextRequests(allocateID: ids.take).isEmpty)
        #expect(p.isComplete)
    }
}
