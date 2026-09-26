// Menu bar extra (PRD R5.7): live speed in the menu bar while transferring,
// and a panel with the condensed HUD. Optional, per the HIG (Settings).

import SwiftUI

struct MenuBarLabel: View {
    @Environment(TransferManager.self) private var transfers
    /// Animation frame for the pixel arrow's marching stem.
    @State private var frame = 0

    var body: some View {
        label
    }

    @ViewBuilder private var label: some View {
        if let job = transfers.featured, job.isActive, !job.isOperation {
            HStack(spacing: 4) {
                Image(nsImage: PixelArt.image(PixelArt.menuBarArrow(frame: frame), cell: 1.5))
                Text(rateText(job)).monospacedDigit()
            }
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(160))
                    frame = (frame + 1) % 3
                }
            }
        } else {
            Image(nsImage: PixelArt.image(PixelArt.menuBarArrow(frame: nil), cell: 1.5))
        }
    }

    private func rateText(_ job: TransferJob) -> String {
        if !job.verifying.isEmpty, job.transferred >= job.totalBytes { return "SHA256" }
        if job.status == .preparing { return "…" }
        if case .waiting = job.status { return "RETRY" }
        return String(format: "%.0f MB/s", job.rate)
    }
}

struct MenuBarPanel: View {
    @Environment(TransferManager.self) private var transfers
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let job = transfers.featured {
                MenuBarTransfer(job: job)
            } else {
                Text("No transfers").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                if transfers.hasActiveWork || transfers.queuePaused {
                    Button(transfers.queuePaused ? "Resume All" : "Pause All") {
                        transfers.queuePaused ? transfers.resumeAll() : transfers.pauseAll()
                    }
                }
                Button("Open Blit") {
                    openWindow(id: "main")
                    NSApp.activate()
                }
                Spacer()
                Button("Quit Blit") { NSApp.terminate(nil) }
            }
        }
        .padding(12)
        .frame(width: 320)
    }
}

/// The menu bar panel's transfer view: the condensed HUD stacked into a
/// narrow column, so nothing truncates at menu bar width.
struct MenuBarTransfer: View {
    let job: TransferJob

    var body: some View {
        let verifying = job.isVerifyingOnly
        let fraction = verifying ? (job.verifyProgress ?? job.progress) : job.progress
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                hudText(countLabel, glyphSize: 9)
                    .font(HUDFont.label())
                    .fixedSize()
                Text(job.title.uppercased())
                    .font(HUDFont.terminal(17))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            hudText("→ \(job.destinationName.uppercased())", glyphSize: 11)
                .font(HUDFont.terminal(15))
                .foregroundStyle(HUDColor.dim)
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: 8) {
                GeometryReader { geo in
                    PixelCells(fraction: fraction, count: max(12, Int(geo.size.width / 6)))
                }
                .frame(height: 10)
                Text("\(Int((fraction * 100).rounded()))%")
                    .font(HUDFont.terminal(17))
                    .frame(width: 40, alignment: .trailing)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(headline).font(HUDFont.terminal(24))
                Text(unit).font(HUDFont.terminal(13)).foregroundStyle(HUDColor.dim)
                Spacer()
                Text(detail).font(HUDFont.terminal(15)).foregroundStyle(HUDColor.dim)
            }
            if !job.failures.isEmpty {
                hudText("✕ \(job.failures.count) WARNING\(job.failures.count == 1 ? "" : "S")", glyphSize: 9)
                    .font(HUDFont.label())
                    .foregroundStyle(HUDColor.onFailure)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(HUDColor.failure)
            }
        }
        .foregroundStyle(HUDColor.bright)
        .padding(10)
        .background(HUDColor.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(HUDColor.border, lineWidth: 0.5))
        .environment(\.colorScheme, .dark)
    }

    private var countLabel: String {
        let arrow = job.isActive ? "▲" : (job.status == .finished ? (job.allAlreadyPresent ? "=" : "✓") : "✕")
        return job.fileCount > 0 ? "\(arrow) \(job.filesFinished)/\(job.fileCount)" : arrow
    }

    private var headline: String {
        if case .operation(let verb, _) = job.kind { return verb }
        if job.status == .paused { return "PAUSED" }
        if job.status == .cancelled { return "CANCELLED" }
        if job.isVerifyingOnly { return "SHA256" }
        if job.status == .preparing { return "…" }
        if case .waiting = job.status { return "RETRY" }
        if !job.isActive { return job.status == .finished ? (job.allAlreadyPresent ? "PRESENT" : "DONE") : "FAILED" }
        return String(format: "%.1f", job.rate)
    }

    private var unit: String {
        if job.isVerifyingOnly { return job.hashRate > 0.5 ? String(format: "%.0f MB/S", job.hashRate) : "" }
        return job.isActive && !job.isOperation && job.status == .running ? "MB/S" : ""
    }

    private var detail: String {
        if job.isVerifyingOnly {
            return job.verifySecondsLeft.map { String(format: "~%d:%02d LEFT", $0 / 60, $0 % 60) } ?? "VERIFYING"
        }
        guard job.isActive, !job.isOperation, job.rate > 0.1 else {
            return job.isOperation ? "" : TransferJob.bytes(job.totalBytes)
        }
        let seconds = Int(Double(job.totalBytes - job.transferred) / (job.rate * 1e6))
        return String(format: "ETA %d:%02d", seconds / 60, seconds % 60)
    }
}

struct SettingsView: View {
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true
    @AppStorage("expandHUDOnTransfer") private var expandHUDOnTransfer = true

    var body: some View {
        Form {
            Toggle("Show Blit in the menu bar", isOn: $showMenuBarExtra)
            Text("Shows transfer speed while Blit is working, and keeps the transfer HUD one click away when the window is closed.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Open the full transfer HUD when a transfer starts", isOn: $expandHUDOnTransfer)
            Text("Collapse it and it stays collapsed until those transfers finish.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 420)
    }
}
