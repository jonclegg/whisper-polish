import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(TranscriptionService.self) private var transcription

    @AppStorage(SettingsKeys.recordOnLaunch) private var recordOnLaunch = false
    @AppStorage(SettingsKeys.autoCopyTranscript) private var autoCopy = false
    @AppStorage(SettingsKeys.openRouterKey) private var apiKey = ""
    @AppStorage(SettingsKeys.polishModel) private var model = SettingsKeys.defaultModel
    @AppStorage(SettingsKeys.defaultStyle) private var defaultStyleRaw = PolishStyle.email.rawValue
    @AppStorage(SettingsKeys.stealthByDefault) private var stealthByDefault = false
    @AppStorage(SettingsKeys.engine) private var engineRaw = TranscriptionEngine.parakeet.rawValue

    private let modelPresets = [
        "openai/gpt-4o",
        "anthropic/claude-sonnet-4.5",
        "google/gemini-2.5-pro",
        "deepseek/deepseek-chat",
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("General") {
                    Toggle("Record on launch", isOn: $recordOnLaunch)
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
                } header: {
                    Text("Transcription (on-device)")
                } footer: {
                    if case .failed(let message) = transcription.state {
                        Text("Download failed: \(message)")
                    } else if case .downloading = transcription.state {
                        Text("Keep the app open while the model downloads.")
                    }
                }

                Section("Polish") {
                    SecureField("OpenRouter API key (sk-or-…)", text: $apiKey)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Picker("Model", selection: $model) {
                        ForEach(modelPresets, id: \.self) { preset in
                            Text(preset).tag(preset)
                        }
                        if !modelPresets.contains(model) {
                            Text(model).tag(model)
                        }
                    }
                    Picker("Default style", selection: $defaultStyleRaw) {
                        ForEach(PolishStyle.allCases) { style in
                            Text(style.displayName).tag(style.rawValue)
                        }
                    }
                    Toggle(isOn: $stealthByDefault) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Stealth by default")
                            Text("Always use the translation-hop pipeline")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
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
        }
    }

    @ViewBuilder
    private func engineTrailing(_ engine: TranscriptionEngine) -> some View {
        if engineRaw == engine.rawValue {
            switch transcription.state {
            case .downloading(let fraction):
                ProgressView(value: fraction)
                    .frame(width: 60)
            case .optimizing:
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
}
