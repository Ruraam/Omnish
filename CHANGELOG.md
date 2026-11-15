# Changelog

All notable changes to Omnish are documented here.

This project follows Semantic Versioning. The entries below summarize changes since the latest published release.

## [3.0.0] - Unreleased

### Added
- **Quick Archive:** create archives from selected files and browse archive contents without extracting them to disk.
- **Nested archive browsing:** inspect supported archives inside archives with bounded recursion.
- **Quick Transfer:** send marked or selected files through a temporary local HTTP server, or use the optional Croc and Magic Wormhole integrations.
- **Private Scratchpad:** keep notes and TODOs in a user-only Markdown file shared by the fzf and loop backends.
- **Expanded integration coverage:** exercise archive formats and security boundaries, installer upgrades and rollback, and Quick Transfer lifecycle and cleanup behavior.

### Improved
- Hardened the runtime and aligned selection behavior between the fzf and loop backends.
- Improved terminal-state restoration and interactive exit handling.
- Made preview layouts more responsive in landscape and narrow terminal windows.
- Improved image previews with safer Chafa rendering and better terminal capability detection.
- Hardened installation and upgrade operations with transactional cleanup and rollback.
- Restricted installation and uninstallation paths to the intended user-local locations.
- Improved Quick Transfer network address selection, port handling, staging isolation, readiness checks, and server shutdown cleanup.
- Expanded CI checks for syntax, ShellCheck, regression, installer, PTY, Quick Archive, and Quick Transfer coverage.

### Security
- Quick Transfer's local HTTP mode is **not encrypted and has no authentication**. Use it only on a trusted network and stop the temporary server immediately after the transfer.
- Croc and Magic Wormhole remain optional alternatives for encrypted transfers.

## [1.0.0] - 2026-11-10

### Added
- Initial public release of Omnish.
