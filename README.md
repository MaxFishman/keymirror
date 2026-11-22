# keymirror

Mirror **← → ↑ ↓ space** from a primary Mac to a redundant Mac over the LAN,
in realtime, with neither app needing to be focused. For keeping two playback
machines in sync.

- **Primary Mac** captures the keys system-wide (passive tap — your local
  playback still responds) and forwards them.
- **Redundant Mac** injects them into whatever app is focused there.

Features: shared-secret auth (HMAC-SHA256 challenge-response), a heartbeat with
live round-trip latency, automatic reconnect with backoff, a pause-mirroring
hotkey, Bonjour auto-discovery (no IPs to type), persisted config, a status
surface, a **menu-bar app**, and **in-app auto-updates**.

> Apple Silicon Macs only. macOS 13+.

## Install

1. Download **KeyMirror.zip** from the
   [latest release](https://github.com/MaxFishman/keymirror/releases/latest).
2. Unzip it, then in Terminal:

   ```bash
   mv ~/Downloads/KeyMirror.app /Applications/
   xattr -dr com.apple.quarantine /Applications/KeyMirror.app
   open /Applications/KeyMirror.app
   ```

   (The `xattr` step is needed because the app is ad-hoc signed, not notarized —
   without it macOS blocks the app. Or just run the bundled `./install.sh`,
   which does all of the above.)

3. A **⌨ icon** appears in the menu bar. Grant permissions when asked (below),
   set a shared secret in **Preferences**, and pick a mode.

Do this on **both** Macs. Choose *Receiver* on the one being controlled and
*Sender* on the one you type on.

### Auto-updates

The app checks GitHub Releases on launch and every few hours. When a newer
version exists, the menu shows **⬆ Install update** — one click downloads it,
swaps itself in place, and relaunches. (With ad-hoc signing, macOS re-prompts
for Accessibility / Input Monitoring after an update; a Developer ID signature
would remove that — see *Releasing*.)

## Menu-bar app

A **⌨ icon** appears in the menu bar. Its menu lets you:

- pick a **mode** — *Off*, *Sender* (this Mac controls the other), or
  *Receiver* (this Mac is controlled);
- see **live status** — state, peer, latency, key counts;
- **pause forwarding** (sender), also ⌃⌥⌘P;
- edit the **shared secret / name / host / port** in Preferences;
- grant **Accessibility / Input Monitoring** via one-click shortcuts;
- toggle **Launch at Login**.

Set the same shared secret on both Macs (Preferences), choose *Receiver* on one
and *Sender* on the other, and they sync. No terminal needed; it keeps running
in the background whether or not any app is focused.

> First launch on each Mac, macOS asks for **Accessibility**, **Input
> Monitoring** (sender only), and **Local Network** — allow all three. The app
> is ad-hoc signed (fine for personal use on your own Macs); for distribution to
> other machines, sign with a Developer ID certificate and notarize.

## CLI (same binary)

The bundle wraps a command-line binary you can also run directly — handy for
testing or headless use.

## Build

```bash
swift build -c release
# binary at: ./.build/release/keymirror
```

## Run

Pick a shared secret (any string) and use the **same value on both Macs**.

**1. On the REDUNDANT Mac** (the one being controlled):

```bash
./.build/release/keymirror recv --secret hunter2
```

**2. On the PRIMARY Mac** (where you press the keys) — no IP needed, it finds
the receiver over Bonjour:

```bash
./.build/release/keymirror send --secret hunter2
```

> First run on each Mac, macOS will ask your terminal for **Local Network**
> access — allow it, or auto-discovery can't see the other Mac. If you'd rather
> skip discovery (or it's blocked), pass `--host <redundant-mac-ip>` on the
> sender; find the IP on the receiver with `ipconfig getifaddr en0`.

Now focus your playback app on BOTH Macs. Pressing ← → ↑ ↓ or space on the
primary advances both. Hold a key and it repeats on both (auto-repeat is
forwarded). The sender prints `● link up — RTT x.xx ms` every few seconds so
you can see the link is healthy. If a Mac sleeps or Wi-Fi blips, the sender
reconnects automatically. `Ctrl-C` either side to stop.

### Pause forwarding

On the primary, press **⌃⌥⌘P** (Control-Option-Command-P) to stop forwarding
(so you can type locally without it reaching the redundant Mac); press again to
resume. If that hotkey is unavailable in your environment, the sender prints a
`kill -USR1 <pid>` fallback that toggles the same thing.

### Shared secret

- `--secret <s>` on both ends, or set `KEYMIRROR_SECRET` in the environment.
- If you omit it, a built-in default is used **with a warning** — fine for a
  quick test on a trusted network, not for real use.
- The secret itself never crosses the wire: the receiver sends a random
  challenge, the sender replies with `HMAC-SHA256(secret, challenge)`.

## Permissions (one-time, per Mac)

macOS requires these for global key capture/injection. The app's menu has
one-click buttons to grant them, or set them in System Settings → Privacy &
Security:

- **Sender Mac:** **Accessibility** *and* **Input Monitoring**
- **Receiver Mac:** **Accessibility**
- **Both:** **Local Network** (for Bonjour auto-discovery)

(If you run the CLI from a terminal instead, grant these to your terminal app.)

## Options

- `--host <ip>` — (send) receiver address; omit to auto-discover via Bonjour.
- `--port <n>` — TCP port (default `52525`). Auto-discovery uses the advertised port.
- `--secret <s>` — shared secret (or `KEYMIRROR_SECRET`), must match on both ends.
- `--name <n>` — Bonjour name to advertise (recv) / prefer (send). Default: host name.
- `--status-file <p>` — write live status JSON to `<p>` every second.

## Config

Persist defaults so you don't retype flags (shared by the CLI and, later, the
menu-bar app):

```bash
keymirror config set --role recv --secret hunter2 --name "Booth Mac"
keymirror config show
```

Stored at `~/Library/Application Support/keymirror/config.json`. Precedence
everywhere is **flag > environment > config > default**.

## Status surface

`--status-file /tmp/keymirror.json` writes a snapshot every second:

```json
{ "role": "recv", "state": "connected", "peer": "192.168.1.48:49351",
  "rttMs": 0.21, "keysSent": 0, "keysInjected": 42, "paused": false }
```

## Wire format

TCP with `TCP_NODELAY`. On connect: `MAGIC "KM2" + 16-byte challenge` from the
receiver, `MAGIC + HMAC-SHA256(secret, challenge)` back from the sender, then a
1-byte accept/reject. After that, fixed framed messages:

- `KEY`  = `0x4B [keyCode, down, isRepeat]` (sender → receiver)
- `PING` = `0x50 <uint64 BE monotonic ns>`  (sender → receiver, every 1s)
- `PONG` = `0x51 <same uint64 echoed>`       (receiver → sender, for RTT)

## Build from source

```bash
./build-app.sh          # -> dist/KeyMirror.app  (release build, ad-hoc signed)
open dist/KeyMirror.app
```

Requires the Xcode command-line tools. The CLI binary is at
`.build/release/keymirror` after a `swift build -c release`.

## Releasing new versions

Cut a release from this Mac:

```bash
./release.sh 0.5.1
```

This builds `KeyMirror.app` at that version, zips it, tags the commit, and
publishes a GitHub Release. The in-app updater compares the release version to
the running one and offers the update within a few hours (or on *Check for
Updates*).

> There's also a `.github/workflows/release.yml` that does the same in CI, but
> GitHub-hosted **macOS runners aren't currently available to this account**
> (`macos-14` reports "not supported"; `macos-13` jobs sit queued), so the
> workflow is set to manual and `release.sh` is the reliable path. If you enable
> macOS runners later, switch the workflow trigger back to `push: tags`.

### Upgrading to Developer ID (seamless updates)

Today the app is **ad-hoc signed**, so after each update macOS re-prompts for
Accessibility / Input Monitoring. A stable **Developer ID** signature fixes that
(permissions persist, no Gatekeeper warnings). When you have an Apple Developer
account, the change is localized:

1. In `build-app.sh`, replace `codesign --sign -` with
   `codesign --sign "Developer ID Application: <you>" --options runtime`.
2. Add a notarization step (`xcrun notarytool submit … && xcrun stapler staple`).
3. In CI, provide the certificate and an app-specific password as repository
   secrets.

Nothing in the app code or the updater changes.
