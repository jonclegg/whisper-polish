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

                Section("Transcription") {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Parakeet V3 (on-device)")
                            Text(transcriptionStatus)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        switch transcription.state {
                        case .ready:
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.waveGreen)
                        case .downloading:
                            ProgressView()
                        case .idle, .failed:
                            Button("Download") {
                                Task { await transcription.prepare() }
                            }
                            .font(.footnote.weight(.semibold))
                        }
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

    private var transcriptionStatus: String {
        switch transcription.state {
        case .idle: return "0.6B · ~500 MB · not downloaded"
        case .downloading: return "Downloading model…"
        case .ready: return "0.6B · downloaded"
        case .failed(let message): return "Download failed: \(message)"
        }
    }
}
