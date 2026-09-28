// Live connections per server. Browsing uses one SFTP session per server,
// kept open for the life of the app: connected at launch, pinged so servers
// with idle timeouts (SFTPGo drops idle sessions after 15 minutes by default)
// don't close it, and reopened after sleep. Transfers open their own pool
// (PRD R3.2).

import AppKit
import BlitLocal
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
    /// Round trip and route per connected server, for the sidebar's hover.
    private(set) var links: [UUID: LinkInfo] = [:]

    struct LinkInfo: Equatable {
        var rttMilliseconds: Double?
        var interface: String?
        var wifiDespiteWired = false

        /// "148 ms · EN7", or a warning when Wi-Fi carries it while wired is up.
        var summary: String {
            var parts: [String] = []
            if let rttMilliseconds { parts.append("\(Int(rttMilliseconds.rounded())) ms") }
            if let interface { parts.append(wifiDespiteWired ? "over Wi-Fi (\(interface)) while a wired link is up" : interface) }
            return parts.joined(separator: " · ")
        }
    }
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
        for server in servers where server.hasCredential {
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
            reconnectInBackground(server)
        }
    }

    /// Reopens a session in the background (PRD R2.14), retrying with growing
    /// delays: after a wake or a dropped link the network often needs a few
    /// seconds to come back. Stops if the server is disconnected or removed,
    /// or if something else (a click on it) already reconnected.
    private func reconnectInBackground(_ server: ServerConfig) {
        Task {
            for delay in [2, 5, 15, 30] {
                try? await Task.sleep(for: .seconds(delay))
                guard self.servers[server.id] != nil, self.browseClients[server.id] == nil else { return }
                if (try? await browseClient(for: server)) != nil { return }
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
                if alive {
                    let rtt = await TransferManager.roundTrip(client)
                    alive = rtt != nil
                    if let rtt { self?.links[server.id]?.rttMilliseconds = rtt }
                }
                if !alive {
                    // It stopped answering: drop it so the sidebar shows it
                    // disconnected, and reopen it in the background (R2.14).
                    await client.connection.close()
                    guard let self, self.browseClients[server.id] === client else { return }
                    self.browseClients[server.id] = nil
                    self.states[server.id] = .idle
                    self.reconnectInBackground(server)
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
        let credential = try server.credential()
        servers[server.id] = server
        states[server.id] = .connecting
        let endpoint = server.endpoint
        let verifier = self.verifier
        let task = Task {
            let connection = try await SSHConnection.connect(to: endpoint, credential: credential, verifier: verifier)
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
            measureLink(client, for: server)
            return client
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if inFlight[server.id] == task { states[server.id] = .failed("\(error)") }
            throw error
        }
    }

    /// Samples the round trip and route once a session opens.
    private func measureLink(_ client: SFTPClient, for server: ServerConfig) {
        let host = server.host, port = UInt16(clamping: server.port)
        Task {
            let rtt = await TransferManager.roundTrip(client)
            let path = await Task.detached { NetworkPath.to(host: host, port: port) }.value
            links[server.id] = LinkInfo(rttMilliseconds: rtt, interface: path?.interface,
                                        wifiDespiteWired: path?.wifiDespiteWired ?? false)
        }
    }

    func disconnect(_ server: ServerConfig) {
        // An attempt still connecting is abandoned (its result is closed on
        // arrival), and forgetting the server stops any background reconnect.
        inFlight.removeValue(forKey: server.id)?.cancel()
        servers[server.id] = nil
        keepAlive.removeValue(forKey: server.id)?.cancel()
        listings = listings.filter { $0.key.serverID != server.id }
        if let client = browseClients.removeValue(forKey: server.id) {
            Task { await client.connection.close() }
        }
        states[server.id] = .idle
    }
}
