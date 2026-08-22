import QuickLook
import CryptoKit
import Network
import PhotosUI
import Security
import SwiftUI
import UIKit
import UniformTypeIdentifiers

final class LocalSendTrustStore {
    private let defaults: UserDefaults
    private let prefix = "org.tzap.zmanager.localsend.trusted."

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func isTrusted(_ device: LocalSendDevice) -> Bool {
        guard let fingerprint = device.fingerprint else { return false }
        return defaults.bool(forKey: prefix + fingerprint)
    }

    func remember(_ device: LocalSendDevice) {
        guard let fingerprint = device.fingerprint else { return }
        defaults.set(true, forKey: prefix + fingerprint)
    }

    func forget(_ device: LocalSendDevice) {
        guard let fingerprint = device.fingerprint else { return }
        forget(fingerprint: fingerprint)
    }

    func forget(fingerprint: String) {
        defaults.removeObject(forKey: prefix + fingerprint)
    }

    func fingerprints() -> [String] {
        defaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(prefix) && defaults.bool(forKey: $0) }
            .map { String($0.dropFirst(prefix.count)) }
            .sorted()
    }
}

/// LocalSend v2.2 outbound HTTP transfer subsystem. It intentionally has no
/// dependency on archive parsing or creation.
