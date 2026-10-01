import CryptoKit
import Darwin
import Foundation
import MaosVPNCore

private let helperSocketPath = "/var/run/app.maosvpn.helper.sock"
private let helperExecutablePath = "/Library/PrivilegedHelperTools/app.maosvpn.helper"
private let helperCorePath = "/Library/PrivilegedHelperTools/app.maosvpn.sing-box"
private let helperUIDPath = "/Library/PrivilegedHelperTools/app.maosvpn.allowed-uid"
private let helperLabel = "app.maosvpn.helper"

/// Root-side process. It is the app executable launched by launchd with `--maosvpn-helper`.
/// The administrator password is used only to install this service, never stored.
enum PrivilegedHelperServer {
    static func run() -> Never {
        signal(SIGPIPE, SIG_IGN)
        guard let allowedUID = readAllowedUID() else {
            log("allowed user id is missing")
            exit(1)
        }
        guard let listenFD = listenSocket() else {
            log("could not open \(helperSocketPath)")
            exit(1)
        }
        defer { close(listenFD) }
        while true {
            let client = accept(listenFD, nil, nil)
            if client < 0 { continue }
            handle(client: client, allowedUID: allowedUID)
            close(client)
        }
    }

    private static func handle(client: Int32, allowedUID: uid_t) {
        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        guard getpeereid(client, &peerUID, &peerGID) == 0, peerUID == allowedUID else {
            reply(client, "ERR\tunauthorized")
            return
        }
        guard peerIsCurrentHelper(client) else {
            reply(client, "ERR\tunauthorized-client")
            return
        }
        guard let line = readLine(client) else {
            reply(client, "ERR\tbad-request")
            return
        }
        let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        switch parts.first {
        case "STATUS":
            guard let helperHash = sha256File(helperExecutablePath),
                  let coreHash = sha256File(helperCorePath) else {
                reply(client, "ERR\tnot-installed")
                return
            }
            reply(client, "OK\t\(helperHash)\t\(coreHash)")
        case "START":
            guard parts.count == 2 else {
                reply(client, "ERR\tbad-request")
                return
            }
            do {
                let pid = try startCore(configPath: parts[1], uid: peerUID, gid: peerGID)
                reply(client, "OK\t\(pid)")
            } catch let error as HelperCommandError {
                reply(client, "ERR\t\(error.description)")
            } catch {
                reply(client, "ERR\tstart-failed")
            }
        case "STOP":
            guard parts.count == 2, let pid = pid_t(parts[1]), pid > 1 else {
                reply(client, "ERR\tbad-request")
                return
            }
            if kill(pid, 0) != 0 {
                if errno == ESRCH {
                    reply(client, "OK")
                } else {
                    reply(client, "ERR\tstop-failed")
                }
                return
            }
            if !isManagedCore(pid) {
                var status: Int32 = 0
                if waitpid(pid, &status, WNOHANG) == pid {
                    reply(client, "OK")
                    return
                }
                reply(client, "ERR\tnot-our-process")
                return
            }
            stop(pid)
            reply(client, "OK")
        default:
            reply(client, "ERR\tunknown-command")
        }
    }

