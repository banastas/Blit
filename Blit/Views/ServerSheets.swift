// Server editor, host-key trust prompt, and password prompt: standard sheets.

import BlitRemote
import BlitSFTP
import SwiftUI

struct ServerEditor: View {
    @State var server: ServerConfig
    let isNew: Bool
    let onSave: (ServerConfig, String?) -> Void
    @State private var password = ""
    @State private var useKey = false
    @State private var keyProblem: String?
    @State private var measuring = false
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
                    if !isNew {
                        HStack {
                            Group {
                                if let tuning = server.tuning {
                                    Text("Measured \(tuning.date.formatted(date: .abbreviated, time: .omitted)): "
                                         + tuning.rates.keys.sorted().map { "\($0) → \(Int(tuning.rates[$0]!.rounded())) MB/s" }.joined(separator: ", ")
                                         + (server.isTuned ? "" : " (now set by hand)"))
                                } else {
                                    Text("Measure how many connections are fastest to this server.")
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Button("Measure…") { measuring = true }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .sheet(isPresented: $measuring) {
                TuneConnectionsView(server: server) { tuning in
                    server.tuning = tuning
                    server.connections = tuning.chosen
                }
            }
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
            if addsKeyType {
                Label("Blit already trusts a different key for this server. A server can add a new kind of key, "
                      + "but an attacker intercepting the connection would look exactly like this. "
                      + "Only trust it if you know the server added this key.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
                if addsKeyType {
                    // Return cancels: trusting a second key type takes a deliberate click.
                    Button("Trust New Key Type") {
                        onTrust()
                        dismiss()
                    }
                    Button("Cancel", role: .cancel) { dismiss() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel", role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Trust and Connect") {
                        onTrust()
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    /// The server already has a trusted key (of another type): it may be an interception.
    private var addsKeyType: Bool { !request.known.isEmpty }
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

/// Measure… in the server editor (PRD R3.2): 1, 2, 3 and 4 connections
/// against a large file on the server, then the count to keep.
struct TuneConnectionsView: View {
    let server: ServerConfig
    let onUse: (ConnectionTuning) -> Void
    @Environment(ConnectionManager.self) private var connections
    @Environment(\.dismiss) private var dismiss
    @State private var file: (path: RemotePath, size: UInt64)?
    @State private var problem: String?
    @State private var running = false
    @State private var results: [Int: Result<Double, Error>] = [:]
    @State private var tuning: ConnectionTuning?
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Measure Connections").font(.headline)
            Text("Blit reads the largest file in the server's start folder with 1, 2, 3 and 4 connections, ten seconds each, every stream from a different part of the file, and keeps the fewest that come within 5% of the fastest. It downloads about a minute's worth of data and keeps none of it. Best run while nothing else is transferring.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let file {
                Text("File: \(file.path.lastComponent.description) · \(Int64(file.size).formatted(.byteCount(style: .file)))")
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                ForEach(ConnectionTuner.counts, id: \.self) { count in
                    GridRow {
                        Text("\(count) connection\(count == 1 ? "" : "s")")
                        Group {
                            switch results[count] {
                            case .success(let rate)?: Text("\(Int(rate.rounded())) MB/s").monospacedDigit()
                                .fontWeight(tuning?.chosen == count ? .semibold : .regular)
                            case .failure(let error)?: Text(FileOperations.describe(error)).foregroundStyle(Color.failureText).lineLimit(1)
                            case nil: Text(running && results.count + 1 == count ? "measuring…" : "—").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            if let problem { Text(problem).foregroundStyle(Color.failureText).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Cancel") { task?.cancel(); dismiss() }
                    .keyboardShortcut(.cancelAction)
                if let tuning {
                    Button("Use \(tuning.chosen) Connection\(tuning.chosen == 1 ? "" : "s")") { onUse(tuning); dismiss() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Measure") { start() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(running)
                }
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func start() {
        running = true
        problem = nil
        results = [:]
        let verifier = connections.verifier
        task = Task {
            defer { running = false }
            do {
                let client = try await connections.browseClient(for: server)
                guard let found = try await ConnectionTuner.testFile(on: server, using: client) else {
                    problem = "No file of \(Int64(ConnectionTuner.minimumSize).formatted(.byteCount(style: .file))) or more in the start folder (or a folder in it) to read."
                    return
                }
                file = found
                var first = 0
                tuning = await ConnectionTuner.run(file: found.path.description, measure: { count in
                    defer { first += count }
                    return try await ConnectionTuner.measure(count, file: found.path, size: found.size, firstPart: first,
                                                             server: server, verifier: verifier)
                }, progress: { count, result in results[count] = result })
                if tuning == nil, !Task.isCancelled { problem = "No connection count could be measured." }
            } catch {
                problem = FileOperations.describe(error)
            }
        }
    }
}
