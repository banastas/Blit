// Keeping NAS shares on the cable (PRD R1.7). macOS keeps a share's connection
// on the interface it was made on: a share that connected, or reconnected
// after a drop, while only Wi-Fi was up stays on Wi-Fi once the cable is back,
// though new connections take the cable. Before a transfer reads or writes
// such a share, Blit ejects and remounts it so it comes back over the cable,
// when that's safe: no other transfer is using it, nothing else has a file
// open on it (a normal eject refuses), and its password is saved in the
// Keychain, so the remount can't stop at a password prompt. Otherwise the HUD
// says why it stayed. Found when a laptop's copy to the NAS crawled at
// 0–9 MB/s with a gigabit cable plugged in.

import AppKit
import BlitLocal
import Foundation

/// How the check looks at and reconnects shares. A test copy swaps in
/// stand-ins, so no real share is ejected.
@MainActor
struct ShareTools {
    /// The SMB shares (mount points) these paths are on.
    var mounts: ([String]) -> [String]
    /// A share's live connection (runs two tools, off the main thread).
    var connection: (String) async -> SMBConnection?
    /// The mounted SMB shares Blit can remount, with the server each is connected to.
    var known: () async -> [(mountPoint: String, server: String)]
    /// Blit knows the share's smb:// address, so it can mount it again.
    var canRemount: (String) -> Bool
    var hasSavedPassword: (String) -> Bool
    /// nil once ejected, else why not.
    var eject: (String) async -> String?
    /// nil once mounted again in the same place, else the problem.
    var remount: (String) async -> String?

    static let live = ShareTools(
        mounts: { paths in
            Array(Set(paths.compactMap { MountInfo.containing($0) }.filter(\.isSMB).map(\.mountPoint))).sorted()
        },
        connection: { mountPoint in
            await Task.detached { SMBConnection.of(mountPoint: mountPoint) }.value
        },
        known: {
            let shares = MountInfo.all().filter { $0.isSMB && ShareMounter.isKnown($0.mountPoint) }.map(\.mountPoint)
            return await Task.detached {
                shares.compactMap { share in SMBConnection.server(ofMountPoint: share).map { (share, $0.server) } }
            }.value
        },
        canRemount: { ShareMounter.isKnown($0) },
        hasSavedPassword: { ShareMounter.hasSavedPassword($0) },
        eject: { await ShareMounter.eject($0) },
        remount: { await ShareMounter.reconnect($0) })
}

extension TransferJob {
    /// Whether a pane showing `pane` shows this transfer: it's the
    /// destination or a source, or inside one (where files are landing or
    /// coming from), or the folder one sits in (it's a row there). By the
    /// paths alone: the HUD and the tab bar ask as they redraw.
    func touches(_ pane: BrowseLocation) -> Bool {
        guard !isOperation else { return false }
        let ends = [BrowseLocation.local(destination)] + sources
        return ends.contains { FileOperations.location($0, textuallyContains: pane) }
            || ends.compactMap(\.parent).contains { FileOperations.same($0, pane) }
    }

    /// Whether this transfer reads or writes on the share mounted at `mountPoint`.
    func uses(_ mountPoint: String) -> Bool {
        ([destination.path] + sources.compactMap { $0.localURL?.path }).contains { path in
            let path = LexicalPath.normalize(path)
            return path == mountPoint || path.hasPrefix(mountPoint + "/")
        }
    }
}

extension TransferManager {
    /// Before `job` reads or writes NAS shares: moves any share stuck on Wi-Fi
    /// to the cable when that's safe, and says which link each runs over.
    /// Returns the LINK label: the destination share's ("SMB · EN7"), or a
    /// source share's when the destination isn't one. Checks run one at a
    /// time, so transfers starting together don't count each other as using a
    /// share, or eject it twice.
    @discardableResult
    func keepSharesOnCable(_ job: TransferJob) async -> String? {
        job.sharesChecked = false
        let previous = shareCheckTail
        let check = Task { @MainActor [weak self] () -> String? in
            await previous?.value
            return await self?.checkShares(job)
        }
        shareCheckTail = Task { _ = await check.value }
        let label = await check.value
        job.sharesChecked = true
        return label
    }

    private func checkShares(_ job: TransferJob) async -> String? {
        let paths = [job.destination.path] + job.sources.compactMap { $0.localURL?.path }
        let destinationShares = shareTools.mounts([job.destination.path])
        job.routeWarning = nil
        job.wifiShares = []
        var label: String?
        for mountPoint in shareTools.mounts(paths) {
            guard var connection = await shareTools.connection(mountPoint) else { continue }
            if connection.reconnectMovesToWired {
                switch await moveToCable(mountPoint, connection, for: job) {
                case .left: break
                case .moved(let now): connection = now
                case .gone: continue   // the transfer waits for it, and says so
                }
            } else if connection.isWiFi, connection.fresh?.wifiDespiteWired == true {
                job.note("✕ \(Self.shareName(mountPoint)) IS ON WI-FI (\(connection.interface.uppercased())) AND THE CABLE ISN'T ON THE NAS'S NETWORK · SEE PRD R1.7",
                         failure: true)
            }
            if connection.isWiFi, !connection.isMultichannel, connection.fresh?.activeWired.isEmpty == false {
                job.routeWarning = "Wi-Fi (\(connection.interface)) while wired is up"
                job.wifiShares.insert(mountPoint)
            }
            if label == nil || destinationShares.contains(mountPoint) {
                label = "SMB · \(connection.interface.uppercased())"
            }
        }
        return label
    }