    private static func startCore(configPath: String, uid: uid_t, gid: gid_t) throws -> pid_t {
        let config = try verifiedConfigPath(configPath, uid: uid)
        let logPath = "/tmp/maosvpn-\(uid).log"
        let devNull = open("/dev/null", O_RDONLY)
        if devNull < 0 { throw HelperCommandError("open-null") }
        defer { close(devNull) }
        let logFD = open(logPath, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        if logFD < 0 { throw HelperCommandError("open-log") }
        defer { close(logFD) }
        _ = fchown(logFD, uid, gid)
        guard let pid = spawn(core: helperCorePath, config: config, stdin: devNull, output: logFD), pid > 1 else {
            throw HelperCommandError("spawn-failed")
        }
        return pid
    }

    private static func stop(_ pid: pid_t) {
        if processHasExited(pid) { return }
        guard isManagedCore(pid) else { return }
        _ = kill(pid, SIGTERM)
        for _ in 0..<50 {
            if processHasExited(pid) { return }
            usleep(100_000)
        }
        if isManagedCore(pid) {
            _ = kill(pid, SIGKILL)
            for _ in 0..<20 {
                if processHasExited(pid) { return }
                usleep(100_000)
            }
        }
    }

    /// Reaps a core started by this helper. Without waitpid, a terminated core
    /// remains a zombie and kill(pid, 0) incorrectly reports that it still exists.
    private static func processHasExited(_ pid: pid_t) -> Bool {
        var status: Int32 = 0
        if waitpid(pid, &status, WNOHANG) == pid { return true }
        if kill(pid, 0) == 0 { return false }
        return errno == ESRCH
    }

    private static func verifiedConfigPath(_ path: String, uid: uid_t) throws -> String {
        guard !path.contains("\t"), !path.contains("\n"),
              let home = homeDirectory(uid) else { throw HelperCommandError("bad-config") }
        let expected = (home as NSString).appendingPathComponent("Library/Application Support/MaosVPN/config.json")
        guard let resolved = realPath(path), let expectedResolved = realPath(expected),
              resolved == expectedResolved else { throw HelperCommandError("bad-config") }
        var info = stat()
        guard stat(resolved, &info) == 0,
              info.st_uid == uid,
              (info.st_mode & S_IFMT) == S_IFREG,
              (info.st_mode & S_IWGRP) == 0,
              (info.st_mode & S_IWOTH) == 0,
              info.st_size > 0,
              info.st_size < 512_000 else { throw HelperCommandError("bad-config") }
        return resolved
    }

    private static func peerIsCurrentHelper(_ client: Int32) -> Bool {
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(client, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0,
              let peerPath = executablePath(pid),
              let peerHash = sha256File(peerPath),
              let selfHash = sha256File(helperExecutablePath),
              peerHash == selfHash else { return false }
        return true
    }

    private static func isManagedCore(_ pid: pid_t) -> Bool {
        guard let command = commandLine(pid) else { return false }
        return command.contains("sing-box") && command.contains("MaosVPN/config.json")
    }

    private static func commandLine(_ pid: pid_t) -> String? {
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
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }

    private static func listenSocket() -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var flags = fcntl(fd, F_GETFD)
        if flags >= 0 { _ = fcntl(fd, F_SETFD, flags | FD_CLOEXEC) }
        unlink(helperSocketPath)
        guard var address = unixAddress(helperSocketPath) else {
            close(fd)
            return nil
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            close(fd)
            return nil
        }
        _ = chmod(helperSocketPath, 0o666)
        return fd
    }

    private static func spawn(core: String, config: String, stdin: Int32, output: Int32) -> pid_t? {
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { return nil }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawn_file_actions_adddup2(&actions, stdin, STDIN_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, output, STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, output, STDERR_FILENO) == 0 else { return nil }

        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { return nil }
        defer { posix_spawnattr_destroy(&attributes) }
        _ = posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))

        let arguments = [core, "run", "-c", config]
        let cStrings: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        defer {
            for case let pointer? in cStrings {
                free(UnsafeMutableRawPointer(pointer))
            }
        }
        var argv = cStrings
        var pid: pid_t = 0
        let result = core.withCString { path -> Int32 in
            argv.withUnsafeMutableBufferPointer { buffer -> Int32 in
                guard let argvPointer = buffer.baseAddress else { return EINVAL }
                return posix_spawn(&pid, path, &actions, &attributes, argvPointer, environ)
            }
        }
        return result == 0 ? pid : nil
    }

    private static func readAllowedUID() -> uid_t? {
        guard let text = try? String(contentsOfFile: helperUIDPath, encoding: .utf8),
              let value = UInt32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return uid_t(value)
    }

    private static func homeDirectory(_ uid: uid_t) -> String? {
        guard let entry = getpwuid(uid), let directory = entry.pointee.pw_dir else { return nil }
        return String(cString: directory)
    }

    private static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [Int8](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func realPath(_ path: String) -> String? {
        guard let pointer = realpath(path, nil) else { return nil }
        defer { free(pointer) }
        return String(cString: pointer)
    }

    private static func readLine(_ fd: Int32) -> String? {
        var bytes = [UInt8]()
        bytes.reserveCapacity(256)
        var byte: UInt8 = 0
        while bytes.count < 8192 {
            let count = read(fd, &byte, 1)
            if count == 0 { break }
            if count < 0 { return nil }
            if byte == 10 { break }
            if byte != 13 { bytes.append(byte) }
        }
        return String(bytes: bytes, encoding: .utf8)
    }

    private static func reply(_ fd: Int32, _ line: String) {
        var text = line
        if !text.hasSuffix("\n") { text.append("\n") }
        _ = text.withCString { pointer in
            write(fd, pointer, strlen(pointer))
        }
    }

    private static func log(_ message: String) {
        fputs("maosvpn-helper: \(message)\n", stderr)
    }
}

