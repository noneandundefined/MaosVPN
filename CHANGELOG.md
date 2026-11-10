# Changelog

All notable user-facing changes will be documented here. The project follows semantic versioning where practical.

## [1.3.0] - 2026-11-10

### Added
- Import Hysteria v1 share links and sing-box JSON (separate from Hysteria2), including authentication, bandwidth and TLS.
- Preserve provider-specific outbound TLS/transport options and recursively resolve `detour` / selector / urltest dependencies in multi-hop sing-box JSON.
- Show received, imported and skipped counts and per-node explanations in subscription details; report does not contain credentials or subscription URLs.
- The existing sequential four-User-Agent comparison now evaluates detailed compatibility including chained proxy nodes, choosing one coherent provider response.

### Fixed
- Unsupported JSON proxy types and broken chains are no longer dropped without explanation.
- Smart auto-selection retains per-server dependent proxy chains with collision-free tags.
- Hysteria v1 is displayed as UDP traffic and is measured without false TCP-port probing.

### Compatibility
- Provider HTTP 401/403/429, HWID rejection and network failures still stop UA probing, as in v1.2.2. Device limits are never bypassed.
- Configuration fixtures are validated against the bundled macOS Intel sing-box core.
- Refresh the existing subscription and open its information panel to inspect import results.

## [1.2.2] - 2026-11-10

### Added
- Compare subscription responses with Karing, Happ, v2rayNG, and sing-box User-Agent headers.
- Automatically choose the response containing the highest number of importable MaosVPN profiles, not the largest HTTP body.
- Show the winning client format and counts from each supported response in subscription details.

### Security and compatibility
- The original subscription URL and stable device-identification headers are reused for all requests.
- Requests are sequential and capped at four; probing stops immediately on access denial, device rejection, network failure, or HTTP 429 throttling.
- Do not combine incompatible formats or import profiles rejected by the MaosVPN config builder.
- Live provider verification depends on the user's private subscription link. Tests use local HTTP mocks only.

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
