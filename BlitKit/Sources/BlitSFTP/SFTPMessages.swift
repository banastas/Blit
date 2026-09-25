// SFTP v3 requests (client → server) and responses (server → client).

import NIOCore

public enum SFTPRequest: Sendable {
    case initialize(version: UInt32)
    case open(id: UInt32, path: RemotePath, flags: SFTPOpenFlags, attributes: SFTPAttributes)
    case close(id: UInt32, handle: ByteBuffer)
    case read(id: UInt32, handle: ByteBuffer, offset: UInt64, length: UInt32)
    case stat(id: UInt32, path: RemotePath)
    case lstat(id: UInt32, path: RemotePath)
    case fstat(id: UInt32, handle: ByteBuffer)
    case opendir(id: UInt32, path: RemotePath)
    case readdir(id: UInt32, handle: ByteBuffer)
    case realpath(id: UInt32, path: RemotePath)
    case mkdir(id: UInt32, path: RemotePath, attributes: SFTPAttributes)
    case rmdir(id: UInt32, path: RemotePath)
    case remove(id: UInt32, path: RemotePath)
    case rename(id: UInt32, from: RemotePath, to: RemotePath)
    case extended(id: UInt32, name: String, payload: ByteBuffer)

    public var type: SFTPPacketType {
        switch self {
        case .initialize: .initialize
        case .open: .open
        case .close: .close
        case .read: .read
        case .stat: .stat
        case .lstat: .lstat
        case .fstat: .fstat
        case .opendir: .opendir
        case .readdir: .readdir
        case .realpath: .realpath
        case .mkdir: .mkdir
        case .rmdir: .rmdir
        case .remove: .remove
        case .rename: .rename
        case .extended: .extended
        }
    }

    /// Appends the complete packet (uint32 length, type byte, body) to `buffer`.
    public func encode(into buffer: inout ByteBuffer) {
        let lengthIndex = buffer.writerIndex
        buffer.writeInteger(UInt32(0))
        buffer.writeInteger(type.rawValue)
        switch self {
        case .initialize(let version):
            buffer.writeInteger(version)
        case .open(let id, let path, let flags, let attributes):
            buffer.writeInteger(id)
            buffer.writeSFTPString(path.bytes)
            buffer.writeInteger(flags.rawValue)
            attributes.write(to: &buffer)
        case .close(let id, let handle), .fstat(let id, let handle), .readdir(let id, let handle):
            buffer.writeInteger(id)
            buffer.writeSFTPString(handle)
        case .read(let id, let handle, let offset, let length):
            buffer.writeInteger(id)
            buffer.writeSFTPString(handle)
            buffer.writeInteger(offset)
            buffer.writeInteger(length)
        case .stat(let id, let path), .lstat(let id, let path), .opendir(let id, let path), .realpath(let id, let path),
             .rmdir(let id, let path), .remove(let id, let path):
            buffer.writeInteger(id)
            buffer.writeSFTPString(path.bytes)
        case .mkdir(let id, let path, let attributes):
            buffer.writeInteger(id)
            buffer.writeSFTPString(path.bytes)
            attributes.write(to: &buffer)
        case .rename(let id, let from, let to):
            buffer.writeInteger(id)
            buffer.writeSFTPString(from.bytes)
            buffer.writeSFTPString(to.bytes)
        case .extended(let id, let name, let payload):
            buffer.writeInteger(id)
            buffer.writeSFTPString(name)
            buffer.writeImmutableBuffer(payload)
        }
        buffer.setInteger(UInt32(buffer.writerIndex - lengthIndex - 4), at: lengthIndex)
    }
}

public struct SFTPExtension: Equatable, Sendable {
    public var name: String
    public var data: String
}

public struct SFTPNameEntry: Equatable, Sendable {
    /// The entry's name exactly as the server sent it.
    public var filename: RemotePath
    /// `ls -l`-style line; informational only.
    public var longname: String
    public var attributes: SFTPAttributes
}

/// `limits@openssh.com` reply (OpenSSH 8.5+). Zero means "no limit stated".
public struct SFTPLimits: Equatable, Sendable {
    public var maxPacketLength: UInt64
    public var maxReadLength: UInt64
    public var maxWriteLength: UInt64
    public var maxOpenHandles: UInt64

    public init(payload: ByteBuffer) throws {
        var p = payload
        maxPacketLength = try p.readSFTPInteger("max-packet-length")
        maxReadLength = try p.readSFTPInteger("max-read-length")
        maxWriteLength = try p.readSFTPInteger("max-write-length")
        maxOpenHandles = try p.readSFTPInteger("max-open-handles")
    }
}

public enum SFTPResponse: Equatable, Sendable {
    case version(UInt32, extensions: [SFTPExtension])
    case status(id: UInt32, code: UInt32, message: String)
    case handle(id: UInt32, handle: ByteBuffer)
    case data(id: UInt32, data: ByteBuffer)
    case name(id: UInt32, entries: [SFTPNameEntry])
    case attributes(id: UInt32, SFTPAttributes)
    case extendedReply(id: UInt32, payload: ByteBuffer)

    /// Decodes a response body (after the length and type byte).
    public init(type rawType: UInt8, body: ByteBuffer) throws {
        guard let type = SFTPPacketType(rawValue: rawType) else {
            throw SFTPError.malformedPacket("unknown packet type \(rawType)")
        }
        var b = body
        switch type {
        case .version:
            let version = try b.readSFTPInteger("version", as: UInt32.self)
            var extensions: [SFTPExtension] = []
            while b.readableBytes > 0 {
                let name = try b.readSFTPText("extension name")
                let data = try b.readSFTPText("extension data")
                extensions.append(SFTPExtension(name: name, data: data))
            }
            self = .version(version, extensions: extensions)
        case .status:
            let id = try b.readSFTPInteger("id", as: UInt32.self)
            let code = try b.readSFTPInteger("status code", as: UInt32.self)
            // Message and language tag are optional in some old servers.
            let message = b.readableBytes > 0 ? try b.readSFTPText("status message") : ""
            self = .status(id: id, code: code, message: message)
        case .handle:
            self = .handle(id: try b.readSFTPInteger("id"), handle: try b.readSFTPBuffer("handle"))
        case .data:
            self = .data(id: try b.readSFTPInteger("id"), data: try b.readSFTPBuffer("data"))
        case .name:
            let id = try b.readSFTPInteger("id", as: UInt32.self)
            let count = try b.readSFTPInteger("name count", as: UInt32.self)
            var entries: [SFTPNameEntry] = []
            entries.reserveCapacity(Int(min(count, 4096)))
            for _ in 0..<count {
                let filename = RemotePath(bytes: try b.readSFTPBytes("filename"))
                let longname = try b.readSFTPText("longname")
                let attributes = try SFTPAttributes.read(from: &b)
                entries.append(SFTPNameEntry(filename: filename, longname: longname, attributes: attributes))
            }
            self = .name(id: id, entries: entries)
        case .attributes:
            let id = try b.readSFTPInteger("id", as: UInt32.self)
            self = .attributes(id: id, try SFTPAttributes.read(from: &b))
        case .extendedReply:
            let id = try b.readSFTPInteger("id", as: UInt32.self)
            self = .extendedReply(id: id, payload: b)
        default:
            throw SFTPError.malformedPacket("\(type) is not a server response")
        }
    }

    public var id: UInt32? {
        switch self {
        case .version: nil
        case .status(let id, _, _), .handle(let id, _), .data(let id, _), .name(let id, _),
             .attributes(let id, _), .extendedReply(let id, _): id
        }
    }
}
