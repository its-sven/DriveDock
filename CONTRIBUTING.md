# Contributing to DriveDock

Thanks for helping! Bug reports, ideas and pull requests are all welcome.

## Reporting bugs

Please include your macOS version, the server type (Windows Server, Samba, NAS model …),
the login mode, and the relevant lines from `~/Library/Logs/DriveDock.log`.
Remove server names, user names and IP addresses you don't want to share.

## Development

- Requirements: macOS 26 or later and the Xcode Command Line Tools. Full Xcode works too but isn't needed.
- `make signing` once, then `make install` to build and run your changes.
- The project is a plain Swift package (`Package.swift`); `scripts/build-app.sh` turns the
  binary into an app bundle.
- Views keep their state in small `ObservableObject`s instead of `@State`, because `@State`
  is a macro in current SDKs and its plugin only ships with full Xcode. Please keep it that
  way so the project keeps building with the Command Line Tools alone.
- Match the style of the surrounding code; comments explain *why*, not *what*.

## Pull requests

Keep them focused, describe what you tested (which server, which login mode), and add an entry
under *Unreleased* in `CHANGELOG.md`.
