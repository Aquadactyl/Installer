# Aquadactyl Installer

Git-based installation and managed updates for Aquadactyl v1.0-beta, with
Blueprint included. This release is a prerelease; validate your deployment and
addons in staging before opening it to users.

## Install

Use a dedicated Ubuntu 24.04/26.04 LTS or Debian 12/13 host. You need root,
working DNS, outbound HTTPS and enough disk space for a source build and backups.
The script configures system packages and services on that host.

```bash
git clone --depth 1 --branch v1.0-beta https://github.com/Aquadactyl/Installer.git /opt/aquadactyl-installer
cd /opt/aquadactyl-installer
sudo bash deploy.sh install v1.0-beta
```

Review `deploy.sh` before executing it. `install` selects the exact panel tag,
sets up PHP 8.5/FPM (8.4 is supported), Composer 2, Node.js 24 and pinned pnpm,
installs locked packages, generates missing application secrets, migrates the
schema, initializes bundled Blueprint, builds assets and configures Nginx,
`aquaq.service` and the minute scheduler. It prompts for panel/database settings
and administrator creation. Existing initialized panels must use `update`.

Use a real HTTPS `APP_URL`. Obtain a trusted TLS certificate before going live;
the initial self-signed certificate is only for bootstrapping. Set email delivery,
then complete **Admin > Settings > Panel setup**. Configure trusted proxies when
TLS terminates at Nginx, Traefik or Dokploy. Keep the database and Redis private.
See the [panel deployment reference](https://github.com/Aquadactyl/aquadactyl/blob/main/docs/DEPLOYMENT.md)
and [Manta installation](https://github.com/Aquadactyl/manta/blob/main/docs/INSTALLING.md).

## Update

Use a reviewed version of this installer, then select the published panel tag:

```bash
cd /opt/aquadactyl-installer
sudo bash deploy.sh update v1.0-beta
```

To select a newer installer release first, use `git fetch origin tag VERSION`
and `git checkout --detach VERSION` in this tools checkout. The panel source is
fetched separately from the exact Git tag. Do not `git pull` over a live panel's
addon-modified files. `.installed-commit` records Git update provenance.

Updates have a maintenance window. Before replacing files the updater validates
the source, requires every installed addon's original `.blueprint` package,
stops active queues and creates private SQL/filesystem backups under
`/var/backups/aquadactyl`. It preserves `.env`, keys, storage and addon state,
removes obsolete core files, reinstalls locked dependencies and reapplies addons.
An extension, build, migration or service failure leaves maintenance active.

Keep backups off-host and test restoring them. An update does not automatically
reverse database migrations. For recovery, stop FPM/queues, restore the panel
snapshot and SQL together, reinstall that version's dependencies, regenerate
caches, then restart services and run `php artisan up` after verifying the panel.

For an independently downloaded release archive and reviewed SHA256:

```bash
sudo bash deploy.sh update --archive /path/to/panel.tar.gz YOUR_64_CHARACTER_SHA256
```

## Configuration

| Variable | Default | Purpose |
| --- | --- | --- |
| `PANEL_ROOT` | `/var/www/aquadactyl` | Dedicated served panel directory |
| `WEB_USER` / `WEB_GROUP` | `www-data` | PHP/queue user and readable code group |
| `PHP_VERSION` | `8.5` | PHP CLI/FPM minor version for host setup |
| `PHP_FPM_SERVICE` | autodetected | Service to reload after updating |
| `BACKUP_DIR` | `/var/backups/aquadactyl` | Private backups outside the panel |
| `NON_INTERACTIVE` | `0` | Use an already configured `.env`; no prompts |

Preconfigure `.env` in `PANEL_ROOT` for unattended deployment. Preserve `APP_KEY`
and `HASHIDS_SALT` permanently. Never copy the local Docker example's credentials
into a public installation. `sudo bash deploy.sh permissions` repairs the code
ownership and writable directories. Logs use unique root-only files in `/var/log`.

`setup-host` only provisions packages. The legacy `remove` command is destructive:
it deletes panel data and can remove host services; it is not an update/rollback
mechanism and should not be used on a shared host.

## Validate changes

```bash
bash -n deploy.sh
bash tests/deploy.sh
shellcheck --severity=error deploy.sh tests/deploy.sh
```

These checks exercise release pinning, tag/path validation and dotenv handling
in temporary directories. Full installation also requires a disposable Linux
host and real database, queue, web server and Blueprint checks.

With a panel checkout beside this repository, test the application installation
and Git update with real MariaDB, Redis, Composer, pnpm and Blueprint:

```bash
docker compose -f tests/compose.yaml run --build --rm panel
docker compose -f tests/compose.yaml down
```

This stack publishes no ports and mounts no Docker socket. It verifies keys,
uploads, addon data, SQL backups, obsolete-file removal and the login HTTP page.
Systemd/FPM calls are stubbed in this test image; validate actual host services
and trusted HTTPS on a disposable Linux host too. Reports stay in ignored `build/`.
