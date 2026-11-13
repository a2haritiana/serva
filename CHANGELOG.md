# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), versions: [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Base steps for Ubuntu 24.04/26.04 LTS and Debian 12/13: `user` (sudo user, sudo password, public key pasted, from GitHub or copied from root), `ssh` (key-only, no root, `sshd -t`, timed confirmation with automatic rollback by a systemd timer), `firewall` (ufw), `fail2ban`, `updates` (unattended-upgrades), `swap`, `sysctl` and `cleanup` (provider accounts, root keys, root password).
- `serva setup [STEP...]`, `status`, `list` and an interactive whiptail menu; `--dry-run`, `--yes` and `--config FILE` (parsed, never executed).
- Backups in `/var/backups/serva`, log in `/var/log/serva.log`, session summaries in `/var/log/serva/`.
- `install.sh` with SHA-256 verification of release archives; CI (ShellCheck, bats, dry run) and release workflow.

[Unreleased]: https://github.com/a2haritiana/serva/commits/main
