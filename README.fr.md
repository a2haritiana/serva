# serva

[English version](README.md)

Préparer et sécuriser un VPS Ubuntu ou Debian neuf pour déployer des applications, en une session guidée dans le terminal.

serva est sécurisé par défaut parce qu'il vient d'incidents réels : un panneau Dokploy laissé sur un port public a été pris par un robot en quelques minutes (compte admin créé, clé SSH injectée, mineur de cryptomonnaie installé), Docker contourne ufw pour les ports publiés, et durcir SSH peut vous enfermer dehors. La v0.1 prépare le système de base ; les v0.2 et v0.3 ajoutent Docker, Dokploy, Coolify et WireGuard, sans jamais exposer les panneaux d'administration.

## Installation

Prérequis : un serveur Ubuntu 24.04/26.04 LTS ou Debian 12/13 neuf, un accès root en SSH, une clé SSH **sur votre ordinateur** (`ssh-keygen -t ed25519 -a 100`, puis `cat ~/.ssh/id_ed25519.pub`) et la console web de l'hébergeur en secours.

```bash
curl -fsSL https://raw.githubusercontent.com/a2haritiana/serva/main/install.sh | sudo bash
sudo serva setup --dry-run   # aperçu, ne change rien
sudo serva setup
```

L'installateur télécharge la dernière version, vérifie son SHA-256 avec `SHA256SUMS` et l'installe dans `/opt/serva` (commande : `/usr/local/bin/serva`). Autre version : `... | sudo bash -s -- --version v0.1.0`. Code non publié, sans somme de contrôle : `--ref main`, ou `git clone https://github.com/a2haritiana/serva && sudo ./serva/serva setup`.

## Utilisation

```text
sudo serva                   menu interactif
sudo serva setup [ÉTAPE...]  toutes les étapes, ou seulement celles indiquées
sudo serva status            étapes déjà en place
serva list                   liste des étapes

-n, --dry-run       montre ce qui serait fait, ne change rien
-y, --yes           aucune question : valeurs du fichier de config et défauts prudents
-c, --config FICH   lit les réglages SERVA_CLÉ=valeur dans FICH
```

Une session : choisissez les étapes, créez l'utilisateur admin et collez votre clé publique, puis testez la nouvelle connexion SSH depuis un second terminal et tapez `yes` dans les 2 minutes. Le résumé final contient un bloc `~/.ssh/config` prêt à copier.

## Étapes

| Étape | Ce qu'elle fait | Garde-fou |
| --- | --- | --- |
| `user` | Utilisateur admin avec sudo, un mot de passe sudo (12 caractères ou plus) et votre clé publique : collée, prise sur `github.com/<user>.keys` ou copiée depuis root | Clés vérifiées avec `ssh-keygen` : exemples, clés privées, DSA et RSA < 2048 refusés. Aucune clé privée n'est jamais créée sur le serveur |
| `ssh` | `/etc/ssh/sshd_config.d/00-serva.conf` : pas de connexion root, pas de mot de passe, `AllowUsers <admin>`, `MaxAuthTries 3` | Refusé sans clé valide ; `sshd -t` ; sans confirmation d'une nouvelle connexion dans les 2 minutes, un minuteur systemd remet l'ancienne configuration, même si votre session coupe |
| `firewall` | ufw : entrées bloquées sauf SSH (limité) et, si vous voulez, 80/443 | Règle SSH posée avant l'activation |
| `fail2ban` | Prison SSH sur le journal systemd : 5 échecs en 10 minutes, bannissement d'une heure | Votre IP actuelle peut être mise en liste blanche |
| `updates` | Mise à niveau complète, correctifs de sécurité quotidiens, redémarrage automatique optionnel à heure fixe | Toutes les questions avant la longue mise à niveau |
| `swap` | `/swapfile` (2 Go, 4 Go au-delà de 8 Go de RAM), swappiness 10 | Ignoré si un swap existe ; n'écrase jamais un fichier |
| `sysctl` | Durcissement réseau dans `/etc/sysctl.d/99-serva.conf` | `rp_filter` souple et `ip_forward` intact, pour que Docker et WireGuard fonctionnent |
| `cleanup` | Verrouille les comptes de l'hébergeur (`ubuntu`, `debian`...), vide `authorized_keys` de root, verrouille le mot de passe root | Seulement quand l'admin fonctionne, et après un oui ; rien par défaut avec `--yes` |

## Sur le serveur

serva ne modifie jamais les fichiers de configuration de la distribution : il ajoute des fichiers à lui (`00-serva.conf` pour SSH, `/etc/fail2ban/jail.d/serva.local`, `/etc/apt/apt.conf.d/20auto-upgrades` et `52serva-unattended-upgrades`, `/etc/sysctl.d/99-serva*.conf`), `/swapfile`, des règles ufw et le `authorized_keys` de l'admin. Chaque fichier est d'abord sauvegardé dans `/var/backups/serva/<session>/` ; le journal est `/var/log/serva.log`, les résumés sont dans `/var/log/serva/`. Les étapes déjà en place sont sautées : serva peut être relancé.

Pour annuler une étape, supprimez son fichier, par exemple `sudo rm /etc/ssh/sshd_config.d/00-serva.conf && sudo systemctl reload ssh`, ou `sudo ufw disable`.

## Mode sans questions

```bash
sudo serva setup --yes --config serva.env
```

```bash
SERVA_USER=deploy
SERVA_USER_PASSWORD_HASH='$6$...'   # openssl passwd -6
SERVA_PUBKEY_GITHUB=votre-compte-github
SERVA_SWAP_SIZE=2G
```

Toutes les clés sont dans [examples/serva.env.example](examples/serva.env.example). Le fichier est lu, jamais exécuté. Les défauts sont prudents (aucun compte verrouillé, aucune clé root supprimée), et sans personne pour tester, serva ne peut pas prouver que la connexion SSH fonctionne : gardez la console de l'hébergeur sous la main.

## Feuille de route

- **v0.1** (cette version) : système de base. Publiée après un test sur un VPS neuf sans perte d'accès SSH.
- **v0.2** : Docker avec ufw-docker, Dokploy et Coolify installés panneaux fermés (comptes admin créés par tunnel SSH ou à l'installation).
- **v0.3** : WireGuard (wg-easy) pour l'administration, panneaux joignables uniquement par le VPN, `serva audit`.

## Développement

Code : `serva` (point d'entrée), `lib/` (journal, dialogues, système, état, résumé), `modules/base/` (un fichier par étape, avec `describe`, `check` et `apply`, ce dernier renvoyant 0 fait, 1 échec ou 2 ignoré ; les changements passent par `core::run` et `core::write_file`, d'où le `--dry-run`).

```bash
shellcheck -x serva install.sh lib/*.sh modules/base/*.sh tests/*.bash
bats tests
```

Pour publier, réglez `SERVA_VERSION` dans `lib/core.sh` et poussez un tag `vX.Y.Z` : GitHub Actions publie l'archive et son `SHA256SUMS`.

Licence MIT. Inspiré de [ufw-docker](https://github.com/chaifeng/ufw-docker), [du_setup](https://github.com/buildplan/du_setup), [ironboot](https://github.com/dshark3y/ironboot) et [vps-audit](https://github.com/Nuver-Labs/vps-audit).
