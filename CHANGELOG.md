# Changelog

All notable changes to DriveDock. The format follows [Keep a Changelog](https://keepachangelog.com/),
versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.5.0] – 2026-10-19

### Added
- English user interface. DriveDock now follows the system language (English or German);
  more languages can be added as `Resources/<language>.lproj` (see CONTRIBUTING.md).
- Credit line with a link to the GitHub project at the bottom of the *General* settings page.
- `make check` / `scripts/check-localization.py`: verifies that every UI text is translated, also in CI.

### Changed
- New installations use `~/Network Drives` as the folder for the server profiles
  (`~/Netzlaufwerke` on German systems). Existing installations keep their folder.
- Homebrew cask uses the Homebrew 7 install-step format.

## [0.4.0] – 2026-10-16

First public release.

### Added
- Menu bar app that keeps SMB and WebDAV shares mounted and reconnects after sleep,
  network changes and VPN connects.
- Server profiles (server + login) with several shares each, shown as a folder with its own
  Finder sidebar entry; several users on the same server at the same time.
- "Connect all shares" mode with per-share opt-out and automatic pickup of new shares.
- Share list loaded from the server, with search and select all / none.
- Login with user and password or with the Mac's domain login (Kerberos), and a choice of
  connecting by IP address or server name.
- Detection of shares without permission ("no access"); a wrong password stops automatic
  retries to avoid account lockouts.
- Colors per server, duplicating a server, launch at login.
- Activity log at `~/Library/Logs/DriveDock.log`.
- Universal build (Apple Silicon and Intel), DMG and ZIP releases, Homebrew cask.

[Unreleased]: https://github.com/its-sven/DriveDock/compare/v0.5.0...HEAD
[0.5.0]: https://github.com/its-sven/DriveDock/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/its-sven/DriveDock/releases/tag/v0.4.0
