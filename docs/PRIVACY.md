# Privacy

Maos VPN does not include analytics, advertising, telemetry, crash-reporting SDKs, or a project-operated backend.

## Data stored locally

The app stores the selected interface language, subscription URL, parsed profiles, last known VPN process identifier, and a randomly generated installation identifier in the current macOS user's preferences. The identifier remains stable so subscription providers with a device limit do not count every refresh as a new device. It is not derived from the Mac serial number, Apple ID, user name, or other hardware identifiers. The generated `sing-box` configuration is stored in:

```text
~/Library/Application Support/MaosVPN/config.json
```

The configuration is written with user-only file permissions. A temporary runtime log may be written under `/tmp` while the VPN engine runs.

Subscription URLs and profiles can contain credentials. Anyone with access to your macOS account or an unencrypted backup may be able to read locally stored settings. Protect the Mac account and revoke exposed subscriptions through the provider.

## Network connections

The app contacts only:

- the subscription URL entered by the user;
- servers contained in that subscription;
- DNS services configured for VPN operation.

When fetching a subscription, Maos VPN sends the random installation identifier in the `X-Hwid` header together with the operating system name/version and the generic device model `Mac`. This provides compatibility with Happ-style subscription panels. These values are sent only to the subscription URL entered by the user and are not sent to the Maos VPN project.

GitHub is contacted only by a browser when the user visits project links. The installed app does not automatically contact this repository for updates.

## Administrator password

The password prompt is presented and processed by macOS. Maos VPN receives only the success or failure result and never receives or stores the password.

## Removal

Uninstall instructions in [README.en.md](../README.en.md) explain how to remove the app and local preferences.
