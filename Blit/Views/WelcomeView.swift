// First run (PRD R2.24): a short Welcome that sets Blit up, once, on a fresh
// install (no servers, no favorites): servers (imported from Transmit or
// ForkLift, or added), the drives and NAS shares to keep as favorites, Full
// Disk Access (in place of its own first-launch sheet), and how Blit works.
// Every step can be skipped; Help › Welcome to Blit… brings it back.

import AppKit
import SwiftUI

enum Welcome {
    private static let shownKey = "welcomeShown"

    /// Whether to show it at launch: never before, nothing set up yet (an
    /// existing install never sees it), not a test copy.
    @MainActor
    static func shouldShow(servers: [ServerConfig], favorites: [Favorite]) -> Bool {
        guard !TransferManager.isIsolated else { return false }
        let decision = decide(servers: servers.count, favorites: favorites.count, shown: UserDefaults.standard.bool(forKey: shownKey))
        if decision.markShown { UserDefaults.standard.set(true, forKey: shownKey) }
        return decision.show
    }

    /// Show it on a fresh install; an install already set up is marked so it never does.
    static func decide(servers: Int, favorites: Int, shown: Bool) -> (show: Bool, markShown: Bool) {
        guard !shown else { return (false, false) }
        return servers == 0 && favorites == 0 ? (true, false) : (false, true)
    }

    @MainActor
    static func markShown() {
        guard !TransferManager.isIsolated else { return }
        UserDefaults.standard.set(true, forKey: shownKey)
    }
}

struct WelcomeView: View {
    enum Step: Int, CaseIterable {
        case welcome, servers, places, access, ready
    }

