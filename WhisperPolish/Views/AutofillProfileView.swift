import SwiftUI

/// The details the keyboard offers in form fields: imported from the user's
/// contact card, entered here, or saved from what they typed.
struct AutofillProfileView: View {
    private static let detailSections: [(title: String, fields: [ProfileField])] = [
        ("Name", [.fullName, .givenName, .familyName]),
        ("Email", [.email]),
        ("Phone", [.phone]),
        ("Company", [.organization]),
    ]

    @AppStorage(SettingsKeys.autofillOffersToSave, store: AppGroup.defaults) private var offersToSave = true
    @State private var profile = AutofillProfile.load()
    @State private var picker = ContactCardPicker()

    var body: some View {
        Form {
            Section {
                Button {
                    picker.present { profile.importContact($0) }
                } label: {
                    Label("Import from my contact card", systemImage: "person.crop.circle.badge.plus")
                }
            } footer: {
                Text("Pick your own card. Whisper Polish only sees the card you pick, and your details never leave your phone.")
            }

            ForEach(Self.detailSections, id: \.title) { section in
                detailSection(section.title, fields: section.fields)
            }

            ForEach(profile.addresses, id: \.self) { address in
                addressSection(address)
            }
            Section {
                Button {
                    addAddress()
                } label: {
                    Label("Add address", systemImage: "plus")
                }
            }

            learnedSection
        }
        .navigationTitle("AutoFill")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: profile) { _, profile in
            var cleaned = profile
            cleaned.values.removeAll { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            cleaned.save()
        }
    }

    // MARK: - Sections

    private func detailSection(_ title: String, fields: [ProfileField]) -> some View {
        let values = profile.values.filter { fields.contains($0.field) && $0.source != .typed && $0.address == nil }
        return Section(title) {
            ForEach(values) { value in
                HStack {
                    if fields.count > 1 {
                        Text(value.field.title)
                            .foregroundStyle(.secondary)
                            .frame(width: 96, alignment: .leading)
                    }
                    TextField(value.field.title, text: text(of: value.id))
                        .textContentType(nil)
                        .autocorrectionDisabled()
                        .keyboardType(value.field == .email ? .emailAddress : value.field == .phone ? .phonePad : .default)
                        .textInputAutocapitalization(value.field == .email ? .never : .words)
                }
            }
            .onDelete { offsets in
                for offset in offsets { profile.remove(values[offset].id) }
            }
            if fields.count == 1 {
                addButton(fields[0])
            } else {
                Menu {
                    ForEach(fields) { field in
                        Button(field.title) { add(field) }
                    }
                } label: {
                    Label("Add \(title.lowercased())", systemImage: "plus")
                }
            }
        }
    }

    private func addButton(_ field: ProfileField) -> some View {
        Button {
            add(field)
        } label: {
            Label("Add \(field.title.lowercased())", systemImage: "plus")
        }
    }

    private func addressSection(_ address: UUID) -> some View {
        let label = profile.values.first { $0.address == address }?.label
        return Section(label.map { "\($0.localizedCapitalized) address" } ?? "Address") {
            ForEach(ProfileField.addressParts) { field in
                HStack {
                    Text(field.title)
                        .foregroundStyle(.secondary)
                        .frame(width: 96, alignment: .leading)
                    TextField(field.title, text: addressText(field, in: address))
                        .textContentType(nil)
                        .autocorrectionDisabled()
                }
            }
            Button("Delete address", role: .destructive) {
                profile.values.removeAll { $0.address == address }
            }
        }
    }

    /// Details saved from what the user typed into forms, to look over and remove.
    private var learnedSection: some View {
        let learned = profile.values.filter { $0.source == .typed }
        return Section {
            Toggle("Offer to save what I type", isOn: $offersToSave)
            ForEach(learned) { value in
                VStack(alignment: .leading, spacing: 2) {
                    Text(value.text)
                    Text(value.field.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .onDelete { offsets in
                for offset in offsets { profile.remove(learned[offset].id) }
            }
        } header: {
            Text("Learned from typing")
        } footer: {
            Text("When you type a detail into a form, the keyboard offers to save it. Swipe left on one to remove it.")
        }
    }

    // MARK: - Editing

    private func text(of id: UUID) -> Binding<String> {
        Binding {
            profile.values.first { $0.id == id }?.text ?? ""
        } set: { text in
            guard let index = profile.values.firstIndex(where: { $0.id == id }) else { return }
            profile.values[index].text = text
        }
    }

    private func addressText(_ field: ProfileField, in address: UUID) -> Binding<String> {
        Binding {
            profile.value(for: field, in: address)?.text ?? ""
        } set: { text in
            if let index = profile.values.firstIndex(where: { $0.address == address && $0.field == field }) {
                profile.values[index].text = text
            } else {
                let label = profile.values.first { $0.address == address }?.label
                profile.values.append(.init(field: field, text: text, source: .manual, address: address, label: label, lastUsed: Date()))
            }
        }
    }

    private func add(_ field: ProfileField) {
        profile.values.append(.init(field: field, text: "", source: .manual, lastUsed: Date()))
    }

    /// An address exists through its parts, so a new one starts with an empty street.
    private func addAddress() {
        profile.values.append(.init(field: .streetLine1, text: "", source: .manual, address: UUID(), lastUsed: Date()))
    }
}
