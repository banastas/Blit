import NIOCore
import Testing

@testable import BlitSFTP

@Suite struct SFTPMessagesTests {
    let allocator = ByteBufferAllocator()

    func encoded(_ request: SFTPRequest) -> [UInt8] {
        var b = allocator.buffer(capacity: 64)
        request.encode(into: &b)
        return b.readBytes(length: b.readableBytes)!
    }

    @Test func readRequestWireFormat() {
        let handle = allocator.buffer(bytes: [0xAA, 0xBB])
        let bytes = encoded(.read(id: 7, handle: handle, offset: 0x1_0000_0000, length: 32768))
        #expect(bytes == [
            0, 0, 0, 23,                  // length: 1 type + 4 id + 6 handle + 8 offset + 4 length
            5,                            // SSH_FXP_READ
            0, 0, 0, 7,                   // id
            0, 0, 0, 2, 0xAA, 0xBB,       // handle
            0, 0, 0, 1, 0, 0, 0, 0,       // offset
            0, 0, 0x80, 0,                // length
        ])
    }

    @Test func initAndOpenWireFormat() {
        #expect(encoded(.initialize(version: 3)) == [0, 0, 0, 5, 1, 0, 0, 0, 3])
        let open = encoded(.open(id: 1, path: RemotePath("a"), flags: .read, attributes: SFTPAttributes()))
        #expect(open == [0, 0, 0, 18, 3, 0, 0, 0, 1, 0, 0, 0, 1, 0x61, 0, 0, 0, 1, 0, 0, 0, 0])
    }

    @Test func decodesVersionWithExtensions() throws {
        var body = allocator.buffer(capacity: 64)
        body.writeInteger(UInt32(3))
        body.writeSFTPString("limits@openssh.com")
        body.writeSFTPString("1")
        body.writeSFTPString("statvfs@openssh.com")
        body.writeSFTPString("2")
        let r = try SFTPResponse(type: 2, body: body)
        #expect(r == .version(3, extensions: [
            SFTPExtension(name: "limits@openssh.com", data: "1"),
            SFTPExtension(name: "statvfs@openssh.com", data: "2"),
        ]))
        #expect(r.id == nil)
    }

    @Test func decodesStatusWithAndWithoutMessage() throws {
        var full = allocator.buffer(capacity: 32)
        full.writeInteger(UInt32(9))
        full.writeInteger(SFTPStatusCode.eof.rawValue)
        full.writeSFTPString("End of file")
        full.writeSFTPString("")
        #expect(try SFTPResponse(type: 101, body: full) == .status(id: 9, code: 1, message: "End of file"))

        var bare = allocator.buffer(capacity: 8)
        bare.writeInteger(UInt32(9))
        bare.writeInteger(UInt32(0))
        #expect(try SFTPResponse(type: 101, body: bare) == .status(id: 9, code: 0, message: ""))
    }

    @Test func nameEntriesKeepInvalidUTF8Bytes() throws {
        let rawName: [UInt8] = [0x66, 0xFF, 0x6F]   // "f", invalid byte, "o"
        var body = allocator.buffer(capacity: 64)
        body.writeInteger(UInt32(4))
        body.writeInteger(UInt32(1))
        body.writeSFTPString(rawName)
        body.writeSFTPString("-rw-r--r-- 1 u g 10 Sep 24 f?o")
        SFTPAttributes(size: 10, permissions: 0o100644, modificationTime: 1_758_700_000).write(to: &body)
        guard case .name(4, let entries) = try SFTPResponse(type: 104, body: body) else {
            Issue.record("expected NAME")
            return
        }
        #expect(entries.count == 1)
        #expect(entries[0].filename.bytes == rawName)
        #expect(entries[0].filename.string == nil)
        #expect(entries[0].filename.description == "f\u{FFFD}o")
        #expect(entries[0].attributes.isRegularFile)
        #expect(entries[0].attributes.size == 10)
    }

    @Test func attributesRoundTrip() throws {
        var a = SFTPAttributes(size: 923_000_000, permissions: 0o040755, modificationTime: 1_758_700_000)
        a.uid = 1000
        a.gid = 1000
        a.extended = [.init(type: "x@example.com", data: [1, 2, 3])]
        var b = allocator.buffer(capacity: 64)
        a.write(to: &b)
        #expect(try SFTPAttributes.read(from: &b) == a)
        #expect(b.readableBytes == 0)
        #expect(a.isDirectory)
    }

    @Test func decodesLimits() throws {
        var p = allocator.buffer(capacity: 32)
        for v: UInt64 in [262_144, 261_120, 261_120, 0] { p.writeInteger(v) }
        let limits = try SFTPLimits(payload: p)
        #expect(limits.maxReadLength == 261_120)
        #expect(limits.maxOpenHandles == 0)
    }

    @Test func rejectsTruncatedAndUnknownPackets() {
        var truncated = allocator.buffer(capacity: 8)
        truncated.writeInteger(UInt32(1))
        truncated.writeInteger(UInt32(100))    // claims a 100-byte handle, provides none
        #expect(throws: SFTPError.self) { try SFTPResponse(type: 102, body: truncated) }
        #expect(throws: SFTPError.self) { try SFTPResponse(type: 99, body: ByteBuffer()) }
        #expect(throws: SFTPError.self) { try SFTPResponse(type: 5, body: ByteBuffer()) }   // a request type
    }

    @Test func remotePathJoins() {
        #expect(RemotePath("files/downloads").appending(RemotePath("a.mkv")) == RemotePath("files/downloads/a.mkv"))
        #expect(RemotePath("/").appending(RemotePath("x")) == RemotePath("/x"))
        #expect(RemotePath("").appending(RemotePath("x")) == RemotePath("x"))
    }
}
