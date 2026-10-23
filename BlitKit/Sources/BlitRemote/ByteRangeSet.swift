// A set of byte ranges, kept sorted and merged. Records which parts of a
// `.blitpart` file are already on disk (PRD R3.6).

import BlitSFTP

public struct ByteRangeSet: Codable, Equatable, Sendable {
    public private(set) var ranges: [Range<UInt64>] = []

    public init(_ ranges: [Range<UInt64>] = []) {
        for r in ranges { insert(r) }
    }

    /// Decoded ranges go through `insert` too: a `.blitpart.state` file can be
    /// written by anyone who can write the folder, and unmerged, overlapping
    /// ranges would overflow `byteCount` (and confuse `gaps`).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(try container.decode([Range<UInt64>].self, forKey: .ranges))
    }

    private enum CodingKeys: String, CodingKey { case ranges }

    /// Merged ranges never overlap, so their total fits; saturating anyway.
    public var byteCount: UInt64 { ranges.saturatingSum { $0.upperBound - $0.lowerBound } }

    public mutating func insert(_ range: Range<UInt64>) {
        guard !range.isEmpty else { return }
        var merged = range
        var kept: [Range<UInt64>] = []
        kept.reserveCapacity(ranges.count + 1)
        for r in ranges {
            if r.upperBound < merged.lowerBound || r.lowerBound > merged.upperBound {
                kept.append(r)
            } else {
                // Overlapping or touching: absorb.
                merged = min(r.lowerBound, merged.lowerBound)..<max(r.upperBound, merged.upperBound)
            }
        }
        kept.append(merged)
        ranges = kept.sorted { $0.lowerBound < $1.lowerBound }
    }

    /// The parts of `total` not covered by the set.
    public func gaps(in total: Range<UInt64>) -> [Range<UInt64>] {
        var result: [Range<UInt64>] = []
        var cursor = total.lowerBound
        for r in ranges where r.upperBound > total.lowerBound && r.lowerBound < total.upperBound {
            if r.lowerBound > cursor { result.append(cursor..<r.lowerBound) }
            cursor = max(cursor, r.upperBound)
        }
        if cursor < total.upperBound { result.append(cursor..<total.upperBound) }
        return result
    }
}
