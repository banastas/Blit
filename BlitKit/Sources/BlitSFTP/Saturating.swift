// Sizes come from servers and files, not from Blit: sums of them stop at the
// largest value instead of trapping (a Swift overflow ends the whole app).

extension Sequence {
    /// The sum of `value` over the elements, capped at UInt64.max.
    public func saturatingSum(_ value: (Element) -> UInt64) -> UInt64 {
        reduce(0) { total, element in
            let (sum, overflow) = total.addingReportingOverflow(value(element))
            return overflow ? .max : sum
        }
    }
}
