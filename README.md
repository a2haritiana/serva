# serva

[Version française](README.fr.md)

Set up and harden a fresh Ubuntu or Debian VPS for app deployment, in one guided terminal session.

serva is secure by default because it comes from real incidents: a Dokploy panel left on a public port was taken over by a bot within minutes (admin account created, SSH key injected, cryptominer installed), Docker bypasses ufw for published ports, and SSH hardening can lock you out. v0.1 sets up the base system; v0.2 and v0.3 add Docker, Dokploy, Coolify and WireGuard with admin panels never exposed.

## Install

Requirements: a fresh Ubuntu 24.04/26.04 LTS or Debian 12/13 server, root access over SSH, an SSH key **on your computer** (`ssh-keygen -t ed25519 -a 100`, then `cat ~/.ssh/id_ed25519.pub`), and your provider's web console as a fallback.

```bash
curl -fsSL https://raw.githubusercontent.com/a2haritiana/serva/main/install.sh | sudo bash
sudo serva setup --dry-run   # preview, changes nothing
sudo serva setup
```

The installer downloads the latest release, checks its SHA-256 against `SHA256SUMS` and installs it in `/opt/serva` (command: `/usr/local/bin/serva`). Other versions: `... | sudo bash -s -- --version v0.1.0`. Unreleased code, without checksum: `--ref main`, or `git clone https://github.com/a2haritiana/serva && sudo ./serva/serva setup`.

## Usage

```text
sudo serva                   interactive menu
sudo serva setup [STEP...]   all steps, or only the given ones
sudo serva status            which steps are in place
serva list                   the steps

-n, --dry-run       show what would be done, change nothing
-y, --yes           no questions: config file values and safe defaults
-c, --config FILE   read SERVA_KEY=value settings from FILE
```

A session: pick the steps, create the admin user and paste your public key, then test the new SSH login from a second terminal and type `yes` within 2 minutes. The summary ends with a ready-to-paste `~/.ssh/config` block.

## Steps

| Step | What it does | Safety net |
| --- | --- | --- |
| `user` | Admin user with sudo, a sudo password (12+ characters) and your public key: pasted, from `github.com/<user>.keys` or copied from root | Keys checked with `ssh-keygen`: placeholders, private keys, DSA and RSA < 2048 refused. No private key is ever created on the server |
| `ssh` | `/etc/ssh/sshd_config.d/00-serva.conf`: no root login, no passwords, `AllowUsers <admin>`, `MaxAuthTries 3` | Refused without a valid key; `sshd -t`; unless you confirm a new login within 2 minutes, a systemd timer restores the previous config, even if your session drops |
| `firewall` | ufw: incoming traffic denied except SSH (rate-limited) and, if you want, 80/443 | SSH rule added before the firewall is enabled |
| `fail2ban` | SSH jail on the systemd journal: 5 failures in 10 minutes, 1 hour ban | Your current IP can be whitelisted |
| `updates` | Full upgrade now, daily security updates, optional automatic reboot at a set time | All questions asked before the long upgrade |
| `swap` | `/swapfile` (2 GB, 4 GB above 8 GB of RAM), swappiness 10 | Skipped if swap exists; never overwrites a file |
| `sysctl` | Network hardening in `/etc/sysctl.d/99-serva.conf` | Loose `rp_filter` and untouched `ip_forward`, so Docker and WireGuard keep working |
| `cleanup` | Locks provider accounts (`ubuntu`, `debian`...), empties root's `authorized_keys`, locks the root password | Each only once the admin user works, and after a yes; nothing by default with `--yes` |

## On the server

serva never edits the distribution's own config files: it adds drop-ins (`00-serva.conf` for SSH, `/etc/fail2ban/jail.d/serva.local`, `/etc/apt/apt.conf.d/20auto-upgrades` and `52serva-unattended-upgrades`, `/etc/sysctl.d/99-serva*.conf`), `/swapfile`, ufw rules and the admin user's `authorized_keys`. Every file is backed up first in `/var/backups/serva/<session>/`; the log is `/var/log/serva.log`, session summaries are in `/var/log/serva/`. Steps already in place are skipped, so serva can be run again.

To undo a step, remove its drop-in, for example `sudo rm /etc/ssh/sshd_config.d/00-serva.conf && sudo systemctl reload ssh`, or `sudo ufw disable`.

## Unattended mode

```bash
sudo serva setup --yes --config serva.env
```

```bash
SERVA_USER=deploy
SERVA_USER_PASSWORD_HASH='$6$...'   # openssl passwd -6
SERVA_PUBKEY_GITHUB=your-github-name
SERVA_SWAP_SIZE=2G
```

All keys are in [examples/serva.env.example](examples/serva.env.example). The file is parsed, never executed. Defaults are conservative (no account locked, no root key removed), and unattended SSH hardening cannot prove that you can log in: keep the provider console at hand.

## Roadmap

- **v0.1** (this version): base system. Released after a test on a fresh VPS without losing SSH access.
- **v0.2**: Docker with ufw-docker, Dokploy and Coolify installed with their panels closed (admin accounts created through an SSH tunnel or at install time).
- **v0.3**: WireGuard (wg-easy) for admin access, panels reachable only through the VPN, `serva audit`.

## Development

Code: `serva` (entry point), `lib/` (logging, dialogs, system, state, summary), `modules/base/` (one file per step, each with `describe`, `check` and `apply`, the latter returning 0 done, 1 failed or 2 skipped; changes go through `core::run` and `core::write_file`, so `--dry-run` works).

```bash
shellcheck -x serva install.sh lib/*.sh modules/base/*.sh tests/*.bash
bats tests
```

To release, set `SERVA_VERSION` in `lib/core.sh` and push a `vX.Y.Z` tag: GitHub Actions publishes the archive and its `SHA256SUMS`.

MIT license. Inspired by [ufw-docker](https://github.com/chaifeng/ufw-docker), [du_setup](https://github.com/buildplan/du_setup), [ironboot](https://github.com/dshark3y/ironboot) and [vps-audit](https://github.com/Nuver-Labs/vps-audit).
