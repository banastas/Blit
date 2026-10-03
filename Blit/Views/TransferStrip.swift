// The condensed transfer HUD (PRD Transfer HUD): a bounded, always-dark,
// 1-bit pixel-terminal strip. Two lines: progress, histogram, rate and link;
// then the latest log line. Failures add a muted-red warning tag.

import AppKit
import CoreText
import SwiftUI

enum HUDFont {
    /// Registers bundled fonts (Silkscreen, VT323; SIL OFL) once at launch.
    static func registerBundled() {
        for ext in ["ttf", "otf"] {
            for url in Bundle.main.urls(forResourcesWithExtension: ext, subdirectory: nil) ?? [] {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
    }

    /// Pixel uppercase labels; system monospaced small caps until the font is bundled.
    static func label(_ size: CGFloat = 11) -> Font {
        NSFont(name: "Silkscreen-Regular", size: size) != nil
            ? .custom("Silkscreen-Regular", fixedSize: size)
            : .system(size: size - 1, weight: .medium, design: .monospaced).smallCaps()
    }

    /// Terminal numerals and text.
    static func terminal(_ size: CGFloat) -> Font {
        NSFont(name: "VT323-Regular", size: size) != nil
            ? .custom("VT323-Regular", fixedSize: size)
            : .system(size: size * 0.72, design: .monospaced)
    }
}

enum HUDColor {
    static let background = Color(white: 0.04)
    static let border = Color(white: 0.17)
    static let bright = Color(white: 0.94)
    static let dim = Color(white: 0.49)
    static let off = Color(white: 0.15)
    /// Fills and tags (the WARNING tag and panel). Black text on it measures 4.6:1.
    static let failure = Color.failure
    static let onFailure = Color.black
    /// Failure text on the HUD's black: the lighter tint of the same red
    /// (#C98080, 6.5:1; #b35c5c itself is 4.3:1, under WCAG AA for small text).
    static let failureText = Color(red: 0xC9 / 255, green: 0x80 / 255, blue: 0x80 / 255)
}

struct TransferStrip: View {
    @Environment(TransferManager.self) private var transfers
    let job: TransferJob
    @State private var showingWarnings = false

    var body: some View {
        #if DEBUG
        let _ = UITestHarness.tick("TransferStrip")
        #endif
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                Button {
                    transfers.isExpanded = true
                } label: {
                    hudText(countLabel, glyphSize: 9)
                        .font(HUDFont.label())
                        .foregroundStyle(HUDColor.bright)
                        .fixedSize()
                }
                .buttonStyle(.plain)
                .help("Show the full transfer HUD")
                .accessibilityLabel("Show transfer details")
                HStack(spacing: 8) {
                    Text(job.title.uppercased())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !job.destinationName.isEmpty {
                        hudText("→ \(job.destinationName.uppercased())", glyphSize: 12)
                            .foregroundStyle(HUDColor.dim)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                .font(HUDFont.terminal(18))
                .frame(minWidth: 80, maxWidth: .infinity, alignment: .leading)
                if job.notice == nil {
                    PixelCells(fraction: displayedProgress, count: 24)
                    Text("\(Int((displayedProgress * 100).rounded()))%")
                        .font(HUDFont.terminal(18))
                        .frame(width: 38, alignment: .trailing)
                }
                separator
                if job.isOperation, job.failures.isEmpty {
                    EmptyView()
                } else if job.failures.isEmpty {
                    PixelHistogram(samples: Array(job.history.suffix(30)), scale: job.histogramScale)
                        .frame(width: 60, height: 20)
                } else {
                    // What went wrong, right here: the full HUD doesn't show file
                    // operations (a Move to Trash), so opening it did nothing.
                    Button {
                        showingWarnings = true
                    } label: {
                        hudText("✕ \(job.failures.count) WARNING\(job.failures.count == 1 ? "" : "S")", glyphSize: 9)
                            .font(HUDFont.label())
                            .foregroundStyle(HUDColor.onFailure)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(HUDColor.failure)
                            .fixedSize()
                    }
                    .buttonStyle(.plain)
                    .help("Show what went wrong")
                    .accessibilityLabel("\(job.failures.count) warning\(job.failures.count == 1 ? "" : "s"), show them")
                    .popover(isPresented: $showingWarnings, arrowEdge: .top) {
                        WarningsPopover(job: job) { showingWarnings = false }
                    }
                }
                rate
                separator
                VStack(alignment: .trailing, spacing: 2) {
                    HStack(spacing: 3) {
                        ForEach(0..<max(job.connections, 0), id: \.self) { index in
                            Rectangle().fill(job.isConnectionMoving(index) ? HUDColor.bright : HUDColor.dim).frame(width: 5, height: 5)
                        }
                    }
                    Text(job.link).font(HUDFont.label()).foregroundStyle(HUDColor.dim).fixedSize()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(job.movingConnections) of \(job.connections) connection\(job.connections == 1 ? "" : "s") active over \(job.link)")
                .help("\(job.movingConnections) of \(job.connections) connections moving data")
                if !job.isOperation, job.isActive || job.status == .paused || job.status == .queued {
                    separator
                    JobControls(job: job, compact: true)
                }
                // Clears transfers that ended; a paused or waiting one has its own ✕ (cancel) above.
                if !job.isActive, job.status != .paused, job.status != .queued {
                    Button {
                        transfers.dismissFinished()
                    } label: {
                        Image(systemName: "xmark").font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(HUDColor.dim)
                    .help("Clear finished transfers")
                    .accessibilityLabel("Clear finished transfers")
                }
            }
            Rectangle()
                .fill(.clear)
                .frame(height: 1)
                .overlay(Rectangle().stroke(style: StrokeStyle(lineWidth: 1, dash: [3, 3])).foregroundStyle(HUDColor.off))
            logLine
                .font(HUDFont.terminal(15))
                .lineLimit(1)
                .truncationMode(.tail)
                .help(job.failures.joined(separator: "\n"))
        }
        .foregroundStyle(HUDColor.bright)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 7)
        .background(HUDColor.background, in: RoundedRectangle(cornerRadius: 10))
        .contextMenu { queueMenu }
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(HUDColor.border, lineWidth: 0.5))
        .environment(\.colorScheme, .dark)
        // Keep the buttons inside reachable; the group reads as one summary.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(job.spokenSummary)
    }

    /// Right-click on the strip: the queue controls without opening the HUD.
    @ViewBuilder private var queueMenu: some View {
        if !job.isOperation {
            switch job.status {
            case .waiting:
                Button("Retry Now") { transfers.retryNow(job) }
                Button("Pause") { transfers.pause(job) }
                Button("Cancel") { transfers.cancel(job) }
            case .queued, .preparing, .running, .waitingForSpace:
                if job.destinationTrashBytes > 0 {
                    Button("Empty Trash on Destination (\(job.destinationTrashBytes.formatted(.byteCount(style: .file))))…") {
                        let destination = job.destination
                        Task { await transfers.emptyTrash(onDriveContaining: destination) }
                    }
                    Divider()
                }
                Button("Pause") { transfers.pause(job) }
                Button("Cancel") { transfers.cancel(job) }
            case .paused:
                Button("Resume") { transfers.resume(job) }
                Button("Cancel") { transfers.cancel(job) }
            case .failed, .cancelled:
                Button("Retry") { transfers.retry(job) }
            case .finished:
                EmptyView()
            }
            Divider()
            if transfers.queuePaused {
                Button("Resume All") { transfers.resumeAll() }
            } else {
                Button("Pause All") { transfers.pauseAll() }
            }
            Button("Show Queue") { transfers.isExpanded = true }
        }
    }

    private var separator: some View {
        Rectangle().fill(HUDColor.border).frame(width: 1, height: 18)
    }

    private var countLabel: String { job.countLabel }

    private var isVerifyingOnly: Bool { job.isVerifyingOnly }

    /// Transfer progress, or verification progress once only checksums remain.
    private var displayedProgress: Double {
        isVerifyingOnly ? (job.verifyProgress ?? job.progress) : job.progress
    }

    @ViewBuilder private var rate: some View {
        if job.notice != nil {
            EmptyView()   // the WARNING tag and the log line say it
        } else if case .waitingForSpace = job.status {
            Text("NO SPACE")
                .font(HUDFont.terminal(26))
                .foregroundStyle(HUDColor.failureText)
                .fixedSize()
        } else if job.status == .paused || job.status == .cancelled {
            Text(job.status == .paused ? "PAUSED" : "CANCELLED")
                .font(HUDFont.terminal(26))
                .fixedSize()
        } else if case .operation(let verb, _) = job.kind {
            Text(verb)
                .font(HUDFont.terminal(26))
                .fixedSize()
        } else if isVerifyingOnly {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("SHA256").font(HUDFont.terminal(26))
                if job.hashRate > 0.5 {
                    Text(String(format: "%.0f MB/S", job.hashRate)).font(HUDFont.terminal(14)).foregroundStyle(HUDColor.dim)
                }
            }
            .fixedSize()
        } else if !job.isActive, job.allAlreadyPresent {
            Text("PRESENT")
                .font(HUDFont.terminal(26))
                .fixedSize()
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(job.isActive ? String(format: "%.1f", job.rate) : averageRate)
                    .font(HUDFont.terminal(26))
                Text("MB/S").font(HUDFont.terminal(14)).foregroundStyle(HUDColor.dim)
            }
            .fixedSize()
        }
    }

