<p align="center">
  <img src="docs/images/banner.jpg" alt="DriveDock – your network drives, always in Finder">
</p>

<p align="center">
  <b>A small macOS menu bar app that keeps SMB and WebDAV shares mounted</b> —<br>
  it reconnects after sleep, Wi‑Fi changes and VPN, and lets you use several accounts on the same server.
</p>

<p align="center">
  <a href="https://github.com/its-sven/DriveDock/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/its-sven/DriveDock"></a>
  <a href="https://github.com/its-sven/DriveDock/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/its-sven/DriveDock/actions/workflows/ci.yml/badge.svg"></a>
  <img alt="macOS 26+" src="https://img.shields.io/badge/macOS-26%2B-blue">
  <img alt="Apple Silicon and Intel" src="https://img.shields.io/badge/Apple%20Silicon%20%26%20Intel-universal-lightgrey">
  <a href="LICENSE"><img alt="MIT License" src="https://img.shields.io/badge/license-MIT-green"></a>
</p>

---

macOS can mount network shares, but it forgets them: after sleep, after switching networks, or when the VPN comes up later, you are back to *Go → Connect to Server…*. And connecting to the same server as two different users (say, your normal account and an admin account) usually doesn't work at all.

DriveDock fixes that. You set up a server once, and its shares stay in Finder, under a name you choose, ready when you are. It is a free, open-source take on the "always mounted" part of tools like Mountain Duck, built on the Mac's own SMB client.

