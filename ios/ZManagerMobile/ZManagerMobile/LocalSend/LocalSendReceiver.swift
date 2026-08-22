import QuickLook
import CryptoKit
import Network
import PhotosUI
import Security
import SwiftUI
import UIKit
import UniformTypeIdentifiers

final class LocalSendReceiver: @unchecked Sendable {
    private struct ExpectedFile {
        let id: String
        let displayName: String
        let expectedBytes: Int64
        let sha256: String?
        let token: String
    }

    private final class ReceiveSession {
        let root: URL
        let destinationRoot: URL
        let files: [String: ExpectedFile]
        var completed = Set<String>()

        init(root: URL, destinationRoot: URL, files: [String: ExpectedFile]) {
            self.root = root
            self.destinationRoot = destinationRoot
            self.files = files
        }
    }

    private final class RequestState {
        var headerBuffer = Data()
        var bodyBuffer = Data()
        var headersParsed = false
        var method = ""
        var path = ""
        var headers = [String: String]()
        var remaining = 0
        var session: ReceiveSession?
        var sessionID: String?
        var expected: ExpectedFile?
        var preparedSessionID: String?
        var temporaryFile: URL?
        var fileHandle: FileHandle?
        var digest = SHA256()
    }

    private let alias: String
    private let fingerprint: String
    private let port: UInt16
    private let fileManager: FileManager
    private let queue = DispatchQueue(label: "org.tzap.zmanager.localsend.receiver")
    var onFileCommitted: ((URL, String) -> Void)?
    private var listener: NWListener?
    private var announceConnection: NWConnectionGroup?
    private var announceTimer: DispatchSourceTimer?
    private var sessions = [String: ReceiveSession]()
    private var destinationRoot: URL?

    init(
        alias: String = "ZManager Mobile",
        fingerprint: String? = nil,
        port: UInt16 = UInt16(LocalSendClient.defaultPort),
        fileManager: FileManager = .default
    ) {
        self.alias = alias
        self.fingerprint = fingerprint ?? LocalSendIdentity.fingerprint()
        self.port = port
        self.fileManager = fileManager
    }

    func start(destinationRoot: URL) throws -> Int {
        guard listener == nil else { throw LocalSendTransferError.receiverAlreadyRunning }
        try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
        self.destinationRoot = destinationRoot
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        startAnnouncements()
        return Int(port)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        announceTimer?.cancel()
        announceTimer = nil
        announceConnection?.cancel()
        announceConnection = nil
        sessions.values.forEach { try? fileManager.removeItem(at: $0.root) }
        sessions.removeAll()
        destinationRoot = nil
    }

