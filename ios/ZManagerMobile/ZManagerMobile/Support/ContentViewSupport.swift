import QuickLook
import CryptoKit
import Network
import PhotosUI
import Security
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct StableSecureInputField: UIViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let contentType: UITextContentType?
    let onSubmit: (String) -> Void
    let onTextChanged: (String) -> Void
    let onFieldReady: (UITextField) -> Void

    init(
        _ placeholder: String,
        text: Binding<String>,
        contentType: UITextContentType? = nil,
        onSubmit: @escaping (String) -> Void = { _ in },
        onTextChanged: @escaping (String) -> Void = { _ in },
        onFieldReady: @escaping (UITextField) -> Void = { _ in }
    ) {
        self._text = text
        self.placeholder = placeholder
        self.contentType = contentType
        self.onSubmit = onSubmit
        self.onTextChanged = onTextChanged
        self.onFieldReady = onFieldReady
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit, onTextChanged: onTextChanged)
    }

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField(frame: .zero)
        field.borderStyle = .roundedRect
        field.placeholder = placeholder
        field.isSecureTextEntry = true
        field.textContentType = contentType
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.returnKeyType = .done
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.valueChanged(_:)), for: .editingChanged)
        field.accessibilityLabel = placeholder
        field.text = text
        context.coordinator.inputValue = text
        onFieldReady(field)
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onSubmit = onSubmit
        context.coordinator.onTextChanged = onTextChanged
        // UIKit remains the source of truth after makeUIView. SwiftUI may
        // render a frame behind the latest editingChanged event; copying the
        // stale binding back would truncate automation and hardware-keyboard
        // input after the first character.
        field.placeholder = placeholder
        field.accessibilityLabel = placeholder
        onFieldReady(field)
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var text: Binding<String>
        var onSubmit: (String) -> Void
        var onTextChanged: (String) -> Void
        var inputValue = ""

        init(
            text: Binding<String>,
            onSubmit: @escaping (String) -> Void,
            onTextChanged: @escaping (String) -> Void
        ) {
            self.text = text
            self.onSubmit = onSubmit
            self.onTextChanged = onTextChanged
        }

        @objc func valueChanged(_ sender: UITextField) {
            let value = sender.text ?? ""
            inputValue = value
            text.wrappedValue = value
            onTextChanged(value)
        }

        func textField(
            _ textField: UITextField,
            shouldChangeCharactersIn range: NSRange,
            replacementString string: String
        ) -> Bool {
            let current = inputValue as NSString
            guard range.location <= current.length,
                  range.location + range.length <= current.length else {
                return false
            }
            inputValue = current.replacingCharacters(in: range, with: string)
            textField.text = inputValue
            text.wrappedValue = inputValue
            onTextChanged(inputValue)
            return false
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            text.wrappedValue = textField.text ?? ""
            onSubmit(textField.text ?? "")
            return true
        }
    }
}

final class StableInputBuffer: ObservableObject {
    @Published var value = ""
    weak var field: UITextField?
}

struct PreviewDocument: Identifiable, Equatable {
    let id = UUID()
    let url: URL
}

struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        context.coordinator.url = url
        controller.reloadData()
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL

        init(url: URL) {
            self.url = url
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            1
        }

        func previewController(
            _ controller: QLPreviewController,
            previewItemAt index: Int
        ) -> QLPreviewItem {
            url as NSURL
        }
    }
}

struct RecoveryShareSheet: UIViewControllerRepresentable {
    let urls: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: urls, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

