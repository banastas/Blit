// Links an SMB share to an SSH login on the NAS so copies are verified with
// sha256sum on the NAS itself (PRD R1.6, R4.2). Tests the login and finds
// the share's path on the NAS before saving.

import BlitLocal
import BlitRemote
import SwiftUI

struct NASVerificationSheet: View {
    let share: VolumeLocation
    let verifier: BlitHostKeyVerifier
    let onSave: (ServerConfig, String?) -> Void
    @State private var login: ServerConfig
    @State private var password = ""
    @State private var status: Status = .idle
    @Environment(\.dismiss) private var dismiss

    enum Status: Equatable {
        case idle, testing
        case trust(presented: HostKeyIdentity, known: [HostKeyIdentity])
        case failed(String)
        case found(String)
    }

    init(share: VolumeLocation, existing: ServerConfig?, verifier: BlitHostKeyVerifier,
         onSave: @escaping (ServerConfig, String?) -> Void) {
        self.share = share
        self.verifier = verifier
        self.onSave = onSave
        if let existing {
            _login = State(initialValue: existing)
        } else {
            // Prefill from the mount: //user@host._smb._tcp.local/Share
            let mount = MountInfo.of(share.url.path)
            let source = mount?.source ?? ""
            let user = source.split(separator: "@").first.map { String($0.drop { $0 == "/" }) } ?? ""
            let host = source.split(separator: "@").last?.split(separator: "/").first
                .map { String($0).replacingOccurrences(of: "._smb._tcp", with: "") } ?? ""
            var config = ServerConfig()
            config.name = "\(share.name) (NAS)"
            config.host = NetworkPath.ipv4Address(host) ?? host
            config.username = user
            config.nasMountPoint = share.url.path
            _login = State(initialValue: config)
        }
    }

    private var shareName: String { MountInfo.of(share.url.path)?.shareName ?? share.name }
    private var isNew: Bool { login.nasRoot == nil }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Text("Blit logs in to the NAS over SSH after each copy to \(share.name) and checks the file with sha256sum on the NAS's own disks. DSM needs SSH enabled and an account in the administrators group.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Section("SSH login") {
                    TextField("Host", text: $login.host)
                    TextField("Port", value: $login.port, format: .number.grouping(.never))
                    TextField("Username", text: $login.username)
                    SecureField("Password", text: $password, prompt: Text(isNew ? "Required" : "Unchanged"))
                }
                Section {
                    statusView
                }
            }
            .formStyle(.grouped)
            HStack {
                Button("Test") { Task { await test() } }
                    .disabled(login.host.isEmpty || login.username.isEmpty || (isNew && password.isEmpty) || status == .testing)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(login, password.isEmpty ? nil : password)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isFound)
            }
            .padding()
        }
        .frame(width: 460)
    }

    private var isFound: Bool {
        if case .found = status { return true }
        return false
    }

    @ViewBuilder private var statusView: some View {
        switch status {
        case .idle:
            Text("Test the login to find “\(shareName)” on the NAS.").foregroundStyle(.secondary)
        case .testing:
            HStack { ProgressView().controlSize(.small); Text("Connecting…") }
        case .found(let root):
            Label("Found \(shareName) at \(root)", systemImage: "checkmark.circle")
        case .failed(let why):
            Label(why, systemImage: "exclamationmark.triangle").foregroundStyle(Color.failureText)
        case .trust(let presented, let known):
            VStack(alignment: .leading, spacing: 6) {
                Text("The NAS presented a host key Blit hasn't seen:")
                Text("\(presented.type) \(presented.fingerprint)")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                ForEach(known, id: \.self) { key in
                    Text("Already trusted: \(key.type) \(key.fingerprint)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Button("Trust and Test Again") {
                    try? HostKeyStore().pin(presented, host: login.host, port: login.port)
                    Task { await test() }
                }
            }
        }
    }

    private func test() async {
        status = .testing
        let secret = password.isEmpty ? (Keychain.password(for: login) ?? "") : password
        do {
            let connection = try await SSHConnection.connect(to: login.endpoint, credential: .password(secret), verifier: verifier)
            defer { Task { await connection.close() } }
            if let root = try await NASVerifier.findShareRoot(shareName, on: connection) {
                login.nasRoot = root
                status = .found(root)
            } else {
                status = .failed("Logged in, but couldn't find a share named “\(shareName)” under /volume*/.")
            }
        } catch let error as SSHError {
            switch error {
            case .hostKeyRejected(_, _, let presented, let known) where !error.isChangedHostKey:
                status = .trust(presented: presented, known: known)
            case .authenticationFailed:
                status = .failed("The NAS rejected that username or password.")
            default:
                status = .failed(error.description)
            }
        } catch {
            status = .failed("\(error)")
        }
    }
}
