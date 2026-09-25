// Live connections per server. Browsing uses one SFTP session, opened on
// demand; transfers open their own pool (PRD R3.2).

import BlitRemote
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
    let verifier = BlitHostKeyVerifier()

    func state(_ server: ServerConfig) -> ConnectionState { states[server.id] ?? .idle }

    /// The browsing session for `server`, connecting if needed. Concurrent
    /// callers share one attempt.
    func browseClient(for server: ServerConfig) async throws -> SFTPClient {
        if let client = browseClients[server.id], client.connection.isActive { return client }
        if let pending = inFlight[server.id] { return try await pending.value }
        guard let password = Keychain.password(for: server) else { throw ConnectionError.noPassword }
        states[server.id] = .connecting
        let endpoint = server.endpoint
        let verifier = self.verifier
        let task = Task {
            let connection = try await SSHConnection.connect(to: endpoint, credential: .password(password), verifier: verifier)
            return try await SFTPClient.open(on: connection)
        }
        inFlight[server.id] = task
        defer { inFlight[server.id] = nil }
        do {
            let client = try await task.value
            browseClients[server.id] = client
            states[server.id] = .connected
            return client
        } catch {
            states[server.id] = .failed("\(error)")
            throw error
        }
    }

    func disconnect(_ server: ServerConfig) {
        if let client = browseClients.removeValue(forKey: server.id) {
            Task { await client.connection.close() }
        }
        states[server.id] = .idle
    }
}
