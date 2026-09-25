// The expanded transfer HUD (PRD Transfer HUD): boxed Item, Throughput and
// Link data panels, the log, and a Nostromo-style WARNING panel listing
// failures. Always dark; opened from the condensed strip's count.

import SwiftUI

struct TransferHUD: View {
    @Environment(TransferManager.self) private var transfers
    let job: TransferJob

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            HStack(alignment: .top, spacing: 10) {
                itemPanel.frame(maxWidth: .infinity).debugHeight("item")
                throughputPanel.frame(maxWidth: .infinity).debugHeight("throughput")
                linkPanel.frame(width: 210).debugHeight("link")
            }
            .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 10) {
                logPanel.frame(maxWidth: .infinity).debugHeight("log")
                if !job.failures.isEmpty {
                    warningPanel.frame(width: 260)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(HUDColor.bright)
        .padding(14)
        .background(HUDColor.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(HUDColor.border, lineWidth: 0.5))
        .environment(\.colorScheme, .dark)
        .debugHeight("HUD")
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
            let hashing = job.hashing
            if !hashing.isEmpty, job.isActive {
                Text("SERVER SHA256").font(HUDFont.label()).foregroundStyle(HUDColor.dim).padding(.top, 4)
                ForEach(hashing.prefix(3), id: \.name) { file in
                    HStack(spacing: 6) {
                        Text((file.name as NSString).lastPathComponent.uppercased())
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(width: 140, alignment: .leading)
                            .foregroundStyle(HUDColor.dim)
                        let fraction = file.fraction
                        GeometryReader { geo in
                            PixelCells(fraction: fraction, count: max(8, Int(geo.size.width / 6)), height: 6)
                        }
                        .frame(height: 6)
                        Text("\(Int((file.fraction * 100).rounded()))%").frame(width: 40, alignment: .trailing)
                    }
                    .font(HUDFont.terminal(16))
                }
            }
            if !job.connectionRates.isEmpty, job.isActive, !job.isVerifyingOnly {
                Text(isDownload ? "CONNECTIONS" : "STREAMS").font(HUDFont.label()).foregroundStyle(HUDColor.dim).padding(.top, 4)
                let top = max(job.connectionRates.max() ?? 1, 1)
                ForEach(Array(job.connectionRates.enumerated()), id: \.offset) { index, rate in
                    HStack(spacing: 6) {
                        Text("\(isDownload ? "C" : "S")\(index + 1)").foregroundStyle(HUDColor.dim).frame(width: 22, alignment: .leading)
                        GeometryReader { geo in
                            PixelCells(fraction: rate / top, count: max(8, Int(geo.size.width / 6)), height: 6)
                        }
                        .frame(height: 6)
                        Text(String(format: "%.1f", rate)).frame(width: 40, alignment: .trailing)
                    }
                    .font(HUDFont.terminal(16))
                }
            }
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
            PixelHistogram(samples: Array(job.history.suffix(60)), scale: max(job.peakRate, 1), columns: 60)
                .frame(height: 64)
            HUDRow(String(format: "PEAK %.1f", job.peakRate), eta)
        }
    }

    private var linkPanel: some View {
        HUDPanel("Link data") {
            HUDRow("CONN", "\(job.connections)")
            HUDRow("LINK", job.link.isEmpty ? "—" : job.link)
            HUDRow("VERIFY", job.verificationMethod)
            HUDRow("RESUMED", job.resumedBytes > 0 ? TransferJob.bytes(job.resumedBytes) : "—")
            HUDRow("PRESENT", "\(job.filesAlreadyPresent)")
            HUDRow("ELAPSED", elapsed)
        }
    }

    private var logPanel: some View {
        HUDPanel("Log") {
            ForEach(job.log.suffix(6)) { line in
                hudText("\(line.time.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))) \(line.text)")
                    .foregroundStyle(line.isFailure ? Color(red: 0xC9 / 255, green: 0x80 / 255, blue: 0x80 / 255) : HUDColor.dim)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
            }
        }
        .font(HUDFont.terminal(16))
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
            .frame(maxHeight: 90)
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
            return String(format: "VERIFY %02d:%02d", seconds / 60, seconds % 60)
        }
        guard job.isActive, job.rate > 0.1 else { return "ETA --:--" }
        let seconds = Int(Double(job.totalBytes - job.transferred) / (job.rate * 1e6))
        return seconds >= 3600
            ? String(format: "ETA %d:%02d:%02d", seconds / 3600, seconds % 3600 / 60, seconds % 60)
            : String(format: "ETA %02d:%02d", seconds / 60, seconds % 60)
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
