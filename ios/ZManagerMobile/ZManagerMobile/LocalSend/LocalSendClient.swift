import QuickLook
import CryptoKit
import Network
import PhotosUI
import Security
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct LocalSendSourceStager {
    let fileManager: FileManager
    let securityScope: SecurityScopedResourceAccess

    init(
        fileManager: FileManager = .default,
        securityScope: SecurityScopedResourceAccess = .system
    ) {
        self.fileManager = fileManager
        self.securityScope = securityScope
    }

    func stageFiles(_ urls: [URL]) throws -> StagedCreationSources {
        guard !urls.isEmpty else { throw ArchiveImportError.emptySelection }
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("ZManagerMobile/LocalSendSources/\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            var paths: [String] = []
            for url in urls {
                try securityScope.withAccess(url) {
                    let target = uniqueTarget(root: root, name: ArchiveImportStore.sanitizedDisplayName(url.lastPathComponent))
                    try fileManager.copyItem(at: url, to: target)
                    paths.append(target.path)
                }
            }
            return StagedCreationSources(root: root, sourcePaths: paths)
        } catch {
            try? fileManager.removeItem(at: root)
            throw error
        }
    }

    func discard(_ staged: StagedCreationSources) {
        try? fileManager.removeItem(at: staged.root)
    }

    private func uniqueTarget(root: URL, name: String) -> URL {
        let safeName = name.isEmpty ? "file" : name
        var candidate = root.appendingPathComponent(safeName)
        var index = 1
        while fileManager.fileExists(atPath: candidate.path) {
            let base = candidate.deletingPathExtension().lastPathComponent
            let ext = candidate.pathExtension
            let next = ext.isEmpty ? "\(base) (\(index))" : "\(base) (\(index)).\(ext)"
            candidate = root.appendingPathComponent(next)
            index += 1
        }
        return candidate
    }
}

