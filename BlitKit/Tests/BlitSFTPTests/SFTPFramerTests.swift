import NIOCore
import Testing

@testable import BlitSFTP

@Suite struct SFTPFramerTests {
    func packet(type: UInt8, body: [UInt8]) -> [UInt8] {
        let length = UInt32(body.count + 1)
        return [UInt8(length >> 24), UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF), type] + body
    }

    @Test func reassemblesPacketSplitAcrossReads() throws {
        var framer = SFTPFramer()
        let bytes = packet(type: 103, body: Array(repeating: 7, count: 100))
        framer.append(ByteBuffer(bytes: bytes[..<3]))
        #expect(try framer.next() == nil)
        framer.append(ByteBuffer(bytes: bytes[3..<50]))
        #expect(try framer.next() == nil)
        framer.append(ByteBuffer(bytes: bytes[50...]))
        let p = try #require(try framer.next())
        #expect(p.type == 103)
        #expect(p.body.readableBytes == 100)
        #expect(try framer.next() == nil)
    }

    @Test func yieldsSeveralPacketsFromOneRead() throws {
        var framer = SFTPFramer()
        framer.append(ByteBuffer(bytes: packet(type: 101, body: [1]) + packet(type: 102, body: [2, 2]) + packet(type: 103, body: [])))
        #expect(try framer.next()?.type == 101)
        #expect(try framer.next()?.body.readableBytes == 2)
        #expect(try framer.next()?.type == 103)
        #expect(try framer.next() == nil)
    }

    @Test func rejectsOversizedAndZeroLengthPackets() {
        var big = SFTPFramer(maxPacketLength: 1024)
        big.append(ByteBuffer(bytes: [0, 0, 0x10, 0, 103]))
        #expect(throws: SFTPError.packetTooLarge(4096)) { try big.next() }

        var zero = SFTPFramer()
        zero.append(ByteBuffer(bytes: [0, 0, 0, 0]))
        #expect(throws: SFTPError.self) { try zero.next() }
    }
}
