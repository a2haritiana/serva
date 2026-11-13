# Security policy

Report vulnerabilities privately through [GitHub private vulnerability reporting](https://github.com/a2haritiana/serva/security/advisories/new), not in public issues. Include the serva version, the system and the steps to reproduce. Only the latest release gets fixes.

In scope: serva itself (`serva`, `lib/`, `modules/`, `install.sh`), especially anything that could lock an administrator out, leak a secret or run unexpected code as root. Bugs in the software serva configures (OpenSSH, ufw, fail2ban...) belong to those projects.

serva's own choices: no private key is ever created on the server; release archives are checked against `SHA256SUMS` before install (`--ref` installs are not, and are for testing only); every changed file is backed up first; `--dry-run` changes nothing; config files are parsed, never executed; SSH changes are validated with `sshd -t` and rolled back unless a new login is confirmed in time.
