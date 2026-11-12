import AppKit
import SwiftUI

struct SettingsView: View {
    let preferences: Preferences
    let models: ModelManager
    let s1Mini: S1MiniModel
    let onHotkeyChange: (HotkeyBinding) -> Void
    let fixShortcutRegistration: FixShortcutRegistration
    let onLaunchAtLoginChange: () -> Void

    var body: some View {
        TabView {
            GeneralSettingsTab(
                preferences: preferences, onHotkeyChange: onHotkeyChange,
                fixShortcutRegistration: fixShortcutRegistration,
                onLaunchAtLoginChange: onLaunchAtLoginChange)
                .tabItem { Label("General", systemImage: "gearshape") }
            ModelsSettingsTab(models: models)
                .tabItem { Label("Models", systemImage: "square.and.arrow.down") }
            CleanupSettingsTab(preferences: preferences, s1Mini: s1Mini)
                .tabItem { Label("Cleanup", systemImage: "wand.and.sparkles") }
        }
        .frame(width: 520, height: 420)
    }
}

private struct GeneralSettingsTab: View {
    let preferences: Preferences
    let onHotkeyChange: (HotkeyBinding) -> Void
    let fixShortcutRegistration: FixShortcutRegistration
    let onLaunchAtLoginChange: () -> Void

    @State private var insertionMode: InsertionMode = .paste
    @State private var launchAtLogin = false

    var body: some View {
        Form {
            Section("Hold to talk") {
                HotkeyPickerView(preferences: preferences, onHotkeyChange: onHotkeyChange)
            }
            FixShortcutSection(preferences: preferences, registration: fixShortcutRegistration)
            Section("Insertion") {
                Picker("When dictation finishes", selection: $insertionMode) {
                    Text("Paste into the focused app").tag(InsertionMode.paste)
                    Text("Copy to the clipboard only").tag(InsertionMode.clipboardOnly)
                }
                .pickerStyle(.radioGroup)
            }
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            insertionMode = preferences.insertionMode
            launchAtLogin = LoginItem.isEnabled
        }
        .onChange(of: insertionMode) { _, new in preferences.insertionMode = new }
        .onChange(of: launchAtLogin) { _, new in
            LoginItem.setEnabled(new)
            onLaunchAtLoginChange()
        }
    }
}

/// The fix shortcut's recorder. Every change is written to `preferences` and
/// registered straight away, so it takes effect without a relaunch.
private struct FixShortcutSection: View {
    let preferences: Preferences
    let registration: FixShortcutRegistration

    @State private var shortcut = HotkeyBinding.defaultFixShortcut

    var body: some View {
        Section("Fix selected text") {
            HStack(alignment: .firstTextBaseline) {
                Text("Shortcut")
                Spacer()
                ShortcutRecorderView(
                    binding: recordedShortcut, rule: .fixShortcut,
                    onRecordingChange: { isRecording in
                        if isRecording {
                            registration.unregister()
                        } else {
                            registration.register(preferences.fixShortcut)
                        }
                    })
                Button("Reset") {
                    preferences.fixShortcut = .defaultFixShortcut
                    shortcut = .defaultFixShortcut
                    registration.register(preferences.fixShortcut)
                }
                .disabled(shortcut == .defaultFixShortcut)
            }
            if let error = registration.registrationError {
                Text(error.localizedDescription).font(.caption).foregroundStyle(.red)
            }
            Text("Select text in any app and press \(shortcut.displayName). \(S1Mini.displayName) cleans it up on this Mac and shows the edit for you to Replace, Copy or Dismiss. With nothing selected, it fixes the clipboard. Download the model in Cleanup.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear { shortcut = preferences.fixShortcut }
    }

    /// Persists as it is set, before the recorder reports that recording
    /// stopped, so the re-registration that follows, which reads
    /// `preferences`, picks up the new shortcut.
    private var recordedShortcut: Binding<HotkeyBinding> {
        Binding(
            get: { shortcut },
            set: { recorded in
                preferences.fixShortcut = recorded
                shortcut = recorded
            }
        )
    }
}

private struct ModelsSettingsTab: View {
    let models: ModelManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(ModelCatalog.all) { descriptor in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(descriptor.name).font(.body)
                        Text("\(descriptor.detail) · \(descriptor.sizeLabel)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    controls(for: descriptor)
                }
                .padding(.vertical, 4)
            }
            if let error = models.lastError {
                Text(error).font(.caption).foregroundStyle(.orange).padding(12)
            }
        }
    }

