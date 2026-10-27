# Changelog

All notable changes to DriveDock. The format follows [Keep a Changelog](https://keepachangelog.com/),
versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.5.2] – 2026-10-27

### Changed
- All server passwords now live in a single keychain item. Without an Apple Team ID macOS asks
  for keychain access after every update – now once instead of once per server. Passwords from
  earlier versions are moved over automatically the first time they are needed.
- Keychain access runs one call at a time in the background and is cached in memory: a pending
  keychain prompt can no longer freeze the UI or hold up other servers, reconnects don't touch
  the keychain, and a denied prompt is not repeated until you click *Connect*.
- Switches and *Connect*/*Disconnect* react immediately; disconnecting shows "Disconnecting …"
  and unmounts all shares of a server in parallel.
- Shares appear one by one while a server connects instead of all at the end.
- Finder sidebar lookups (*General* page, saving a server) run off the main thread.

### Fixed
- Servers that log in with the Mac's domain login no longer read the keychain at all.
- Checking whether a share is mounted no longer touches the file system, which could stall
  the UI when a server is unreachable.
- A server named "." or ".." can't point its folder at the mount root or the home folder.

### Documentation
- Corrected: a self-signed certificate does not prevent the keychain prompt after updates
  (only an Apple Team ID does); it keeps privacy permissions such as local network access.

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

[Unreleased]: https://github.com/its-sven/DriveDock/compare/v0.5.2...HEAD
[0.5.2]: https://github.com/its-sven/DriveDock/compare/v0.5.1...v0.5.2
[0.5.1]: https://github.com/its-sven/DriveDock/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/its-sven/DriveDock/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/its-sven/DriveDock/releases/tag/v0.4.0
