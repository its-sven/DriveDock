# Changelog

All notable changes to DriveDock. The format follows [Keep a Changelog](https://keepachangelog.com/),
versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.5.1] – 2026-10-27

### Fixed
- Crash right after launch or wake while several shares connected at the same time: the mount
  table was read with `getmntinfo()`, which isn't thread-safe; DriveDock now uses `getfsstat()`
  with its own buffer.
- Cleaning up empty share folders could in a rare race delete the contents of a share that
  got mounted at that moment; it now uses `rmdir`, which never deletes contents.
- A command line tool that didn't exit (e.g. `mount_smbfs` stuck in the kernel) could leave a
  server on "Connecting …" until restart. Tools now get a hard deadline (terminate, then kill,
  then give up), and a timed-out mount under `expect` takes its child process down too.
- Disconnecting, editing or removing a server while it was connecting could leave shares
  mounted with the toggle off, mounts from the old login, or orphan mounts. Outdated connect
  attempts now undo their mounts, and a disconnected server stays disconnected.
- Possible crash of the activity log when the disk is full.
- Resolving old Finder sidebar entries could try to mount an offline server and show UI.
- A profile whose folder is itself a mount point no longer retries every second.
- Server names that map to the same folder (e.g. "A/B" and "A - B") are now made unique.

### Changed
- Blocking work (mounting, keychain, share lists) runs on its own queue instead of Swift's
  cooperative thread pool, unmounting never shows UI and has a timeout, and the UI reads a
  cached mount table and only re-renders on real changes – memory use dropped from about
  90 MB to about 25 MB.

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

[Unreleased]: https://github.com/its-sven/DriveDock/compare/v0.5.1...HEAD
[0.5.1]: https://github.com/its-sven/DriveDock/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/its-sven/DriveDock/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/its-sven/DriveDock/releases/tag/v0.4.0
