// The expanded transfer HUD (PRD Transfer HUD): boxed Item, Throughput and
// Link data panels, the log, and a Nostromo-style WARNING panel listing
// failures. Always dark; opened from the condensed strip's count.

import BlitRemote
import SwiftUI

struct TransferHUD: View {
    @Environment(TransferManager.self) private var transfers
    let job: TransferJob

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            HStack(alignment: .top, spacing: 10) {
                itemPanel.frame(maxWidth: .infinity)
                throughputPanel.frame(maxWidth: .infinity)
                linkPanel.frame(width: 210)
            }
            .fixedSize(horizontal: false, vertical: true)
            // The log sets this row's height; the WARNING panel takes exactly
            // that height (an overlay), so a failure never makes the HUD taller.
            HStack(alignment: .top, spacing: 10) {
                logPanel.frame(maxWidth: .infinity)
                if !job.failures.isEmpty {
                    Color.clear.frame(width: 260)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .overlay(alignment: .topTrailing) {
                if !job.failures.isEmpty {
                    warningPanel.frame(width: 260).frame(maxHeight: .infinity)
                }
            }
            // Shown once there's more than one job, at a fixed height (three
            // rows, then it scrolls), so jobs coming and going don't resize it.
            if transfers.transferJobs.count > 1 || transfers.queuePaused {
                QueuePanel()
            }
        }
        .foregroundStyle(HUDColor.bright)
        .padding(14)
        .background(HUDColor.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(HUDColor.border, lineWidth: 0.5))
        .environment(\.colorScheme, .dark)
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Button {
                transfers.collapse()
            } label: {
                hudText("▼ TRANSFER · \(stateLabel)", glyphSize: 9)
                    .font(HUDFont.label())
                    .foregroundStyle(HUDColor.bright)
            }
            .buttonStyle(.plain)
            .help("Collapse")
            Spacer()
            if transfers.queuedCount > 0 {
                Text("\(transfers.queuedCount) QUEUED").font(HUDFont.label()).foregroundStyle(HUDColor.dim)
            }
            Text("BLIT://HUD").font(HUDFont.label()).foregroundStyle(HUDColor.dim)
            if !job.isActive {
                Button {
                    transfers.dismissFinished()
                } label: {
                    Image(systemName: "xmark").font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(HUDColor.dim)
                .help("Clear finished transfers")
            }
        }
    }

    private var stateLabel: String {
        let route: String
        switch job.kind {
        case .download(let server): route = "\(server.displayName.uppercased()) → \(job.destinationName.uppercased())"
        case .copy: route = "COPY → \(job.destinationName.uppercased())"
        case .operation(let verb, _): route = "\(verb) → \(job.destinationName.uppercased())"
        }
        switch job.status {
        case .queued: return "QUEUED · " + route
        case .preparing: return "PREPARING · " + route
        case .running: return route + (job.restored ? " · RESUMED" : "")
        case .finished: return (job.allAlreadyPresent ? "ALREADY PRESENT · " : "DONE · ") + route
        case .failed: return "FAILED · " + route
        case .waiting: return "WAITING TO RETRY · " + route
        case .waitingForSpace: return "WAITING FOR SPACE · " + route
        case .paused: return "PAUSED · " + route
        case .cancelled: return "CANCELLED · " + route
        }
    }

    // MARK: Panels

    private var itemPanel: some View {
        HUDPanel("Item") {
            Text(job.title.uppercased())
                .font(HUDFont.terminal(20))
                .lineLimit(1)
                .truncationMode(.middle)
            hudText(sourceLine)
                .font(HUDFont.terminal(15))
                .foregroundStyle(HUDColor.dim)
                .lineLimit(1)
                .truncationMode(.middle)
            // Read the value here, not inside the GeometryReader, so the bar
            // redraws as it changes.
            let fraction = job.progress
            GeometryReader { geo in
                PixelCells(fraction: fraction, count: max(16, Int(geo.size.width / 6)))
            }
            .frame(height: 10)
            .padding(.vertical, 4)
            HUDRow("\(TransferJob.bytes(job.transferred)) / \(TransferJob.bytes(job.totalBytes))",
                   "\(Int((job.progress * 100).rounded()))%")
            HUDRow("FILES \(job.filesFinished)/\(job.fileCount)", "VERIFIED \(job.filesVerified)")
            detailSlot
        }
    }

