// A set of byte ranges, kept sorted and merged. Records which parts of a
// `.blitpart` file are already on disk (PRD R3.6).

public struct ByteRangeSet: Codable, Equatable, Sendable {
    public private(set) var ranges: [Range<UInt64>] = []

    public init(_ ranges: [Range<UInt64>] = []) {
        for r in ranges { insert(r) }
    }

    public var byteCount: UInt64 { ranges.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) } }

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
