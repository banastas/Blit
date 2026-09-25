// SFTP v3 file attributes (ATTRS).

import NIOCore

public struct SFTPAttributes: Equatable, Sendable {
    public var size: UInt64?
    public var uid: UInt32?
    public var gid: UInt32?
    public var permissions: UInt32?
    /// Whole seconds since the epoch; SFTP v3 has no sub-second precision (PRD R3.11).
    public var accessTime: UInt32?
    public var modificationTime: UInt32?
    public var extended: [Extension] = []

    public struct Extension: Equatable, Sendable {
        public var type: String
        public var data: [UInt8]
    }

    public init(size: UInt64? = nil, permissions: UInt32? = nil, modificationTime: UInt32? = nil) {
        self.size = size
        self.permissions = permissions
        self.modificationTime = modificationTime
        if modificationTime != nil { accessTime = modificationTime }
    }

    static let flagSize: UInt32 = 0x0000_0001
    static let flagUIDGID: UInt32 = 0x0000_0002
    static let flagPermissions: UInt32 = 0x0000_0004
    static let flagACModTime: UInt32 = 0x0000_0008
    static let flagExtended: UInt32 = 0x8000_0000

    private static let typeMask: UInt32 = 0o170000

    public var isDirectory: Bool { permissions.map { $0 & Self.typeMask == 0o040000 } ?? false }
    public var isRegularFile: Bool { permissions.map { $0 & Self.typeMask == 0o100000 } ?? false }
    public var isSymlink: Bool { permissions.map { $0 & Self.typeMask == 0o120000 } ?? false }

    public static func read(from buffer: inout ByteBuffer) throws -> SFTPAttributes {
        var a = SFTPAttributes()
        let flags = try buffer.readSFTPInteger("attr flags", as: UInt32.self)
        if flags & flagSize != 0 { a.size = try buffer.readSFTPInteger("size") }
        if flags & flagUIDGID != 0 {
            a.uid = try buffer.readSFTPInteger("uid")
            a.gid = try buffer.readSFTPInteger("gid")
        }
        if flags & flagPermissions != 0 { a.permissions = try buffer.readSFTPInteger("permissions") }
        if flags & flagACModTime != 0 {
            a.accessTime = try buffer.readSFTPInteger("atime")
            a.modificationTime = try buffer.readSFTPInteger("mtime")
        }
        if flags & flagExtended != 0 {
            let count = try buffer.readSFTPInteger("extended count", as: UInt32.self)
            for _ in 0..<count {
                let type = try buffer.readSFTPText("extended type")
                let data = try buffer.readSFTPBytes("extended data")
                a.extended.append(Extension(type: type, data: data))
            }
        }
        return a
    }

    public func write(to buffer: inout ByteBuffer) {
        var flags: UInt32 = 0
        if size != nil { flags |= Self.flagSize }
        if uid != nil, gid != nil { flags |= Self.flagUIDGID }
        if permissions != nil { flags |= Self.flagPermissions }
        if accessTime != nil, modificationTime != nil { flags |= Self.flagACModTime }
        if !extended.isEmpty { flags |= Self.flagExtended }
        buffer.writeInteger(flags)
        if let size { buffer.writeInteger(size) }
        if let uid, let gid {
            buffer.writeInteger(uid)
            buffer.writeInteger(gid)
        }
        if let permissions { buffer.writeInteger(permissions) }
        if let accessTime, let modificationTime {
            buffer.writeInteger(accessTime)
            buffer.writeInteger(modificationTime)
        }
        if !extended.isEmpty {
            buffer.writeInteger(UInt32(extended.count))
            for e in extended {
                buffer.writeSFTPString(e.type)
                buffer.writeSFTPString(e.data)
            }
        }
    }
}
