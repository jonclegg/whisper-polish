import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(TranscriptionService.self) private var transcription
    @Environment(OpenRouterKeyStore.self) private var openRouterKey
    @Environment(SubscriptionStore.self) private var subscription

    @AppStorage(SettingsKeys.recordOnLaunch) private var recordOnLaunch = false
    @AppStorage(SettingsKeys.autoCopyTranscript) private var autoCopy = false
    @AppStorage(SettingsKeys.cloudAccessMode) private var cloudAccessRaw = CloudAccessMode.personalKey.rawValue
    @AppStorage(SettingsKeys.defaultStyle) private var defaultStyleRaw = PolishStyle.email.id
    @AppStorage(SettingsKeys.engine) private var engineRaw = TranscriptionEngine.parakeet.rawValue
    @AppStorage(SettingsKeys.customStyles) private var customStylesJSON = ""

    @State private var editingStyle: PolishStyle?
    @State private var showingNewStyle = false
    @State private var apiKey = ""
    @State private var purchaseInFlight = false
    @State private var cloudError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("General") {
                    Toggle("Record on open", isOn: $recordOnLaunch)
                    Toggle("Auto-copy transcript", isOn: $autoCopy)
                }

                Section {
                    ForEach(TranscriptionEngine.allCases) { engine in
                        Button {
                            selectEngine(engine)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(engine.displayName)
                                        .foregroundStyle(.primary)
                                    Text("\(engine.subtitle) · \(engine.sizeLabel)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                engineTrailing(engine)
                            }
                        }
                        .disabled(transcription.state.isDownloading)
                    }
                    if transcription.state.isDownloading {
                        Button("Cancel download", role: .destructive) {
                            transcription.cancelPreparation()
                        }
                    }
                } header: {
                    Text("Transcription (on-device)")
                } footer: {
                    if case .failed(let message) = transcription.state {
                        Text("Download failed: \(message)")
                    } else if case .downloading = transcription.state {
                        Text("Keep the app open while the model downloads.")
                    } else if case .loading = transcription.state {
                        Text("Loading the model into memory.")
                    }
                }

                Section {
                    Picker("Cloud access", selection: $cloudAccessRaw) {
                        ForEach(CloudAccessMode.allCases) { mode in
                            Text(mode.title).tag(mode.rawValue)
                        }
                    }

                    if cloudAccessMode == .personalKey {
                        SecureField("OpenRouter API key (sk-or-…)", text: $apiKey)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .onChange(of: apiKey) { _, value in
                                do {
                                    try openRouterKey.update(value)
                                    cloudError = nil
                                } catch {
                                    cloudError = error.localizedDescription
                                }
                            }
                    } else if subscription.isSubscribed {
                        LabeledContent("Plan", value: "Active")
                        if let usage = subscription.usage {
                            LabeledContent("This month", value: "\(usage.remaining) of \(usage.limit) left")
                        } else {
                            LabeledContent("Included", value: "Up to \(CloudPlan.monthlyPolishLimit) polishes/month")
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Up to \(CloudPlan.monthlyPolishLimit) cloud polishes each month")
                                .font(.subheadline.weight(.semibold))
                            Text("\(subscription.priceText) per month · cancel anytime")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Button(purchaseInFlight ? "Starting…" : "Subscribe") {
                            purchaseInFlight = true
                            Task {
                                defer { purchaseInFlight = false }
                                do { try await subscription.purchase() }
                                catch { cloudError = error.localizedDescription }
                            }
                        }
                        .disabled(purchaseInFlight || subscription.product == nil)

                        Button("Restore Purchases") {
                            Task {
                                do { try await subscription.restore() }
                                catch { cloudError = error.localizedDescription }
                            }
                        }
                    }

                    Picker("Default style", selection: $defaultStyleRaw) {
                        ForEach(PolishStyle.all(customJSON: customStylesJSON)) { style in
                            Text(style.name).tag(style.id)
                        }
                    }
                } header: {
                    Text("Polish")
                } footer: {
                    if let cloudError {
                        Text(cloudError).foregroundStyle(.red)
                    } else if cloudAccessMode == .personalKey {
                        Text("Your key stays in this device's Keychain. Polishing goes directly to OpenRouter.")
                    } else {
                        Text("Cloud requests use the plan's cost-controlled model. Personal Key mode keeps the full model picker.")
                    }
                }

                Section {
                    ForEach(customStyles) { style in
                        Button {
                            editingStyle = style
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(style.name)
                                    .foregroundStyle(.primary)
                                Text(style.instruction)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                    .onDelete(perform: deleteStyles)
                    Button {
                        showingNewStyle = true
                    } label: {
                        Label("New style", systemImage: "plus")
                    }
                } header: {
                    Text("Custom styles")
                } footer: {
                    Text("A style is just an instruction telling the model how to shape your text. Built-in styles can't be edited — make your own version instead.")
                }

                Section("About") {
                    Link("Privacy Policy", destination: AppLinks.privacyPolicy)
                    Link("Terms of Use", destination: AppLinks.termsOfUse)
                    Link("Support", destination: AppLinks.support)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .sheet(isPresented: $showingNewStyle) {
                StyleEditorView()
            }
            .sheet(item: $editingStyle) { style in
                StyleEditorView(editing: style)
            }
            .onAppear { apiKey = openRouterKey.value }
        }
    }

    private var cloudAccessMode: CloudAccessMode {
        CloudAccessMode(rawValue: cloudAccessRaw) ?? .personalKey
    }

    @ViewBuilder
    private func engineTrailing(_ engine: TranscriptionEngine) -> some View {
        if engineRaw == engine.rawValue {
            switch transcription.state {
            case .downloading(let fraction):
                ProgressView(value: fraction)
                    .frame(width: 60)
            case .loading:
                ProgressView()
            case .ready where transcription.loadedEngine == engine:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.polishTeal)
            default:
                Image(systemName: "arrow.down.circle")
                    .foregroundStyle(Color.polishTeal)
            }
        } else {
            Image(systemName: "circle")
                .foregroundStyle(Color(.systemFill))
        }
    }

    private func selectEngine(_ engine: TranscriptionEngine) {
        engineRaw = engine.rawValue
        Task { await transcription.prepare() }
    }

    private var customStyles: [PolishStyle] {
        PolishStyle.decodeCustom(customStylesJSON)
    }

    private func deleteStyles(at offsets: IndexSet) {
        var styles = customStyles
        let removed = offsets.map { styles[$0].id }
        styles.remove(atOffsets: offsets)
        customStylesJSON = PolishStyle.encodeCustom(styles)
        if removed.contains(defaultStyleRaw) {
            defaultStyleRaw = PolishStyle.email.id
        }
    }
}
