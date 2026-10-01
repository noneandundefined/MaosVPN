import AppKit
import MaosVPNCore

final class StatusBarController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let statusMenuItem = NSMenuItem()
    private let connectMenuItem = NSMenuItem()
    private let disconnectMenuItem = NSMenuItem()
    private let openMenuItem = NSMenuItem()
    private let quitMenuItem = NSMenuItem()
    private let idleImage = StatusBarController.powerImage(connected: false)
    private let activeImage = StatusBarController.powerImage(connected: true)

    private let vpnController: VPNController
    private let selectedProfile: () -> VPNProfile?
    private let showWindow: () -> Void
    private let connect: () -> Void
    private let disconnect: () -> Void

    init(vpnController: VPNController,
         selectedProfile: @escaping () -> VPNProfile?,
         showWindow: @escaping () -> Void,
         connect: @escaping () -> Void,
         disconnect: @escaping () -> Void) {
        self.vpnController = vpnController
        self.selectedProfile = selectedProfile
        self.showWindow = showWindow
        self.connect = connect
        self.disconnect = disconnect
        super.init()
        statusMenuItem.isEnabled = false
        connectMenuItem.target = self
        connectMenuItem.action = #selector(connectFromMenu)
        disconnectMenuItem.target = self
        disconnectMenuItem.action = #selector(disconnectFromMenu)
        openMenuItem.target = self
        openMenuItem.action = #selector(openFromMenu)
        quitMenuItem.target = NSApp
        quitMenuItem.action = #selector(NSApplication.terminate(_:))
        menu.delegate = self
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())
        menu.addItem(connectMenuItem)
        menu.addItem(disconnectMenuItem)
        menu.addItem(.separator())
        menu.addItem(openMenuItem)
        menu.addItem(quitMenuItem)
        statusItem.menu = menu
        statusItem.button?.imagePosition = .imageOnly
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refreshAppearance),
            name: .maosVPNConnectionStateDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refreshAppearance),
            name: .maosVPNLanguageDidChange,
            object: nil
        )
        refreshAppearance()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        vpnController.noteProcessIfExited()
        refreshAppearance()
    }

    @objc private func refreshAppearance() {
        let state = vpnController.state
        let connected = state == .connected
        statusItem.button?.image = connected ? activeImage : idleImage
        switch state {
        case .disconnected:
            statusMenuItem.title = L10n.text(.disconnected)
        case .connecting:
            statusMenuItem.title = L10n.text(.connecting)
        case .connected:
            statusMenuItem.title = selectedProfile().map { ServerPlaceParser.parse($0.name).title } ?? L10n.text(.connected)
        case .disconnecting:
            statusMenuItem.title = L10n.text(.disconnecting)
        }
        connectMenuItem.title = L10n.text(.connect)
        disconnectMenuItem.title = L10n.text(.disconnect)
        openMenuItem.title = L10n.text(.openWindow)
        quitMenuItem.title = L10n.text(.quit)
        connectMenuItem.isEnabled = state == .disconnected && selectedProfile() != nil
        disconnectMenuItem.isEnabled = state == .connected
        let tip = connected ? L10n.text(.connected) : L10n.text(.disconnected)
        statusItem.button?.toolTip = "Maos VPN — \(tip)"
    }

    @objc private func connectFromMenu() {
        connect()
    }

    @objc private func disconnectFromMenu() {
        disconnect()
    }

    @objc private func openFromMenu() {
        showWindow()
    }

    private static func powerImage(connected: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            let center = NSPoint(x: 9, y: 8)
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: 5.2, startAngle: 130, endAngle: 50, clockwise: false)
            arc.lineWidth = connected ? 2.2 : 1.5
            arc.lineCapStyle = .round
            arc.stroke()
            let stem = NSBezierPath()
            stem.move(to: NSPoint(x: center.x, y: center.y + 1.2))
            stem.line(to: NSPoint(x: center.x, y: center.y + 6.5))
            stem.lineWidth = connected ? 2.2 : 1.5
            stem.lineCapStyle = .round
            stem.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }
}