    private var throughputPanel: some View {
        HUDPanel("Throughput · 60 s") {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if job.isVerifyingOnly {
                    Text("SHA256").font(HUDFont.terminal(40))
                    if job.hashRate > 0.5 {
                        Text(String(format: "%.1f MB/S", job.hashRate)).font(HUDFont.terminal(18)).foregroundStyle(HUDColor.dim)
                    }
                } else if !job.isActive, job.allAlreadyPresent {
                    Text("PRESENT").font(HUDFont.terminal(40))
                } else {
                    Text(String(format: "%.1f", job.isActive ? job.rate : averageRate)).font(HUDFont.terminal(40))
                    Text("MB/S").font(HUDFont.terminal(18)).foregroundStyle(HUDColor.dim)
                }
            }
            PixelHistogram(samples: Array(job.history.suffix(60)), scale: job.histogramScale, columns: 60)
                .frame(height: 64)
            HUDRow(String(format: "PEAK %.1f", job.peakRate), eta)
        }
    }

    private var linkPanel: some View {
        HUDPanel("Link data") {
            HUDRow("CONN", "\(job.connections)")
            HUDRow("LINK", job.link.isEmpty ? "—" : job.link)
            // The same rows for every job ("—" where they don't apply), so the
            // panel keeps its height.
            HUDRow("RTT", isDownload ? job.rttMilliseconds.map { "\(Int($0.rounded())) MS" } ?? "—" : "—")
            HUDRow("WINDOW", isDownload ? "\((SSHTuning().maximumPacketSize * 64) >> 20) MB · RCVBUF \(SSHTuning().receiveBufferBytes >> 20) MB" : "—")
            HUDRow("HASH CACHE", isDownload && job.filesVerified > 0 ? "\(job.hashCacheHits)/\(job.filesVerified)" : "—")
            HUDRow("VERIFY", job.verificationMethod)
            HUDRow("EXISTS", job.existsRule.hudLabel)
            HUDRow("RESUMED", job.resumedBytes > 0 ? TransferJob.bytes(job.resumedBytes) : "—")
            HUDRow("PRESENT", "\(job.filesAlreadyPresent)")
            HUDRow("ELAPSED", elapsed)
        }
    }

    /// Six lines at a fixed height each (a line with a pixel glyph would
    /// otherwise be taller), padded while the log is shorter.
    private var logPanel: some View {
        let lines = Array(job.log.suffix(Self.logLines))
        return HUDPanel("Log") {
            ForEach(0..<Self.logLines, id: \.self) { slot in
                let index = slot - (Self.logLines - lines.count)
                Group {
                    if index >= 0 {
                        let line = lines[index]
                        hudText("\(line.time.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))) \(line.text)")
                            .foregroundStyle(line.isFailure ? HUDColor.failureText : HUDColor.dim)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .textSelection(.enabled)
                    } else {
                        Color.clear
                    }
                }
                .frame(maxWidth: .infinity, minHeight: Self.lineHeight, maxHeight: Self.lineHeight, alignment: .leading)
            }
        }
        .font(HUDFont.terminal(16))
    }

    static let logLines = 6
    static let lineHeight: CGFloat = 18
    /// Lines in the Item panel's detail area (connections and server hashing).
    static let detailLines = 6

    private enum DetailLine: Identifiable {
        case label(String)
        case bar(key: String, name: String?, fraction: Double, value: String)
        case more(String)
        var id: String {
            switch self {
            case .label(let t): "l" + t
            case .bar(let k, let n, _, _): "b" + k + (n ?? "")
            case .more(let t): "m" + t
            }
        }
    }

    /// Connections (or streams) and files the server is hashing, in a fixed
    /// number of lines; what doesn't fit is summed up in a last "+N MORE" line.
    private var detailLines: [DetailLine] {
        let showConnections = !job.connectionRates.isEmpty && job.isActive && !job.isVerifyingOnly
        let hashing = job.isActive ? job.hashing : []
        // Each group needs a label plus a line per row. When both don't fit,
        // hashing keeps two lines (label and one file) and connections the rest.
        let needConnections = showConnections ? job.connectionRates.count + 1 : 0
        let needHashing = hashing.isEmpty ? 0 : hashing.count + 1
        let hashingLines = needConnections + needHashing <= Self.detailLines ? needHashing
            : min(needHashing, max(2, Self.detailLines - needConnections))
        let connectionLines = Self.detailLines - hashingLines
        var lines: [DetailLine] = []
        if showConnections {
            let rates = job.connectionRates
            let top = max(rates.max() ?? 1, 1)
            let rows = rates.enumerated().map { index, rate in
                DetailLine.bar(key: "\(isDownload ? "C" : "S")\(index + 1)", name: nil, fraction: rate / top,
                               value: String(format: "%.1f", rate))
            }
            lines += Self.group(isDownload ? "CONNECTIONS" : "STREAMS", rows, lines: connectionLines) { shown in
                String(format: "+%d MORE · %.1f MB/S", rates.count - shown, rates.dropFirst(shown).reduce(0, +))
            }
        }
        if !hashing.isEmpty {
            let rows = hashing.map { file in
                DetailLine.bar(key: "", name: (file.name as NSString).lastPathComponent.uppercased(), fraction: file.fraction,
                               value: "\(Int((file.fraction * 100).rounded()))%")
            }
            lines += Self.group("SERVER SHA256", rows, lines: hashingLines) { shown in "+\(hashing.count - shown) MORE FILES" }
        }
        return lines
    }

    /// A label and its rows in `lines` lines; when they don't fit, the last
    /// line says what's hidden.
    private static func group(_ label: String, _ rows: [DetailLine], lines: Int,
                              more: (_ shown: Int) -> String) -> [DetailLine] {
        guard rows.count > lines - 1 else { return [.label(label)] + rows }
        if lines <= 2 {
            // No room for a separate "more" line: the count goes in the label.
            return [.label("\(label) · +\(rows.count - 1) MORE")] + rows.prefix(1)
        }
        let shown = lines - 2
        return [.label(label)] + rows.prefix(shown) + [.more(more(shown))]
    }

    private var detailSlot: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(detailLines) { line in
                Group {
                    switch line {
                    case .label(let text):
                        Text(text).font(HUDFont.label()).foregroundStyle(HUDColor.dim)
                    case .more(let text):
                        Text(text).font(HUDFont.label()).foregroundStyle(HUDColor.dim)
                    case .bar(let key, let name, let fraction, let value):
                        HStack(spacing: 6) {
                            if let name {
                                Text(name).lineLimit(1).truncationMode(.middle)
                                    .frame(width: 140, alignment: .leading).foregroundStyle(HUDColor.dim)
                            } else {
                                Text(key).foregroundStyle(HUDColor.dim).frame(width: 22, alignment: .leading)
                            }
                            GeometryReader { geo in
                                PixelCells(fraction: fraction, count: max(8, Int(geo.size.width / 6)), height: 6)
                            }
                            .frame(height: 6)
                            Text(value).frame(width: 40, alignment: .trailing)
                        }
                        .font(HUDFont.terminal(16))
                    }
                }
                .frame(maxWidth: .infinity, minHeight: Self.lineHeight, maxHeight: Self.lineHeight, alignment: .leading)
            }
        }
        .frame(height: Self.lineHeight * CGFloat(Self.detailLines), alignment: .top)
        .padding(.top, 4)
    }

    private var warningPanel: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(job.failures.count == 1 ? "1 FAILURE" : "\(job.failures.count) FAILURES").font(HUDFont.label())
                Spacer()
                hudText("✕", glyphSize: 11)
            }
            Text("WARNING").font(HUDFont.terminal(30))
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(job.failures.enumerated()), id: \.offset) { _, failure in
                        Text(failure.uppercased())
                            .font(HUDFont.terminal(15))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
        .foregroundStyle(HUDColor.onFailure)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(HUDColor.failure)
    }

    // MARK: Values

    private var isDownload: Bool {
        if case .download = job.kind { return true }
        return false
    }

    private var sourceLine: String {
        let first = job.sources.first
        let from: String
        switch (job.kind, first) {
        case (.download(let server), .remote(_, let bytes)?):
            let parent = BrowseLocation.remote(server: server.id, path: bytes).parent
            from = "\(server.displayName):" + (parent?.remotePath?.description ?? "~")
        case (_, .local(let url)?):
            from = (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
        default:
            from = ""
        }
        return "\(from) → \(job.destinationName)".uppercased()
    }

    private var averageRate: Double {
        guard let start = job.startedAt, let end = job.finishedAt, end > start else { return 0 }
        return Double(job.counter.total) / end.timeIntervalSince(start) / 1e6
    }

    private var eta: String {
        if job.isVerifyingOnly {
            guard let seconds = job.verifySecondsLeft else { return "VERIFY --:--" }
            return "VERIFY \(TransferJob.duration(seconds))"
        }
        guard job.isActive, job.rate > 0.1 else { return "ETA --:--" }
        let seconds = Int(Double(job.totalBytes - job.transferred) / (job.rate * 1e6))
        return "ETA \(TransferJob.duration(seconds))"
    }

    private var elapsed: String {
        guard let start = job.startedAt else { return "—" }
        let seconds = Int((job.finishedAt ?? Date()).timeIntervalSince(start))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// A boxed HUD panel with a pixel label.
private struct HUDPanel<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased()).font(HUDFont.label()).foregroundStyle(HUDColor.dim).padding(.bottom, 2)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .overlay(Rectangle().strokeBorder(Color(white: 0.23), lineWidth: 1))
    }
}