private struct HelperCommandError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

final class PrivilegedHelperClient {
    private let lock = NSLock()
    private var readyFingerprint: String?

    func start(configURL: URL) throws -> Int32 {
        let response = try exchange("START\t\(configURL.path)")
        let parts = response.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, parts[0] == "OK", let pid = Int32(parts[1]), pid > 1 else {
            throw failed(response)
        }
        return pid
    }

    func stop(pid: Int32) throws {
        try lock.locked {
            let request = "STOP\t\(pid)"
            var lastUnavailable = false
            for attempt in 0..<16 {
                do {
                    let response = try roundTrip(request)
                    let normalized = response.lowercased()
                    if response == "OK"
                        || normalized.contains("no-process")
                        || normalized.contains("no such process")
                        || normalized.contains("esrch") {
                        return
                    }
                    throw failed(response)
                } catch is HelperUnavailable {
                    lastUnavailable = true
                    if !processExists(pid) { return }
                    if attempt < 15 { Thread.sleep(forTimeInterval: 0.2) }
                }
            }
            if lastUnavailable { throw helperDown() }
        }
    }

    private func exchange(_ line: String) throws -> String {
        try lock.locked {
            try ensureInstalled()
            do {
                return try roundTrip(line)
            } catch is HelperUnavailable {
                readyFingerprint = nil
                try ensureInstalled()
                do {
                    return try roundTrip(line)
                } catch is HelperUnavailable {
                    throw helperDown()
                }
            }
        }
    }

    private func helperDown() -> Error {
        MaosVPNError.privilegeHelper(AppLanguage.text(
            russian: "Служба VPN не отвечает. Подключитесь ещё раз.",
            english: "The VPN helper is not responding. Try connecting again."
        ))
    }

    private func ensureInstalled() throws {
        let executable = try bundleExecutable()
        let core = try bundledCore()
        let fingerprint = try "\(sha256FileOrThrow(executable)):\(sha256FileOrThrow(core))"
        if readyFingerprint == fingerprint { return }
        if waitForInstalledHelper(fingerprint: fingerprint, timeout: 1.6) {
            readyFingerprint = fingerprint
            return
        }
        try install(executable: executable, core: core, uid: getuid())
        let deadline = Date().addingTimeInterval(5)
        var last = "helper did not start"
        while Date() < deadline {
            if let status = try? statusLine(), status == "OK\t" + fingerprint.replacingOccurrences(of: ":", with: "\t") {
                readyFingerprint = fingerprint
                return
            }
            if let status = try? statusLine() { last = status }
            Thread.sleep(forTimeInterval: 0.2)
        }
        readyFingerprint = nil
        throw MaosVPNError.privilegeHelper(AppLanguage.text(
            russian: "Служба VPN не запустилась после установки. \(last)",
            english: "The VPN helper did not start after installation. \(last)"
        ))
    }

