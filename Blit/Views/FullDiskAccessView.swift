// Full Disk Access (PRD R2.20): the first-launch sheet, and its row in
// Settings › General. Native, as the rest of the window: the pixel-terminal
// look stays the transfer HUD's.

import SwiftUI

/// Shown once, at first launch, while Blit doesn't have Full Disk Access.
struct FullDiskAccessSheet: View {
    @Environment(\.dismiss) private var dismiss
    private var access: FullDiskAccess { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Give Blit Full Disk Access").font(.title3.weight(.semibold))
                    Text("So moving, renaming and deleting work everywhere you browse.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("macOS protects some places (iCloud Drive, Desktop, Documents, Downloads and the Trash) until you allow an app in System Settings. It can’t ask with a prompt, and without access, changes there fail with “you don’t have permission”.")
                .fixedSize(horizontal: false, vertical: true)
            if access.isGranted {
                Label("Blit has Full Disk Access.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("1. Click Open System Settings.")
                    Text("2. Turn on Blit in the list (or click + and choose Blit in Applications).")
                    Text("3. Come back to Blit.")
                }
                .foregroundStyle(.secondary)
            }
            Text("Drives and NAS shares don’t need it: macOS asks about those the first time Blit opens one.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                if access.isGranted {
                    Button("Done", action: close).keyboardShortcut(.defaultAction)
                } else {
                    Button("Not Now", action: close).keyboardShortcut(.cancelAction)
                    Button("Open System Settings") { access.openSettings() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(22)
        .frame(width: 460)
        .onAppear { access.refresh() }
    }

    private func close() {
        access.markOffered()
        dismiss()
    }
}

/// Settings › General: whether Blit has Full Disk Access, and the way to it.
struct FullDiskAccessRow: View {
    private var access: FullDiskAccess { .shared }

    var body: some View {
        Group {
            LabeledContent("Full Disk Access") {
                if access.isGranted {
                    Label("On", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Button("Open System Settings…") { access.openSettings() }
                }
            }
            Text(access.isGranted
                 ? "Blit can move, rename and delete in every folder, iCloud Drive and the Trash included."
                 : "Needed to move, rename or delete in iCloud Drive, Desktop, Documents, Downloads and the Trash. Drives and NAS shares don’t need it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { access.refresh() }
    }
}
