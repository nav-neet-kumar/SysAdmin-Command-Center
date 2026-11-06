# Office Command Center

A control panel you open from a file. It runs on your Windows 11 laptop only: no Python, no installs, no cloud.

| Tab | What it does |
|---|---|
| **Terminal** | A real PowerShell session. Type, see the output, run on your laptop as your account. `cd` and variables persist. Up/Down = history, Ctrl+C = stop, Ctrl+L = clear. |
| **Websites** | Add/remove links. Each has a green/red status dot. Click one to open it in a new tab. |
| **Monitor** | Add/remove an IP, host, `host:port` or URL and see whether it is reachable. |
| **Applications** | Add any program (type a path, **Browse…**, or pick from **Installed programs…**). Tick **Run as administrator** per app; click the app to launch it. |
| **Remote Desktop** | Add/remove server IPs. Click one and `mstsc` opens with that address. |

## Why there is a helper

A web page cannot run PowerShell, launch programs or open `mstsc`; browsers forbid it. So the page talks to a tiny
PowerShell script (`helper.ps1`) on your laptop. It is not a service you manage: you never restart it by hand.

## Use it

1. Unzip anywhere (keep all files together).
2. Right-click `install.ps1` → **Run with PowerShell**. It asks before each change (all per-user, no admin rights):
   makes the **Start helper** button work, optionally starts at login, optionally adds a Desktop shortcut.
3. Double-click **`CommandCenter.html`** (or the Desktop shortcut). If the helper is stopped, the page shows
   **Start helper**; click it and the panel opens by itself. Your browser may ask once to allow the link: allow it.

No install? Double-click `Start Command Center.bat` instead (visible window, shows errors).
Stop it with `stop-helper.ps1`. Remove everything with `uninstall.ps1`.

If PowerShell says scripts are disabled: this is a security setting and we do not bypass it. `install.ps1` offers the
standard per-user fix (`RemoteSigned`). If your company policy controls it, ask IT to allow this folder.

## Security (always on, nothing in the UI can turn it off)

- Listens on `127.0.0.1` only; never your network. Non-local clients and unexpected Host headers are refused.
- Every API call needs a random per-run token; cross-site requests and wrong `Origin` are rejected (CSRF protection).
- Strict Content-Security-Policy, no framing, no caching. The UI never uses `innerHTML`.
- Applications and servers launch only if you saved them. Requests cannot supply a path or host to run.
- RDP hosts, URLs and monitor targets are validated; URLs with embedded passwords are refused. No shell is involved.
- Terminal runs as you, never elevated. Risky commands (delete, shutdown, registry edits, encoded or download commands…)
  ask for confirmation first. This is a speed bump, not a sandbox.
- "Run as administrator" shows the normal Windows UAC prompt. It cannot bypass credentials or company policy.
- Actions are logged to `%APPDATA%\OfficeCommandCenter\logs\audit.log` (secret-looking values masked). Command output is never logged.
- No passwords are stored anywhere. Windows asks for RDP credentials itself.
- The `occstart:` link is registered for your user only, takes no arguments, and only starts `helper.ps1`.

Your lists live in `%APPDATA%\OfficeCommandCenter\config` (plain JSON; copy the folder to back up).

## Files

```
CommandCenter.html          double-click this
helper.ps1                  the local helper (server, terminal, monitor, launcher)
web/                        the control panel (index.html, style.css, app.js)
pick-file.ps1               the "Browse…" file dialog
install.ps1 / uninstall.ps1 / stop-helper.ps1 / start-hidden.vbs / Start Command Center.bat
```
