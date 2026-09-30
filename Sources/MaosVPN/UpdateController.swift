import AppKit
import CryptoKit
import Foundation
import MaosVPNCore

final class UpdateController {
    private struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let downloadURL: String

            enum CodingKeys: String, CodingKey {
                case name
                case downloadURL = "browser_download_url"
            }
        }

        let tagName: String
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case assets
        }
    }

    private enum UpdateError: LocalizedError {
        case invalidResponse
        case invalidVersion
        case missingAssets
        case invalidDownloadURL
        case downloadFailed(String)
        case checksumMismatch
        case invalidPackage(String)
        case vpnIsActive
        case installationFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return AppLanguage.text(
                    russian: "GitHub вернул некорректный ответ об обновлении.",
                    english: "GitHub returned an invalid update response."
                )
            case .invalidVersion:
                return AppLanguage.text(
                    russian: "Не удалось определить версию обновления.",
                    english: "The update version could not be determined."
                )
            case .missingAssets:
                return AppLanguage.text(
                    russian: "В релизе отсутствует ZIP или файл SHA256SUMS.txt.",
                    english: "The release is missing its ZIP or SHA256SUMS.txt file."
                )
            case .invalidDownloadURL:
                return AppLanguage.text(
                    russian: "Релиз содержит небезопасную ссылку загрузки.",
                    english: "The release contains an unsafe download URL."
                )
            case .downloadFailed(let details):
                return AppLanguage.text(
                    russian: "Не удалось скачать обновление. \(details)",
                    english: "The update could not be downloaded. \(details)"
                )
            case .checksumMismatch:
                return AppLanguage.text(
                    russian: "Контрольная сумма обновления не совпадает. Установка отменена.",
                    english: "The update checksum does not match. Installation was cancelled."
                )
            case .invalidPackage(let details):
                return AppLanguage.text(
                    russian: "Пакет обновления не прошёл проверку. \(details)",
                    english: "The update package failed validation. \(details)"
                )
            case .vpnIsActive:
                return AppLanguage.text(
                    russian: "Сначала отключите VPN, затем выберите «Проверить обновления» в меню Maos VPN.",
                    english: "Disconnect the VPN first, then choose Check for Updates from the Maos VPN menu."
                )
            case .installationFailed(let details):
                return AppLanguage.text(
                    russian: "Не удалось установить обновление. \(details)",
                    english: "The update could not be installed. \(details)"
                )
            }
        }
    }

    private let releaseAPI = URL(string: "https://api.github.com/repos/noneandundefined/MaosVPN/releases/latest")!
    private let zipName = "MaosVPN-macOS-10.15-Intel.zip"
    private let checksumName = "SHA256SUMS.txt"
    private let lastCheckKey = "lastUpdateCheckDate"
    private let session: URLSession
    private let defaults: UserDefaults
    private let worker = DispatchQueue(label: "app.maosvpn.updater", qos: .userInitiated)
    private weak var presentingWindow: NSWindow?
    private let canInstall: () -> Bool
    private var isChecking = false
    private var isInstalling = false
    private var progressAlert: NSAlert?

    init(
        presentingWindow: NSWindow,
        session: URLSession = .shared,
        defaults: UserDefaults = .standard,
        canInstall: @escaping () -> Bool
    ) {
        self.presentingWindow = presentingWindow
        self.session = session
        self.defaults = defaults
        self.canInstall = canInstall
    }

    func checkAutomatically() {
        if let lastCheck = defaults.object(forKey: lastCheckKey) as? Date,
           Date().timeIntervalSince(lastCheck) < 6 * 60 * 60 {
            return
        }
        checkForUpdates(silent: true)
    }

    func checkForUpdates(silent: Bool) {
        guard !isChecking, !isInstalling else { return }
        isChecking = true

        var request = URLRequest(url: releaseAPI)
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("MaosVPN/\(currentVersionString)", forHTTPHeaderField: "User-Agent")

        session.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isChecking = false

                if let error = error {
                    if !silent { self.showError(UpdateError.downloadFailed(error.localizedDescription)) }
                    return
                }
                guard let http = response as? HTTPURLResponse,
                      (200...299).contains(http.statusCode),
                      let data = data,
                      let release = try? JSONDecoder().decode(Release.self, from: data) else {
                    if !silent { self.showError(UpdateError.invalidResponse) }
                    return
                }

                self.defaults.set(Date(), forKey: self.lastCheckKey)
                guard let current = AppVersion(self.currentVersionString),
                      let latest = AppVersion(release.tagName) else {
                    if !silent { self.showError(UpdateError.invalidVersion) }
                    return
                }

                if latest > current {
                    self.showAvailableUpdate(release, version: latest.description)
                } else if !silent {
                    self.showUpToDate()
                }
            }
        }.resume()
    }

    private var currentVersionString: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    private func showAvailableUpdate(_ release: Release, version: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = AppLanguage.text(
            russian: "Доступна версия \(version)",
            english: "Version \(version) is available"
        )
        alert.informativeText = AppLanguage.text(
            russian: "Maos VPN скачает обновление, проверит его и перезапустится. Текущая версия: \(currentVersionString).",
            english: "Maos VPN will download and verify the update, then restart. Current version: \(currentVersionString)."
        )
        alert.addButton(withTitle: AppLanguage.text(russian: "Обновить", english: "Update"))
        alert.addButton(withTitle: AppLanguage.text(russian: "Позже", english: "Later"))
        present(alert) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.beginInstallation(release, version: version)
        }
    }

    private func showUpToDate() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = AppLanguage.text(
            russian: "Установлена последняя версия",
            english: "Maos VPN is up to date"
        )
        alert.informativeText = AppLanguage.text(
            russian: "Текущая версия: \(currentVersionString).",
            english: "Current version: \(currentVersionString)."
        )
        alert.addButton(withTitle: AppLanguage.text(russian: "Хорошо", english: "OK"))
        present(alert, completion: nil)
    }

    private func beginInstallation(_ release: Release, version: String) {
        guard canInstall() else {
            showError(UpdateError.vpnIsActive)
            return
        }
        guard !isInstalling else { return }
        guard let zipAsset = release.assets.first(where: { $0.name == zipName }),
              let checksumAsset = release.assets.first(where: { $0.name == checksumName }) else {
            showError(UpdateError.missingAssets)
            return
        }
        guard let zipURL = secureDownloadURL(zipAsset.downloadURL),
              let checksumURL = secureDownloadURL(checksumAsset.downloadURL) else {
            showError(UpdateError.invalidDownloadURL)
            return
        }

        isInstalling = true
        showProgress()
        fetchData(from: checksumURL) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let error):
                self.finishInstallation(with: error)
            case .success(let checksumData):
                self.downloadArchive(from: zipURL, checksumData: checksumData, version: version)
            }
        }
    }

    private func fetchData(from url: URL, completion: @escaping (Result<Data, Error>) -> Void) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("MaosVPN/\(currentVersionString)", forHTTPHeaderField: "User-Agent")
        session.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(UpdateError.downloadFailed(error.localizedDescription)))
                return
            }
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  let data = data, !data.isEmpty else {
                completion(.failure(UpdateError.downloadFailed("HTTP response was invalid.")))
                return
            }
            completion(.success(data))
        }.resume()
    }

    private func downloadArchive(from url: URL, checksumData: Data, version: String) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 120
        request.setValue("MaosVPN/\(currentVersionString)", forHTTPHeaderField: "User-Agent")
        session.downloadTask(with: request) { [weak self] temporaryURL, response, error in
            guard let self = self else { return }
            if let error = error {
                self.finishInstallation(with: UpdateError.downloadFailed(error.localizedDescription))
                return
            }
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  let temporaryURL = temporaryURL else {
                self.finishInstallation(with: UpdateError.downloadFailed("HTTP response was invalid."))
                return
            }

            do {
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("MaosVPNUpdate-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let archiveURL = directory.appendingPathComponent(self.zipName)
                try FileManager.default.copyItem(at: temporaryURL, to: archiveURL)

                self.worker.async {
                    do {
                        try self.validateAndInstall(
                            archiveURL: archiveURL,
                            checksumData: checksumData,
                            expectedVersion: version,
                            temporaryDirectory: directory
                        )
                        try? FileManager.default.removeItem(at: directory)
                        DispatchQueue.main.async { self.finishInstallation(with: nil) }
                    } catch {
                        try? FileManager.default.removeItem(at: directory)
                        self.finishInstallation(with: error)
                    }
                }
            } catch {
                self.finishInstallation(with: UpdateError.downloadFailed(error.localizedDescription))
            }
        }.resume()
    }

    private func validateAndInstall(
        archiveURL: URL,
        checksumData: Data,
        expectedVersion: String,
        temporaryDirectory: URL
    ) throws {
        guard let checksumText = String(data: checksumData, encoding: .utf8),
              let expectedChecksum = expectedChecksum(in: checksumText, filename: zipName) else {
            throw UpdateError.invalidPackage("SHA256SUMS.txt is malformed.")
        }
        guard try sha256(of: archiveURL) == expectedChecksum else {
            throw UpdateError.checksumMismatch
        }

        let extractedDirectory = temporaryDirectory.appendingPathComponent("extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: extractedDirectory, withIntermediateDirectories: true)
        try runProcess("/usr/bin/ditto", arguments: ["-x", "-k", archiveURL.path, extractedDirectory.path])

        let candidateURL = extractedDirectory.appendingPathComponent("Maos VPN.app", isDirectory: true)
        guard let candidateBundle = Bundle(url: candidateURL),
              candidateBundle.bundleIdentifier == "app.maosvpn.client",
              candidateBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == expectedVersion,
              FileManager.default.isExecutableFile(
                atPath: candidateURL.appendingPathComponent("Contents/MacOS/MaosVPN").path
              ) else {
            throw UpdateError.invalidPackage("The application identity or version is invalid.")
        }

        try runProcess("/usr/bin/codesign", arguments: ["--verify", "--deep", "--strict", candidateURL.path])
        try replaceCurrentApplication(with: candidateURL)
    }

    private func replaceCurrentApplication(with candidateURL: URL) throws {
        let targetURL = Bundle.main.bundleURL.standardizedFileURL
        guard targetURL.pathExtension == "app",
              Bundle.main.bundleIdentifier == "app.maosvpn.client" else {
            throw UpdateError.installationFailed("The running application path is invalid.")
        }

        let parent = targetURL.deletingLastPathComponent()
        let nonce = UUID().uuidString
        let stagedURL = parent.appendingPathComponent(".MaosVPN-update-\(nonce).app")
        let backupURL = parent.appendingPathComponent(".MaosVPN-backup-\(nonce).app")
        let command = """
        set -e
        /bin/rm -rf \(shellQuote(stagedURL.path)) \(shellQuote(backupURL.path))
        /usr/bin/ditto \(shellQuote(candidateURL.path)) \(shellQuote(stagedURL.path))
        /bin/mv \(shellQuote(targetURL.path)) \(shellQuote(backupURL.path))
        if /bin/mv \(shellQuote(stagedURL.path)) \(shellQuote(targetURL.path)); then
          /bin/rm -rf \(shellQuote(backupURL.path))
        else
          /bin/mv \(shellQuote(backupURL.path)) \(shellQuote(targetURL.path))
          exit 1
        fi
        """

        do {
            try runPrivileged(command)
        } catch {
            throw UpdateError.installationFailed(error.localizedDescription)
        }

        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "sleep 2; /usr/bin/open \(shellQuote(targetURL.path))"]
        relaunch.standardOutput = FileHandle.nullDevice
        relaunch.standardError = FileHandle.nullDevice
        try relaunch.run()
    }

    private func expectedChecksum(in text: String, filename: String) -> String? {
        for line in text.components(separatedBy: .newlines) {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 2 else { continue }
            let listedName = String(fields.last!).trimmingCharacters(in: CharacterSet(charactersIn: "*"))
            let checksum = String(fields[0]).lowercased()
            if listedName == filename,
               checksum.count == 64,
               checksum.rangeOfCharacter(from: CharacterSet(charactersIn: "0123456789abcdef").inverted) == nil {
                return checksum
            }
        }
        return nil
    }

    private func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func secureDownloadURL(_ value: String) -> URL? {
        guard let url = URL(string: value), url.scheme?.lowercased() == "https" else { return nil }
        return url
    }

    private func runProcess(_ executable: String, arguments: [String]) throws {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let details = String(data: data, encoding: .utf8) ?? "exit code \(process.terminationStatus)"
            throw UpdateError.invalidPackage(details.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private func runPrivileged(_ shellCommand: String) throws {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "do shell script \(appleScriptString(shellCommand)) with administrator privileges"]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let details = String(data: data, encoding: .utf8) ?? "exit code \(process.terminationStatus)"
            throw UpdateError.installationFailed(details.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private func showProgress() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = AppLanguage.text(russian: "Обновление Maos VPN", english: "Updating Maos VPN")
            alert.informativeText = AppLanguage.text(
                russian: "Загрузка и проверка обновления…",
                english: "Downloading and verifying the update…"
            )
            let progress = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 240, height: 20))
            progress.style = .spinning
            progress.startAnimation(nil)
            alert.accessoryView = progress
            let button = alert.addButton(withTitle: AppLanguage.text(russian: "Подождите…", english: "Please wait…"))
            button.isEnabled = false
            self.progressAlert = alert
            if let window = self.presentingWindow {
                alert.beginSheetModal(for: window, completionHandler: nil)
            }
        }
    }

    private func finishInstallation(with error: Error?) {
        DispatchQueue.main.async {
            self.isInstalling = false
            if let alert = self.progressAlert {
                alert.window.sheetParent?.endSheet(alert.window)
                alert.window.orderOut(nil)
                self.progressAlert = nil
            }

            if let error = error {
                self.showError(error)
            } else {
                NSApp.terminate(nil)
            }
        }
    }

    private func showError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.alertStyle = .warning
        alert.addButton(withTitle: AppLanguage.text(russian: "Хорошо", english: "OK"))
        present(alert, completion: nil)
    }

    private func present(_ alert: NSAlert, completion: ((NSApplication.ModalResponse) -> Void)?) {
        if let window = presentingWindow {
            alert.beginSheetModal(for: window) { response in completion?(response) }
        } else {
            let response = alert.runModal()
            completion?(response)
        }
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
