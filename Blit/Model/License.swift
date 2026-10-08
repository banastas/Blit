// Licensing (PRD open question 12): a 7-day trial, then a license key sold
// through Lemon Squeezy. Keys are activated per Mac with Lemon Squeezy's
// public license API (no Blit server) and re-checked weekly; a Mac that
// can't reach the API stays licensed for 30 days. When the trial has ended
// (or a key is revoked), only *starting* transfers is locked: queued and
// running transfers finish, and browsing, file management and the log work.

import AppKit
import Foundation
import Observation
import Security

enum LicenseConfig {
    /// Off until launch (0.3.0): no trial clock, no Keychain writes, no License
    /// UI, and transfers are never locked. Turning it on starts each Mac's trial
    /// at its next launch.
    static let enforced = false
    /// Lemon Squeezy store and product. Keys from any other store or product
    /// are refused once these are set (nil: not checked yet).
    static let storeID: Int? = 484_060
    /// The test-mode product for now; the live product gets its own ID.
    static let productID: Int? = 1_390_732
    /// Test-mode keys (bought with test cards) only unlock debug builds.
    static var acceptsTestKeys: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }
    /// Where Buy Blit… goes: the product's Lemon Squeezy checkout. (Test mode
    /// for now; the live product gets its own link when the store goes live.)
    static let buyURL = URL(string: "https://banastas.lemonsqueezy.com/checkout/buy/1eb9b37f-ef04-4947-a7ab-ee13a6af1fc6")!
    static let trialDays = 7
    static let revalidateEvery: TimeInterval = 7 * 86_400
    static let offlineGrace: TimeInterval = 30 * 86_400
    static let api = URL(string: "https://api.lemonsqueezy.com/v1/licenses/")!
}

/// What's saved about an activated key.
struct StoredLicense: Codable, Equatable {
    var key: String
    var instanceID: String
    var email: String?
    var name: String?
    var lastValidated: Date
}

/// The Keychain in the app; memory in isolated test copies, so they can't
/// touch the real trial or license.
@MainActor
protocol LicenseStorage {
    func read(_ account: String) -> Data?
    func write(_ data: Data?, _ account: String)
}

@MainActor
final class KeychainLicenseStorage: LicenseStorage {
    private let service = "Blit License"

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func read(_ account: String) -> Data? {
        var q = query(account)
        q[kSecReturnData as String] = true
        var result: AnyObject?
        return SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess ? result as? Data : nil
    }

    func write(_ data: Data?, _ account: String) {
        SecItemDelete(query(account) as CFDictionary)
        guard let data else { return }
        var q = query(account)
        q[kSecValueData as String] = data
        SecItemAdd(q as CFDictionary, nil)
    }
}

@MainActor
final class MemoryLicenseStorage: LicenseStorage {
    var items: [String: Data] = [:]
    func read(_ account: String) -> Data? { items[account] }
    func write(_ data: Data?, _ account: String) { items[account] = data }
}

@MainActor
@Observable
final class LicenseManager {
    static let shared = LicenseManager(storage: TransferManager.isIsolated ? MemoryLicenseStorage() : KeychainLicenseStorage())

    enum State: Equatable {
        case trial(daysLeft: Int)
        case trialEnded
        case licensed(email: String?)
        /// A key the store no longer accepts (refunded, disabled, deactivated elsewhere).
        case revoked(String)
    }

    private(set) var state: State = .trial(daysLeft: LicenseConfig.trialDays)
    private(set) var isWorking = false
    @ObservationIgnored let storage: LicenseStorage
    @ObservationIgnored var now: () -> Date = Date.init

    init(storage: LicenseStorage) {
        self.storage = storage
        if LicenseConfig.enforced || TransferManager.isIsolated { refresh() }
    }

    /// Whether licensing is in effect (always in isolated test copies, so the
    /// license test still runs).
    var isEnforced: Bool { LicenseConfig.enforced || TransferManager.isIsolated }

    var canStartTransfers: Bool {
        guard isEnforced else { return true }
        switch state {
        case .trial, .licensed: return true
        case .trialEnded, .revoked: return false
        }
    }

    var license: StoredLicense? {
        storage.read("license").flatMap { try? JSONDecoder().decode(StoredLicense.self, from: $0) }
    }

    /// When the trial began: the first launch that looked (kept in the Keychain,
    /// so reinstalling doesn't restart it).
    var trialStart: Date {
        if let data = storage.read("trial-start"), let seconds = Double(String(decoding: data, as: UTF8.self)) {
            return Date(timeIntervalSince1970: seconds)
        }
        let start = now()
        storage.write(Data(String(start.timeIntervalSince1970).utf8), "trial-start")
        return start
    }

    static func trialState(start: Date, now: Date) -> State {
        let elapsedDays = Int(max(0, now.timeIntervalSince(start)) / 86_400)
        let left = LicenseConfig.trialDays - elapsedDays
        return left > 0 ? .trial(daysLeft: left) : .trialEnded
    }

    func refresh() {
        guard isEnforced else { return }
        if let license {
            // Unchecked for the weekly interval plus the grace period: ask to
            // reconnect. The key stays; the next successful check restores it.
            if now().timeIntervalSince(license.lastValidated) > LicenseConfig.revalidateEvery + LicenseConfig.offlineGrace {
                state = .revoked("Blit hasn't been able to check your license for over a month. Connect to the internet and it'll check again.")
            } else {
                state = .licensed(email: license.email)
            }
        } else if case .revoked = state {
            return
        } else {
            state = Self.trialState(start: trialStart, now: now())
        }
    }

