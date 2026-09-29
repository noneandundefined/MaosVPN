# Support / Поддержка

## Before asking for help

1. Confirm the Mac uses Intel and macOS 10.15 or newer.
2. Install the newest release from this repository.
3. Reload the subscription.
4. Try another profile from the same subscription.
5. Disconnect other VPN, proxy, DNS, or network-filtering apps.
6. Restart Maos VPN and macOS.

## Common problems

### “The app cannot be opened”

Right-click the app and choose **Open**. If necessary, follow the Gatekeeper instructions in [README.en.md](README.en.md). Never bypass quarantine for an app from an untrusted source.

### The subscription does not load

Check that it starts with `https://`, is still active, and opens on the same Mac. Provider pages and subscription API links are different; Maos VPN needs the API/subscription link that returns share profiles.

### The server list is empty

The subscription may use an unsupported or provider-specific format. Create a bug report with a synthetic example or heavily redacted response. Do not publish your real link.

### Connected, but sites do not open

Try another server, disable another VPN/filter temporarily, and confirm the provider works on another client. A successful TUN startup cannot guarantee that the remote endpoint is online.

### Administrator prompt appears

This is expected. The independent `sing-box` process needs elevated permission to create and remove the system TUN interface and routes. Maos VPN never receives the password.

## Creating an issue

Use the provided Bug Report form. Include the Maos VPN version, exact macOS version, Mac model, protocol type, and reproduction steps. Redact every credential.

---

## Кратко на русском

Проверьте Intel‑архитектуру, macOS 10.15+, последнюю версию приложения и другой сервер из подписки. Временно отключите другие VPN, DNS-фильтры и прокси. Запрос пароля администратора при подключении является нормальным: он нужен для TUN-интерфейса.

В Issue укажите версию Maos VPN, точную версию macOS, модель Mac, протокол и шаги. Не публикуйте ссылку подписки, UUID, пароль, ключи или полный лог.
