# Releasing DriveDock

Releases are built by GitHub Actions (`.github/workflows/release.yml`) when a version tag is pushed.

## Cutting a release

1. Move the entries under *Unreleased* in `CHANGELOG.md` into a new section `## [x.y.z] – YYYY-MM-DD`
   and update the links at the bottom.
2. Set `CFBundleShortVersionString` in `Resources/Info.plist` to `x.y.z`.
3. Commit, tag and push:

   ```bash
   git commit -am "Release x.y.z"
   git tag vx.y.z
   git push origin main vx.y.z
   ```

The workflow builds a universal app, packages `DriveDock-x.y.z.dmg`, `DriveDock-x.y.z.zip` and
`SHA256SUMS.txt`, and publishes a GitHub release. The notes come from that version's
`CHANGELOG.md` section. To try the packaging locally, run `make release` and look in `dist/`.

## Code signing

There are three levels:

| | Gatekeeper on first launch | Keychain prompt after updates | Privacy permissions (e.g. local network) after updates | Cost |
|---|---|---|---|---|
| Ad hoc (default) | "Open Anyway" needed | once per update | may be asked again | – |
| Self-signed release certificate | "Open Anyway" needed | once per update | kept | – |
| Apple-issued certificate with Team ID (Developer ID + notarization) | opens normally | no | kept | Apple Developer Program |

Why the keychain asks after updates without a Team ID: macOS binds keychain items to a
*partition*. For apps with an Apple Team ID that is `teamid:…`, which stays the same across
versions. For everything else it is the code hash of the binary, which changes with every
build – a self-signed certificate doesn't help here. Since 0.5.2 DriveDock keeps all server
passwords in one keychain item, so this is a single prompt per update, not one per server.

### Self-signed release certificate (optional)

Signing every release with the same certificate keeps the app's code identity stable, so
privacy permissions such as local network access survive updates.

```bash
scripts/make-release-cert.sh ~/drivedock-release-cert
```

Add the two printed values as repository secrets **RELEASE_CERT_P12** and
**RELEASE_CERT_PASSWORD** (*Settings → Secrets and variables → Actions*), store
`release-signing.p12` somewhere safe, and delete the `.txt` files. Losing the certificate
only means users may have to grant privacy permissions once more with the next release.

### Developer ID (later)

With a paid Apple Developer account, replace the signing step by a *Developer ID Application*
certificate with hardened runtime (`codesign --options runtime --timestamp`), then notarize
the DMG with `xcrun notarytool submit --wait` and staple it with `xcrun stapler staple`.
After that, the quarantine workaround in the Homebrew cask and the README can go, and the
keychain no longer asks after updates (stable `teamid:` partition).

## Homebrew

DriveDock is distributed through a personal tap rather than `homebrew/cask`. The official repository
only accepts notarized apps.

One-time setup:

1. Create the public repository **its-sven/homebrew-tap** (the `homebrew-` prefix is required).
2. Create a fine-grained personal access token with *Contents: read and write* on that repository
   only, and add it as the secret **HOMEBREW_TAP_TOKEN** in the DriveDock repository.

From then on, every release updates `Casks/drivedock.rb` in the tap from
`packaging/homebrew/drivedock.rb`. Users install with:

```bash
brew install --cask its-sven/tap/drivedock
```

Without the token, the step is skipped. You can then copy the template by hand and fill in the version
and the SHA-256 of the ZIP from `SHA256SUMS.txt`.