    // MARK: Lemon Squeezy

    struct APIResponse: Decodable {
        var activated: Bool?
        var valid: Bool?
        var deactivated: Bool?
        var error: String?
        var license_key: Key?
        var instance: Instance?
        var meta: Meta?
        struct Key: Decodable { var status: String?; var key: String?; var test_mode: Bool? }
        struct Instance: Decodable { var id: String }
        struct Meta: Decodable {
            var store_id: Int?
            var product_id: Int?
            var customer_name: String?
            var customer_email: String?
        }
    }

    /// Why a response isn't a usable Blit license, or nil if it is.
    static func mismatch(_ response: APIResponse) -> String? {
        if response.license_key?.test_mode == true, !LicenseConfig.acceptsTestKeys { return "This is a test key; it can't unlock Blit." }
        return mismatch(response.meta)
    }

    static func mismatch(_ meta: APIResponse.Meta?) -> String? {
        if let store = LicenseConfig.storeID, meta?.store_id != store { return "This key isn't for Blit." }
        if let product = LicenseConfig.productID, meta?.product_id != product { return "This key isn't for Blit." }
        return nil
    }

    private func call(_ endpoint: String, _ fields: [String: String]) async throws -> APIResponse {
        var request = URLRequest(url: LicenseConfig.api.appendingPathComponent(endpoint))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+")
        request.httpBody = fields.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").data(using: .utf8)
        request.timeoutInterval = 20
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(APIResponse.self, from: data)
    }

    /// Activates `key` on this Mac. Returns a problem to show, or nil on success.
    func activate(_ rawKey: String, instanceName: String? = nil) async -> String? {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return "Enter your license key." }
        isWorking = true
        defer { isWorking = false }
        let name = instanceName ?? Host.current().localizedName ?? "Mac"
        do {
            let response = try await call("activate", ["license_key": key, "instance_name": name])
            guard response.activated == true, let instance = response.instance else {
                return Self.explain(response.error)
            }
            if let problem = Self.mismatch(response) {
                _ = try? await call("deactivate", ["license_key": key, "instance_id": instance.id])
                return problem
            }
            let stored = StoredLicense(key: key, instanceID: instance.id, email: response.meta?.customer_email,
                                       name: response.meta?.customer_name, lastValidated: now())
            storage.write(try? JSONEncoder().encode(stored), "license")
            state = .licensed(email: stored.email)
            return nil
        } catch {
            return "Couldn't reach the license server (\(FileOperations.describe(error))). Check your connection and try again."
        }
    }

    /// Frees this Mac's activation (to move the license to another Mac).
    func deactivate() async -> String? {
        guard let license else { return nil }
        isWorking = true
        defer { isWorking = false }
        do {
            let response = try await call("deactivate", ["license_key": license.key, "instance_id": license.instanceID])
            if response.deactivated != true, let error = response.error { return Self.explain(error) }
        } catch {
            return "Couldn't reach the license server (\(FileOperations.describe(error))). Try again when you're online."
        }
        storage.write(nil, "license")
        state = Self.trialState(start: trialStart, now: now())
        return nil
    }

    /// Re-checks an activated key once a week. Offline is fine within the
    /// grace period; only an answer from the store that the key is no longer
    /// valid revokes it.
    func revalidateIfDue() async {
        guard isEnforced, var license, now().timeIntervalSince(license.lastValidated) >= LicenseConfig.revalidateEvery else { return }
        guard let response = try? await call("validate", ["license_key": license.key, "instance_id": license.instanceID]) else {
            return   // offline or the API is down: keep going (within the grace period, see refresh)
        }
        if response.valid == true, Self.mismatch(response) == nil {
            license.lastValidated = now()
            storage.write(try? JSONEncoder().encode(license), "license")
            state = .licensed(email: license.email)
        } else {
            storage.write(nil, "license")
            state = .revoked(Self.explain(response.error ?? "The license is no longer active."))
        }
    }

    /// Lemon Squeezy's messages, said plainly.
    static func explain(_ error: String?) -> String {
        guard let error, !error.isEmpty else { return "The key couldn't be activated." }
        let e = error.lowercased()
        if e.contains("not found") { return "That license key wasn't found. Check it against your receipt email." }
        if e.contains("activation limit") { return "This key is already active on its maximum number of Macs. Deactivate it on another Mac first (Settings › License)." }
        if e.contains("disabled") || e.contains("expired") { return "This license key is no longer active." }
        return error
    }

    // MARK: Messages

    /// Shown in the strip when a transfer can't start.
    var lockedMessage: String {
        switch state {
        case .revoked(let why): "\(why) Buy Blit or enter another key in Settings › License to start new transfers. Transfers already queued still finish."
        default: "Blit's \(LicenseConfig.trialDays)-day trial has ended. Buy Blit or enter your license key in Settings › License to start new transfers. Transfers already queued still finish."
        }
    }

    var summary: String {
        switch state {
        case .trial(let days): "Trial: \(days) day\(days == 1 ? "" : "s") left"
        case .trialEnded: "Trial ended"
        case .licensed(let email): email.map { "Licensed to \($0)" } ?? "Licensed"
        case .revoked(let why): why
        }
    }

    func openBuyPage() { NSWorkspace.shared.open(LicenseConfig.buyURL) }
}
