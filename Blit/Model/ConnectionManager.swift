// Live connections per server. Browsing uses one SFTP session per server,
// kept open for the life of the app: connected at launch, pinged so servers
// with idle timeouts (SFTPGo drops idle sessions after 15 minutes by default)
// don't close it, and reopened after sleep. Transfers open their own pool
// (PRD R3.2).

import AppKit
import BlitRemote
import BlitSFTP
import Foundation
import Observation

enum ConnectionState: Equatable {
    case idle, connecting, connected
    case failed(String)
}

enum ConnectionError: Error, LocalizedError {
    case noPassword

    var errorDescription: String? { "No password saved for this server." }
}

@MainActor
@Observable
final class ConnectionManager {
    private(set) var states: [UUID: ConnectionState] = [:]
    @ObservationIgnored private var browseClients: [UUID: SFTPClient] = [:]
    @ObservationIgnored private var inFlight: [UUID: Task<SFTPClient, Error>] = [:]
    @ObservationIgnored private var keepAlive: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    /// Last listing of each folder, shown instantly while a fresh one loads.
    @ObservationIgnored var listings: [BrowseLocation: [FileItem]] = [:]
    let verifier = BlitHostKeyVerifier()

    /// How often an idle browsing session sends a tiny request.
    private static let keepAliveInterval: Duration = .seconds(120)

    init() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconnectAfterWake() }
        }
    }

    /// Connects in the background to servers with a saved password, so the
    /// first click on one is instant. Never prompts.
    func warmUp(_ servers: [ServerConfig]) {
        for server in servers where Keychain.password(for: server) != nil {
            Task { _ = try? await browseClient(for: server) }
        }
    }

    /// Sessions rarely survive sleep, and a dead one can take a minute to
    /// notice; reopen the ones that were open, in the background.
    /// The network is often not back for the first seconds after waking, so
    /// each reconnect is retried a few times with growing delays.
    private func reconnectAfterWake() {
        for (id, client) in browseClients {
            keepAlive.removeValue(forKey: id)?.cancel()
            browseClients[id] = nil
            Task { await client.connection.close() }
            guard let server = servers[id] else { continue }
            Task {
                for delay in [2, 5, 15, 30] {
                    try? await Task.sleep(for: .seconds(delay))
                    guard self.servers[id] != nil, self.browseClients[id] == nil else { return }
                    if (try? await browseClient(for: server)) != nil { return }
                }
            }
        }
    }

    /// Servers seen by browseClient, for reconnecting.
    @ObservationIgnored private var servers: [UUID: ServerConfig] = [:]

    private func startKeepAlive(_ client: SFTPClient, for server: ServerConfig) {
        keepAlive[server.id]?.cancel()
        keepAlive[server.id] = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.keepAliveInterval)
                guard !Task.isCancelled else { return }
                var alive = client.connection.isActive
                if alive { alive = (try? await client.stat(RemotePath("."))) != nil }
                if !alive {
                    // It stopped answering; drop it so the next use reconnects.
                    await client.connection.close()
                    guard let self, self.browseClients[server.id] === client else { return }
                    self.browseClients[server.id] = nil
                    self.states[server.id] = .idle
                    return
                }
            }
        }
    }

    func state(_ server: ServerConfig) -> ConnectionState { states[server.id] ?? .idle }

    /// The browsing session for `server`, connecting if needed. Concurrent
    /// callers share one attempt.
    func browseClient(for server: ServerConfig) async throws -> SFTPClient {
        if let client = browseClients[server.id], client.connection.isActive { return client }
        if let pending = inFlight[server.id] { return try await pending.value }
        guard let password = Keychain.password(for: server) else { throw ConnectionError.noPassword }
        servers[server.id] = server
        states[server.id] = .connecting
        let endpoint = server.endpoint
        let verifier = self.verifier
        let task = Task {
            let connection = try await SSHConnection.connect(to: endpoint, credential: .password(password), verifier: verifier)
            return try await SFTPClient.open(on: connection)
        }
        inFlight[server.id] = task
        defer { if inFlight[server.id] == task { inFlight[server.id] = nil } }
        do {
            let client = try await task.value
            // Disconnected, edited or removed while connecting: this session is
            // for the old configuration, so don't install it.
            guard inFlight[server.id] == task else {
                await client.connection.close()
                throw CancellationError()
            }
            browseClients[server.id] = client
            states[server.id] = .connected
            startKeepAlive(client, for: server)
            return client
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if inFlight[server.id] == task { states[server.id] = .failed("\(error)") }
            throw error
        }
    }

    func disconnect(_ server: ServerConfig) {
        // An attempt still connecting is abandoned (its result is closed on arrival).
        inFlight.removeValue(forKey: server.id)?.cancel()
        keepAlive.removeValue(forKey: server.id)?.cancel()
        listings = listings.filter { $0.key.serverID != server.id }
        if let client = browseClients.removeValue(forKey: server.id) {
            Task { await client.connection.close() }
        }
        states[server.id] = .idle
    }
}
