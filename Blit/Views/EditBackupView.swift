// Back Up Edits (PRD R2.26): which edit files would go to the NAS, shoot by
// shoot, before anything is copied. Asks once for the NAS folder that holds
// the camera folders.

import AppKit
import SwiftUI

struct EditBackupView: View {
    let folders: [URL]
    let browser: BrowserModel
    @Environment(TransferManager.self) private var transfers
    @Environment(\.dismiss) private var dismiss
    @State private var nas = PhotoSettings.nasPhotos
    @State private var shoots: [EditBackupShoot]?
    @State private var checked = 0
    @State private var scan: Task<Void, Never>?

    private var toBackUp: Int { shoots?.reduce(0) { $0 + $1.toBackUp } ?? 0 }
    private var shootsToBackUp: Int { shoots?.filter { $0.toBackUp > 0 }.count ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(folders.count == 1 ? "Back Up Edits of “\(folders[0].lastPathComponent)”" : "Back Up Edits of \(folders.count) Shoots")
                .font(.headline)
            Text("Copies each edit file (.dop, .xmp) to the NAS next to its photo, where it's missing or older, and verifies it. Photos aren't copied, and nothing on the NAS is deleted.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("NAS photos folder:").foregroundStyle(.secondary)
                Text(nas.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "not chosen")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button(nas == nil ? "Choose…" : "Change…") { chooseNAS() }
            }
            .font(.callout)
            content
            HStack {
                if let shoots, !shoots.isEmpty {
                    Text(summary(shoots)).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { scan?.cancel(); dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(toBackUp == 0 ? "Back Up" : "Back Up \(toBackUp.formatted()) Edit\(toBackUp == 1 ? "" : "s")") {
                    if let shoots, let problem = EditBackup.start(shoots, transfers: transfers) {
                        browser.report(problem, action: "BACK UP EDITS")
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(toBackUp == 0)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear(perform: check)
        .onDisappear { scan?.cancel() }
    }

    @ViewBuilder private var content: some View {
        if nas == nil {
            Text("Choose the NAS folder that holds a folder for each camera (for example Photographs › Digital, with Sony_a7Riii inside). A shoot's copy there is the folder with the same name in one of them.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        } else if let shoots {
            List(shoots) { shoot in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(shoot.name).lineLimit(1)
                        Text(detail(shoot))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .help(shoot.problem ?? "")
                    }
                    Spacer()
                    Text(shoot.toBackUp > 0 ? "\(shoot.toBackUp.formatted()) to back up" : shoot.problem != nil ? "skipped" : "up to date")
                        .foregroundStyle(shoot.toBackUp > 0 ? .primary : .secondary)
                }
                .padding(.vertical, 2)
            }
            .frame(height: min(CGFloat(max(shoots.count, 1)) * 42 + 12, 320))
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(folders.count == 1 ? "Checking…" : "Checking \(checked) of \(folders.count) shoots…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 60)
        }
    }

    /// "→ Sony_a7Riii · 3 up to date · 1 without its photo on the NAS", or why it's skipped.
    private func detail(_ shoot: EditBackupShoot) -> String {
        if let problem = shoot.problem { return problem }
        var parts: [String] = []
        if !shoot.targets.isEmpty { parts.append("→ " + shoot.targets.map(\.camera).joined(separator: ", ")) }
        if shoot.upToDate > 0 { parts.append("\(shoot.upToDate.formatted()) up to date") }
        if shoot.withoutPhoto > 0 {
            parts.append(shoot.withoutPhoto == 1 ? "1 without its photo on the NAS" : "\(shoot.withoutPhoto) without their photos on the NAS")
        }
        return parts.joined(separator: " · ")
    }

    private func summary(_ shoots: [EditBackupShoot]) -> String {
        let current = shoots.reduce(0) { $0 + $1.upToDate }
        let skipped = shoots.filter { $0.problem != nil }.count
        var parts = ["\(current.formatted()) already up to date"]
        if shootsToBackUp > 0 { parts.insert("\(shootsToBackUp) shoot\(shootsToBackUp == 1 ? "" : "s") to back up", at: 0) }
        if skipped > 0 { parts.append("\(skipped) skipped") }
        return parts.joined(separator: " · ")
    }

    private func check() {
        guard let nas else { return }
        scan?.cancel()
        shoots = nil
        checked = 0
        let folders = folders
        scan = Task {
            let result = await Task.detached(priority: .userInitiated) {
                EditBackup.plan(folders, nas: nas) { count in Task { @MainActor in checked = count } }
            }.value
            guard !Task.isCancelled else { return }
            shoots = result
        }
    }

    private func chooseNAS() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose"
        panel.message = "Choose the NAS folder that holds a folder for each camera."
        if let nas { panel.directoryURL = nas }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        PhotoSettings.nasPhotos = url
        nas = url
        check()
    }
}
