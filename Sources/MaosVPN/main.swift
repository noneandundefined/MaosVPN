import AppKit

if CommandLine.arguments.contains("--maosvpn-helper") {
    PrivilegedHelperServer.run()
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
