// Menu bar extra (PRD R5.7): live speed in the menu bar while transferring,
// and a panel with the condensed HUD. Optional, per the HIG (Settings).

import BlitRemote
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
        return String(format: "%.0f MB/s · %d%%", job.rate, Int((job.progress * 100).rounded(.down)))
    }
}

struct MenuBarPanel: View {
    @Environment(TransferManager.self) private var transfers
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let job = transfers.featured {
                MenuBarTransfer(job: job)
                let others = transfers.transferJobs.filter { $0 !== job && ($0.isActive || $0.status == .queued || $0.status == .paused) }
                if !others.isEmpty {
                    Text("+ \(others.count) more in the queue" + (others.contains(where: \.isActive) ? " · 1 running" : ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("No transfers").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if transfers.isKeepingAwake || transfers.queuedCount > 0 {
                footer
            }
            Divider()
            HStack {
                if let job = transfers.featured, case .waiting = job.status {
                    Button("Retry Now") { transfers.retryNow(job) }
                }
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

    /// "Keeping the Mac awake · 2 queued · 1.9 TB left · ~2 d 4 h".
    private var footer: some View {
        let totals = transfers.queueTotals
        var parts: [String] = []
        if transfers.isKeepingAwake { parts.append("Keeping the Mac awake") }
        if totals.queued > 0 { parts.append("\(totals.queued) queued") }
        if totals.bytesLeft > 0 { parts.append("\(totals.bytesLeft.formatted(.byteCount(style: .file))) left") }
        if let eta = totals.eta { parts.append(TransferJob.duration(eta)) }
        return Label(parts.joined(separator: " · "), systemImage: transfers.isKeepingAwake ? "cup.and.saucer" : "tray.full")
            .font(.caption)
            .foregroundStyle(.secondary)
            .help(transfers.isKeepingAwake
                  ? "Blit holds off idle sleep while transferring. The display can still sleep. Bytes left count jobs whose size is known."
                  : "Bytes left count jobs whose size is known.")
    }
}

/// The menu bar panel's transfer view: the condensed HUD stacked into a
/// narrow column, so nothing truncates at menu bar width.
struct MenuBarTransfer: View {
    @Environment(TransferManager.self) private var transfers
    @Environment(\.openWindow) private var openWindow
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
                // Opens the window with the full HUD, where the WARNING panel is.
                Button {
                    openWindow(id: "main")
                    NSApp.activate()
                    transfers.isExpanded = true
                } label: {
                    hudText("✕ \(job.failures.count) WARNING\(job.failures.count == 1 ? "" : "S")", glyphSize: 9)
                        .font(HUDFont.label())
                        .foregroundStyle(HUDColor.onFailure)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(HUDColor.failure)
                }
                .buttonStyle(.plain)
                .help(job.failures.joined(separator: "\n") + "\n\nClick to show the details in Blit")
                .accessibilityLabel("\(job.failures.count) warning\(job.failures.count == 1 ? "" : "s"), show details")
            }
        }
        .foregroundStyle(HUDColor.bright)
        .padding(10)
        .background(HUDColor.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(HUDColor.border, lineWidth: 0.5))
        .environment(\.colorScheme, .dark)
    }

    private var countLabel: String { job.countLabel }

    private var headline: String {
        if case .operation(let verb, _) = job.kind { return verb }
        if job.status == .paused { return "PAUSED" }
        if job.status == .cancelled { return "CANCELLED" }
        if case .waitingForSpace = job.status { return "NO SPACE" }
        if job.isVerifyingOnly { return "SHA256" }
        if job.status == .preparing { return "…" }
        if case .waiting = job.status { return "RETRY" }
        if !job.isActive {
            guard job.status == .finished else { return "FAILED" }
            return job.allAlreadyPresent ? "PRESENT" : job.failures.isEmpty ? "DONE" : "\(job.failures.count) FAILED"
        }
        return String(format: "%.1f", job.rate)
    }

    private var unit: String {
        if job.isVerifyingOnly { return job.hashRate > 0.5 ? String(format: "%.0f MB/S", job.hashRate) : "" }
        return job.isActive && !job.isOperation && job.status == .running ? "MB/S" : ""
    }

    private var detail: String {
        if job.isVerifyingOnly {
            return job.verifySecondsLeft.map { "\(TransferJob.duration($0)) LEFT" } ?? "VERIFYING"
        }
        guard job.isActive, !job.isOperation, job.rate > 0.1 else {
            return job.isOperation ? "" : TransferJob.bytes(job.totalBytes)
        }
        let seconds = Int(Double(job.totalBytes - job.transferred) / (job.rate * 1e6))
        return "ETA \(TransferJob.duration(seconds))"
    }
}

struct SettingsView: View {
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true
    @AppStorage("expandHUDOnTransfer") private var expandHUDOnTransfer = true
    @AppStorage("existsRule") private var existsRule: ExistsRule = .skipIfSameSize
    @AppStorage("notifyEachTransfer") private var notifyEachTransfer = true
    @AppStorage("verifyFiles") private var verifyFiles = "sha256"

    // Tabs, as in Finder and Mail: each pane holds a few settings and sizes to
    // fit, so nothing scrolls and the window stays small enough for any screen.
    var body: some View {
        TabView {
            pane {
                Section {
                    Toggle("Show Blit in the menu bar", isOn: $showMenuBarExtra)
                    note("Shows transfer speed while Blit is working, and keeps the transfer HUD one click away when the window is closed.")
                    Toggle("Open the full transfer HUD when a transfer starts", isOn: $expandHUDOnTransfer)
                    note("Collapse it and it stays collapsed until those transfers finish.")
                    Picker("Notifications", selection: $notifyEachTransfer) {
                        Text("When each transfer finishes").tag(true)
                        Text("When the queue finishes, and on problems").tag(false)
                    }
                    note("Problems, files that were only size-checked, and waiting for disk space always notify.")
                }
            }
            .tabItem { Label("General", systemImage: "gearshape") }

            pane {
                Section {
                    Picker("Verify files", selection: $verifyFiles) {
                        Text("SHA-256 (recommended)").tag("sha256")
                        Text("Size only (faster)").tag("sizeOnly")
                    }
                    note(verifyFiles == "sizeOnly"
                         ? "Files are checked by size only, with no hashing on the server or NAS. Moves still verify by SHA-256 before removing anything. Applies to transfers queued from now on."
                         : "Each file is checked by SHA-256 where it lands, alongside the download, before it gets its real name. Applies to transfers queued from now on.")
                    Picker("When a file already exists", selection: $existsRule) {
                        ForEach(ExistsRule.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    note(existsRule.explanation + " Applies to transfers queued from now on.")
                }
            }
            .tabItem { Label("Transfers", systemImage: "arrow.down.circle") }

            pane { UpdatesSection() }
                .tabItem { Label("Updates", systemImage: "arrow.triangle.2.circlepath") }

            if LicenseManager.shared.isEnforced {
                pane { LicenseSection() }
                    .tabItem { Label("License", systemImage: "key") }
            }
        }
        .frame(width: 480)
    }

    /// One tab: a grouped form that sizes to its content (no scrolling).
    private func pane<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        Form { content() }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// Settings › Updates: the daily check (Sparkle) and Check Now.
private struct UpdatesSection: View {
    @State private var updates = Updates.shared
    @State private var automatic = Updates.shared.checksAutomatically

    var body: some View {
        Section("Updates") {
            Toggle("Check for updates automatically", isOn: $automatic)
                .onChange(of: automatic) { _, on in updates.checksAutomatically = on }
                .disabled(!updates.isAvailable)
            HStack {
                Text(updates.isAvailable
                     ? "Blit \(Bundle.main.shortVersion). Updates come from blit.banast.as and are signed."
                     : "Updates run in released copies of Blit.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Check Now") { updates.checkNow() }
                    .disabled(!updates.canCheck)
            }
        }
    }
}

extension Bundle {
    var shortVersion: String { object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?" }
}

/// Settings › License: trial or license status, enter a key, deactivate, buy.
private struct LicenseSection: View {
    @State private var license = LicenseManager.shared
    @State private var key = ""
    @State private var problem: String?

    var body: some View {
        Section("License") {
            LabeledContent("Status") {
                Text(license.summary)
                    .foregroundStyle(license.canStartTransfers ? .primary : Color.failureText)
            }
            if let stored = license.license {
                LabeledContent("Key", value: "…" + stored.key.suffix(8))
                HStack {
                    Spacer()
                    Button("Deactivate This Mac") {
                        Task { problem = await license.deactivate() }
                    }
                    .disabled(license.isWorking)
                    .help("Frees this Mac's activation so the license can be used on another Mac")
                }
            } else {
                HStack {
                    TextField("License key", text: $key, prompt: Text("From your receipt email"))
                        .onSubmit(activate)
                    Button("Activate", action: activate)
                        .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty || license.isWorking)
                }
                HStack {
                    Text(trialNote).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Buy Blit…") { license.openBuyPage() }
                }
            }
            if license.isWorking { ProgressView().controlSize(.small) }
            if let problem {
                Text(problem).font(.caption).foregroundStyle(Color.failureText).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var trialNote: String {
        license.canStartTransfers
            ? "Everything works during the \(LicenseConfig.trialDays)-day trial."
            : "New transfers need a license. Queued ones still finish, and browsing and the log keep working."
    }

    private func activate() {
        Task {
            problem = await license.activate(key)
            if problem == nil { key = "" }
        }
    }
}
