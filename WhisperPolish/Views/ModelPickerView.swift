import SwiftUI

/// Dialog for choosing which OpenRouter model runs the polish.
struct ModelPickerView: View {
    @Binding var selection: PolishModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Frontier") {
                    ForEach(PolishModel.frontier) { row($0) }
                }
                Section("Fast & cheap") {
                    ForEach(PolishModel.fast) { row($0) }
                }
            }
            .navigationTitle("Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    private func row(_ model: PolishModel) -> some View {
        Button {
            selection = model
            dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.displayName)
                        .foregroundStyle(.primary)
                    Text(model.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if selection == model {
                    Image(systemName: "checkmark")
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.polishTeal)
                }
            }
        }
    }
}
