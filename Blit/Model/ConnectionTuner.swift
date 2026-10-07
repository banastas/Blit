// Connection auto-tune (PRD R3.2): how many connections a server's downloads
// should use, measured rather than guessed. Run from the server editor
// (Measure…), never on its own: it reads a large file in the server's start
// folder with 1, 2, 3 and 4 connections, ten seconds each, every stream from
// a part of the file no other stream reads (so no pass gets another's cache),
// counting bytes after a two-second warm-up. The fewest connections within 5%
// of the fastest are kept; the Link panel says "TUNED". Nothing it reads is kept.

import BlitRemote
import BlitSFTP
import Foundation

/// A measurement's result, kept with the server.
struct ConnectionTuning: Codable, Hashable, Sendable {
    var date: Date
    /// MB/s by connection count (a count that failed is missing).
    var rates: [Int: Double]
    var chosen: Int
    /// The file it read, for the editor ("…/Show.S01E01.mkv").
    var file: String
}

enum ConnectionTuner {
    static let counts = [1, 2, 3, 4]

    /// The fewest connections within 5% of the fastest.
    static func choose(_ rates: [Int: Double]) -> Int? {
        guard let best = rates.values.max(), best > 0 else { return nil }
        return rates.filter { $0.value >= best * 0.95 }.keys.min()
    }

    /// Measures each count in turn (`measure` gives MB/s); a count that fails
    /// is left out (a server may refuse more logins), and the rest decide.
    @MainActor
    static func run(counts: [Int] = counts, file: String, measure: (Int) async throws -> Double,
                    progress: (Int, Result<Double, Error>) -> Void) async -> ConnectionTuning? {
        var rates: [Int: Double] = [:]
        for count in counts {
            if Task.isCancelled { return nil }
            do {
                let rate = try await measure(count)
                rates[count] = rate
                progress(count, .success(rate))
            } catch {
                progress(count, .failure(error))
            }
        }
        guard let chosen = choose(rates) else { return nil }
        return ConnectionTuning(date: Date(), rates: rates, chosen: chosen, file: file)
    }

    // MARK: The file

    /// The largest file in the start folder, or one level down (a release
    /// folder), if it's big enough to give every stream its own 200 MB: nil if not.
    static func testFile(on server: ServerConfig, using client: SFTPClient) async throws -> (path: RemotePath, size: UInt64)? {
        let start = RemotePath(bytes: Array(server.startPath.utf8))
        let root = server.startPath.isEmpty ? RemotePath(".") : start
        var best: (path: RemotePath, size: UInt64)?
        func consider(_ folder: RemotePath, depth: Int) async throws {
            var folders: [RemotePath] = []
            for entry in try await client.list(folder) where entry.filename.bytes.first != UInt8(ascii: ".") {
                let path = folder.appending(entry.filename)
                if entry.attributes.isRegularFile, let size = entry.attributes.size, size > (best?.size ?? 0) {
                    best = (path, size)
                } else if entry.attributes.isDirectory, depth == 0 {
                    folders.append(path)
                }
            }
            for folder in folders.prefix(25) { try await consider(folder, depth: 1) }
        }
        try await consider(root, depth: 0)
        guard let best, best.size >= minimumSize else { return nil }
        return best
    }

    /// Every stream of every pass gets its own part of the file.
    static var streams: Int { counts.reduce(0, +) }
    static let minimumSize: UInt64 = UInt64(streams) * 200_000_000

    // MARK: Measuring

    /// MB/s with `count` connections, each reading its own part of `file`
    /// (parts `first`…`first + count - 1` of `streams`) for `seconds`, into
    /// /dev/null.
    static func measure(_ count: Int, file: RemotePath, size: UInt64, firstPart first: Int, server: ServerConfig,
                        verifier: any HostKeyVerifier, seconds: Double = 10, warmUp: Double = 2) async throws -> Double {
        let credential = try await MainActor.run { try server.credential() }
        let endpoint = server.endpoint
        let part = size / UInt64(streams)
        var connections: [SSHConnection] = []
        var clients: [SFTPClient] = []
        do {
            for i in 0..<count {
                let connection = try await SSHConnection.connect(to: endpoint, credential: credential, verifier: verifier)
                connections.append(connection)
                clients.append(try await SFTPClient.open(on: connection))
                if i < count - 1 { try await Task.sleep(for: .milliseconds(250)) }
            }
        } catch {
            for connection in connections { await connection.close() }
            throw error
        }
        let counter = ByteCounter()
        let finish = FirstFinish()
        let readers = try clients.enumerated().map { index, client in
            let sink = try PartFile.create(at: "/dev/null", size: 0)
            let start = UInt64(first + index) * part
            return Task {
                defer { sink.close() }
                _ = try? await client.download(file, range: start..<(start + part), into: sink) { counter.add($0) }
                await finish.mark()
            }
        }
        // The window: after the warm-up, until the time's up or a stream runs
        // out of its part (from then on fewer streams would be reading).
        try? await Task.sleep(for: .seconds(warmUp))
        let early = await finish.at != nil
        let atWarmUp = counter.total, measured = Date()
        var moved = 0
        while !early, Date().timeIntervalSince(measured) < seconds, await finish.at == nil {
            try? await Task.sleep(for: .milliseconds(200))
            moved = counter.total - atWarmUp
        }
        let elapsed = Date().timeIntervalSince(measured)
        // Closing the connections ends the reads.
        for connection in connections { await connection.close() }
        for reader in readers { _ = await reader.result }
        guard !early, elapsed >= 2 else { throw TuneError.fileTooSmall }
        return Double(moved) / elapsed / 1e6
    }

    enum TuneError: LocalizedError {
        case fileTooSmall
        var errorDescription: String? { "The file ran out before the measurement did: a larger one is needed" }
    }
}

/// When the first of a pass's streams stopped.
private actor FirstFinish {
    private(set) var at: Date?
    func mark() { if at == nil { at = Date() } }
}