    private func accept(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                let request = RequestState()
                self?.receive(connection, request: request)
            }
        }
        connection.start(queue: queue)
    }

    private func receive(_ connection: NWConnection, request: RequestState) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            if let data, !data.isEmpty {
                do {
                    try self.consume(data, request: request)
                    if request.remaining == 0, request.headersParsed {
                        self.finish(connection, request: request)
                        return
                    }
                } catch {
                    self.respond(connection, status: 400, body: error.localizedDescription)
                    return
                }
            }
            if isComplete || error != nil {
                connection.cancel()
            } else {
                self.receive(connection, request: request)
            }
        }
    }

    private func consume(_ data: Data, request: RequestState) throws {
        if !request.headersParsed {
            request.headerBuffer.append(data)
            guard let marker = request.headerBuffer.range(of: Data("\r\n\r\n".utf8)) else {
                guard request.headerBuffer.count <= 16 * 1024 else { throw LocalSendTransferError.invalidResponse }
                return
            }
            let headerData = request.headerBuffer.subdata(in: 0..<marker.lowerBound)
            let bodyStart = marker.upperBound
            request.headerBuffer = Data(request.headerBuffer[bodyStart...])
            let lines = String(decoding: headerData, as: UTF8.self).components(separatedBy: "\r\n")
            let requestParts = lines.first?.split(separator: " ", maxSplits: 2).map(String.init) ?? []
            guard requestParts.count == 3 else { throw LocalSendTransferError.invalidResponse }
            request.method = requestParts[0]
            request.path = requestParts[1]
            for line in lines.dropFirst() {
                let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
                if parts.count == 2 { request.headers[parts[0].lowercased()] = parts[1].trimmingCharacters(in: .whitespacesAndNewlines) }
            }
            guard request.method == "POST", let length = Int(request.headers["content-length"] ?? "0"), length >= 0 else {
                throw LocalSendTransferError.invalidResponse
            }
            request.remaining = length
            request.headersParsed = true
            if request.path.hasPrefix("/api/localsend/v2/upload") {
                try prepareUploadFile(request)
            }
            let initialBody = request.headerBuffer
            request.headerBuffer.removeAll(keepingCapacity: false)
            if !initialBody.isEmpty { try consumeBody(initialBody, request: request) }
            return
        }
        try consumeBody(data, request: request)
    }

    private func consumeBody(_ data: Data, request: RequestState) throws {
        guard request.remaining > 0 else { return }
        let count = min(request.remaining, data.count)
        let chunk = data.prefix(count)
        if request.path.hasPrefix("/api/localsend/v2/upload") {
            try request.fileHandle?.write(contentsOf: Data(chunk))
            request.digest.update(data: Data(chunk))
        } else {
            guard request.bodyBuffer.count + count <= 4 * 1024 * 1024 else { throw LocalSendTransferError.invalidResponse }
            request.bodyBuffer.append(chunk)
        }
        request.remaining -= count
    }

    private func prepareUploadFile(_ request: RequestState) throws {
        guard let destinationRoot, let components = URLComponents(string: "http://localhost\(request.path)"),
              let sessionID = components.queryItems?.first(where: { $0.name == "sessionId" })?.value,
              let fileID = components.queryItems?.first(where: { $0.name == "fileId" })?.value,
              let token = components.queryItems?.first(where: { $0.name == "token" })?.value,
              let session = sessions[sessionID], let expected = session.files[fileID], expected.token == token else {
            throw LocalSendTransferError.rejected
        }
        request.session = session
        request.sessionID = sessionID
        request.expected = expected
        let temporary = session.root.appendingPathComponent("\(fileID).part")
        fileManager.createFile(atPath: temporary.path, contents: nil)
        request.temporaryFile = temporary
        request.fileHandle = try FileHandle(forWritingTo: temporary)
        _ = destinationRoot
    }

    private func finish(_ connection: NWConnection, request: RequestState) {
        do {
            if request.path.hasPrefix("/api/localsend/v2/prepare-upload") {
                try prepare(request)
                respond(connection, status: 200, json: prepareResponse(request))
            } else if request.path.hasPrefix("/api/localsend/v2/register") {
                respond(connection, status: 200, json: registrationAnnouncement())
            } else if request.path.hasPrefix("/api/localsend/v2/upload") {
                try commit(request)
                respond(connection, status: 200, body: "OK")
            } else if request.path.hasPrefix("/api/localsend/v2/cancel") {
                cancel(request)
                respond(connection, status: 200, body: "OK")
            } else {
                respond(connection, status: 404, body: "Not found")
            }
        } catch {
            try? request.fileHandle?.close()
            try? request.temporaryFile.map { try fileManager.removeItem(at: $0) }
            if let session = request.session, let sessionID = request.sessionID {
                sessions.removeValue(forKey: sessionID)
                try? fileManager.removeItem(at: session.root)
            }
            let status = (error as? LocalSendTransferError)?.localSendHTTPStatus ?? 400
            respond(connection, status: status, body: error.localizedDescription)
        }
    }

    private func prepare(_ request: RequestState) throws {
        guard let root = destinationRoot,
              let json = try JSONSerialization.jsonObject(with: request.bodyBuffer) as? [String: Any],
              let files = json["files"] as? [String: Any], !files.isEmpty else {
            throw LocalSendTransferError.invalidResponse
        }
        let sessionID = UUID().uuidString
        let sessionRoot = root.appendingPathComponent(".localsend/\(sessionID)", isDirectory: true)
        try fileManager.createDirectory(at: sessionRoot, withIntermediateDirectories: true)
        var expected = [String: ExpectedFile]()
        for (key, rawValue) in files {
            guard let value = rawValue as? [String: Any] else { throw LocalSendTransferError.invalidResponse }
            let id = value["id"] as? String ?? key
            let name = Self.sanitizeIncomingName(value["fileName"] as? String ?? id)
            expected[id] = ExpectedFile(
                id: id,
                displayName: name,
                expectedBytes: (value["size"] as? NSNumber)?.int64Value ?? -1,
                sha256: value["sha256"] as? String,
                token: UUID().uuidString
            )
        }
        let session = ReceiveSession(root: sessionRoot, destinationRoot: root, files: expected)
        sessions[sessionID] = session
        request.session = session
        request.preparedSessionID = sessionID
    }

    private func prepareResponse(_ request: RequestState) -> [String: Any] {
        let sessionID = request.preparedSessionID ?? ""
        let files = request.session?.files.reduce(into: [String: String]()) { result, item in result[item.key] = item.value.token } ?? [:]
        return ["sessionId": sessionID, "files": files]
    }

    private func registrationAnnouncement() -> [String: Any] {
        [
            "alias": alias,
            "version": "2.0",
            "deviceModel": UIDevice.current.model,
            "deviceType": "mobile",
            "fingerprint": fingerprint,
            "port": Int(port),
            "protocol": "http",
            "download": true,
            "announce": false
        ]
    }

    private func commit(_ request: RequestState) throws {
        guard let session = request.session, let expected = request.expected, let temporary = request.temporaryFile else {
            throw LocalSendTransferError.rejected
        }
        try request.fileHandle?.close()
        let values = try temporary.resourceValues(forKeys: [.fileSizeKey])
        let bytes = Int64(values.fileSize ?? 0)
        guard expected.expectedBytes < 0 || expected.expectedBytes == bytes else { throw LocalSendTransferError.rejected }
        if let sha256 = expected.sha256 {
            let actual = request.digest.finalize().map { String(format: "%02x", $0) }.joined()
            guard actual.caseInsensitiveCompare(sha256) == .orderedSame else {
                throw LocalSendTransferError.checksumMismatch
            }
        }
        let target = Self.uniqueTarget(root: session.destinationRoot, name: expected.displayName, fileManager: fileManager)
        try fileManager.moveItem(at: temporary, to: target)
        onFileCommitted?(target, expected.displayName)
        session.completed.insert(expected.id)
        if session.completed.count == session.files.count, let sessionID = request.sessionID {
            sessions.removeValue(forKey: sessionID)
            try? fileManager.removeItem(at: session.root)
        }
    }

    private func cancel(_ request: RequestState) {
        let sessionID = URLComponents(string: "http://localhost\(request.path)")?.queryItems?.first(where: { $0.name == "sessionId" })?.value
        if let sessionID, let session = sessions.removeValue(forKey: sessionID) { try? fileManager.removeItem(at: session.root) }
    }

    private func respond(_ connection: NWConnection, status: Int, body: String) {
        respond(connection, status: status, contentType: "text/plain; charset=utf-8", data: Data(body.utf8))
    }

    private func respond(_ connection: NWConnection, status: Int, json: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        respond(connection, status: status, contentType: "application/json", data: data)
    }

    private func respond(_ connection: NWConnection, status: Int, contentType: String, data: Data) {
        let reason = (200..<300).contains(status) ? "OK" : "Error"
        var response = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n".utf8)
        response.append(data)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func startAnnouncements() {
        guard let group = try? NWMulticastGroup(for: [NWEndpoint.hostPort(host: NWEndpoint.Host(LocalSendClient.multicastAddress), port: NWEndpoint.Port(rawValue: port)!)]) else { return }
        let connection = NWConnectionGroup(with: group, using: .udp)
        announceConnection = connection
        connection.start(queue: queue)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1)
        timer.setEventHandler(handler: DispatchWorkItem { [weak self] in
            guard let self, let connection = self.announceConnection else { return }
            let announcement = LocalSendAnnouncement(
                alias: self.alias,
                version: "2.0",
                deviceModel: UIDevice.current.model,
                deviceType: "mobile",
                fingerprint: self.fingerprint,
                port: Int(self.port),
                protocol: "http",
                download: true,
                announce: true
            )
            if let data = try? JSONEncoder().encode(announcement) { connection.send(content: data, completion: { _ in }) }
        })
        announceTimer = timer
        timer.resume()
    }

    static func sanitizeIncomingName(_ raw: String) -> String {
        let name = raw.split(separator: "/").last.map(String.init)?.split(separator: "\\").last.map(String.init) ?? raw
        let cleaned = name.replacingOccurrences(of: #"[\\/:*?\"<>|]"#, with: "_", options: .regularExpression)
            .filter { !$0.isNewline && $0.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) } }
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return cleaned.isEmpty ? "received-file" : cleaned
    }

    private static func uniqueTarget(root: URL, name: String, fileManager: FileManager) -> URL {
        let safe = sanitizeIncomingName(name)
        var candidate = root.appendingPathComponent(safe)
        var index = 1
        while fileManager.fileExists(atPath: candidate.path) {
            let base = candidate.deletingPathExtension().lastPathComponent
            let ext = candidate.pathExtension
            candidate = root.appendingPathComponent(ext.isEmpty ? "\(base) (\(index))" : "\(base) (\(index)).\(ext)")
            index += 1
        }
        return candidate
    }
}

private extension URLSessionTask {
    func value() async throws {
        while state == .running { try await Task.sleep(nanoseconds: 50_000_000) }
        if state == .canceling { throw CancellationError() }
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else {
            throw LocalSendTransferError.rejected
        }
    }
}

