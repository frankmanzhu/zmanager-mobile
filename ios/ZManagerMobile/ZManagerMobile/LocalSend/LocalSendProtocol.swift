import QuickLook
import CryptoKit
import Network
import PhotosUI
import Security
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct LocalSendDevice: Identifiable, Equatable {
    let id: String
    let address: String
    let port: Int
    let protocolName: String
    let alias: String
    let version: String
    let deviceModel: String?
    let deviceType: String?
    let fingerprint: String?
    let download: Bool

    var baseURL: URL? { URL(string: "\(protocolName)://\(address):\(port)") }
}

struct LocalSendTransferFile {
    let id: String
    let url: URL
    let displayName: String
    let mimeType: String

    init(url: URL, displayName: String? = nil, mimeType: String = "application/octet-stream") {
        self.id = UUID().uuidString
        self.url = url
        self.displayName = displayName ?? url.lastPathComponent
        self.mimeType = mimeType
    }
}

struct LocalSendUploadSession {
    let sessionID: String
    let tokens: [String: String]
}

enum LocalSendIdentity {
    private static let key = "org.tzap.zmanager.localsend.fingerprint"

    static func fingerprint(defaults: UserDefaults = .standard) -> String {
        if let stored = defaults.string(forKey: key) {
            return stored
        }
        let generated = UUID().uuidString
        defaults.set(generated, forKey: key)
        return generated
    }
}

struct LocalSendAnnouncement: Codable {
    let alias: String
    let version: String
    let deviceModel: String?
    let deviceType: String?
    let fingerprint: String
    let port: Int
    let `protocol`: String
    let download: Bool
    let announce: Bool?
}

enum LocalSendTransferError: LocalizedError {
    case missingToken
    case pinRequired
    case rejected
    case checksumMismatch
    case invalidResponse
    case receiverAlreadyRunning

    var localSendHTTPStatus: Int {
        switch self {
        case .checksumMismatch: return 422
        default: return 400
        }
    }

    var errorDescription: String? {
        switch self {
        case .missingToken: return "The LocalSend device did not provide an upload token."
        case .pinRequired: return "The LocalSend device requires a PIN."
        case .rejected: return "The LocalSend device rejected the transfer."
        case .checksumMismatch: return "Received checksum does not match the request."
        case .invalidResponse: return "The LocalSend device returned an invalid response."
        case .receiverAlreadyRunning: return "LocalSend receiving is already enabled."
        }
    }
}
