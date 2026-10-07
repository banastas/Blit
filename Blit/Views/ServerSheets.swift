// Server editor, host-key trust prompt, and password prompt: standard sheets.

import BlitRemote
import SwiftUI

struct ServerEditor: View {
    @State var server: ServerConfig
    let isNew: Bool
    let onSave: (ServerConfig, String?) -> Void
    @State private var password = ""
    @State private var useKey = false
    @State private var keyProblem: String?
    @Environment(\.dismiss) private var dismiss

    init(server: ServerConfig, isNew: Bool, onSave: @escaping (ServerConfig, String?) -> Void) {
        _server = State(initialValue: server)
        self.isNew = isNew
        self.onSave = onSave
        _useKey = State(initialValue: server.usesKey)
    }

    private var canSave: Bool {
        guard !server.host.isEmpty, !server.username.isEmpty else { return false }
        if useKey { return server.usesKey && keyProblem == nil }
        // A new server, or one switching from a key, needs a password.
        return !password.isEmpty || !(isNew || server.usesKey)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $server.name, prompt: Text("Seedbox"))
                    TextField("Host", text: $server.host, prompt: Text("example.com"))
                    TextField("Port", value: $server.port, format: .number.grouping(.never))
                    TextField("Username", text: $server.username)
                    Picker("Sign in with", selection: $useKey) {
                        Text("Password").tag(false)
                        Text("SSH Key").tag(true)
                    }
                    if useKey {
                        LabeledContent("Key file") {
                            HStack {
                                Text(server.keyPath.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "None")
                                    .foregroundStyle(server.usesKey ? .primary : .secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Button("Choose…", action: chooseKey)
                            }
                        }
                    } else {
                        SecureField("Password", text: $password,
                                    prompt: Text(isNew || server.usesKey ? "Required" : "Unchanged"))
                    }
                } footer: {
                    Group {
                        if useKey, let keyProblem {
                            Text(keyProblem).foregroundStyle(.red)
                        } else if useKey {
                            Text("An ed25519 or ECDSA key without a passphrase. Blit reads the file each time it connects.")
                        } else {
                            Text("The password is stored in your Keychain.")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Section("Advanced") {
                    TextField("Start folder", text: $server.startPath, prompt: Text("Home folder"))
                    Stepper("Connections for transfers: \(server.connections)", value: $server.connections, in: 1...8)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add Server" : "Save") {
                    var saved = server
                    if !useKey { saved.keyPath = nil }
                    onSave(saved, useKey || password.isEmpty ? nil : password)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
            .padding()
        }
        .frame(width: 440)
        .onAppear { if let keyPath = server.keyPath { check(keyPath) } }
    }

    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.message = "Choose the private key to sign in with"
        panel.showsHiddenFiles = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/.ssh", isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        server.keyPath = (url.path as NSString).abbreviatingWithTildeInPath
        check(url.path)
    }

    /// Reads the key now, so an unsupported one is caught here, not at connect.
    private func check(_ path: String) {
        do {
            _ = try SSHKeyFile.load(path)
            keyProblem = nil
        } catch {
            keyProblem = "\(error)"
        }
    }
}

struct TrustSheet: View {
    let request: TrustRequest
    let onTrust: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Verify the server's identity", systemImage: "lock.shield")
                .font(.headline)
            Text("“\(request.server.displayName)” (\(request.server.host):\(String(request.server.port))) presented a host key Blit hasn't seen before.")
                .fixedSize(horizontal: false, vertical: true)
            GroupBox {
                VStack(alignment: .leading, spacing: 4) {
                    Text(request.presented.type).font(.caption).foregroundStyle(.secondary)
                    Text(request.presented.fingerprint)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !request.known.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Keys of other types are already trusted for this server:")
                        .font(.callout)
                    ForEach(request.known, id: \.self) { key in
                        Text("\(key.type) \(key.fingerprint)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            Text("If you can, compare the fingerprint with the one your provider publishes.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Trust and Connect") {
                    onTrust()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}

struct PasswordSheet: View {
    let server: ServerConfig
    let onSubmit: (String) -> Void
    @State private var password = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Password for \(server.displayName)", systemImage: "key")
                .font(.headline)
            Text("\(server.username)@\(server.host):\(String(server.port))")
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
            SecureField("Password", text: $password)
                .onSubmit(submit)
            Text("Saved in your Keychain.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Connect", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func submit() {
        guard !password.isEmpty else { return }
        onSubmit(password)
        dismiss()
    }
}

/// Import Servers (PRD R1.8): the SFTP favorites found in Transmit and
/// ForkLift, each ticked unless Blit has it already; the chosen ones become
/// Blit servers. Passwords stay in those apps: Blit asks on first connect.
struct ImportServersView: View {
    @Environment(ServerStore.self) private var servers
    @Environment(\.dismiss) private var dismiss
    /// Called with what was imported (the window selects the first).
    var onImported: ([ServerConfig]) -> Void = { _ in }
    @State private var found: [ImportedServer]?
    @State private var chosen: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import Servers").font(.headline)
            Text("SFTP favorites saved in Transmit and ForkLift. Passwords aren't brought over: Blit asks for each one the first time it connects.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Group {
                if let found {
                    if found.isEmpty {
                        Text("No SFTP favorites found in Transmit or ForkLift.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 80)
                    } else {
                        List(found) { server in row(server) }
                            .listStyle(.bordered(alternatesRowBackgrounds: true))
                            .frame(height: min(320, CGFloat(found.count) * 44 + 12))
                    }
                } else {
                    ProgressView("Looking…").frame(maxWidth: .infinity, minHeight: 80)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(chosen.isEmpty ? "Import" : "Import \(chosen.count) Server\(chosen.count == 1 ? "" : "s")") { importChosen() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosen.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 500)
        .task {
            let list = await Task.detached(priority: .userInitiated) { ServerImport.find() }.value
            found = list
            chosen = Set(list.filter { !inBlit($0) }.map(\.id))
        }
    }

    private func inBlit(_ server: ImportedServer) -> Bool { servers.servers.contains(where: server.matches) }

    private func row(_ server: ImportedServer) -> some View {
        let already = inBlit(server)
        return Toggle(isOn: Binding(get: { chosen.contains(server.id) },
                                    set: { if $0 { chosen.insert(server.id) } else { chosen.remove(server.id) } })) {
            VStack(alignment: .leading, spacing: 1) {
                Text(server.name)
                Text("\(server.username.isEmpty ? "" : server.username + "@")\(server.host)\(server.port == 22 ? "" : ":\(server.port)") · \(already ? "already in Blit" : "from \(server.source)")\(server.keyPath == nil ? "" : " · key file")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(already)
    }

    private func importChosen() {
        let imported = (found ?? []).filter { chosen.contains($0.id) && !inBlit($0) }.map(\.config)
        for server in imported { servers.save(server, password: nil) }
        dismiss()
        onImported(imported)
    }
}
