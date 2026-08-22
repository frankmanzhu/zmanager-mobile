import QuickLook
import CryptoKit
import Network
import PhotosUI
import Security
import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum LocalSendCertificatePinning {
    static func normalize(_ value: String) -> String {
        value.filter { $0.isLetter || $0.isNumber }.uppercased()
    }

    static func fingerprint(_ trust: SecTrust) -> String? {
        guard let certificate = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first else {
            return nil
        }
        let data = SecCertificateCopyData(certificate) as Data
        return SHA256.hash(data: data).map { String(format: "%02X", $0) }.joined()
    }

    static func validate(
        _ trust: SecTrust,
        expectedFingerprint: String?,
        allowUntrusted: Bool
    ) -> String? {
        guard let actual = fingerprint(trust) else { return nil }
        if allowUntrusted {
            return actual
        }
        guard let expectedFingerprint,
              normalize(expectedFingerprint) == actual else {
            return nil
        }
        return actual
    }
}

final class LocalSendTrustDelegate: NSObject, URLSessionDelegate {
    let expectedFingerprint: String?
    let allowUntrusted: Bool
    private(set) var serverFingerprint: String?

    init(expectedFingerprint: String?, allowUntrusted: Bool) {
        self.expectedFingerprint = expectedFingerprint
        self.allowUntrusted = allowUntrusted
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard let trust = challenge.protectionSpace.serverTrust,
              let actual = LocalSendCertificatePinning.validate(
                trust,
                expectedFingerprint: expectedFingerprint,
                allowUntrusted: allowUntrusted
              ) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        serverFingerprint = actual
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

