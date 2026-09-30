import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class KeyboardModel {
    private(set) var styles: [PolishStyle] = PolishStyle.builtIns
    var selectedStyle: PolishStyle = .email
    private(set) var isPolishing = false
    private(set) var statusMessage: String?
    private(set) var hasFullAccess = false
    private(set) var needsInputModeSwitchKey = false

    @ObservationIgnored
    unowned let controller: KeyboardViewController

    init(controller: KeyboardViewController) {
        self.controller = controller
    }

    private var proxy: UITextDocumentProxy { controller.textDocumentProxy }

    func refresh() {
        hasFullAccess = controller.hasFullAccess
        needsInputModeSwitchKey = controller.needsInputModeSwitchKey
        guard hasFullAccess else {
            statusMessage = "Turn on Allow Full Access in Settings › General › Keyboard › Keyboards › Whisper Polish."
            return
        }
        statusMessage = nil
        let customJSON = AppGroup.defaults.string(forKey: SettingsKeys.customStyles) ?? ""
        styles = PolishStyle.all(customJSON: customJSON)
        let defaultID = AppGroup.defaults.string(forKey: SettingsKeys.defaultStyle) ?? PolishStyle.email.id
        selectedStyle = PolishStyle.find(id: defaultID, customJSON: customJSON) ?? .email
    }

    func polish() {
        guard hasFullAccess, !isPolishing else { return }
        let selected = proxy.selectedText ?? ""
        let before = proxy.documentContextBeforeInput ?? ""
        let after = proxy.documentContextAfterInput ?? ""
        let text = selected.isEmpty ? before + after : selected
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            statusMessage = "Type or select some text to polish."
            return
        }
        guard let jws = AppGroup.defaults.string(forKey: SettingsKeys.cloudEntitlementJWS) else {
            statusMessage = CloudPolishError.missingEntitlement.localizedDescription
            return
        }
        guard let endpoint = AppConfiguration.cloudPolishEndpoint else {
            statusMessage = CloudConfigurationError.missingEndpoint.localizedDescription
            return
        }

        let style = selectedStyle
        AppGroup.defaults.set(style.id, forKey: SettingsKeys.defaultStyle)
        isPolishing = true
        statusMessage = nil
        Task {
            defer { isPolishing = false }
            do {
                let result = try await CloudPolishService(endpoint: endpoint).polish(
                    text: text,
                    style: style,
                    transactionJWS: jws
                )
                if selected.isEmpty {
                    await replaceContext(beforeCount: before.count, afterCount: after.count, with: result.text)
                } else {
                    proxy.insertText(result.text)
                }
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    func record() {
        guard hasFullAccess else { return }
        controller.openContainingApp(AppGroup.dictationURL)
    }

    func insertPendingDictation() {
        guard hasFullAccess,
              let text = AppGroup.defaults.string(forKey: SettingsKeys.pendingDictation) else { return }
        AppGroup.defaults.removeObject(forKey: SettingsKeys.pendingDictation)
        proxy.insertText(text)
    }

    func insert(_ text: String) {
        proxy.insertText(text)
    }

    func deleteBackward() {
        proxy.deleteBackward()
    }

    /// The proxy only edits at the cursor: jump to the end of the text we
    /// read, delete all of it, then insert the rewrite.
    private func replaceContext(beforeCount: Int, afterCount: Int, with text: String) async {
        proxy.adjustTextPosition(byCharacterOffset: afterCount)
        // The host applies the cursor move asynchronously.
        try? await Task.sleep(for: .milliseconds(100))
        for _ in 0..<(beforeCount + afterCount) {
            proxy.deleteBackward()
        }
        proxy.insertText(text)
    }
}
