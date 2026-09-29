# Architecture

Maos VPN is intentionally small and dependency-light.

```text
Subscription URL
      │ HTTPS
      ▼
MaosVPNCore parser ──► VPNProfile list ──► AppKit server list
                                              │ Connect
                                              ▼
                                      sing-box JSON builder
                                              │ validate
                                              ▼
                                  bundled sing-box (root process)
                                              │
                                              ▼
                                      macOS TUN + routes
```

## Modules

- `MaosVPNCore`: share-link parsing, models, bilingual errors, and sing-box configuration generation.
- `MaosVPN`: AppKit user interface, preferences, privileged lifecycle, process validation, and localization.
- `Scripts`: icon generation and deterministic app/DMG packaging.
- `Tests`: parser tests and an engine-validated configuration fixture.

## Privilege boundary

The GUI runs as the signed-in user. Only the bundled `sing-box` command is launched through the macOS administrator prompt. The app stores and validates its PID, verifies the command line before stopping it, and sends termination signals through a narrowly scoped elevated shell command.

## Release pipeline

The GitHub Actions workflow downloads the pinned official legacy Intel core, verifies its published checksum, validates a representative configuration, runs Swift tests, builds for macOS 10.15 x86_64, generates the icon, ad-hoc signs the bundle, verifies the signature, and emits DMG/ZIP checksums.
