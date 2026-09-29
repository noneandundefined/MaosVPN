# Security Policy / Политика безопасности

## Supported versions

Security fixes are provided for the latest published release and the current default branch. Older builds may be asked to upgrade before a report is investigated.

## Reporting a vulnerability

Do not open a public issue for a vulnerability or leaked credential.

Use **GitHub → Security → Report a vulnerability** to create a private security advisory. Include:

- affected version and macOS version;
- clear reproduction steps;
- expected security impact;
- a minimal redacted log or proof of concept;
- whether the problem involves elevated commands, local profile storage, subscription parsing, or bundled `sing-box` behavior.

Never include a working subscription URL, UUID, password, private key, or unredacted server address. If a credential was exposed, revoke it at the provider immediately.

Maintainers should acknowledge a complete report within seven days. Timelines for validation and release depend on severity and reproducibility. Please allow a reasonable remediation period before public disclosure.

Issues in `sing-box` itself may need coordinated reporting to the upstream project after confirming the problem is not caused by Maos VPN integration.

---

## Русский

Исправления безопасности выпускаются для последнего релиза и основной ветки.

Не создавайте публичный Issue для уязвимости или утечки credentials. Откройте приватный отчёт через **GitHub → Security → Report a vulnerability** и укажите версию приложения, версию macOS, шаги воспроизведения, возможные последствия и очищенный от секретов журнал.

Никогда не отправляйте рабочую ссылку подписки, UUID, пароль, private key или полный адрес сервера. Скомпрометированные данные сразу отзовите у провайдера.
