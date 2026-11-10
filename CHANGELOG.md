# Changelog

All notable user-facing changes will be documented here. The project follows semantic versioning where practical.

## [1.2.2] - 2026-11-10

### Added
- Hysteria v1 share links and sing-box JSON import (distinct from Hysteria2), including credentials, bandwidth and TLS fields.
- Import of complex sing-box outbound chains using `detour`, `selector` and `urltest` dependencies, preserving provider TLS and transport details.
- Visible import diagnostics: received/imported/skipped counts, selected User-Agent and individual skip explanations in subscription details.
- Automatic comparison of Karing, Happ, sing-box and v2rayN User-Agent responses on the same subscription URL, using the response with the most compatible servers.

### Changed
- Unsupported JSON outbounds and malformed share links are never skipped silently; diagnostics report why an entry is unsupported.
- Smart auto server retains dependent proxy graphs with unique tags rather than losing chained nodes.
- Never concatenate or merge separate provider responses, which could mix incompatible credentials or configuration graphs.
- All requests retain the same stable device headers; the original subscription URL and credentials are not included in diagnostics.

### Notes
- Only protocols supported by the bundled sing-box and MaosVPN parser are imported. Unsupported protocols are shown as skipped, not misrepresented as working servers.
- To inspect the selected User-Agent and rejected entries for an existing subscription, click refresh (↻) then info (ⓘ).
- No actual private provider URL is available to the build system; compatibility is validated with local fixtures and mocked HTTP responses.

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
