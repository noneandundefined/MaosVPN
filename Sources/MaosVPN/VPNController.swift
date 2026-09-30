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

    private(set) var state: State = .disconnected {
        didSet {
            let currentState = state
            DispatchQueue.main.async { [weak self] in self?.onStateChange?(currentState) }
        }
    }
    var onStateChange: ((State) -> Void)?
    var onLog: ((String) -> Void)?

    private let worker = DispatchQueue(label: "app.maosvpn.controller", qos: .userInitiated)
    private let defaults = UserDefaults.standard
    private let pidKey = "activeSingBoxPID"

    var isConnected: Bool {
        guard let pid = savedPID else { return false }
        return isManagedProcess(pid)
    }

    init() {
        if isConnected { state = .connected }
    }

    func connect(profile: VPNProfile, completion: @escaping (Error?) -> Void) {
        if state == .connected && !isConnected {
            savedPID = nil
            state = .disconnected
        }
        guard state == .disconnected else { return }
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

                let logURL = self.logURL()
                // Catalina's /usr/bin/nohup can fail with TIOCNOTTY when it is
                // launched through `osascript ... with administrator privileges`.
                // Closing stdin and redirecting both output streams lets the
                // non-interactive shell release the background process safely.
                let command = "\(self.shellQuote(coreURL.path)) run -c \(self.shellQuote(configURL.path)) < /dev/null > \(self.shellQuote(logURL.path)) 2>&1 & echo $!"
                let output = try self.runPrivileged(command)
                guard let pid = Int32(output.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 else {
                    throw MaosVPNError.processDidNotStart(output)
                }
                self.savedPID = pid
                Thread.sleep(forTimeInterval: 0.8)
                guard self.isManagedProcess(pid) else {
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
        if processExists(pid) && isManagedProcess(pid) {
            // Only a numeric PID created and persisted by this app is interpolated here.
            _ = try runPrivileged("kill -TERM \(pid); for i in 1 2 3 4 5; do kill -0 \(pid) 2>/dev/null || exit 0; sleep 1; done; kill -KILL \(pid) 2>/dev/null || true")
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

    private func runPrivileged(_ shellCommand: String) throws -> String {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "do shell script \(appleScriptString(shellCommand)) with administrator privileges"]
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()

        let stdout = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw MaosVPNError.privilegeHelper(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return stdout
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
        return command.contains("sing-box") && command.contains("MaosVPN/config.json")
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

    private func shellQuote(_ value: String) -> String {
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func appleScriptString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }

    private func emitLog(_ value: String) {
        DispatchQueue.main.async { [weak self] in self?.onLog?(value) }
    }
}
