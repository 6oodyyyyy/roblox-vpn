# RobloxVPN

A minimal-data, split-tunnel VPN client for Windows that unblocks Roblox where
it is blocked at the ISP level (e.g. Egypt since Feb 2026).

**Design goals:** $0 cost, minimal mobile/metered data usage, no ping increase.

## How it works

- Drives the **official AmneziaWG Windows client** programmatically
  (`amneziawg /installtunnelservice`, `awg show`) — no GUI automation hacks.
  AmneziaWG is a WireGuard fork with handshake obfuscation (`Jc/Jmin/Jmax/
  S1-S4/H1-H4`), which matters because raw WireGuard UDP handshakes are
  easy for DPI to fingerprint.
- **Split tunnel only**: `AllowedIPs = 128.116.0.0/17` (Roblox, AS22697 —
  verified via ARIN WHOIS). Everything else stays on your direct connection,
  so background apps never burn VPN data. Full-tunnel configs (`0.0.0.0/0`)
  are **rejected on import** (override exists in the dashboard, off by default).
- Sensible defaults: MTU 1420, tunnel on **UDP 443** (less conspicuous than
  51820), `PersistentKeepalive = 25`.
- The tunnel Windows service is set to **manual start** and is fully
  uninstalled on disconnect — it can never silently come up on boot and burn
  data.

## The app

System-tray app (Windows 10/11):

- **Connect / Disconnect** (tunnel up/down as a Windows service)
- **Live data counter** — session up/down plus lifetime totals, persisted in
  `%APPDATA%\RobloxVPN\stats.json`. Visible in the tray menu and the dashboard.
- **Import** any AmneziaWG/WireGuard `.conf` (validated; full-tunnel refused)
- **Generate** a client config from server details (endpoint, keys) with one
  click, including random obfuscation parameters
- **Mock mode** (`RobloxVPN.exe --mock`): dry-runs the whole tunnel bring-up
  with simulated traffic — no admin rights, no server needed. Good for testing.
- **Self-test** (`RobloxVPN.exe --self-test`): 32 built-in logic tests.

### Requirements

1. Windows 10/11, 64-bit.
2. The official AmneziaWG Windows client installed
   (https://github.com/amnezia-vpn/amneziawg-windows-client → Releases).
   The app detects it and tells you if it is missing.
3. Administrator rights on first connect (the app self-elevates via UAC).
   A WireGuard/AmneziaWG server somewhere outside the blocked network
   (see `server/`).

### Quick start

1. Run `RobloxVPN.exe` (accept the UAC prompt).
2. Tray icon → **Import .conf...** and pick the client config from your server
   (or **Generate config...** if you have the server keys).
3. **Connect**. Open Roblox only after the tray shows "Connected".

## The server

`server/setup-awg-server.sh` — one-shot Ubuntu setup (cloud-init compatible,
fully non-interactive):

```bash
sudo bash setup-awg-server.sh [--port 443] [--endpoint auto|YOUR_IP]
```

It installs AmneziaWG from the official PPA (`ppa:amnezia/ppa`,
`amneziawg-dkms` + `amneziawg-tools`), enables IP forwarding + NAT
masquerade, generates keys and matching obfuscation parameters, starts the
tunnel on UDP 443, and prints a ready-to-import client `.conf`
(also saved to `/root/roblox-client.conf`).

Target: Oracle Cloud **Always Free** VM (Ubuntu 22.04/24.04, Frankfurt —
measured ~65 ms from Cairo), but any Ubuntu VPS works.

**Oracle Cloud networking note:** you must allow UDP 443 ingress in the VCN
security list / NSG, or handshakes will never reach the server.

## Building the .exe

Built with PyInstaller on Windows via GitHub Actions
(`.github/workflows/build-exe.yml`):

```
pyinstaller --noconfirm --onefile --noconsole --name RobloxVPN client/roblox_vpn.py
```

The workflow also runs `RobloxVPN.exe --self-test` as a smoke test.

## Data-usage notes

- Only traffic to `128.116.0.0/17` enters the tunnel. Roblox gameplay is
  typically tens of KB/s — the WireGuard overhead is ~60 bytes/packet
  (~0.2 ms added latency).
- The lifetime counter is the honest number: check the dashboard before
  worrying.
- The Roblox CDN (`rbxcdn`, on third-party CDNs) is intentionally left on the
  direct connection — the block targets Roblox's own servers.

## Limitations / honest blockers

- **Server required.** There is no way to hide your location without an exit
  server outside the blocked network. This repo gives you the client + a
  $0 server recipe (Oracle Always Free), not a free server itself.
- **No kill switch (yet).** If the tunnel drops, traffic to Roblox fails
  closed only insofar as the ISP still blocks it — nothing leaks to Roblox,
  but there is no firewall-level kill switch.
- **AmneziaWG versions must match.** A server using AmneziaWG 3.1-only
  features (e.g. random packet trailers) needs a 3.1-capable Windows client.
  The configs generated here use the classic parameter set compatible with
  both. If the handshake never completes, check versions on both ends.
- **DPI is an arms race.** Obfuscation raises the bar; it is not invisibility.
- The client stores the tunnel private key in `%APPDATA%\RobloxVPN\`
  (user-readable). Treat that folder like a password.

## Project layout

```
roblox-vpn/
  client/roblox_vpn.py      the app (tray + backend + config tools)
  client/requirements.txt
  server/setup-awg-server.sh Ubuntu server setup (AmneziaWG + NAT)
  dist/                     built RobloxVPN.exe goes here
  README.md
```