> Available in **English** and **German** – DriveDock follows your system language. More translations are welcome, see [CONTRIBUTING.md](CONTRIBUTING.md#translations).

## Features

- **Always connected.** Shares are mounted at login and reconnected automatically after sleep, network changes and VPN connects. Unreachable servers are retried quietly, less often the longer they stay away. No error pop-ups.
- **Several users per server.** Each server profile (server + login) gets its own SMB session, so `\\fileserver\Data` can be mounted as *you* and as *admin* at the same time.
- **Clean Finder integration.** Every profile is a folder in `~/Network Drives` (`~/Netzlaufwerke` on German systems) with its own entry in the Finder sidebar, named the way you named it; its shares appear inside.
- **All shares, like Windows.** Optionally mount everything a server offers to that user. New shares show up by themselves, and you can opt out of single ones. Or pick shares by hand from a searchable list loaded from the server.
- **Knows the difference between "wrong password" and "no access".** Shares the user isn't allowed to open are marked *no access* and not retried in a loop. A wrong password stops automatic retries right away, so Active Directory accounts don't get locked.
- **Works on domain-joined Macs.** If the Mac is logged in to Active Directory, macOS likes to use *that* Kerberos ticket instead of the credentials you entered. DriveDock makes sure the account you configured is the one that logs in, or deliberately uses the Mac's domain login if you prefer.
- **LAN and VPN.** Give a server several addresses; the first one that answers is used.
- **Passwords stay in the Keychain** and are never passed on a command line.
- **Native and light.** SwiftUI, Liquid Glass design, a universal binary for Apple Silicon and Intel. Around 15 MB of memory, no background services besides the app itself.

## Screenshots

<table>
  <tr>
    <td align="center" valign="top" width="40%">
      <picture>
        <source media="(prefers-color-scheme: dark)" srcset="docs/images/menu-dark.png">
        <img src="docs/images/menu-light.png" alt="The menu bar popover: four servers with their status and shares">
      </picture>
      <br><sub><b>Menu bar.</b> Every server with its status; click a share to open it in Finder.</sub>
    </td>
    <td align="center" valign="top" width="60%">
      <picture>
        <source media="(prefers-color-scheme: dark)" srcset="docs/images/servers-dark.png">
        <img src="docs/images/servers-light.png" alt="The server window: login, connection and the shares of a server">
      </picture>
      <br><sub><b>Servers.</b> One profile per server and login. Mount all shares like Windows, or pick them.</sub>
      <br><br>
      <picture>
        <source media="(prefers-color-scheme: dark)" srcset="docs/images/general-dark.png">
        <img src="docs/images/general-light.png" alt="General settings: launch at login, Finder sidebar, activity log">
      </picture>
      <br><sub><b>General.</b> Launch at login, Finder sidebar and the activity log.</sub>
    </td>
  </tr>
</table>

<sub>Screenshots show made-up servers from DriveDock's demo mode (`make demo`).</sub>

## Installation

### Download

1. Get **DriveDock-x.y.z.dmg** from the [latest release](https://github.com/its-sven/DriveDock/releases/latest).
2. Open it and drag **DriveDock** into **Applications**.
3. Start DriveDock. Because releases are not notarized by Apple yet (that needs a paid developer account), macOS will refuse the first launch. Open **System Settings → Privacy & Security**, scroll down and click **Open Anyway**. Or in Terminal:

   ```bash
   xattr -dr com.apple.quarantine /Applications/DriveDock.app
   ```

DriveDock adds itself to your login items on first launch (you can turn that off in its settings).

### Homebrew

```bash
brew install --cask its-sven/tap/drivedock
```

### Build from source

All you need is the Xcode Command Line Tools (`xcode-select --install`). Full Xcode is not required.

```bash
git clone https://github.com/its-sven/DriveDock.git
cd DriveDock
make signing   # optional, once: local signing identity, see below
make install   # builds, copies to ~/Applications and launches
```

`make signing` creates a self-signed code signing certificate in your login keychain. With it, every build keeps the same code identity, so privacy permissions such as local network access survive rebuilds.

| Command | What it does |
|---|---|
| `make app` | Builds `build/DriveDock.app` for this Mac |
| `make install` | Builds, installs to `~/Applications`, launches |
| `make release` | Universal build plus DMG and ZIP in `dist/` |
| `make test` | Runs the unit tests |
| `make check` | Verifies that every UI text has a translation |
| `make demo` | Opens DriveDock with made-up servers; mounts nothing, touches no keychain |
| `make screenshots` | Re-captures the README screenshots (light and dark) and the banner from the demo |
| `make icon` | Re-renders the app icon from `scripts/make-icon.swift` |
| `make clean` | Removes build output |

## Usage

1. Click the drive icon in the menu bar → **Manage Servers …**.
2. Click **+** and enter the server (`fileserver.example.com` or an IP) and the login. For SMB, load the shares with ↻ and pick the ones you want — or switch on **Connect All Shares**.
3. Save with **⌘S**. The shares are mounted and the profile shows up in the Finder sidebar.

For a second account on the same server, use **Duplicate** and change the user. Each profile can get its own color.

The menu bar popover shows every profile with its status. The switch keeps a profile connected or disconnects it on purpose (it then stays disconnected until you switch it on again). Click a share chip to open it in Finder.

### Login modes

| Mode | Use it when |
|---|---|
| **User & Password** | You want a specific account, for example an admin account, or the server is not in your Mac's domain. |
| **Domain Login** | Your Mac is joined to Active Directory and you want to use your Mac login (Kerberos). No password is stored. |

With *User & Password*, DriveDock picks how to reach the server (**Connect via**):

- a short NetBIOS domain such as `CORP` → by **IP address**, so the Mac's own Kerberos ticket cannot take over the login
- a DNS-style domain such as `corp.example.com` → by **server name**, so macOS can get a Kerberos ticket for the account you entered

You can force either one per server if a server behaves differently.

## How it works

DriveDock is a SwiftUI menu bar app on a plain AppKit lifecycle: the menu and the server window exist only while they are open, so nothing renders in the background. Every 20 seconds and on every wake, network and unmount event, it compares what should be mounted with the system's mount table and mounts what is missing. Servers that keep failing are retried with a growing pause (up to 5 minutes), and a burst of events leads to a single check.

SMB shares are mounted with `mount_smbfs`, and share lists come from `smbutil view`. That was a deliberate choice over the NetFS API that Finder's *Connect to Server* uses. In testing, NetFS hands every mount to `NetAuthSysAgent`, which:

- sometimes never answers for shares the user may not open — and then blocks **every** further network mount on the Mac, Finder included
- silently falls back to **guest access** when a login fails, so a wrong password can go unnoticed on servers that allow guests
- prefers the Mac's Kerberos ticket over the credentials you pass in

`mount_smbfs` reports *permission denied* and *authentication error* immediately and honestly, and the mount table shows which user is actually logged in. Before mounting, DriveDock checks the login once with `smbutil`. Only if that succeeds does it mount, so a wrong password is never retried share by share.

Both tools only read passwords from a terminal, so they run under `expect` and receive the password through the environment, never as a command line argument. WebDAV shares are mounted through NetFS.

| File | Purpose |
|---|---|
| `ConnectionManager.swift` | Desired-vs-actual reconciliation, reconnect triggers and backoff, share discovery |
| `Mounter.swift` | SMB via `mount_smbfs`, WebDAV via NetFS, mount table |
| `ShareBrowser.swift` | Share lists via `smbutil view` |
| `ToolRunner.swift` | Runs CLI tools with a hard timeout; passwords via `expect` |
| `VolumeEvents.swift` | Mount and unmount events from the kernel |
| `Keychain.swift` | All passwords in one login keychain item |
| `ConnectionStore.swift` | The server list in Application Support |
| `FinderSidebar.swift` | Finder sidebar favorites |
| `Localization.swift` | `tr()` lookup; translations in `Resources/<language>.lproj` |
| `DriveDockApp.swift` | App lifecycle, menu bar item, server window |
| `MenuView.swift`, `SettingsView.swift`, `DesignKit.swift` | User interface |
| `DeveloperMode.swift` | Demo mode, screenshots, UI stress test |
| `Tests/DriveDockTests` | Unit tests: share list parsing, tool runner, mount table, server list |

## Privacy and security

- Passwords are stored in your login keychain only. Connection settings (no passwords) are in `~/Library/Application Support/DriveDock/connections.json`.
- No network traffic other than to the servers you configure. No telemetry, no update checks.
- A plain-text activity log (status changes and mount errors, never passwords) is written to `~/Library/Logs/DriveDock.log`.
- The app is not sandboxed: it needs to run `mount_smbfs` and `smbutil` and to mount into your home folder.

## Troubleshooting

**"No access" on a share.** The login works, but the server doesn't allow this account to open that share. Ask your admin or deselect the share.

**"Login failed".** Wrong user, domain or password. DriveDock stops retrying until you change the credentials or connect manually, so your account doesn't get locked.

**Logged in as the wrong user.** On a domain-joined Mac, set **Connect via** to *IP address*. Check who is logged in with `mount | grep smbfs`; the user is shown in front of the server.

**macOS asks for keychain access after every update.** Expected for now: without an Apple Team ID, macOS ties saved passwords to the exact app version. DriveDock keeps all server passwords in one keychain item, so it is one question per update – enter your password and choose *Always Allow*. Details in [docs/RELEASING.md](docs/RELEASING.md#code-signing).

**Finder or other apps can't mount anything anymore.** That is the `NetAuthSysAgent` hang described above (DriveDock no longer triggers it for SMB). Quit it with `pkill NetAuthSysAgent`; macOS restarts it on demand.

Anything else: check `~/Library/Logs/DriveDock.log` and [open an issue](https://github.com/its-sven/DriveDock/issues).

## Roadmap

- More languages (contributions welcome)
- On-demand shares through a File Provider extension: shares listed in Finder like on Windows, connected only when opened, offline files
- SFTP and other protocols macOS can't mount natively
- Notarized releases with an Apple Developer ID

## Contributing

Issues and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE) © 2026 Sven Würth
