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
    static let failure = Color.failure
    static let onFailure = Color(red: 0x1C / 255, green: 0x0E / 255, blue: 0x0E / 255)
}

struct TransferStrip: View {
    @Environment(TransferManager.self) private var transfers
    let job: TransferJob

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                Button {
                    transfers.isExpanded = true
                } label: {
                    Text(countLabel)
                        .font(HUDFont.label())
                        .foregroundStyle(HUDColor.bright)
                        .fixedSize()
                }
                .buttonStyle(.plain)
                .help("Show the full transfer HUD")
                HStack(spacing: 8) {
                    Text(job.title.uppercased())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("→ \(job.destinationName.uppercased())")
                        .foregroundStyle(HUDColor.dim)
                        .lineLimit(1)
                        .fixedSize()
                }
                .font(HUDFont.terminal(18))
                .frame(minWidth: 80, maxWidth: .infinity, alignment: .leading)
                PixelCells(fraction: job.progress, count: 24)
                Text("\(Int((job.progress * 100).rounded()))%")
                    .font(HUDFont.terminal(18))
                    .frame(width: 38, alignment: .trailing)
                separator
                if job.failures.isEmpty {
                    PixelHistogram(samples: Array(job.history.suffix(30)), scale: max(job.peakRate, 1))
                        .frame(width: 60, height: 20)
                } else {
                    Text("✕ \(job.failures.count) WARNING\(job.failures.count == 1 ? "" : "S")")
                        .font(HUDFont.label())
                        .foregroundStyle(HUDColor.onFailure)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(HUDColor.failure)
                        .fixedSize()
                        .help(job.failures.joined(separator: "\n"))
                }
                rate
                separator
                VStack(alignment: .trailing, spacing: 2) {
                    HStack(spacing: 3) {
                        ForEach(0..<max(job.connections, 0), id: \.self) { _ in
                            Rectangle().fill(job.isActive ? HUDColor.bright : HUDColor.dim).frame(width: 5, height: 5)
                        }
                    }
                    Text(job.link).font(HUDFont.label()).foregroundStyle(HUDColor.dim).fixedSize()
                }
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
            Rectangle()
                .fill(.clear)
                .frame(height: 1)
                .overlay(Rectangle().stroke(style: StrokeStyle(lineWidth: 1, dash: [3, 3])).foregroundStyle(HUDColor.off))
            logLine
                .font(HUDFont.terminal(15))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(HUDColor.bright)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 7)
        .background(HUDColor.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(HUDColor.border, lineWidth: 0.5))
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .combine)
    }

    private var separator: some View {
        Rectangle().fill(HUDColor.border).frame(width: 1, height: 18)
    }

    private var countLabel: String {
        let arrow = job.isActive ? "▲" : (job.status == .finished ? "✓" : "✕")
        guard job.fileCount > 0 else { return "\(arrow) --/--" }
        let width = max(2, String(job.fileCount).count)
        let done = String(job.filesFinished).leftPadded(width)
        return "\(arrow) \(done)/\(String(job.fileCount).leftPadded(width))"
    }

    /// All bytes are in and files are waiting on their checksums.
    private var isVerifyingOnly: Bool {
        job.isActive && !job.verifying.isEmpty && job.transferred >= job.totalBytes
    }

    @ViewBuilder private var rate: some View {
        if isVerifyingOnly {
            Text("SHA256")
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
        if job.status == .preparing {
            Text("PREPARING · LISTING FILES…").foregroundStyle(HUDColor.dim)
        } else if !job.isActive, job.status != .queued {
            let queued = transfers.queuedCount
            Text(summary + (queued > 0 ? " · \(queued) QUEUED" : ""))
                .foregroundStyle(job.failures.isEmpty ? HUDColor.bright : Color(red: 0xC9 / 255, green: 0x80 / 255, blue: 0x80 / 255))
        } else if isVerifyingOnly, let (name, since) = job.verifying.min(by: { $0.value < $1.value }) {
            // Verification can take minutes on big files; show it's alive (elapsed time).
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let elapsed = Int(context.date.timeIntervalSince(since))
                let others = job.verifying.count - 1
                Text("VERIFYING \(name.uppercased())\(others > 0 ? " +\(others)" : "") · \(job.verificationMethod) · \(elapsed / 60):\(String(format: "%02d", elapsed % 60))")
                    .foregroundStyle(HUDColor.bright)
            }
        } else if let last = job.log.last {
            Text("\(last.time.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))) \(last.text)")
                .foregroundStyle(last.isFailure ? Color(red: 0xC9 / 255, green: 0x80 / 255, blue: 0x80 / 255) : HUDColor.dim)
        }
    }

    private var summary: String {
        let verified = "\(job.filesVerified)/\(job.fileCount) VERIFIED"
        let size = TransferJob.bytes(job.totalBytes)
        if case .failed(let why) = job.status, job.fileCount == 0 { return "✕ \(why.uppercased())" }
        return "\(job.failures.isEmpty ? "✓" : "✕") \(verified) · \(size) → \(job.destinationName.uppercased())"
            + (job.filesAlreadyPresent > 0 ? " · \(job.filesAlreadyPresent) ALREADY THERE" : "")
            + (job.failures.isEmpty ? "" : " · \(job.failures.count) FAILED")
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
        .accessibilityLabel("\(Int(fraction * 100)) percent")
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
    }
}

extension String {
    func leftPadded(_ width: Int) -> String { count >= width ? self : String(repeating: "0", count: width - count) + self }
}