/// Key on the left (dim), value on the right.
private struct HUDRow: View {
    let key: String
    let value: String

    init(_ key: String, _ value: String) {
        self.key = key
        self.value = value
    }

    var body: some View {
        HStack {
            Text(key).foregroundStyle(HUDColor.dim)
            Spacer(minLength: 6)
            Text(value).lineLimit(1)
        }
        .font(HUDFont.terminal(18))
    }
}

/// The HUD switching on and off like an old CRT: a bright line sweeps out
/// horizontally, then opens vertically; switching off runs it backwards.
struct CRTEffect: ViewModifier, Animatable {
    /// 0 = off, 1 = fully on.
    var progress: Double

    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let p = max(0, min(1, progress))
        let line = 0.3   // share of the animation spent as a line
        let x = p < line ? max(0.02, p / line) : 1
        let y = p < line ? 0.015 : 0.015 + (p - line) / (1 - line) * 0.985
        content
            .brightness(p < 1 ? 0.6 * (1 - p) : 0)
            .scaleEffect(x: x, y: y, anchor: .center)
            .opacity(p < 0.01 ? 0 : 1)
    }
}

extension AnyTransition {
    static var crt: AnyTransition {
        .modifier(active: CRTEffect(progress: 0), identity: CRTEffect(progress: 1))
    }
}

