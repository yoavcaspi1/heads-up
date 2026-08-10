import AppKit
import SwiftUI

/// Owns the single Setup Guide window. Hide-on-close like Settings: the
/// wizard model (current step, pasted fields) survives show/hide cycles,
/// and its own JSON state file survives relaunches.
final class SetupWizardWindowController: NSObject, NSWindowDelegate {
    private(set) var window: NSWindow?
    let model: SetupWizardModel
    private let makeContent: () -> NSView

    init(credentials: GoogleCredentialsStore, registry: GoogleAccountsRegistry) {
        let supportDir = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask)[0]
            .appendingPathComponent("HeadsUp")
        try? FileManager.default.createDirectory(at: supportDir,
                                                 withIntermediateDirectories: true)
        let model = SetupWizardModel(
            stateURL: supportDir.appendingPathComponent("setup_wizard.json"),
            saveCredentials: { id, secret in
                credentials.save(clientId: id, clientSecret: secret)
            },
            credentialsConfigured: { credentials.isConfigured })
        self.model = model
        var closeWindow: (() -> Void)?
        self.makeContent = {
            NSHostingView(rootView: SetupWizardView(
                model: model,
                signIn: { _ = try await registry.addAccount() },
                onFinished: { closeWindow?() }))
        }
        super.init()
        closeWindow = { [weak self] in self?.window?.orderOut(nil) }
    }

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 500),
                             styleMask: [.titled, .closable],
                             backing: .buffered, defer: false)
            w.title = "Heads Up Setup Guide"
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.contentView = makeContent()
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Closing hides; the window is recreated cheaply but state lives in the model.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}
