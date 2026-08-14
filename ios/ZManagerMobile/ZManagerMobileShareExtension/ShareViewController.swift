import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private static let appGroupIdentifier = "group.org.tzap.zmanager.mobile"
    private static let incomingDirectoryName = "Incoming"

    private let statusLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        statusLabel.text = "Preparing archive import…"
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])

        Task { await importSharedItems() }
    }

    private func importSharedItems() async {
        do {
            let identifier = UUID().uuidString
            let root = try incomingRoot(identifier: identifier)
            let extensionItems = extensionContext?.inputItems as? [NSExtensionItem] ?? []
            let providers = extensionItems
                .flatMap { $0.attachments ?? [] }
                .filter { !$0.registeredTypeIdentifiers.isEmpty }
            guard !providers.isEmpty else {
                throw ShareImportError.noFiles
            }

            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for (index, provider) in providers.enumerated() {
                let typeIdentifier = provider.registeredTypeIdentifiers.first ?? UTType.data.identifier
                let source = try await loadFile(provider: provider, typeIdentifier: typeIdentifier)
                let name = sanitizedName(provider.suggestedName ?? source.lastPathComponent)
                let target = uniqueURL(
                    in: root,
                    name: name.isEmpty ? "shared-file-\(index + 1)" : name
                )
                try FileManager.default.copyItem(at: source, to: target)
            }

            guard let url = URL(string: "zmanager://import?id=\(identifier)") else {
                throw ShareImportError.invalidHandoff
            }
            await MainActor.run { statusLabel.text = "Opening ZManager Mobile…" }
            let opened = await extensionContext?.open(url) ?? false
            if !opened {
                finish(with: ShareImportError.hostUnavailable)
                return
            }
            extensionContext?.completeRequest(returningItems: nil)
        } catch {
            finish(with: error)
        }
    }

    private func incomingRoot(identifier: String) throws -> URL {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier
        ) else {
            throw ShareImportError.sharedContainerUnavailable
        }
        return container
            .appendingPathComponent(Self.incomingDirectoryName, isDirectory: true)
            .appendingPathComponent(identifier, isDirectory: true)
    }

    private func loadFile(provider: NSItemProvider, typeIdentifier: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let url {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: ShareImportError.fileUnavailable)
                }
            }
        }
    }

    private func sanitizedName(_ name: String) -> String {
        let leaf = name.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        let invalid = CharacterSet(charactersIn: "\\/:*?\"<>|").union(.controlCharacters)
        let result = leaf.components(separatedBy: invalid).joined(separator: "_")
        return result.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
    }

    private func uniqueURL(in root: URL, name: String) -> URL {
        var candidate = root.appendingPathComponent(name)
        var index = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            let base = candidate.deletingPathExtension().lastPathComponent
            let ext = candidate.pathExtension
            candidate = root.appendingPathComponent(
                ext.isEmpty ? "\(base) (\(index))" : "\(base) (\(index)).\(ext)"
            )
            index += 1
        }
        return candidate
    }

    private func finish(with error: Error) {
        Task { @MainActor in
            statusLabel.text = error.localizedDescription
            extensionContext?.cancelRequest(withError: error)
        }
    }
}

private enum ShareImportError: LocalizedError {
    case noFiles
    case invalidHandoff
    case hostUnavailable
    case sharedContainerUnavailable
    case fileUnavailable

    var errorDescription: String? {
        switch self {
        case .noFiles: return "No files were provided for import."
        case .invalidHandoff: return "Unable to prepare the ZManager Mobile handoff."
        case .hostUnavailable: return "ZManager Mobile could not be opened."
        case .sharedContainerUnavailable: return "The shared import container is unavailable."
        case .fileUnavailable: return "The shared file is no longer available."
        }
    }
}