    private enum CableMove { case left, moved(SMBConnection), gone }

    /// Ejects and remounts the share, with any other share connected to the
    /// same NAS (they share the connection), so it reconnects over the cable.
    private func moveToCable(_ mountPoint: String, _ connection: SMBConnection, for job: TransferJob) async -> CableMove {
        let name = Self.shareName(mountPoint)
        func stay(_ reason: String) -> CableMove {
            job.note("✕ \(name) IS ON WI-FI (\(connection.interface.uppercased())) THOUGH THE CABLE REACHES THE NAS · LEFT AS IS: \(reason)",
                     failure: true)
            return .left
        }
        // A link that keeps dropping back to Wi-Fi isn't ejected over and over.
        if let last = lastCableReconnect[connection.server], Date().timeIntervalSince(last) < 600 {
            return stay("IT WAS RECONNECTED \(max(1, Int(Date().timeIntervalSince(last) / 60))) MIN AGO")
        }
        guard shareTools.canRemount(mountPoint) else { return stay("BLIT HASN'T SEEN HOW IT WAS CONNECTED") }
        let siblings = await shareTools.known().filter { SMBConnection.sameAddress($0.server, connection.server) }.map(\.mountPoint)
        let shares = siblings.contains(mountPoint) ? siblings : [mountPoint] + siblings
        if let other = jobs.first(where: { other in
            other !== job && other.isActive && other.sharesChecked && shares.contains { other.uses($0) }
        }) {
            return stay("ANOTHER TRANSFER IS USING IT (\(other.title.uppercased()))")
        }
        if let locked = shares.first(where: { !shareTools.hasSavedPassword($0) }) {
            return stay("MACOS HAS NO SAVED PASSWORD FOR \(Self.shareName(locked)) · CONNECT IT IN FINDER AND CHOOSE REMEMBER THIS PASSWORD")
        }
        let others = shares.filter { $0 != mountPoint }.map(Self.shareName)
        job.note("\(name) IS ON WI-FI (\(connection.interface.uppercased())) THOUGH THE CABLE REACHES THE NAS · RECONNECTING IT"
                 + (others.isEmpty ? "" : " WITH \(others.joined(separator: ", ")) (SAME NAS)"))
        lastCableReconnect[connection.server] = Date()
        var ejected: [String] = []
        for share in shares {
            if let problem = await shareTools.eject(share) {
                // Put back what was already ejected: the share stays on Wi-Fi.
                for back in ejected { _ = await shareTools.remount(back) }
                return stay("COULDN'T EJECT \(Self.shareName(share)) · \(problem.uppercased())")
            }
            ejected.append(share)
        }
        for share in shares {
            if let problem = await shareTools.remount(share) { job.note("✕ \(problem.uppercased())", failure: true) }
        }
        guard let after = await shareTools.connection(mountPoint) else {
            job.note("✕ \(name) DIDN'T COME BACK YET · THE TRANSFER WAITS FOR IT", failure: true)
            return .gone
        }
        if after.isWiFi {
            job.note("✕ \(name) CAME BACK ON WI-FI (\(after.interface.uppercased()))", failure: true)
        } else {
            job.note("RECONNECTED \(name) · NOW OVER \(after.interface.uppercased())")
        }
        return .moved(after)
    }

    /// While `job` runs, every 30 s: which link its shares are on, so the HUD
    /// stays true if one falls back to Wi-Fi mid-transfer (after a drop). It's
    /// left there until this transfer ends; the next one moves it back.
    func watchShares(_ job: TransferJob, setsLink: Bool) async {
        let mounts = shareTools.mounts([job.destination.path] + job.sources.compactMap { $0.localURL?.path })
        let destinationShares = shareTools.mounts([job.destination.path])
        guard !mounts.isEmpty else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled, job.status == .running else { continue }
            for mountPoint in mounts {
                guard let connection = await shareTools.connection(mountPoint), !Task.isCancelled else { continue }
                if setsLink, destinationShares.contains(mountPoint) || destinationShares.isEmpty {
                    job.link = "SMB · \(connection.interface.uppercased())"
                }
                guard connection.isWiFi, !connection.isMultichannel, connection.fresh?.activeWired.isEmpty == false else { continue }
                job.routeWarning = "Wi-Fi (\(connection.interface)) while wired is up"
                if job.wifiShares.insert(mountPoint).inserted {
                    job.note("✕ \(Self.shareName(mountPoint)) FELL BACK TO WI-FI (\(connection.interface.uppercased())) MID-TRANSFER"
                             + (connection.reconnectMovesToWired ? " · THE NEXT TRANSFER MOVES IT BACK TO THE CABLE" : ""), failure: true)
                }
            }
        }
    }

    static func shareName(_ mountPoint: String) -> String {
        (mountPoint as NSString).lastPathComponent.uppercased()
    }
}
