// Bytes at an offset, from a file or from memory, for the header readers. A
// file is read in 64 KB chunks, each once, up to a limit: a header takes one
// or two reads, which matters on a NAS share.

import Foundation

public protocol ByteSource {
    var size: UInt64 { get }
    /// Up to `count` bytes at `offset` (fewer at the end).
    func read(at offset: UInt64, count: Int) throws -> Data
}

public struct DataSource: ByteSource {
    private let data: Data

    public init(_ data: Data) { self.data = data }

    public var size: UInt64 { UInt64(data.count) }

    public func read(at offset: UInt64, count: Int) throws -> Data {
        guard offset < size, count > 0 else { return Data() }
        let start = data.startIndex + Int(offset)
        return data[start..<min(data.endIndex, start + count)]
    }
}

public enum ProbeError: Error {
    /// The header goes on past the bytes a probe may read.
    case tooLarge
}

public final class FileSource: ByteSource {
    static let chunkSize = 65_536
    private let handle: FileHandle
    public let size: UInt64
    private var chunks: [UInt64: Data] = [:]
    private var budget: Int

    /// `limit`: the most bytes read in all.
    public init(url: URL, limit: Int = 4 << 20) throws {
        handle = try FileHandle(forReadingFrom: url)
        size = try handle.seekToEnd()
        budget = limit
    }

    deinit { try? handle.close() }

    public func read(at offset: UInt64, count: Int) throws -> Data {
        var out = Data()
        var position = offset
        let end = min(size, offset + UInt64(max(count, 0)))
        while position < end {
            let index = position / UInt64(Self.chunkSize)
            let chunk = try self.chunk(index)
            let start = Int(position - index * UInt64(Self.chunkSize))
            guard start < chunk.count else { break }
            let take = min(chunk.count - start, Int(end - position))
            out.append(chunk[(chunk.startIndex + start)..<(chunk.startIndex + start + take)])
            position += UInt64(take)
        }
        return out
    }

    private func chunk(_ index: UInt64) throws -> Data {
        if let chunk = chunks[index] { return chunk }
        guard budget > 0 else { throw ProbeError.tooLarge }
        budget -= Self.chunkSize
        try handle.seek(toOffset: index * UInt64(Self.chunkSize))
        let chunk = try handle.read(upToCount: Self.chunkSize) ?? Data()
        chunks[index] = chunk
        return chunk
    }
}