    private func install(executable: URL, core: URL, uid: uid_t) throws {
        let script = installScript(executable: executable.path, core: core.path, uid: uid)
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "do shell script \(appleScriptString(script)) with administrator privileges"]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard process.terminationStatus == 0 else {
            throw MaosVPNError.privilegeHelper(AppLanguage.text(
                russian: "macOS не подтвердила установку службы VPN.\n\(text)",
                english: "macOS did not approve installing the VPN helper.\n\(text)"
            ))
        }
    }

    private func statusLine() throws -> String {
        try roundTrip("STATUS")
    }

    /// launchd may be restarting an already installed helper. Waiting briefly
    /// avoids showing an unnecessary administrator prompt during that window.
    private func waitForInstalledHelper(fingerprint: String, timeout: TimeInterval) -> Bool {
        let expected = "OK\t" + fingerprint.replacingOccurrences(of: ":", with: "\t")
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            do {
                return try statusLine() == expected
            } catch is HelperUnavailable {
                if Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
            } catch {
                return false
            }
        } while Date() < deadline
        return false
    }

    private func roundTrip(_ line: String) throws -> String {
        guard var address = unixAddress(helperSocketPath) else {
            throw failed("bad-socket")
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw failed("socket") }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 4, tv_usec: 0)
        let timeoutLength = socklen_t(MemoryLayout<timeval>.size)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, timeoutLength)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, timeoutLength)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connected != 0 { throw HelperUnavailable() }
        var request = line
        if !request.hasSuffix("\n") { request.append("\n") }
        let written = request.withCString { pointer in
            write(fd, pointer, strlen(pointer))
        }
        if written < 0 { throw HelperUnavailable() }
        var bytes = [UInt8]()
        var byte: UInt8 = 0
        while bytes.count < 8192 {
            let count = read(fd, &byte, 1)
            if count == 0 { break }
            if count < 0 { throw HelperUnavailable() }
            if byte == 10 { break }
            if byte != 13 { bytes.append(byte) }
        }
        guard let response = String(bytes: bytes, encoding: .utf8), !response.isEmpty else {
            throw HelperUnavailable()
        }
        return response
    }

    private func processExists(_ pid: Int32) -> Bool {
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    private func bundleExecutable() throws -> URL {
        guard let url = Bundle.main.executableURL else { throw MaosVPNError.missingCore }
        return url
    }

    private func bundledCore() throws -> URL {
        guard let url = Bundle.main.url(forResource: "sing-box", withExtension: nil),
              FileManager.default.isExecutableFile(atPath: url.path) else {
            throw MaosVPNError.missingCore
        }
        return url
    }

    private func sha256FileOrThrow(_ url: URL) throws -> String {
        guard let hash = sha256File(url.path) else { throw MaosVPNError.missingCore }
        return hash
    }

    private func failed(_ details: String) -> Error {
        MaosVPNError.privilegeHelper(details)
    }

    private func installScript(executable: String, core: String, uid: uid_t) -> String {
        """
        set -e
        mkdir -p /Library/PrivilegedHelperTools
        cp -f \(shellQuote(executable)) \(helperExecutablePath).new
        cp -f \(shellQuote(core)) \(helperCorePath).new
        chown root:wheel \(helperExecutablePath).new \(helperCorePath).new
        chmod 755 \(helperExecutablePath).new \(helperCorePath).new
        mv -f \(helperExecutablePath).new \(helperExecutablePath)
        mv -f \(helperCorePath).new \(helperCorePath)
        printf '%s\\n' \(uid) > \(helperUIDPath)
        chown root:wheel \(helperUIDPath)
        chmod 644 \(helperUIDPath)
        cat > /Library/LaunchDaemons/\(helperLabel).plist <<'EOF'
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        <key>Label</key>
        <string>\(helperLabel)</string>
        <key>ProgramArguments</key>
        <array>
        <string>\(helperExecutablePath)</string>
        <string>--maosvpn-helper</string>
        </array>
        <key>RunAtLoad</key>
        <true/>
        <key>KeepAlive</key>
        <true/>
        <key>ThrottleInterval</key>
        <integer>2</integer>
        <key>StandardOutPath</key>
        <string>/var/log/maosvpn-helper.log</string>
        <key>StandardErrorPath</key>
        <string>/var/log/maosvpn-helper.log</string>
        </dict>
        </plist>
        EOF
        chown root:wheel /Library/LaunchDaemons/\(helperLabel).plist
        chmod 644 /Library/LaunchDaemons/\(helperLabel).plist
        launchctl bootout system/\(helperLabel) >/dev/null 2>&1 || true
        launchctl enable system/\(helperLabel) >/dev/null 2>&1 || true
        launchctl bootstrap system /Library/LaunchDaemons/\(helperLabel).plist
        """
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func appleScriptString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }
}

private struct HelperUnavailable: Error {}

private extension NSLock {
    func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

private func unixAddress(_ path: String) -> sockaddr_un? {
    guard path.utf8.count < 104 else { return nil }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    _ = path.withCString { source in
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            strncpy(UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self), source, 103)
        }
    }
    return address
}

private func sha256File(_ path: String) -> String? {
    let url = URL(fileURLWithPath: path)
    guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
          size > 0, size < 80_000_000,
          let data = try? Data(contentsOf: url) else { return nil }
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
