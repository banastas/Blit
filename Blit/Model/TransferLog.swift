// A durable record of every file Blit transferred (PRD R4.4): one JSON line
// per file in ~/Library/Application Support/Blit/transfers.jsonl, exportable
// as CSV.

import AppKit
import Foundation
import UniformTypeIdentifiers

struct TransferRecord: Codable, Sendable {
    var time: Date
    var source: String
    var destination: String
    var size: UInt64
    var sha256: String?
    /// "server-sha256", "nas-sha256", "read-back", "size-only", "cloned", "already-present", "none"
    var verification: String
    var result: String        // "ok" or "failed"
    var detail: String?
}

@MainActor
enum TransferLog {
    static var url: URL {
        URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/Blit/transfers.jsonl")
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    static func append(_ record: TransferRecord) {
        guard var line = try? encoder.encode(record) else { return }
        line.append(0x0A)
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: url)
        }
    }

    static func records() -> [TransferRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(TransferRecord.self, from: Data($0)) }
    }

    /// File › Export Transfer Log…: saves every record as CSV.
    static func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "Blit Transfer Log \(Date().formatted(.iso8601.year().month().day())).csv"
        guard panel.runModal() == .OK, let target = panel.url else { return }
        let formatter = ISO8601DateFormatter()
        func field(_ s: String?) -> String {
            let v = s ?? ""
            return v.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) ? "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : v
        }
        var csv = "time,result,verification,size,sha256,source,destination,detail\n"
        for r in records() {
            csv += [formatter.string(from: r.time), r.result, r.verification, String(r.size), r.sha256 ?? "",
                    r.source, r.destination, r.detail ?? ""].map(field).joined(separator: ",") + "\n"
        }
        try? csv.write(to: target, atomically: true, encoding: .utf8)
    }
}