struct LocalSendPanel: View {
    let archive: ImportedArchive?
    let selectedFileCount: Int
    let state: LocalSendUIState
    let onDiscover: () -> Void
    let onChooseFiles: () -> Void
    let onClearFiles: () -> Void
    let onSend: (LocalSendDevice) -> Void
    @Binding var pinInput: String
    let onSubmitPin: (LocalSendDevice, String) -> Void
    let onCancelSend: () -> Void
    let receiveDestinationLabel: String
    let onChooseReceiveDestination: () -> Void
    let onStartReceive: () -> Void
    let onStopReceive: () -> Void
    let trustedFingerprints: [String]
    let onForgetTrustedFingerprint: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Share on local network")
                .font(.headline)
                .accessibilityIdentifier("localSendPanel")
            Text("Only send to devices you recognize on this local network.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Choose files", action: onChooseFiles)
                if selectedFileCount > 0 {
                    Button("Clear", action: onClearFiles)
                }
            }
            if selectedFileCount > 0 {
                Text("\(selectedFileCount) file(s) selected for sharing")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !trustedFingerprints.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Trusted devices").font(.subheadline.weight(.semibold))
                    ForEach(trustedFingerprints, id: \.self) { fingerprint in
                        HStack {
                            Text(fingerprint)
                                .font(.caption)
                                .lineLimit(1)
                                .textSelection(.enabled)
                            Spacer()
                            Button("Forget") { onForgetTrustedFingerprint(fingerprint) }
                                .accessibilityLabel("Forget trusted device \(fingerprint)")
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Trusted devices")
            }
            Button(state.isDiscovering ? "Discovering" : "Find LocalSend devices", action: onDiscover)
                .accessibilityIdentifier("localSendDiscover")
                .disabled((archive == nil && selectedFileCount == 0) || state.isDiscovering)
            if case .receiving(let port) = state {
                Button("Stop receiving", action: onStopReceive)
                Text("Receiving LocalSend files on port \(port) into \(receiveDestinationLabel).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button("Receive to: \(receiveDestinationLabel)", action: onChooseReceiveDestination)
                Button("Receive files", action: onStartReceive)
            }
            switch state {
            case .idle, .receiving, .discovering:
                EmptyView()
            case .devices(let devices):
                if devices.isEmpty { Text("No compatible devices found.") }
                ForEach(devices) { device in
                    HStack {
                        VStack(alignment: .leading) {
                            Text("\(device.alias) (\(device.address))")
                            if let fingerprint = device.fingerprint {
                                Text("Fingerprint: \(fingerprint)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button(selectedFileCount > 0 ? "Send files" : "Send archive") { onSend(device) }
                    }
                }
            case .sending(let device, let message):
                HStack {
                    Text("\(message) to \(device.alias)")
                    Spacer()
                    Button("Cancel", action: onCancelSend)
                }
            case .pinRequired(let device):
                Text("\(device.alias) requires a PIN before receiving this transfer.")
                StableSecureInputField("LocalSend PIN", text: $pinInput, contentType: .oneTimeCode)
                HStack {
                    Button("Retry with PIN") {
                        let pin = pinInput
                        pinInput = ""
                        onSubmitPin(device, pin)
                    }
                    .disabled(pinInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Cancel", action: onCancelSend)
                }
            case .completed(let device):
                Text("Sent to \(device.alias)")
            case .failed(let message):
                Text(message).foregroundStyle(.red)
            }
        }
    }
}

private extension LocalSendUIState {
    var isDiscovering: Bool {
        if case .discovering = self { return true }
        return false
    }
}

enum LocalSendUIState {
    case idle
    case receiving(Int)
    case discovering
    case devices([LocalSendDevice])
    case sending(LocalSendDevice, String)
    case pinRequired(LocalSendDevice)
    case completed(LocalSendDevice)
    case failed(String)
}

final class LocalSendClient: @unchecked Sendable {
    static let multicastAddress = "224.0.0.167"
    static let defaultPort = 53317

    static func isPinRequiredStatus(_ statusCode: Int) -> Bool { statusCode == 401 }

    private let alias: String
    private let fingerprint: String
    private let port: Int
    private var activeTask: URLSessionTask?

    init(alias: String = "ZManager Mobile", fingerprint: String? = nil, port: Int = LocalSendClient.defaultPort) {
        self.alias = alias
        self.fingerprint = fingerprint ?? LocalSendIdentity.fingerprint()
        self.port = port
    }

    func discover(timeout: TimeInterval = 1.5) async throws -> [LocalSendDevice] {
        let group = try NWMulticastGroup(for: [
            NWEndpoint.hostPort(
                host: NWEndpoint.Host(Self.multicastAddress),
                port: NWEndpoint.Port(rawValue: UInt16(Self.defaultPort))!
            )
        ])
        let connection = NWConnectionGroup(with: group, using: .udp)
        return await withCheckedContinuation { continuation in
            let lock = NSLock()
            var finished = false
            var devices = [String: LocalSendDevice]()
            func finish() {
                lock.lock()
                guard !finished else { lock.unlock(); return }
                finished = true
                let result = Array(devices.values)
                lock.unlock()
                connection.cancel()
                continuation.resume(returning: result)
            }
            connection.setReceiveHandler(maximumMessageSize: 16 * 1024, rejectOversizedMessages: true) { message, content, _ in
                guard let content,
                      let json = try? JSONSerialization.jsonObject(with: content) as? [String: Any],
                      let alias = json["alias"] as? String,
                      let port = json["port"] as? Int else { return }
                guard let remoteEndpoint = message.remoteEndpoint,
                      case .hostPort(let endpointHost, _) = remoteEndpoint else { return }
                let host = endpointHost.debugDescription
                guard host != UIDevice.current.name else { return }
                let device = LocalSendDevice(
                    id: "\(host):\(port)",
                    address: host,
                    port: port,
                    protocolName: (json["protocol"] as? String) ?? "http",
                    alias: alias,
                    version: (json["version"] as? String) ?? "2.0",
                    deviceModel: json["deviceModel"] as? String,
                    deviceType: json["deviceType"] as? String,
                    fingerprint: json["fingerprint"] as? String,
                    download: (json["download"] as? Bool) ?? false
                )
                lock.lock()
                devices[device.id] = device
                lock.unlock()
            }
            connection.stateUpdateHandler = { state in
                if case .failed = state { finish() }
            }
            connection.start(queue: .global(qos: .userInitiated))
            let data = try? JSONSerialization.data(withJSONObject: announcement(announce: true))
            if let data { connection.send(content: data, completion: { _ in }) }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                finish()
            }
        }
    }

    /// HTTP registration fallback for networks where multicast discovery is unavailable.
    func discoverHTTP(hosts: [String]) async -> [LocalSendDevice] {
        await withTaskGroup(of: LocalSendDevice?.self, returning: [LocalSendDevice].self) { group in
            for host in hosts {
                for protocolName in ["http", "https"] {
                    group.addTask {
                        guard let url = URL(string: "\(protocolName)://\(host):\(Self.defaultPort)/api/localsend/v2/register") else {
                            return nil
                        }
                        var request = URLRequest(url: url)
                        request.httpMethod = "POST"
                        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                        request.httpBody = try? JSONSerialization.data(withJSONObject: self.announcement(announce: false))
                        guard let (data, response, certificateFingerprint) = try? await self.data(
                            for: request,
                            expectedFingerprint: nil,
                            allowUntrusted: protocolName == "https"
                        ),
                        (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true,
                        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                        let alias = json["alias"] as? String else {
                            return nil
                        }
                        let port = json["port"] as? Int ?? Self.defaultPort
                        let fingerprint = json["fingerprint"] as? String
                        guard fingerprint != self.fingerprint else { return nil }
                        if protocolName == "https" {
                            guard let fingerprint,
                                  let certificateFingerprint,
                                  LocalSendCertificatePinning.normalize(fingerprint) == certificateFingerprint else {
                                return nil
                            }
                        }
                        return LocalSendDevice(
                            id: "\(host):\(port)",
                            address: host,
                            port: port,
                            protocolName: (json["protocol"] as? String) ?? protocolName,
                            alias: alias,
                            version: (json["version"] as? String) ?? "2.0",
                            deviceModel: json["deviceModel"] as? String,
                            deviceType: json["deviceType"] as? String,
                            fingerprint: fingerprint,
                            download: (json["download"] as? Bool) ?? false
                        )
                    }
                }
            }
            var devices = [String: LocalSendDevice]()
            for await device in group {
                if let device { devices[device.id] = device }
            }
            return Array(devices.values)
        }
    }

    func prepareUpload(
        to device: LocalSendDevice,
        files: [LocalSendTransferFile],
        pin: String? = nil
    ) async throws -> LocalSendUploadSession {
        guard let baseURL = device.baseURL else { throw URLError(.badURL) }
        var components = URLComponents(url: baseURL.appendingPathComponent("api/localsend/v2/prepare-upload"), resolvingAgainstBaseURL: false)
        if let pin { components?.queryItems = [URLQueryItem(name: "pin", value: pin)] }
        guard let url = components?.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let hashes = try Dictionary(uniqueKeysWithValues: files.map { file in
            (file.id, try sha256(file.url))
        })
        let body: [String: Any] = [
            "info": announcement(announce: false),
            "files": Dictionary(uniqueKeysWithValues: files.map { file in
                (file.id, [
                    "id": file.id,
                    "fileName": file.displayName,
                    "size": (try? file.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0,
                    "fileType": file.mimeType,
                    "sha256": hashes[file.id] as Any
                ])
            })
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response, _) = try await data(
            for: request,
            expectedFingerprint: device.fingerprint,
            allowUntrusted: false
        )
        try validate(response)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let sessionID = try string(json, key: "sessionId")
        let tokenObject = json["files"] as? [String: String] ?? [:]
        return LocalSendUploadSession(sessionID: sessionID, tokens: tokenObject)
    }

    func upload(
        to device: LocalSendDevice,
        session: LocalSendUploadSession,
        files: [LocalSendTransferFile],
        onProgress: @escaping (_ file: LocalSendTransferFile, _ sent: Int64, _ total: Int64) -> Void = { _, _, _ in }
    ) async throws {
        guard let baseURL = device.baseURL else { throw URLError(.badURL) }
        for file in files {
            guard let token = session.tokens[file.id] else { throw LocalSendTransferError.missingToken }
            var components = URLComponents(url: baseURL.appendingPathComponent("api/localsend/v2/upload"), resolvingAgainstBaseURL: false)
            components?.queryItems = [
                URLQueryItem(name: "sessionId", value: session.sessionID),
                URLQueryItem(name: "fileId", value: file.id),
                URLQueryItem(name: "token", value: token)
            ]
            guard let url = components?.url else { throw URLError(.badURL) }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            let delegate = LocalSendUploadDelegate(
                file: file,
                expectedFingerprint: device.fingerprint,
                onProgress: onProgress
            )
            let sessionConfiguration = URLSessionConfiguration.default
            let delegateSession = URLSession(configuration: sessionConfiguration, delegate: delegate, delegateQueue: nil)
            let uploadTask = delegateSession.uploadTask(with: request, fromFile: file.url)
            self.activeTask = uploadTask
            defer {
                delegateSession.invalidateAndCancel()
                self.activeTask = nil
            }
            try await delegate.start(task: uploadTask)
        }
    }

    func cancel(to device: LocalSendDevice, sessionID: String) async throws {
        cancelActiveUpload()
        guard let baseURL = device.baseURL else { throw URLError(.badURL) }
        var components = URLComponents(url: baseURL.appendingPathComponent("api/localsend/v2/cancel"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "sessionId", value: sessionID)]
        guard let url = components?.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let (_, response, _) = try await data(
            for: request,
            expectedFingerprint: device.fingerprint,
            allowUntrusted: false
        )
        try validate(response)
    }

    func cancelActiveUpload() {
        activeTask?.cancel()
        activeTask = nil
    }

    private func data(
        for request: URLRequest,
        expectedFingerprint: String?,
        allowUntrusted: Bool
    ) async throws -> (Data, URLResponse, String?) {
        let delegate = LocalSendTrustDelegate(
            expectedFingerprint: expectedFingerprint,
            allowUntrusted: allowUntrusted
        )
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        return (data, response, delegate.serverFingerprint)
    }

    private func announcement(announce: Bool) -> [String: Any] {
        [
            "alias": alias,
            "version": "2.0",
            "deviceModel": UIDevice.current.model,
            "deviceType": "mobile",
            "fingerprint": fingerprint,
            "port": port,
            "protocol": "http",
            "download": false,
            "announce": announce
        ]
    }

    private func sha256(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw LocalSendTransferError.rejected
        }
        if Self.isPinRequiredStatus(http.statusCode) { throw LocalSendTransferError.pinRequired }
        guard (200..<300).contains(http.statusCode) else {
            throw LocalSendTransferError.rejected
        }
    }

    private func string(_ json: [String: Any], key: String) throws -> String {
        guard let value = json[key] as? String else { throw LocalSendTransferError.invalidResponse }
        return value
    }
}

private final class LocalSendUploadDelegate: NSObject, URLSessionTaskDelegate {
    private let file: LocalSendTransferFile
    private let expectedFingerprint: String?
    private let onProgress: (LocalSendTransferFile, Int64, Int64) -> Void
    private var continuation: CheckedContinuation<Void, Error>?

    init(
        file: LocalSendTransferFile,
        expectedFingerprint: String?,
        onProgress: @escaping (LocalSendTransferFile, Int64, Int64) -> Void
    ) {
        self.file = file
        self.expectedFingerprint = expectedFingerprint
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard let trust = challenge.protectionSpace.serverTrust,
              LocalSendCertificatePinning.validate(
                trust,
                expectedFingerprint: expectedFingerprint,
                allowUntrusted: false
              ) != nil else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func start(task: URLSessionTask) async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            task.resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        onProgress(file, totalBytesSent, totalBytesExpectedToSend)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            if let urlError = error as? URLError, urlError.code == .cancelled {
                continuation?.resume(throwing: CancellationError())
            } else {
                continuation?.resume(throwing: error)
            }
            continuation = nil
            return
        }
        guard let response = task.response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else {
            continuation?.resume(throwing: LocalSendTransferError.rejected)
            continuation = nil
            return
        }
        continuation?.resume()
        continuation = nil
    }
}

/// LocalSend upload receiver. The listener owns only app-storage paths and
/// commits a file after size, token, and optional SHA-256 checks succeed.