    @Environment(ServerStore.self) private var servers
    @Environment(SidebarModel.self) private var sidebar
    @Environment(\.dismiss) private var dismiss
    @State var step: Step = .welcome
    /// SFTP favorites in Transmit or ForkLift that Blit hasn't got (nil: still looking).
    @State private var importable: Int?
    @State private var importing = false
    @State private var addingServer = false
    private var access: FullDiskAccess { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.self) { item in
                    Capsule()
                        .fill(item.rawValue <= step.rawValue ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(width: item == step ? 22 : 8, height: 6)
                }
                Spacer()
                if step != .ready {
                    Button("Skip Setup") { finish() }
                        .buttonStyle(.link)
                        .help("Close this; Help › Welcome to Blit… shows it again")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Step \(step.rawValue + 1) of \(Step.allCases.count)")
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack {
                if step != .welcome {
                    Button("Back") { move(-1) }
                }
                Spacer()
                if step == .ready {
                    Button("Start Using Blit") { finish() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(step == .welcome ? "Get Started" : "Continue") { move(1) }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 560, height: 470)
        .task {
            let known = servers.servers
            let found = await Task.detached(priority: .userInitiated) { ServerImport.find() }.value
            importable = found.filter { server in !known.contains(where: server.matches) }.count
        }
        .sheet(isPresented: $importing, onDismiss: refreshImportable) { ImportServersView() }
        .sheet(isPresented: $addingServer) {
            ServerEditor(server: ServerConfig(), isNew: true) { server, password in servers.save(server, password: password) }
        }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .welcome: welcome
        case .servers: serversStep
        case .places: placesStep
        case .access: accessStep
        case .ready: readyStep
        }
    }

    private func title(_ text: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text).font(.title2.weight(.semibold))
            Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 84, height: 84)
                .accessibilityHidden(true)
            title("Welcome to Blit",
                  "Blit moves files from servers to your drives and NAS, and between them, checking every file by SHA-256 on the way.")
            Text("A few things to set up first. Each one can be skipped and done later.")
                .foregroundStyle(.secondary)
        }
    }

    private var serversStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            title("Your servers", "Blit downloads over SFTP: from a seedbox, a NAS, any server you can sign in to with SSH.")
            if let importable, importable > 0 {
                Label("Transmit or ForkLift has \(importable) SFTP favorite\(importable == 1 ? "" : "s") Blit can bring in.",
                      systemImage: "square.and.arrow.down")
            }
            HStack {
                Button("Import from Transmit or ForkLift…") { importing = true }
                    .disabled(importable == 0)
                    .help(importable == 0 ? "No SFTP favorites found in Transmit or ForkLift" : "")
                Button("Add a Server…") { addingServer = true }
            }
            if !servers.browsable.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(servers.browsable) { server in
                        Label("\(server.displayName) — \(server.username)@\(server.host)", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    private var placesStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            title("Drives and NAS shares",
                  "Favorites keep the places you use most one click away in the sidebar, and they take drops: drag files onto one to copy them there.")
            let places = sidebar.drives.filter { !$0.isInternal } + sidebar.networkShares
            if places.isEmpty {
                Text("No external drives or NAS shares are mounted right now.").foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(places) { place in
                            Toggle(isOn: favoriteBinding(place.url)) {
                                Label(place.host.map { "\(place.name) — \($0)" } ?? place.name, systemImage: place.symbol)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 190)
            }
            Button("Choose a Folder…") { chooseFolder() }
        }
    }

    private var accessStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            title("Full Disk Access", "So moving, renaming and deleting work everywhere you browse.")
            Text("macOS protects some places (iCloud Drive, Desktop, Documents, Downloads and the Trash) until you allow an app in System Settings. It can’t ask with a prompt, and without access, changes there fail with “you don’t have permission”. Drives and NAS shares don’t need it.")
                .fixedSize(horizontal: false, vertical: true)
            if access.isGranted {
                Label("Blit has Full Disk Access.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Text("Open System Settings, turn on Blit in the list (or click + and choose Blit in Applications), then come back.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open System Settings") { access.openSettings() }
            }
        }
        .onAppear { access.refresh() }
    }

    private var readyStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            title("Ready", "How Blit works, in four lines.")
            tip(PixelGlyph.check, "Every file is checked",
                "Copies are verified by SHA-256: a ✓ after a file’s name says Blit verified it, and the Transfer Log (⌥⌘L) keeps the record.")
            tip(PixelGlyph.arrow, "Two panes",
                "F5 copies and F6 moves the selection to the other pane. View › Compare Panes (⌃⌘C) shows what’s already there.")
            tip(PixelGlyph.play, "Space",
                "Previews a file; on a folder, a summary of what’s in it: size, the video’s details, the .nfo.")
            tip(PixelGlyph.down, "The strip",
                "Transfers show at the bottom of the window. Click the count for the full HUD; pause or cancel from there.")
        }
    }

    private func tip(_ glyph: PixelGlyph, _ heading: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(nsImage: glyph.image(size: 13)).foregroundStyle(.primary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(heading).fontWeight(.semibold)
                Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Actions

    private func move(_ by: Int) {
        if step == .access { access.markOffered() }
        step = Step(rawValue: step.rawValue + by) ?? step
    }

    private func finish() {
        Welcome.markShown()
        access.markOffered()
        dismiss()
    }

    private func refreshImportable() {
        let known = servers.servers
        Task {
            let found = await Task.detached(priority: .userInitiated) { ServerImport.find() }.value
            importable = found.filter { server in !known.contains(where: server.matches) }.count
        }
    }

    private func favoriteBinding(_ url: URL) -> Binding<Bool> {
        Binding(get: { sidebar.isFavorite(.local(url)) }, set: { on in
            if on {
                sidebar.addFavorite(.local(url))
            } else if let favorite = sidebar.favorites.first(where: { $0.location.localURL?.lexicalPath == url.lexicalPath }) {
                sidebar.removeFavorite(favorite)
            }
        })
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add to Favorites"
        guard panel.runModal() == .OK else { return }
        sidebar.addFavorites(panel.urls)
    }
}
