# Contributing to Maos VPN

[Русская версия](CONTRIBUTING.ru.md)

Thank you for helping improve Maos VPN. Bug fixes, compatibility reports, translations, documentation, and focused feature proposals are welcome.

## Before opening an issue

- Search existing issues and the [support guide](SUPPORT.md).
- Test the latest release when possible.
- Remove subscription URLs, UUIDs, passwords, server addresses, Reality keys, and provider account data.
- Do not attach full logs until you have reviewed and redacted them.

Security vulnerabilities must be reported according to [SECURITY.md](SECURITY.md), not in a public issue.

## Development setup

You need an Intel or Apple Silicon Mac with Xcode Command Line Tools. Release packaging targets Intel macOS 10.15 and uses the official legacy `sing-box` binary.

```bash
swift test
swift build
```

To package the Intel app locally:

```bash
APP_VERSION=0.1.0 BUILD_NUMBER=1 \
  bash Scripts/package.sh /path/to/sing-box /path/to/sing-box-LICENSE
```

## Pull requests

1. Create a focused branch from the default branch.
2. Keep unrelated formatting or refactoring out of the change.
3. Add or update tests for parser and configuration behavior.
4. Update both English and Russian user-facing text.
5. Run `swift test` and verify `sing-box check` for configuration changes.
6. Explain user impact, compatibility, and manual verification in the pull request.

Pull requests must not add tracking, analytics, advertising, provider-specific secrets, or downloadable executables to Git history.

## Code style

- Prefer AppKit APIs available on macOS 10.15.
- Keep networking and profile parsing in `MaosVPNCore`.
- Keep elevated operations small, explicit, and auditable.
- Never log credentials or complete share links.
- Use plain Swift without unnecessary third-party dependencies.
- Preserve English and Russian localization parity.

## Commit messages

Use short imperative messages, for example:

```text
Fix Reality short ID parsing
Add English connection error
Document Catalina installation
```

By contributing, you agree that your contribution is licensed under the project's MIT License.
