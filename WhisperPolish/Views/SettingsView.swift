import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(TranscriptionService.self) private var transcription

    @AppStorage(SettingsKeys.recordOnLaunch) private var recordOnLaunch = false
    @AppStorage(SettingsKeys.autoCopyTranscript) private var autoCopy = false
    @AppStorage(SettingsKeys.openRouterKey) private var apiKey = ""
    @AppStorage(SettingsKeys.defaultStyle) private var defaultStyleRaw = PolishStyle.email.id
    @AppStorage(SettingsKeys.engine) private var engineRaw = TranscriptionEngine.parakeet.rawValue
    @AppStorage(SettingsKeys.customStyles) private var customStylesJSON = ""

    @State private var editingStyle: PolishStyle?
    @State private var showingNewStyle = false

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
                    SecureField("OpenRouter API key (sk-or-…)", text: $apiKey)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Picker("Default style", selection: $defaultStyleRaw) {
                        ForEach(PolishStyle.all(customJSON: customStylesJSON)) { style in
                            Text(style.name).tag(style.id)
                        }
                    }
                } header: {
                    Text("Polish")
                } footer: {
                    Text("Polishing runs via OpenRouter on the model you pick in the polish sheet.")
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
        }
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
