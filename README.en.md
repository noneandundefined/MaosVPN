# Maos VPN — User Guide

[Русская версия](README.ru.md) · [Project overview](README.md) · [Download latest release](../../releases/latest)

Maos VPN is a simple open-source subscription client for Intel Macs running macOS Catalina 10.15 or later. It uses a system TUN interface, so supported traffic from browsers and desktop applications is routed through the selected VPN server.

## Installation

1. Open **[GitHub Releases](../../releases/latest)**.
2. Download `MaosVPN-macOS-10.15-Intel.dmg`.
3. Open the DMG and drag **Maos VPN.app** into **Applications**.
4. Right-click **Maos VPN.app**, select **Open**, then confirm **Open**.

The extra confirmation is required because community builds are ad-hoc signed. A future Developer ID build can remove this step.

If macOS does not offer the **Open** button, run this once in Terminal:

```bash
xattr -dr com.apple.quarantine "/Applications/Maos VPN.app"
```

Only run this command for an app downloaded from this project's official Releases page. Compare its SHA-256 value with `SHA256SUMS.txt` when possible.

## Connecting

1. Start Maos VPN.
2. Choose **English** or **Русский** in the top-right corner.
3. Paste your HTTPS subscription URL.
4. Click **Load** and select a server in the sidebar.
5. Click **Connect**.
6. Enter your macOS administrator password when the system asks.

The prompt authorizes creation of a TUN interface. Maos VPN does not see or save the password.

## Supported formats

- Base64 or plain-text subscription lists;
- VLESS;
- VMess;
- Trojan;
- Shadowsocks;
- TCP, HTTP, WebSocket, gRPC, HTTPUpgrade, QUIC, TLS, and Reality parameters supported by the profile parser.

Not every provider uses standard share links. If a profile is skipped, open a bug report with all addresses, UUIDs, passwords, public keys, and subscription tokens removed.

## Updating servers

Paste the same subscription URL and click **Load** again. The local list is replaced with the latest valid profiles returned by the provider.

## Uninstalling

1. Disconnect the VPN.
2. Quit Maos VPN.
3. Move the app from **Applications** to Trash.
4. Optionally remove local settings:

```bash
rm -rf "$HOME/Library/Application Support/MaosVPN"
defaults delete app.maosvpn.client
```

The last step removes locally stored profiles and preferences.

## Troubleshooting and privacy

See [SUPPORT.md](SUPPORT.md) for common problems and [Privacy](docs/PRIVACY.md) for the exact local data behavior.

## For maintainers

The project is built with Swift Package Manager and AppKit. Releases bundle the official Intel legacy build of `sing-box`. See [Architecture](docs/ARCHITECTURE.md) and [Contributing](CONTRIBUTING.md).
