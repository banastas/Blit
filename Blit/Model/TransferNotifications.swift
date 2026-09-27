// Notifications for finished transfers. The title says what happened and
// where ("Copied to Movies"), the subtitle names the item (so a long release
// name truncates on its own line), and the body has the details: size, how it
// was verified, and how long it took at what speed. Problems play a sound and
// offer Show Details; everything else offers Show in Finder.

import AppKit
import SwiftUI
import UserNotifications

@MainActor
enum TransferNotifications {
    static let doneCategory = "transfer-done"
    static let problemCategory = "transfer-problem"
    static let revealAction = "reveal"
    static let detailsAction = "details"

    /// Registers the actions and routes clicks (at launch).
    static func register() {
        let center = UNUserNotificationCenter.current()
        let reveal = UNNotificationAction(identifier: revealAction, title: "Show in Finder", options: [.foreground])
        let details = UNNotificationAction(identifier: detailsAction, title: "Show Details", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: doneCategory, actions: [reveal], intentIdentifiers: []),
            UNNotificationCategory(identifier: problemCategory, actions: [details, reveal], intentIdentifiers: []),
        ])
        center.delegate = NotificationRouter.shared
    }

    // MARK: Content

    /// The notification for a finished or failed transfer; nil when a clean
    /// finish isn't worth one (per-transfer notifications off).
    static func content(for job: TransferJob, eachTransfer: Bool, now: Date = Date()) -> UNMutableNotificationContent? {
        let content = UNMutableNotificationContent()
        content.threadIdentifier = "transfers"
        content.subtitle = itemLabel(job)
        content.userInfo = ["job": job.id.uuidString, "reveal": revealPaths(job)]
        let size = job.totalBytes.formatted(.byteCount(style: .file))
        let failed = job.status != .finished || !job.failures.isEmpty

        if failed {
            let count = job.failures.count
            content.title = count == 0 ? "Transfer failed" : count == 1 ? "1 file failed" : "\(count) files failed"
            var reasons = job.failures.map(readable)
            if reasons.isEmpty, case .failed(let why) = job.status { reasons = [why] }
            var body = reasons.first ?? "Open Blit for details."
            if reasons.count > 1 { body += " · and \(reasons.count - 1) more" }
            content.body = body
            content.categoryIdentifier = problemCategory
            content.sound = .default
            return content
        }
        if job.sizeOnlyCount > 0 {
            content.title = "Not fully verified"
            content.body = "\(job.sizeOnlyCount) of \(job.fileCount) only checked by size: the server couldn't hash them. \(job.filesVerified) verified by SHA-256 · \(size)"
            content.categoryIdentifier = problemCategory
            content.sound = .default
            return content
        }
        guard eachTransfer else { return nil }
        content.categoryIdentifier = doneCategory
        let many = job.fileCount != 1
        if job.allAlreadyPresent {
            content.title = "Already in \(job.destinationName)"
            content.body = "Nothing copied: \(many ? "they're" : "it's") there with the same size · \(size)"
            return content
        }
        let verb = job.deleteSources ? "Moved" : job.lane == .download ? "Downloaded" : "Copied"
        content.title = "\(verb) to \(job.destinationName)"
        var parts = [size, verification(job)]
        if job.filesAlreadyPresent > 0 { parts.append("\(job.filesAlreadyPresent) already there") }
        if let timing = timing(job, now: now) { parts.append(timing) }
        content.body = parts.joined(separator: " · ")
        return content
    }

    /// When the queue drains with more than one transfer (or per-transfer
    /// notifications are off).
    static func batchContent(jobs: Int, bytes: Int64, failed: Int, sizeOnly: Int, unverified: Int,
                             elapsed: TimeInterval?) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.threadIdentifier = "transfers"
        content.subtitle = "\(jobs) transfer\(jobs == 1 ? "" : "s")"
        var parts = [bytes.formatted(.byteCount(style: .file))]
        if failed > 0 {
            content.title = "Queue finished with problems"
            parts.append("\(failed) with problems")
            content.categoryIdentifier = problemCategory
            content.sound = .default
        } else {
            content.title = "All transfers finished"
            parts.append(sizeOnly > 0 ? "\(sizeOnly) files only size-checked"
                         : unverified > 0 ? "\(unverified) size-checked (verification off)" : "all verified")
        }
        if let elapsed, elapsed >= 60 { parts.append(duration(elapsed)) }
        content.body = parts.joined(separator: " · ")
        return content
    }

    /// "Go 1999.mkv", or "Pack (12 files)" for a folder or several items.
    static func itemLabel(_ job: TransferJob) -> String {
        job.fileCount > 1 ? "\(job.title) (\(job.fileCount) files)" : job.title
    }

    /// How the files were checked, in words.
    private static func verification(_ job: TransferJob) -> String {
        let moved = job.fileCount - job.filesAlreadyPresent
        let all = moved > 1 ? "all \(moved) " : ""
        let originals = job.deleteSources ? ", originals removed" : ""
        let cloned = job.outcomes.values.filter { $0 == "cloned" }.count
        if cloned > 0, cloned == moved { return "cloned on the same drive, nothing to verify" + originals }
        if job.filesVerified == 0, job.unverifiedCount > 0 { return "checked by size (verification is off)" }
        if job.lane == .download { return (all.isEmpty ? "SHA-256 verified" : "\(all)verified by SHA-256") + originals }
        if job.nasVerified, job.readBackCount == 0 { return (all.isEmpty ? "verified on the NAS" : "\(all)verified on the NAS") + originals }
        return (all.isEmpty ? "verified by read-back" : "\(all)verified by read-back") + originals
    }

    /// "9 min at 117 MB/s", from when the job started to now, and the bytes
    /// this run actually moved (not files already there or resumed).
    private static func timing(_ job: TransferJob, now: Date) -> String? {
        guard let started = job.startedAt else { return nil }
        let elapsed = now.timeIntervalSince(started)
        guard elapsed >= 5 else { return nil }
        let moved = Double(job.counter.total)
        guard moved > 0 else { return duration(elapsed) }
        return "\(duration(elapsed)) at \(Int((moved / elapsed / 1e6).rounded())) MB/s"
    }

    /// "<1 min", "9 min", "1 h 12 min".
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 1 { return "<1 min" }
        if minutes < 60 { return "\(minutes) min" }
        return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
    }

    /// A failure line ("Extras.mkv: SHA-256 mismatch: source …, NAS …") cut to
    /// its file and first reason, without the hashes.
    private static func readable(_ failure: String) -> String {
        var text = failure
        if let range = text.range(of: #":\s*source [0-9a-f]{64}.*"#, options: .regularExpression) { text.removeSubrange(range) }
        return text.count > 140 ? String(text.prefix(139)) + "…" : text
    }

    /// The top-level items at the destination, for Show in Finder.
    private static func revealPaths(_ job: TransferJob) -> [String] {
        if case .operation = job.kind { return [] }
        let names: [String] = job.sources.compactMap { source in
            switch source {
            case .local(let url): url.lastPathComponent
            case .remote(_, let path): path.description.split(separator: "/").last.map(String.init)
            }
        }
        let paths = names.map { job.destination.appendingPathComponent($0).path }
        return paths.isEmpty ? [job.destination.path] : paths
    }
}

/// Handles clicks on Blit's notifications.
@MainActor
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationRouter()
    weak var transfers: TransferManager?
    /// Opens the browser window when none is open (captured from a view).
    var openMainWindow: OpenWindowAction?

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        // Blit in front already shows it in the strip: keep it in Notification Center.
        [.list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        let jobID = (info["job"] as? String).flatMap(UUID.init(uuidString:))
        let paths = info["reveal"] as? [String] ?? []
        await MainActor.run {
            if action == TransferNotifications.revealAction {
                let existing = paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
                if !existing.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(existing) }
                return
            }
            // Show Details, or a click on the notification: Blit, with that job in the HUD.
            NSApp.activate()
            if !NSApp.windows.contains(where: { $0.isVisible && $0.identifier?.rawValue.hasPrefix("main") == true }) {
                openMainWindow?(id: "main")
            }
            if let transfers, let jobID, transfers.jobs.contains(where: { $0.id == jobID }) {
                transfers.pinnedJobID = jobID
                if action == TransferNotifications.detailsAction { transfers.isExpanded = true }
            }
        }
    }
}
