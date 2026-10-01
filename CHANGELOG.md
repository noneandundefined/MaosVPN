# Changelog

All notable user-facing changes will be documented here. The project follows semantic versioning where practical.

## [Unreleased]

### Changed

- Replaced the previous logo with the new glossy blue Maos VPN icon across the app, package, and documentation.

### Fixed

- Disconnecting tolerates an already exited VPN process, reaps the root core correctly, and never triggers helper reinstallation or another password prompt.

### Added

- Polished macOS-style connection dashboard with server search, a dotted world map, connection glow, and compact server/protocol cards.
- System light/dark appearance with live macOS theme changes.
- Per-server latency results and automatic fastest-server selection.
- Automatic update check on every launch and a Dock update badge.
- Hidden persisted subscription sources.
- First-run subscription onboarding and a URL-free main screen.
- Multiple named, collapsible subscription groups with URL and JSON sources.
- Large circular connect control with live VPN session duration.
- Branded drag-to-Applications DMG layout.
- Native macOS 10.15+ Intel client.
- Base64 and plain-text subscription import.
- VLESS, VMess, Trojan, and Shadowsocks parsing.
- Full-device TUN routing through the bundled sing-box engine.
- English and Russian interface with live language switching.
- Automated DMG, ZIP, checksum, and GitHub Release workflow.
- Public contribution, support, privacy, and security documentation.

## [0.1.0] - Unreleased

Initial public preview.
