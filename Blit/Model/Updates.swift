// Automatic updates (Sparkle): Blit is sold outside the Mac App Store, so it
// checks https://blit.banast.as/appcast.xml once a day and installs signed
// updates (EdDSA key in Info.plist). Blit › Check for Updates… checks now;
// Settings turns the daily check off. Only release builds run the updater, so
// debug builds and test copies never offer to replace themselves.

import Foundation
import Observation
import Sparkle

@MainActor
@Observable
final class Updates {
    static let shared = Updates()

    @ObservationIgnored private let controller: SPUStandardUpdaterController?
    private(set) var canCheck = false
    @ObservationIgnored private var observation: NSKeyValueObservation?

    private init() {
        #if DEBUG
        controller = nil
        #else
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        #endif
        observation = controller?.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { updater, _ in
            let can = updater.canCheckForUpdates
            Task { @MainActor in Updates.shared.canCheck = can }
        }
    }

    var isAvailable: Bool { controller != nil }

    func checkNow() { controller?.checkForUpdates(nil) }

    var checksAutomatically: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }
}