    private var averageRate: String {
        guard let start = job.startedAt, let end = job.finishedAt, end > start else { return "0.0" }
        return String(format: "%.1f", Double(job.counter.total) / end.timeIntervalSince(start) / 1e6)
    }

    @ViewBuilder private var logLine: some View {
        if case .waitingForSpace(let reason) = job.status {
            HStack(spacing: 8) {
                Text("WAITING FOR SPACE · \(reason.uppercased()) · FREE SOME UP OR PAUSE")
                    .foregroundStyle(HUDColor.failureText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if job.destinationTrashBytes > 0 {
                    Spacer(minLength: 4)
                    // Deleted files on that drive still hold their space until the Trash is emptied.
                    HUDButton("EMPTY TRASH · \(TransferJob.bytes(job.destinationTrashBytes))",
                              help: "Permanently erase the Trash on the destination drive to free its space (asks first)") {
                        let destination = job.destination
                        Task { await transfers.emptyTrash(onDriveContaining: destination) }
                    }
                }
            }
        } else if case .waiting(let until, let reason) = job.status {
            HStack(spacing: 8) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let left = Int(until.timeIntervalSince(context.date))
                    // Past the countdown it's waiting on something (network, a drive): say that.
                    Text(left > 0 ? "RETRY IN \(TransferJob.duration(left)) · \(reason.uppercased())" : reason.uppercased())
                        .foregroundStyle(HUDColor.failureText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 4)
                HUDButton("RETRY NOW", help: "Try again now (the cause is fixed)") { transfers.retryNow(job) }
            }
        } else if job.status == .preparing {
            Text(job.attempt > 0 ? "RECONNECTING · ATTEMPT \(job.attempt + 1)…" : "PREPARING · LISTING FILES…").foregroundStyle(HUDColor.dim)
        } else if !job.isActive, job.status != .queued {
            let queued = transfers.queuedCount
            hudText(summary + (queued > 0 ? " · \(queued) QUEUED" : ""))
                .foregroundStyle(job.failures.isEmpty && job.sizeOnlyCount == 0
                                 ? HUDColor.bright : HUDColor.failureText)
        } else if isVerifyingOnly, let (name, since) = job.verifying.min(by: { $0.value < $1.value }) {
            // Verification can take minutes on big files; show it's alive (elapsed time).
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let elapsed = Int(context.date.timeIntervalSince(since))
                let others = job.verifying.count - 1
                Text("VERIFYING \(name.uppercased())\(others > 0 ? " +\(others)" : "") · \(job.verificationMethod)\(Self.verifyDetail(job)) · \(elapsed / 60):\(String(format: "%02d", elapsed % 60))")
                    .foregroundStyle(HUDColor.bright)
            }
        } else if let last = job.log.last {
            hudText("\(last.time.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))) \(last.text)")
                .foregroundStyle(last.isFailure ? HUDColor.failureText : HUDColor.dim)
        }
    }

    /// " · 62% · ~1:10 LEFT" where the server reports hashing progress.
    static func verifyDetail(_ job: TransferJob) -> String {
        guard let fraction = job.verifyProgress else { return "" }
        var text = " · \(Int((fraction * 100).rounded()))%"
        if let left = job.verifySecondsLeft { text += " · \(TransferJob.duration(left)) LEFT" }
        return text
    }

    private var summary: String {
        if let notice = job.notice { return "✕ \(notice.uppercased())" }
        if case .operation(_, let done) = job.kind {
            let ok = job.filesFinished - job.failures.count
            // The first failure's reason ("name: reason"), so the line says why.
            let why = job.failures.first.map { failure in
                failure.range(of: ": ").map { String(failure[$0.upperBound...]) } ?? failure
            }
            return "\(job.failures.isEmpty ? "✓" : "✕") \(ok)/\(job.fileCount) \(done) · \(job.destinationName.uppercased())"
                + (job.failures.isEmpty ? "" : " · \(job.failures.count) FAILED")
                + (why.map { ": \($0.uppercased())" } ?? "")
        }
        let verified = "\(job.filesVerified)/\(job.fileCount) VERIFIED"
        let size = TransferJob.bytes(job.totalBytes)
        if case .failed(let why) = job.status, job.fileCount == 0 { return "✕ \(why.uppercased())" }
        if job.allAlreadyPresent, job.failures.isEmpty {
            return "= \(job.fileCount)/\(job.fileCount) ALREADY PRESENT · \(size) → \(job.destinationName.uppercased())"
        }
        let mark = !job.failures.isEmpty ? "✕" : job.sizeOnlyCount > 0 || job.unverifiedCount > 0 ? "=" : "✓"
        return "\(mark) \(verified) · \(size) → \(job.destinationName.uppercased())"
            + (job.sizeOnlyCount > 0 ? " · \(job.sizeOnlyCount) SIZE ONLY, NOT HASH-VERIFIED" : "")
            + (job.unverifiedCount > 0 ? " · \(job.unverifiedCount) SIZE-CHECKED (VERIFY OFF)" : "")
            + (job.filesAlreadyPresent > 0 ? " · \(job.filesAlreadyPresent) ALREADY THERE" : "")
            + (job.failures.isEmpty ? "" : " · \(job.failures.count) FAILED")
    }
}

