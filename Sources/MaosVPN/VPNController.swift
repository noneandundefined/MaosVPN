import Foundation
import Darwin
import MaosVPNCore

final class VPNController {
    enum State {
        case disconnected
        case connecting
        case connected
        case disconnecting
    }

    private let stateQueue = DispatchQueue(label: "app.maosvpn.state")
    private var storedState: State = .disconnected
    private(set) var state: State {
        get { stateQueue.sync { storedState } }
        set { setState(newValue) }
    }
    var onStateChange: ((State) -> Void)?
    var onLog: ((String) -> Void)?

    private let worker = DispatchQueue(label: "app.maosvpn.controller", qos: .userInitiated)
    private let helper = PrivilegedHelperClient()
    private let defaults = UserDefaults.standard
    private let pidKey = "activeSingBoxPID"

    var isConnected: Bool {
        guard let pid = savedPID else { return false }
        return isManagedProcess(pid)
    }

    init() {
        if isConnected { storedState = .connected }
    }

    /// Clears a stale "connected" state after sing-box has already exited.
    func noteProcessIfExited() -> Bool {
        guard state == .connected, let pid = savedPID, !processExists(pid) else { return false }
        savedPID = nil
        state = .disconnected
        return true
    }

    private func setState(_ newValue: State) {
        let changed = stateQueue.sync { () -> Bool in
            guard storedState != newValue else { return false }
            storedState = newValue
            return true
        }
        guard changed else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.onStateChange?(newValue)
            NotificationCenter.default.post(name: .maosVPNConnectionStateDidChange, object: self)
        }
    }

    func connect(profile: VPNProfile, completion: @escaping (Error?) -> Void) {
        if state == .connected && !isConnected {
            savedPID = nil
            state = .disconnected
        }
        guard state == .disconnected else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        state = .connecting

        worker.async { [weak self] in
            guard let self = self else { return }
            do {
                if let previous = self.savedPID, self.isManagedProcess(previous) {
                    self.state = .connected
                    DispatchQueue.main.async { completion(nil) }
                    return
                }
                let coreURL = try self.coreURL()
                let configURL = try self.writeConfig(for: profile)
                try self.validate(coreURL: coreURL, configURL: configURL)

                let pid = try self.helper.start(configURL: configURL)
                self.savedPID = pid
                Thread.sleep(forTimeInterval: 0.8)
                guard self.isManagedProcess(pid) else {
                    try? self.helper.stop(pid: pid)
                    self.savedPID = nil
                    throw MaosVPNError.processDidNotStart(self.readLogTail())
                }
                self.state = .connected
                self.emitLog("\(L10n.text(.vpnConnected)) \(profile.name)")
                DispatchQueue.main.async { completion(nil) }
            } catch {
                self.state = .disconnected
                self.emitLog(error.localizedDescription)
                DispatchQueue.main.async { completion(error) }
            }
        }
    }

    func disconnect(completion: @escaping (Error?) -> Void) {
        if state == .connecting || state == .disconnecting {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        guard state == .connected || isConnected else {
            state = .disconnected
            completion(nil)
            return
        }
        state = .disconnecting
        worker.async { [weak self] in
            guard let self = self else { return }
            do {
                try self.stopSynchronously()
                self.state = .disconnected
                self.emitLog(L10n.text(.vpnDisconnected))
                DispatchQueue.main.async { completion(nil) }
            } catch {
                self.state = .connected
                self.emitLog(error.localizedDescription)
                DispatchQueue.main.async { completion(error) }
            }
        }
    }

    func stopSynchronously() throws {
        guard let pid = savedPID else { return }
        guard processExists(pid) else {
            savedPID = nil
            return
        }
        do {
            try helper.stop(pid: pid)
        } catch {
            // The core can exit between the local PID check and the helper
            // request. An already exited/non-managed process is disconnected.
            guard isManagedProcess(pid) else {
                savedPID = nil
                return
            }
            throw error
        }
        savedPID = nil
    }

    private func coreURL() throws -> URL {
        guard let url = Bundle.main.url(forResource: "sing-box", withExtension: nil),
              FileManager.default.isExecutableFile(atPath: url.path) else {
            throw MaosVPNError.missingCore
        }
        return url
    }

    private func writeConfig(for profile: VPNProfile) throws -> URL {
        let directory = try applicationSupportDirectory()
        let configURL = directory.appendingPathComponent("config.json")
        let config = try SingBoxConfigBuilder.makeConfig(for: profile)
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: configURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
        return configURL
    }

    private func validate(coreURL: URL, configURL: URL) throws {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = coreURL
        process.arguments = ["check", "-c", configURL.path]
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8) ?? "\(L10n.text(.exitCode)) \(process.terminationStatus)"
            throw MaosVPNError.invalidConfiguration(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private func applicationSupportDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base.appendingPathComponent("MaosVPN", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func logURL() -> URL {
        let uid = getuid()
        return URL(fileURLWithPath: "/tmp/maosvpn-\(uid).log")
    }

    private func readLogTail() -> String {
        guard let data = try? Data(contentsOf: logURL()),
              let text = String(data: data, encoding: .utf8) else { return L10n.text(.logUnavailable) }
        return String(text.suffix(3000))
    }

    private func processExists(_ pid: Int32) -> Bool {
        return kill(pid, 0) == 0 || errno == EPERM
    }

    private func isManagedProcess(_ pid: Int32) -> Bool {
        guard processExists(pid) else { return false }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(pid), "-o", "command="]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false
        }
        guard process.terminationStatus == 0 else { return false }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let command = String(data: data, encoding: .utf8) ?? ""
        return command.contains("app.maosvpn.sing-box")
            || (command.contains("sing-box") && command.contains("MaosVPN/config.json"))
    }

    private var savedPID: Int32? {
        get {
            let value = defaults.integer(forKey: pidKey)
            return value > 1 && value <= Int(Int32.max) ? Int32(value) : nil
        }
        set {
            if let value = newValue {
                defaults.set(Int(value), forKey: pidKey)
            } else {
                defaults.removeObject(forKey: pidKey)
            }
        }
    }

    private func emitLog(_ value: String) {
        DispatchQueue.main.async { [weak self] in self?.onLog?(value) }
    }
}
