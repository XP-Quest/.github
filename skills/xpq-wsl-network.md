---
name: xpq-wsl-network
description: Set up WSL2 networking on an XP Quest dev machine (antman, flash) so the machines can reach each other. Modes - mirrored (default), tailscale, nat (revert). Run as /xpq-wsl-network [status|mirrored|tailscale|nat].
---

# xpq-wsl-network

Runs the same on every machine. Mirrored networking gives WSL the Windows host's LAN IP;
Tailscale runs inside WSL and works across networks. NAT is the vanilla WSL default.

Argument: `status` (default if none), `mirrored`, `tailscale` or `nat`. Ask which if unclear.
Never change anything for `status`. For other modes, state what will change and wait for a
yes before running.

## Mechanics

`scripts/wsl-net.ps1` in the `~/xpquest/.xpq-org-main` clone does all Windows-side work. It needs admin; Claude's
PowerShell is not elevated, so launch it through UAC. The user must click Yes on the prompt.

```bash
SCRIPT=~/xpquest/.xpq-org-main/scripts/wsl-net.ps1
cp "$SCRIPT" "$(wslpath "$(cmd.exe /c 'echo %TEMP%' 2>/dev/null | tr -d '\r')")/wsl-net.ps1"
powershell.exe -NoProfile -Command "Start-Process powershell -Verb RunAs -Wait -ArgumentList '-NoProfile -ExecutionPolicy Bypass -Command \"& \$env:TEMP\\wsl-net.ps1 -Mode <MODE> *> \$env:TEMP\\wsl-net.log\"'"
iconv -f UTF-16 -t UTF-8 "$(wslpath "$(cmd.exe /c 'echo %TEMP%' 2>/dev/null | tr -d '\r')")/wsl-net.log"
```

If the UAC prompt is declined, do not retry; give the user the commands to run in an admin
PowerShell instead. `status` needs no elevation: run the script with the same
`powershell.exe -File` form, without `-Verb RunAs`.

What the script does, per mode:
- `mirrored`: sets `networkingMode=mirrored` in `%USERPROFILE%\.wslconfig` (other keys kept,
  backup made), adds inbound-allow rules for TCP 22 scoped to the LAN subnet in BOTH the
  Hyper-V firewall (default inbound is Block) and Windows Defender Firewall (Private profile).
  Extra ports: `-Ports 22,3000`. Rule names start with `XPQ WSL inbound`.
- `tailscale` / `nat`: removes `networkingMode` and the XPQ rules.
- All modes except `status`: delete the legacy `WSL Port Forward 8080` task and reset
  portproxy, since neither belongs with mirrored or tailscale.

## Steps by mode

### mirrored
1. Run the script with `-Mode mirrored`.
2. Warn that `wsl --shutdown` kills this session. Tell the user to run `wsl --shutdown` from
   Windows, reopen WSL, then continue below.
3. In WSL: `ss -tln | grep ':22 '` must show a listener; if not,
   `sudo systemctl enable --now ssh` (the OpenSSH server must be installed).
4. Verify from the other machine: `ping <host>`, `ssh <user>@<host>`. Disconnect NordVPN
   during the test; if it fixes things, enable its LAN-discovery setting.
5. If the hostname does not resolve, that is LAN DNS, not WSL: use router DNS reservations or
   `/etc/hosts` / `C:\Windows\System32\drivers\etc\hosts` entries.

### tailscale
1. Run the script with `-Mode tailscale` (leaves NAT networking, removes mirrored and rules).
2. After `wsl --shutdown`, in WSL (systemd must be on: `/etc/wsl.conf` has `[boot] systemd=true`):
   `curl -fsSL https://tailscale.com/install.sh | sh`, then
   `sudo tailscale up --ssh --hostname=<machine>-wsl`. Distinct hostnames avoid clashing with
   a Windows-side Tailscale node. The user runs `tailscale up` themselves (`! sudo tailscale up ...`)
   because it needs browser login.
3. Verify: `tailscale status`, then `ssh <machine>-wsl` from the other machine.
4. Check the choice against security-model.md before leaving it in place: it adds a
   third-party control plane.

### nat
Run the script with `-Mode nat`, then `wsl --shutdown`. Result: vanilla NAT, no XPQ rules.

## Rules
- Both machines must end in the same mode; after changing one, remind the user to run this
  skill on the other.
- Do not edit sshd settings or Windows sshd; this skill only owns WSL networking.
- Report the script log faithfully, including errors.
