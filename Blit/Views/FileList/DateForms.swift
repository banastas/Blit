// The Modified column's dates (PRD R2.6): four forms, longest first. Every
// row in a column uses the same form, the longest that fits the column, so
// the column reads evenly (a short date fitting a longer form would not).

import AppKit

enum DateForms {
    /// The widest each form gets, so every row picks the same form.
    static let widest = ["Sep 28, 2026 at 20:00", "Sep 28 at 20:00", "Yesterday", "12/28"]

    static func forms(_ date: Date) -> [String] {
        let calendar = Calendar.current
        let full = date.formatted(.dateTime.year().month(.abbreviated).day().hour().minute())
        let thisYear = calendar.isDate(date, equalTo: .now, toGranularity: .year)
        let time = date.formatted(.dateTime.hour().minute())
        let medium = thisYear ? date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
                              : date.formatted(.dateTime.year().month(.abbreviated).day())
        let short: String
        if calendar.isDateInToday(date) {
            short = "Today \(time)"
        } else if calendar.isDateInYesterday(date) {
            short = "Yesterday"
        } else if thisYear {
            short = date.formatted(.dateTime.month(.abbreviated).day())
        } else {
            short = date.formatted(.iso8601.year().month().day())
        }
        let tiny = calendar.isDateInToday(date) ? time
            : thisYear ? date.formatted(.dateTime.month(.defaultDigits).day()) : date.formatted(.dateTime.year())
        return [full, medium, short, tiny]
    }

    /// The longest form whose widest sample fits `width` in `font`.
    @MainActor
    static func level(forWidth width: CGFloat, font: NSFont) -> Int {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        for (level, sample) in widest.enumerated() where (sample as NSString).size(withAttributes: attributes).width <= width {
            return level
        }
        return widest.count - 1
    }
}
