# Changelog

All notable user-facing changes will be documented here. The project follows semantic versioning where practical.

## [1.2.1] - 2026-11-10

### Added
- Happ-compatible subscription metadata from HTTP headers or #comment directives: expiry, used/total traffic, provider name, website, and support URL.
- Subscription information sheet with HTTPS link actions and a hidden-by-default reveal/copy control for the subscription URL.
- Expiry indicator directly under each subscription name; remains unknown when the provider publishes no expiry.

### Fixed
- Manual ping tests can now run while the VPN is connected without blocking the Disconnect control.
- Subscription refresh and removal work while connected. The existing tunnel keeps its current settings until reconnection.
- Removing the last subscription safely disconnects the VPN before switching to onboarding.
- The menu bar retains the actual active server label even after the subscription list changes.

## [1.2.0] - 2026-11-10

### Added

- A first-class "Automatic selection" server at the top of the sidebar, backed by sing-box URLTest (health checks every 30 seconds).
- A visible "Test server latency" button and refresh/remove controls on each subscription group.
- Manual subscription refresh that fetches the existing HTTPS URL again, adds newly published servers, and drops removed ones.
- Confirmation before removing a locally saved subscription.

### Changed

- Server sidebar widened from 248 to 282 points.
- Latency checks target the actual TCP server port where possible; Hysteria2 retains ICMP-based checks.
- Automatic routing changes the outbound for new connections without restarting the VPN tunnel; existing connections remain intact.
- Server UUIDs persist across refreshes for unchanged endpoints, preserving selections and ping results.

### Notes

- Refresh and deletion are available while disconnected; JSON imports do not have a remote URL to refresh.
- The actual automatic routing choice is managed by sing-box. Ping numbers in the UI are connection reachability estimates, not full proxy-handshake timings.

## [Unreleased]

### Changed

- Replaced the previous logo with the new glossy blue Maos VPN icon across the app, package, and documentation.
- Fitted the icon artwork to a 1024×1024 master with balanced Dock and Finder sizing.

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