    /// Every control is gated on `models.isBusy`, which covers activation as
    /// well as downloading: loading a large model takes seconds, and an
    /// enabled "Use" or "Delete" during that window would start a second
    /// activation or pull files out from under the one already running.
    @ViewBuilder
    private func controls(for descriptor: ModelDescriptor) -> some View {
        switch models.state(for: descriptor) {
        case .notInstalled:
            Button("Install") { Task { try? await models.install(descriptor) } }
                .disabled(models.isBusy)
        case let .downloading(fraction):
            ProgressView(value: fraction).frame(width: 90)
        case .installed:
            if models.activatingModelID == descriptor.id {
                ProgressView().controlSize(.small)
            } else {
                HStack(spacing: 8) {
                    Button("Use") { Task { try? await models.makeActive(descriptor) } }
                        .disabled(models.isBusy)
                    Button("Delete") { try? models.delete(descriptor) }
                        .disabled(models.isBusy)
                }
            }
        case .active:
            HStack(spacing: 8) {
                Text("Active").foregroundStyle(.secondary)
                Button("Delete") { try? models.delete(descriptor) }
                    .disabled(models.isBusy)
            }
        }
    }
}

private struct CleanupSettingsTab: View {
    let preferences: Preferences
    let s1Mini: S1MiniModel

    @State private var enabled = true
    @State private var testResult: String?
    @State private var isTesting = false

    var body: some View {
        Form {
            Section {
                Toggle("Clean up transcripts", isOn: $enabled)
                Text("Cleanup runs entirely on this Mac with \(S1Mini.displayName). Nothing you say is sent anywhere. Until the model is downloaded, dictation inserts the raw transcript.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            s1MiniSection
            Section {
                HStack {
                    Button("Test") { runTest() }
                        .disabled(isTesting || s1Mini.state != .installed)
                    if let testResult {
                        Text(testResult).font(.caption).textSelection(.enabled)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { enabled = preferences.cleanupEnabled }
        // Writes only a genuine change. `onAppear` loading the stored value
        // into `@State` is itself a change from the initial value and fires
        // `onChange`, so writing unconditionally would persist that initial
        // value the first time the tab was ever opened.
        .onChange(of: enabled) { _, new in
            guard new != preferences.cleanupEnabled else { return }
            preferences.cleanupEnabled = new
        }
    }

    @ViewBuilder private var s1MiniSection: some View {
        Section(S1Mini.displayName) {
            HStack {
                switch s1Mini.state {
                case .notInstalled:
                    Text("Not downloaded")
                    Spacer()
                    Button("Download (484 MB)") { Task { await s1Mini.install() } }
                case let .downloading(fraction):
                    Text("Downloading…")
                    Spacer()
                    ProgressView(value: fraction).frame(width: 120)
                case .installed:
                    Text("Ready")
                    Spacer()
                    Button("Delete") { Task { await s1Mini.delete() } }
                }
            }
            if let error = s1Mini.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            Text("A small model built only for cleaning up dictation: it removes filler words and false starts, keeps your self-corrections, and fixes punctuation and capitalization. Anything slower than \(Int(DictationCoordinator.Config().cleanupTimeout)) seconds is abandoned and the raw transcript is used. It is also what the fix shortcut uses to fix selected text.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func runTest() {
        isTesting = true
        testResult = "Testing…"
        let sample = "so um I was thinking that we could uh maybe ship it on friday"
        Task {
            do {
                testResult = try await s1Mini.cleaner.clean(sample)
            } catch {
                // `S1MiniError` and `LlamaError` describe themselves without
                // the text they were given, so this is safe to put on screen.
                testResult = error.localizedDescription
            }
            isTesting = false
        }
    }
}
