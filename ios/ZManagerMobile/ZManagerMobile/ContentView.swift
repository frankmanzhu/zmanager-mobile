import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("ZManager")
                    .font(.largeTitle.weight(.semibold))

                Text("Open an archive, inspect its contents, then extract safely.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack {
                Spacer()
                Button("Open Archive") {
                    // TODO: launch iOS document picker.
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
    }
}

#Preview {
    ContentView()
}

