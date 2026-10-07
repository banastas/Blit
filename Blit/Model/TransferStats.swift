// Monthly totals (PRD R4.4): what Blit moved each month, from the transfer
// log, with how much of it was verified, and how fast the bytes went, from a
// small log of finished jobs (jobs.jsonl). A job's speed counts only the
// seconds bytes were moving, not waits, pauses or checksums, so a month's
// "downloads 81 MB/s" is the link's speed, not the queue's.

import Foundation
import Observation

/// One finished transfer job, for the months' speeds.
struct JobRecord: Codable, Sendable {
    var time: Date
    /// "download" or "copy".
    var kind: String
    /// Bytes moved this run (not what was already on disk, or already there).
    var bytes: UInt64
    /// Seconds in which bytes moved.
    var seconds: Double
    var files: Int
}

@MainActor
enum JobLog {
    static var url: URL {
        #if DEBUG
        if let path = UserDefaults.standard.string(forKey: "BlitJobLogPath") { return URL(fileURLWithPath: path) }
        #endif
        return URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/Blit/jobs.jsonl")
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    /// A job ended (or stopped for now): what it moved since it last did.
    static func append(_ job: TransferJob) {
        let bytes = job.counter.total - job.loggedBytes, seconds = job.movingSeconds - job.loggedSeconds
        guard !TransferManager.isIsolated, seconds >= 1, bytes > 0 else { return }
        let kind: String
        switch job.kind {
        case .download: kind = "download"
        case .copy: kind = "copy"
        case .operation: return
        }
        job.loggedBytes = job.counter.total
        job.loggedSeconds = job.movingSeconds
        let record = JobRecord(time: Date(), kind: kind, bytes: UInt64(bytes), seconds: seconds, files: job.filesFinished)
        defer { TransferStats.shared.changed() }
        guard var line = try? encoder.encode(record) else { return }
        line.append(0x0A)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: url)
        }
    }

    nonisolated static func readRecords(at url: URL) -> [JobRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(JobRecord.self, from: Data($0)) }
    }
}

/// A month's totals.
struct MonthTotals: Identifiable, Hashable, Sendable {
    /// The month's first moment, in the Mac's time zone.
    let start: Date
    /// Files moved (not already there, not cloned) and their bytes.
    var files = 0
    var bytes: Int64 = 0
    /// Of those, checked by SHA-256.
    var verified = 0
    /// Already at the destination, left as they were.
    var present = 0
    var cloned = 0
    var failed = 0
    var downloadBytes: UInt64 = 0
    var downloadSeconds: Double = 0
    var copyBytes: UInt64 = 0
    var copySeconds: Double = 0

    var id: Date { start }

    static let hashMethods: Set<String> = ["server-sha256", "nas-sha256", "read-back", "present-sha256"]

    /// MB/s while bytes moved.
    var downloadRate: Double? { downloadSeconds >= 1 ? Double(downloadBytes) / downloadSeconds / 1e6 : nil }
    var copyRate: Double? { copySeconds >= 1 ? Double(copyBytes) / copySeconds / 1e6 : nil }

    var title: String { start.formatted(.dateTime.month(.wide).year()) }

    /// "all verified", "2,170 verified · 10 size only", "nothing moved".
    var verification: String {
        guard files > 0 else { return "nothing moved" }
        if verified == files { return files == 1 ? "verified" : "all verified" }
        return verified == 0 ? "none hash-verified" : "\(verified.formatted()) verified · \((files - verified).formatted()) size only"
    }

    static func rate(_ mbps: Double) -> String { "\(Int(mbps.rounded())) MB/s" }

    /// "24.3 TB · 2,180 files · all verified · downloads 81 MB/s · copies 104 MB/s".
    var summary: String {
        var parts = ["\(bytes.formatted(.byteCount(style: .file)))", "\(files.formatted()) file\(files == 1 ? "" : "s")", verification]
        if let downloadRate { parts.append("downloads " + Self.rate(downloadRate)) }
        if let copyRate { parts.append("copies " + Self.rate(copyRate)) }
        if failed > 0 { parts.append("\(failed.formatted()) failed") }
        return parts.joined(separator: " · ")
    }

    mutating func add(_ record: TransferRecord) {
        guard record.result == "ok" else { return failed += 1 }
        switch record.verification {
        case "already-present", "present-sha256": present += 1
        case "cloned": cloned += 1
        default:
            files += 1
            bytes += Int64(record.size)
            if Self.hashMethods.contains(record.verification) { verified += 1 }
        }
    }

    mutating func add(_ job: JobRecord) {
        if job.kind == "download" {
            downloadBytes += job.bytes
            downloadSeconds += job.seconds
        } else {
            copyBytes += job.bytes
            copySeconds += job.seconds
        }
    }

    /// Every month with something in it, newest first.
    static func make(records: [TransferRecord], jobs: [JobRecord], calendar: Calendar = .current) -> [MonthTotals] {
        var months: [Date: MonthTotals] = [:]
        func month(_ time: Date) -> Date { calendar.dateInterval(of: .month, for: time)?.start ?? time }
        for record in records {
            let start = month(record.time)
            months[start, default: MonthTotals(start: start)].add(record)
        }
        for job in jobs {
            let start = month(job.time)
            months[start, default: MonthTotals(start: start)].add(job)
        }
        return months.values.sorted { $0.start > $1.start }
    }
}

/// The months, read from the logs off the main thread when first asked for,
/// and again a moment after a record is written while anything shows them.
@MainActor
@Observable
final class TransferStats {
    static let shared = TransferStats()

    private(set) var months: [MonthTotals] = []
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var reloadPending = false

    /// This month's, if anything moved.
    var thisMonth: MonthTotals? {
        load()
        let start = Calendar.current.dateInterval(of: .month, for: Date())?.start
        return months.first { $0.start == start }
    }

    func load() {
        guard !loaded else { return }
        loaded = true
        reload()
    }

    /// A record was written: read again in a moment (once for a burst).
    func changed() {
        guard loaded, !reloadPending else { return }
        reloadPending = true
        Task {
            try? await Task.sleep(for: .seconds(3))
            reloadPending = false
            reload()
        }
    }

    private func reload() {
        let transfers = TransferLog.url, jobs = JobLog.url
        Task {
            let months = await Task.detached(priority: .utility) {
                MonthTotals.make(records: TransferLog.readRecords(at: transfers), jobs: JobLog.readRecords(at: jobs))
            }.value
            if months != self.months { self.months = months }
        }
    }
}
