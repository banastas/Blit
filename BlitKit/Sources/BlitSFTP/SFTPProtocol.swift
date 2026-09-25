// SFTP version 3 (draft-ietf-secsh-filexfer-02): constants, paths, and errors.

import NIOCore

public enum SFTPPacketType: UInt8, Sendable {
    case initialize = 1
    case version = 2
    case open = 3
    case close = 4
    case read = 5
    case write = 6
    case lstat = 7
    case fstat = 8
    case setstat = 9
    case fsetstat = 10
    case opendir = 11
    case readdir = 12
    case remove = 13
    case mkdir = 14
    case rmdir = 15
    case realpath = 16
    case stat = 17
    case rename = 18
    case readlink = 19
    case symlink = 20
    case status = 101
    case handle = 102
    case data = 103
    case name = 104
    case attributes = 105
    case extended = 200
    case extendedReply = 201
}

public enum SFTPStatusCode: UInt32, Sendable {
    case ok = 0
    case eof = 1
    case noSuchFile = 2
    case permissionDenied = 3
    case failure = 4
    case badMessage = 5
    case noConnection = 6
    case connectionLost = 7
    case operationUnsupported = 8
}

public struct SFTPOpenFlags: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let read = SFTPOpenFlags(rawValue: 0x01)
    public static let write = SFTPOpenFlags(rawValue: 0x02)
    public static let append = SFTPOpenFlags(rawValue: 0x04)
    public static let create = SFTPOpenFlags(rawValue: 0x08)
    public static let truncate = SFTPOpenFlags(rawValue: 0x10)
    public static let exclusive = SFTPOpenFlags(rawValue: 0x20)
}

public enum SFTPError: Error, Equatable, Sendable {
    case malformedPacket(String)
    case packetTooLarge(Int)
    case status(code: UInt32, message: String)
    case unexpected(String)
}

/// A remote path as raw bytes. Linux filenames can be any bytes except `/` and
/// NUL, so they aren't always valid UTF-8 (PRD R3.10). Keeping the bytes lets
/// Blit open such files again exactly as the server named them.
public struct RemotePath: Hashable, Sendable, CustomStringConvertible {
    public var bytes: [UInt8]

    public init(bytes: [UInt8]) { self.bytes = bytes }
    public init(_ string: String) { self.bytes = Array(string.utf8) }

    /// The path as a String, or nil if it isn't valid UTF-8.
    public var string: String? { String(validating: bytes, as: UTF8.self) }

    /// A String for display; invalid UTF-8 sequences become U+FFFD.
    public var description: String { String(decoding: bytes, as: UTF8.self) }

    public func appending(_ component: RemotePath) -> RemotePath {
        if bytes.isEmpty { return component }
        return RemotePath(bytes: bytes.last == UInt8(ascii: "/") ? bytes + component.bytes : bytes + [UInt8(ascii: "/")] + component.bytes)
    }
}

// MARK: - Wire helpers

extension ByteBuffer {
    mutating func writeSFTPString(_ bytes: [UInt8]) {
        writeInteger(UInt32(bytes.count))
        writeBytes(bytes)
    }

    mutating func writeSFTPString(_ string: String) {
        writeSFTPString(Array(string.utf8))
    }

    mutating func writeSFTPString(_ buffer: ByteBuffer) {
        writeInteger(UInt32(buffer.readableBytes))
        writeImmutableBuffer(buffer)
    }

    mutating func readSFTPInteger<T: FixedWidthInteger>(_ field: String, as: T.Type = T.self) throws -> T {
        guard let value = readInteger(as: T.self) else { throw SFTPError.malformedPacket("truncated \(field)") }
        return value
    }

    mutating func readSFTPBuffer(_ field: String) throws -> ByteBuffer {
        let length = try readSFTPInteger(field, as: UInt32.self)
        guard let slice = readSlice(length: Int(length)) else { throw SFTPError.malformedPacket("truncated \(field)") }
        return slice
    }

    mutating func readSFTPBytes(_ field: String) throws -> [UInt8] {
        var slice = try readSFTPBuffer(field)
        return slice.readBytes(length: slice.readableBytes) ?? []
    }

    /// Lossy for invalid UTF-8; use `readSFTPBytes` where the exact bytes matter.
    mutating func readSFTPText(_ field: String) throws -> String {
        String(decoding: try readSFTPBytes(field), as: UTF8.self)
    }
}
