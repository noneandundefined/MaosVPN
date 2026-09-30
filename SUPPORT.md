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

If the provider reports that the device was rejected, open the provider's device-management page and remove an unused device before reloading. Maos VPN keeps one random installation ID and reuses it for every refresh; reinstalling macOS or deleting the app's preferences may make the provider count it as a new device.

### The server list is empty

The subscription may use an unsupported or provider-specific format. Create a bug report with a synthetic example or heavily redacted response. Do not publish your real link.

### Connected, but sites do not open

Try another server, disable another VPN/filter temporarily, and confirm the provider works on another client. A successful TUN startup cannot guarantee that the remote endpoint is online.

### Administrator prompt appears

This is expected. The independent `sing-box` process needs elevated permission to create and remove the system TUN interface and routes. Maos VPN never receives the password.

### Automatic update fails

Disconnect the VPN and run **Maos VPN → Check for Updates…** again. The app must be running from a writable local disk, not directly from the DMG. Update installation verifies the ZIP checksum, app identity, version, and code signature before replacing the current copy.

## Creating an issue

Use the provided Bug Report form. Include the Maos VPN version, exact macOS version, Mac model, protocol type, and reproduction steps. Redact every credential.

---

## Кратко на русском

Проверьте Intel‑архитектуру, macOS 10.15+, последнюю версию приложения и другой сервер из подписки. Временно отключите другие VPN, DNS-фильтры и прокси. Запрос пароля администратора при подключении является нормальным: он нужен для TUN-интерфейса.

Если сервер подписки отклонил устройство, удалите неиспользуемое устройство в личном кабинете провайдера и загрузите подписку повторно. Maos VPN создаёт один случайный идентификатор установки и использует его при каждом обновлении.

Если автоматическое обновление не устанавливается, отключите VPN и снова выберите **Maos VPN → Проверить обновления…**. Запускайте приложение из папки **Программы**, а не непосредственно из DMG.

В Issue укажите версию Maos VPN, точную версию macOS, модель Mac, протокол и шаги. Не публикуйте ссылку подписки, UUID, пароль, ключи или полный лог.
