// Splits a byte stream into SFTP packets.

import NIOCore

public struct SFTPFramer: Sendable {
    /// Upper bound on a packet's length field. OpenSSH advertises 256 KiB via
    /// limits@openssh.com; anything far beyond that is a broken or hostile peer.
    public let maxPacketLength: Int
    private var buffer: ByteBuffer?

    public init(maxPacketLength: Int = 1 << 20) {
        self.maxPacketLength = maxPacketLength
    }

    public mutating func append(_ bytes: ByteBuffer) {
        if buffer == nil {
            buffer = bytes
        } else {
            var incoming = bytes
            buffer!.writeBuffer(&incoming)
        }
    }

    /// The next complete packet, or nil if more bytes are needed.
    public mutating func next() throws -> (type: UInt8, body: ByteBuffer)? {
        guard var b = buffer, let length = b.getInteger(at: b.readerIndex, as: UInt32.self) else { return nil }
        guard length >= 1 else { throw SFTPError.malformedPacket("zero-length packet") }
        guard Int(length) <= maxPacketLength else { throw SFTPError.packetTooLarge(Int(length)) }
        guard b.readableBytes >= 4 + Int(length) else { return nil }
        b.moveReaderIndex(forwardBy: 4)
        let type: UInt8 = b.readInteger()!
        let body = b.readSlice(length: Int(length) - 1)!
        if b.readableBytes == 0 {
            buffer = nil
        } else {
            if b.readerIndex > 1 << 20 { b.discardReadBytes() }
            buffer = b
        }
        return (type, body)
    }
}
