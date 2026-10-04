import SwiftUI

/// One-time first-launch setup: pick a transcription engine and download it,
/// introduce Whisper Polish Cloud, choose a default polish style, allow the keyboard to paste.
struct OnboardingView: View {
    @Environment(TranscriptionService.self) private var transcription
    @Environment(SubscriptionStore.self) private var subscription
    @AppStorage(SettingsKeys.hasCompletedSetup) private var hasCompletedSetup = false
    @AppStorage(SettingsKeys.engine) private var engineRaw = TranscriptionEngine.parakeet.rawValue
    @AppStorage(SettingsKeys.defaultStyle, store: AppGroup.defaults) private var defaultStyleRaw = PolishStyle.email.id

    @State private var step = 0
    @State private var cloudError: String?
    @State private var pasteSetup = PasteSetup.notStarted

    private enum PasteSetup {
        case notStarted
        case asking
        case needsCopy
        case sentToSettings
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                ForEach(0..<stepCount) { index in
                    Capsule()
                        .fill(index <= step ? Color.polishTeal : Color(.systemFill))
                        .frame(height: 4)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)

            switch step {
            case 0: engineStep
            case 1 where showsCloudStep: cloudStep
            case stepCount - 1: pasteStep
            default: styleStep
            }
        }
        .background(Color(.systemGroupedBackground))
        .interactiveDismissDisabled()
    }

    // MARK: - Step 1: engine

    private var engineStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            header(
                title: "Choose a transcription model",
                subtitle: "Runs entirely on your phone — free, private, works offline. Downloaded once, now, so recording is instant later."
            )

            ForEach(TranscriptionEngine.allCases) { engine in
                Button {
                    guard !transcription.state.isDownloading else { return }
                    engineRaw = engine.rawValue
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(engine.displayName)
                                    .font(.subheadline.weight(.semibold))
                                if engine == .parakeet {
                                    Text("Recommended")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(Color.polishTeal)
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 2)
                                        .background(Capsule().fill(Color.polishTealSoft))
                                }
                            }
                            Text("\(engine.subtitle) · \(engine.sizeLabel)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: engineRaw == engine.rawValue ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(engineRaw == engine.rawValue ? Color.polishTeal : Color(.systemFill))
                            .font(.title3)
                    }
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemGroupedBackground)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(engineRaw == engine.rawValue ? Color.polishTeal : .clear, lineWidth: 1.5)
                    )
                }
                .buttonStyle(.plain)
            }

            Spacer()

            downloadFooter
        }
        .padding(24)
    }

    @ViewBuilder
    private var downloadFooter: some View {
        switch transcription.state {
        case .downloading(let fraction):
            VStack(spacing: 8) {
                ProgressView(value: fraction)
                    .tint(.polishTeal)
                Text(fraction.map { "Downloading… \(Int($0 * 100))%" } ?? "Preparing download…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Keep the app open. This is the one-time part.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Button("Cancel") { transcription.cancelPreparation() }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
        case .loading:
            VStack(spacing: 8) {
                ProgressView()
                Text("Optimizing the model for your iPhone…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("One-time step — it can take a few minutes. Keep the app open.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
        case .ready where transcription.loadedEngine == transcription.selectedEngine:
            primaryButton("Continue") { step = 1 }
        case .failed(let message):
            VStack(spacing: 8) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .multilineTextAlignment(.center)
                primaryButton("Retry download") {
                    Task { await transcription.prepare() }
                }
            }
            .frame(maxWidth: .infinity)
        default:
            primaryButton("Download \(TranscriptionEngine(rawValue: engineRaw)?.displayName ?? "")") {
                Task { await transcription.prepare() }
            }
        }
    }

    private var stepCount: Int { showsCloudStep ? 4 : 3 }

    private var showsCloudStep: Bool { !AppConfiguration.isDevMode }

    // MARK: - Step 2: cloud plan

    private var cloudStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            header(
                title: "Polish with Whisper Polish Cloud",
                subtitle: "Subscribe for a simple monthly allowance. Transcription always stays on your phone."
            )

            VStack(alignment: .leading, spacing: 6) {
                Text("Up to \(CloudPlan.monthlyPolishLimit) cloud polishes per month")
                    .font(.headline)
                Text("\(subscription.priceText)/month · cancel anytime")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if subscription.isSubscribed {
                    Label("Subscription active", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Color.polishTeal)
                } else {
                    Button("Subscribe") {
                        Task {
                            do { try await subscription.purchase() }
                            catch { cloudError = error.localizedDescription }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.polishTeal)
                    .disabled(subscription.product == nil)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemGroupedBackground)))

            if let cloudError {
                Text(cloudError).font(.caption).foregroundStyle(.red)
            }

            Spacer()

            primaryButton("Continue") { step = 2 }

            Button("Set this up later in Settings") { step = 2 }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        }
        .padding(24)
    }

    // MARK: - Step 3: style

    private var styleStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            header(
                title: "Pick your usual style",
                subtitle: "Polish will preselect this style. You can always pick a different one per note."
            )

            FlowLayout(spacing: 8) {
                ForEach(PolishStyle.builtIns) { style in
                    Button {
                        defaultStyleRaw = style.id
                    } label: {
                        Text(style.name)
                            .font(.footnote.weight(defaultStyleRaw == style.id ? .semibold : .regular))
                            .foregroundStyle(defaultStyleRaw == style.id ? .white : .primary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(Capsule().fill(defaultStyleRaw == style.id ? Color.polishTeal : Color(.secondarySystemGroupedBackground)))
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer()

            primaryButton("Continue") { step = stepCount - 1 }
        }
        .padding(24)
    }

    // MARK: - Step 4: paste

    private var pasteStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            header(
                title: "Let the keyboard paste",
                subtitle: "The keyboard shows what you've copied so you can paste it with a tap. Unless you allow it once, iOS asks before every paste."
            )

            VStack(alignment: .leading, spacing: 10) {
                pasteInstruction(1, "Tap Allow Paste when iOS asks.")
                pasteInstruction(2, "In Settings, set Paste from Other Apps to Allow.")
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemGroupedBackground)))

            if pasteSetup == .needsCopy {
                Text("Copy some text in any app, then come back and tap Allow paste.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if pasteSetup == .sentToSettings {
                primaryButton("Start using Whisper Polish") { hasCompletedSetup = true }
            } else {
                primaryButton("Allow paste", action: allowPaste)
                    .disabled(pasteSetup == .asking)

                Button("Not now") { hasCompletedSetup = true }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(24)
    }

    /// Settings only lists Paste from Other Apps once iOS has asked about pasting,
    /// so this reads the clipboard to raise the prompt before opening Settings.
    private func allowPaste() {
        let pasteboard = UIPasteboard.general
        guard pasteboard.hasStrings || pasteboard.hasImages else {
            pasteSetup = .needsCopy
            return
        }
        pasteSetup = .asking
        Task {
            _ = await Task.detached {
                let pasteboard = UIPasteboard.general
                return pasteboard.hasStrings ? pasteboard.string != nil : pasteboard.image != nil
            }.value
            await UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
            pasteSetup = .sentToSettings
        }
    }

    private func pasteInstruction(_ number: Int, _ text: String) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: "\(number).circle.fill")
                .foregroundStyle(Color.polishTeal)
        }
        .font(.subheadline)
    }

    // MARK: - Shared bits

    private func header(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.title2.bold())
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 28)
        .padding(.bottom, 8)
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Capsule().fill(Color.polishTeal))
        }
        .buttonStyle(.plain)
    }
}
