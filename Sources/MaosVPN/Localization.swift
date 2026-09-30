import Foundation
import MaosVPNCore

extension Notification.Name {
    static let maosVPNLanguageDidChange = Notification.Name("MaosVPNLanguageDidChange")
}

enum L10nKey {
    case about, checkForUpdates, hide, quit, edit, undo, cut, copy, paste, selectAll
    case operationInProgress, waitForOperation, okay
    case disconnectFailed, disconnectBeforeQuit, stay, quitAnyway
    case macOSVersion, serversHeading, serverColumn, yourVPN
    case intro, subscriptionURL, load, addSubscription, serversWillAppear
    case adminHint, loadingSubscription, subscriptionUpdated, languageChanged
    case disconnected, connecting, connected, disconnecting
    case connect, disconnect, serverSingular, serverFew, serverMany
    case vpnConnected, vpnDisconnected, exitCode, logUnavailable
}

enum L10n {
    static func text(_ key: L10nKey) -> String {
        switch AppLanguage.current {
        case .russian:
            switch key {
            case .about: return "О Maos VPN"
            case .checkForUpdates: return "Проверить обновления…"
            case .hide: return "Скрыть Maos VPN"
            case .quit: return "Завершить Maos VPN"
            case .edit: return "Правка"
            case .undo: return "Отменить"
            case .cut: return "Вырезать"
            case .copy: return "Копировать"
            case .paste: return "Вставить"
            case .selectAll: return "Выбрать всё"
            case .operationInProgress: return "Операция ещё выполняется"
            case .waitForOperation: return "Дождитесь завершения подключения или отключения VPN."
            case .okay: return "Хорошо"
            case .disconnectFailed: return "Не удалось отключить VPN"
            case .disconnectBeforeQuit: return "Сначала отключите VPN кнопкой в приложении."
            case .stay: return "Остаться"
            case .quitAnyway: return "Выйти всё равно"
            case .macOSVersion: return "для macOS 10.15+"
            case .serversHeading: return "СЕРВЕРЫ"
            case .serverColumn: return "Сервер"
            case .yourVPN: return "Ваш VPN"
            case .intro: return "Вставьте ссылку подписки, выберите сервер и подключитесь."
            case .subscriptionURL: return "Ссылка подписки"
            case .load: return "Загрузить"
            case .addSubscription: return "Добавьте подписку"
            case .serversWillAppear: return "Серверы появятся в списке слева"
            case .adminHint: return "При подключении macOS попросит пароль администратора — он нужен только для создания системного TUN-интерфейса."
            case .loadingSubscription: return "Загрузка подписки…"
            case .subscriptionUpdated: return "Подписка обновлена. Загружено серверов:"
            case .languageChanged: return "Язык интерфейса изменён."
            case .disconnected: return "Не подключено"
            case .connecting: return "Подключение…"
            case .connected: return "VPN включён"
            case .disconnecting: return "Отключение…"
            case .connect: return "Подключиться"
            case .disconnect: return "Отключиться"
            case .serverSingular: return "сервер"
            case .serverFew: return "сервера"
            case .serverMany: return "серверов"
            case .vpnConnected: return "VPN подключён:"
            case .vpnDisconnected: return "VPN отключён"
            case .exitCode: return "код"
            case .logUnavailable: return "Подробный журнал недоступен."
            }
        case .english:
            switch key {
            case .about: return "About Maos VPN"
            case .checkForUpdates: return "Check for Updates…"
            case .hide: return "Hide Maos VPN"
            case .quit: return "Quit Maos VPN"
            case .edit: return "Edit"
            case .undo: return "Undo"
            case .cut: return "Cut"
            case .copy: return "Copy"
            case .paste: return "Paste"
            case .selectAll: return "Select All"
            case .operationInProgress: return "An operation is still running"
            case .waitForOperation: return "Wait for the VPN to finish connecting or disconnecting."
            case .okay: return "OK"
            case .disconnectFailed: return "Could not disconnect the VPN"
            case .disconnectBeforeQuit: return "Disconnect the VPN from the app before quitting."
            case .stay: return "Stay"
            case .quitAnyway: return "Quit Anyway"
            case .macOSVersion: return "for macOS 10.15+"
            case .serversHeading: return "SERVERS"
            case .serverColumn: return "Server"
            case .yourVPN: return "Your VPN"
            case .intro: return "Paste a subscription URL, choose a server, and connect."
            case .subscriptionURL: return "Subscription URL"
            case .load: return "Load"
            case .addSubscription: return "Add a subscription"
            case .serversWillAppear: return "Your servers will appear in the list"
            case .adminHint: return "macOS will request an administrator password when connecting. It is used only to create the system TUN interface."
            case .loadingSubscription: return "Loading subscription…"
            case .subscriptionUpdated: return "Subscription updated. Servers loaded:"
            case .languageChanged: return "Interface language changed."
            case .disconnected: return "Disconnected"
            case .connecting: return "Connecting…"
            case .connected: return "VPN enabled"
            case .disconnecting: return "Disconnecting…"
            case .connect: return "Connect"
            case .disconnect: return "Disconnect"
            case .serverSingular, .serverFew, .serverMany: return "servers"
            case .vpnConnected: return "VPN connected:"
            case .vpnDisconnected: return "VPN disconnected"
            case .exitCode: return "exit code"
            case .logUnavailable: return "Detailed log is unavailable."
            }
        }
    }
}
