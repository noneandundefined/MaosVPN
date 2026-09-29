import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A fixed light appearance keeps the UI predictable on Catalina and newer.
        NSApp.appearance = NSAppearance(named: .aqua)
        installMainMenu()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(languageDidChange(_:)),
            name: .maosVPNLanguageDidChange,
            object: nil
        )

        let controller = MainViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Maos VPN"
        window.minSize = NSSize(width: 920, height: 560)
        window.center()
        window.contentViewController = controller

        let windowController = MainWindowController(window: window, vpnController: controller.vpnController)
        self.windowController = windowController
        windowController.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()

        let applicationItem = NSMenuItem()
        applicationItem.title = "Maos VPN"
        mainMenu.addItem(applicationItem)
        let applicationMenu = NSMenu()
        applicationMenu.addItem(withTitle: L10n.text(.about), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(withTitle: L10n.text(.hide), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(withTitle: L10n.text(.quit), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        applicationItem.submenu = applicationMenu

        let editItem = NSMenuItem()
        editItem.title = L10n.text(.edit)
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: L10n.text(.edit))
        editMenu.addItem(withTitle: L10n.text(.undo), action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: L10n.text(.cut), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: L10n.text(.copy), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: L10n.text(.paste), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: L10n.text(.selectAll), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }

    @objc private func languageDidChange(_ notification: Notification) {
        installMainMenu()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let vpnController = windowController?.vpnController else {
            return .terminateNow
        }

        switch vpnController.state {
        case .connecting, .disconnecting:
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = L10n.text(.operationInProgress)
            alert.informativeText = L10n.text(.waitForOperation)
            alert.addButton(withTitle: L10n.text(.okay))
            alert.runModal()
            return .terminateCancel
        case .disconnected, .connected:
            break
        }

        guard vpnController.isConnected else { return .terminateNow }

        // A live root TUN process must be stopped so macOS routes are restored.
        do {
            try vpnController.stopSynchronously()
            return .terminateNow
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = L10n.text(.disconnectFailed)
            alert.informativeText = "\(L10n.text(.disconnectBeforeQuit))\n\n\(error.localizedDescription)"
            alert.addButton(withTitle: L10n.text(.stay))
            alert.addButton(withTitle: L10n.text(.quitAnyway))
            return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
        }
    }
}

final class MainWindowController: NSWindowController {
    let vpnController: VPNController

    init(window: NSWindow, vpnController: VPNController) {
        self.vpnController = vpnController
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