extension View {
    /// Debug builds: logs this view's height whenever it changes, to
    /// ~/Library/Logs/Blit/layout.log (for chasing layout jitter).
    @ViewBuilder func debugHeight(_ label: String) -> some View {
        #if DEBUG
        onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { old, new in
            guard old != new else { return }
            LayoutLog.write("\(label) y \(String(format: "%.1f", old.minY))→\(String(format: "%.1f", new.minY)) h \(String(format: "%.1f", old.height))→\(String(format: "%.1f", new.height))")
        }
        #else
        self
        #endif
    }
}

extension View {
    /// Debug builds: logs changes to this view's safe-area insets.
    @ViewBuilder func debugSafeArea(_ label: String) -> some View {
        #if DEBUG
        onGeometryChange(for: EdgeInsets.self, of: { $0.safeAreaInsets }) { old, new in
            guard old != new else { return }
            LayoutLog.write("\(label) safe area top \(old.top)→\(new.top) bottom \(old.bottom)→\(new.bottom)")
        }
        #else
        self
        #endif
    }
}

#if DEBUG
enum LayoutLog {
    static let url = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/Blit/layout.log")


    static func write(_ line: String) {
        let stamp = Date().formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits).secondFraction(.fractional(2)))
        let data = Data("\(stamp) \(line)\n".utf8)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
#endif

/// The queue (PRD R5.2): every transfer with its state, and controls to pause,
/// resume, cancel, retry and reorder. Clicking a row shows it in the HUD.
struct QueuePanel: View {
    @Environment(TransferManager.self) private var transfers
    static let visibleRows = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("QUEUE · \(transfers.transferJobs.count)").font(HUDFont.label()).foregroundStyle(HUDColor.dim)
                Spacer()
                if transfers.queuePaused {
                    HUDButton("▶ RESUME ALL") { transfers.resumeAll() }
                } else {
                    HUDButton("‖ PAUSE ALL") { transfers.pauseAll() }
                }
            }
            // Room for three rows, always; a longer queue scrolls.
            Group {
                if transfers.transferJobs.count <= Self.visibleRows {
                    rows
                } else {
                    ScrollView { rows }
                }
            }
            .frame(height: CGFloat(Self.visibleRows) * 26, alignment: .top)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .overlay(Rectangle().strokeBorder(Color(white: 0.23), lineWidth: 1))
    }

    private var rows: some View {
        VStack(spacing: 2) {
            ForEach(transfers.transferJobs) { job in
                QueueRow(job: job, isShown: transfers.featured === job)
            }
        }
    }
}

private struct QueueRow: View {
    @Environment(TransferManager.self) private var transfers
    let job: TransferJob
    let isShown: Bool

