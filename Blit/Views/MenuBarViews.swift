// Menu bar extra (PRD R5.7): live speed in the menu bar while transferring,
// and a panel with the condensed HUD. Optional, per the HIG (Settings).

import SwiftUI

struct MenuBarLabel: View {
    @Environment(TransferManager.self) private var transfers

    var body: some View {
        if let job = transfers.featured, job.isActive {
            HStack(spacing: 3) {
                Image(systemName: "arrow.down.circle")
                Text(rateText(job)).monospacedDigit()
            }
        } else {
            Image(systemName: "arrow.down.circle")
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
                TransferStrip(job: job)
            } else {
                Text("No transfers").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Button("Open Blit") {
                    openWindow(id: "main")
                    NSApp.activate()
                }
                Spacer()
                Button("Quit Blit") { NSApp.terminate(nil) }
            }
        }
        .padding(12)
        .frame(width: 480)
    }
}

struct SettingsView: View {
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true

    var body: some View {
        Form {
            Toggle("Show Blit in the menu bar", isOn: $showMenuBarExtra)
            Text("Shows transfer speed while Blit is working, and keeps the transfer HUD one click away when the window is closed.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 420)
    }
}