/// A transfer's or a file operation's failures, from the strip's WARNING tag:
/// each item with what went wrong, selectable. They used to show only in the
/// tag's tooltip, and clicking it did nothing for operations.
struct WarningsPopover: View {
    @Environment(TransferManager.self) private var transfers
    let job: TransferJob
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            hudText("✕ \(job.failures.count) WARNING\(job.failures.count == 1 ? "" : "S") · \(job.title.uppercased())", glyphSize: 9)
                .font(HUDFont.label())
                .foregroundStyle(HUDColor.failureText)
                .lineLimit(1)
                .truncationMode(.middle)
            if job.failures.count <= 6 {
                list
            } else {
                ScrollView { list }.frame(height: 240)
            }
            if !job.isOperation {
                HStack {
                    Spacer()
                    HUDButton("SHOW IN HUD", help: "Open the full HUD on this transfer") {
                        transfers.pinnedJobID = job.id
                        transfers.isExpanded = true
                        close()
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 480, alignment: .leading)
        .background(HUDColor.background)
        .environment(\.colorScheme, .dark)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(job.failures.enumerated()), id: \.offset) { _, failure in
                Text(failure)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(HUDColor.bright)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Progress as discrete cells, never a smooth bar.
struct PixelCells: View {
    let fraction: Double
    let count: Int
    var height: CGFloat = 10

    var body: some View {
        let on = Int((max(0, min(1, fraction)) * Double(count)).rounded(.down))
        HStack(spacing: 2) {
            ForEach(0..<count, id: \.self) { i in
                Rectangle().fill(i < on ? HUDColor.bright : HUDColor.off).frame(width: 4, height: height)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Progress")
        .accessibilityValue("\(Int(fraction * 100)) percent")
    }
}

/// Throughput as pixel columns, newest on the right.
struct PixelHistogram: View {
    let samples: [Double]
    let scale: Double
    var columns = 30

    var body: some View {
        Canvas { context, size in
            let columns = self.columns
            let width = size.width / CGFloat(columns)
            let offset = columns - samples.count
            for (i, value) in samples.enumerated() {
                let height = max(1, (CGFloat(value / scale) * size.height).rounded())
                let rect = CGRect(x: CGFloat(offset + i) * width, y: size.height - height, width: max(1, width - 0.6), height: height)
                context.fill(Path(rect), with: .color(i == samples.count - 1 ? HUDColor.bright : Color(white: 0.6)))
            }
        }
        .accessibilityLabel("Throughput over the last 30 seconds")
        .accessibilityValue(samples.last.map { String(format: "%.0f megabytes per second now", $0) } ?? "no data")
    }
}

extension String {
    func leftPadded(_ width: Int) -> String { count >= width ? self : String(repeating: "0", count: width - count) + self }
}

extension TransferJob {
    /// "▲ 07/26": the status glyph and files done, shared by the strip and the
    /// menu bar. ‖ paused, ▲/▼ active (see directionGlyph), ✓ verified, = nothing transferred or only
    /// size-checked, ✕ failed, cancelled or finished with failures.
    /// Zero-padded so digits don't jump.
    var countLabel: String {
        if notice != nil { return "✕" }
        let arrow = status == .paused ? "‖"
            : isActive ? directionGlyph
            : status != .finished || !failures.isEmpty ? "✕"
            : allAlreadyPresent || sizeOnlyCount > 0 || unverifiedCount > 0 ? "=" : "✓"
        guard fileCount > 0 else { return "\(arrow) --/--" }
        let width = max(2, String(fileCount).count)
        return "\(arrow) \(String(filesFinished).leftPadded(width))/\(String(fileCount).leftPadded(width))"
    }

    /// Whether connection `index` moved data in the last second (PRD: one
    /// square per connection). Without per-connection rates (local copies),
    /// every square follows the job.
    func isConnectionMoving(_ index: Int) -> Bool {
        guard isActive, status == .running else { return false }
        guard !connectionRates.isEmpty else { return true }
        return index < connectionRates.count && connectionRates[index] > 0.1
    }

    var movingConnections: Int { (0..<max(connections, 0)).filter(isConnectionMoving).count }

    /// The strip in one sentence for VoiceOver ("Movies to Incoming, 64 percent,
    /// 74 megabytes per second, 7 of 26 files").
    var spokenSummary: String {
        var parts = ["\(title) to \(destinationName)"]
        switch status {
        case .queued: parts.append("queued")
        case .preparing: parts.append("preparing")
        case .paused: parts.append("paused")
        case .cancelled: parts.append("cancelled")
        case .waiting(_, let reason): parts.append("waiting to retry: \(reason)")
        case .waitingForSpace(let reason): parts.append("waiting for space: \(reason)")
        case .failed(let why): parts.append("failed: \(why)")
        case .finished: parts.append(failures.isEmpty ? "finished" : "finished with problems")
        case .running:
            if isVerifyingOnly {
                parts.append("verifying checksums" + (verifyProgress.map { ", \(Int(($0 * 100).rounded())) percent" } ?? ""))
            } else {
                parts.append("\(Int((progress * 100).rounded())) percent")
                parts.append(String(format: "%.0f megabytes per second", rate))
            }
        }
        if fileCount > 0 { parts.append("\(filesFinished) of \(fileCount) file\(fileCount == 1 ? "" : "s")") }
        if !failures.isEmpty { parts.append("\(failures.count) warning\(failures.count == 1 ? "" : "s")") }
        return parts.joined(separator: ", ")
    }
}