    var body: some View {
        HStack(spacing: 8) {
            hudText(glyph, glyphSize: 10)
                .frame(width: 14)
            Text(job.title.uppercased())
                .lineLimit(1)
                .truncationMode(.middle)
            hudText("→ \(job.destinationName.uppercased())", glyphSize: 10)
                .foregroundStyle(HUDColor.dim)
                .lineLimit(1)
                .fixedSize()
            Spacer(minLength: 8)
            Text(state)
                .foregroundStyle(stateIsFailure ? HUDColor.failureText : HUDColor.dim)
                .fixedSize()
            controls
        }
        .font(HUDFont.terminal(16))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(isShown ? Color(white: 0.12) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { transfers.pinnedJobID = job.id }
        .help("Show in the HUD")
    }

    private var glyph: String {
        switch job.status {
        case .queued: "·"
        case .preparing, .running, .waiting, .waitingForSpace: "▲"
        case .paused: "‖"
        case .finished: job.allAlreadyPresent ? "=" : "✓"
        case .failed, .cancelled: "✕"
        }
    }

    private var state: String {
        switch job.status {
        case .queued: return "QUEUED"
        case .preparing: return "PREPARING"
        case .running: return job.isVerifyingOnly ? "SHA256" : "\(Int((job.progress * 100).rounded()))%"
        case .waiting: return "RETRYING"
        case .waitingForSpace: return "NO SPACE"
        case .paused: return job.totalBytes > 0 ? "PAUSED · \(Int((job.progress * 100).rounded()))%" : "PAUSED"
        case .finished: return job.allAlreadyPresent ? "PRESENT" : "DONE"
        case .failed: return "FAILED"
        case .cancelled: return "CANCELLED"
        }
    }

    private var stateIsFailure: Bool {
        switch job.status {
        case .failed, .cancelled: true
        default: false
        }
    }

    @ViewBuilder private var controls: some View {
        HStack(spacing: 6) {
            switch job.status {
            case .queued:
                HUDButton("▲", help: "Move up") { transfers.move(job, by: -1) }
                HUDButton("▼", help: "Move down") { transfers.move(job, by: 1) }
                HUDButton("‖", help: "Pause") { transfers.pause(job) }
                HUDButton("✕", help: "Cancel") { transfers.cancel(job) }
            case .waiting:
                HUDButton("RETRY NOW", help: "Try again now (the cause is fixed)") { transfers.retryNow(job) }
                HUDButton("‖", help: "Pause") { transfers.pause(job) }
                HUDButton("✕", help: "Cancel") { transfers.cancel(job) }
            case .preparing, .running, .waitingForSpace:
                HUDButton("‖ PAUSE") { transfers.pause(job) }
                HUDButton("✕", help: "Cancel") { transfers.cancel(job) }
            case .paused:
                HUDButton("▶ RESUME") { transfers.resume(job) }
                HUDButton("✕", help: "Cancel") { transfers.cancel(job) }
            case .failed, .cancelled:
                HUDButton("RETRY") { transfers.retry(job) }
            case .finished:
                EmptyView()
            }
        }
    }
}

/// A HUD text button: pixel label, dim until hovered.
struct HUDButton: View {
    let title: String
    var help: String?
    let action: () -> Void
    @State private var hovered = false

    init(_ title: String, help: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.help = help
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            hudText(title, glyphSize: 9)
                .font(HUDFont.label())
                .foregroundStyle(hovered ? HUDColor.bright : HUDColor.dim)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .overlay(Rectangle().strokeBorder(hovered ? HUDColor.bright : HUDColor.border, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help ?? title)
        .accessibilityLabel(help ?? Self.spoken(title))
    }
}

extension HUDButton {
    /// "‖ PAUSE ALL" → "Pause all": the glyph is decoration next to the word.
    static func spoken(_ title: String) -> String {
        let words = title.filter { PixelGlyph(rawValue: $0) == nil }.trimmingCharacters(in: .whitespaces).lowercased()
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}

extension ExistsRule {
    /// Short label for the HUD's Link data panel.
    var hudLabel: String {
        switch self {
        case .skipIfSameSize: "SKIP SAME SIZE"
        case .replaceIfDifferent: "REPLACE IF DIFF"
        case .replace: "REPLACE"
        case .keepBoth: "KEEP BOTH"
        }
    }

    /// Settings title.
    var title: String {
        switch self {
        case .skipIfSameSize: "Skip if the same size"
        case .replaceIfDifferent: "Replace if different (compare SHA-256)"
        case .replace: "Replace"
        case .keepBoth: "Keep both"
        }
    }

    var explanation: String {
        switch self {
        case .skipIfSameSize: "Fast: a file of the same size is trusted and left; a different size fails the file."
        case .replaceIfDifferent: "Hashes both copies. Identical files are left and count as verified (a move can then remove the source); different ones are transferred again."
        case .replace: "Always transfers again and replaces the existing file, verified as usual."
        case .keepBoth: "Keeps the existing file and saves the new one as “name 2.ext”."
        }
    }
}
