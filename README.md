# Aquadactyl Installer

Git-based installation and managed updates for Aquadactyl v1.1-beta.2, with
Blueprint included. This release is a prerelease; validate your deployment and
addons in staging before opening it to users.

## Install

Use a dedicated Ubuntu 22.04/24.04/26.04 LTS or Debian 12/13 host. You need root,
working DNS, outbound HTTPS and enough disk space for a source build and backups.
The script configures system packages and services on that host.

```bash
git clone --depth 1 --branch v1.1-beta.1 https://github.com/Aquadactyl/Installer.git /opt/aquadactyl-installer
cd /opt/aquadactyl-installer
sudo bash deploy.sh install v1.1-beta.2
```

Review `deploy.sh` before executing it. `install` selects the exact panel tag,
sets up PHP 8.5/FPM (8.4 is supported), Composer 2, Node.js 24 and pinned pnpm,
installs locked packages, generates missing application secrets, migrates the
schema, initializes bundled Blueprint, builds assets and configures Nginx,
`aquaq.service` and the minute scheduler. It prompts for panel/database settings
and administrator creation. Existing initialized panels must use `update`.

The installer revision (`v1.1-beta.1`) and panel release (`v1.1-beta.2`) are separate.
Git's detached-HEAD message is normal when selecting a release tag.

Ubuntu 22.04 uses the same PHP PPA and verified Node.js 24 binaries as newer
Ubuntu hosts; the PHP 8.4/8.5 requirement is unchanged. Host compatibility is
checked before changing panel source or configuration. The installer never
upgrades your operating system. Use systemd-enabled WSL if testing there.
Existing commands are checked for supported versions and availability to the
web user; outdated or private runtimes trigger host provisioning too.
The installer prefers system binaries and does not load root's NVM shell
configuration. Its pnpm installation uses `/usr/local/lib/aquadactyl-tools`,
independent of any private npm global prefix configured for the operator.

If runtime checks still fail after packages are installed, the diagnostic names
the failing command, its selected path/version or the affected web user. A
manually selected older PHP CLI alternative is not automatically changed: use
`php -v`, `command -v php` and `update-alternatives --display php` to inspect it.
Select a supported CLI deliberately before retrying; existing FPM pools and
other applications can have their own PHP requirements.

### Database authentication and resuming installation

If migrations report access denied, verify the saved endpoint, database account,
host and password. `CREATE USER IF NOT EXISTS` preserves an existing account's
password; it does not synchronize that password with a newly written `.env`.
The installer does not reset existing database-account passwords automatically.
Database connectivity is checked before generating keys or entering maintenance.

For an unfinished installation using a local database at `127.0.0.1`, a dedicated
database-login repair is available:

```bash
sudo bash deploy.sh repair-database
```

This explicit command creates a new loopback account scoped only to the saved
panel database. It privately backs up `.env`, verifies the new account, then
atomically changes only `DB_USERNAME` and `DB_PASSWORD`. Existing accounts,
passwords, grants, tables, application keys and other environment settings are
preserved. It requires local administrator socket access through `sudo mariadb`
and refuses remote/URL/socket configuration, system databases, initialized panels
and mismatched source. A failed repair retains the original `.env`.

After repairing the saved database configuration, resume a failed installation
that already installed dependencies but has not initialized Blueprint:

```bash
sudo bash deploy.sh install v1.1-beta.2 --resume
```

Resume requires the matching release source, an existing `.env` and `vendor/`.
It reuses the saved configuration without repeating setup prompts, preserves
existing application keys and uploads, reruns locked dependency installation and
completes migrations, Blueprint, assets and services. It clears maintenance only
after successful completion. Do not regenerate `APP_KEY` or drop the database to
repair authentication. Initialized panels or addon state require `update`.
`--resume` and `--refresh-source` cannot be combined.

If an earlier installer rejected Ubuntu 22.04 after recovering the source,
select Installer `v1.1-beta.1` and retry using the same panel tag as that checkout.
To move an unfinished checkout to `v1.1-beta.2`, use the source-recovery procedure
below. Initialized panels must use `update` instead. Keep the earlier backup.

### APT repository errors

Host provisioning requires a successful refresh of all configured APT
repositories. An unrelated third-party repository with a missing Release file,
an invalid signing key or a network error can block installation. The installer
stops rather than use stale indexes or disable package signature verification.
Repository definitions are in `/etc/apt/sources.list` and
`/etc/apt/sources.list.d/` (`.list` and `.sources` files).

Repair each failing repository using its vendor's instructions, keeping a backup
of any source/keyring file you edit. The old `downloads.plex.tv/repo/deb` source
has been replaced; use the
[Plex repository migration guide](https://support.plex.tv/articles/235974187-enable-repository-updating-for-supported-linux-server-distributions/).
For MaxScale's `NO_PUBKEY 5D87FACA8C27D14E`, follow
[MariaDB's repository signing-key instructions](https://mariadb.com/docs/server/server-management/install-and-upgrade-mariadb/mariadb-package-repository-setup-and-usage#mariadb-maxscale-repository).
Preserve the configured MariaDB server version and any other entries sharing
the same source file; installing a panel does not require switching database
release channels or uninstalling Plex/MaxScale.

Verify the repair, then resume the same panel installation:

```bash
sudo apt-get -o APT::Update::Error-Mode=any update
cd /opt/aquadactyl-installer
sudo bash deploy.sh install v1.1-beta.2
```

Do not bypass these failures using `trusted=yes`, `--allow-unauthenticated` or
insecure-repository flags. An `apt-key` deprecation warning is separate from a
failed signature verification; migrate legacy keyrings using that vendor's
scoped `signed-by` configuration.

### Recover an unfinished checkout

If installation reports that an existing source directory has a different
version (for example, `canary`), and it is an unused or unfinished installation:

```bash
cd /opt/aquadactyl-installer
git fetch origin tag v1.1-beta.1
git checkout --detach v1.1-beta.1
sudo bash deploy.sh install v1.1-beta.2 --refresh-source
```

Recovery fetches and validates the release first, then moves the complete old
checkout into a private `preinstall-*` backup under `/var/backups/aquadactyl`.
It retains `.env`, application keys, `.blueprintrc` and `storage/app` uploads in
the new checkout. It never drops databases. Initialized panels or installed-addon
records are refused: use the managed update/recovery flow for those installations.
Without `--refresh-source`, mismatched source is left unchanged and the installer
prints its detected version and the recovery command before provisioning packages.

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
sudo bash deploy.sh update v1.1-beta.2
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

To test real Ubuntu 22.04 package provisioning, FPM/Nginx configuration checks
and the same application installation/update flow:

```bash
docker compose -f tests/compose.yaml -f tests/compose.host.yaml run --build --rm panel
docker compose -f tests/compose.yaml -f tests/compose.host.yaml down
```

This test also uses simulated service-control calls after provisioning; it does
not replace a systemd host test. `UBUNTU_VERSION` selects another supported Ubuntu
release for the fixture. CI exercises Ubuntu 22.04 provisioning on every change.

Add `-e AQUADACTYL_INSTALLER_LOCAL_DB=1` to the host test's `run` command to use
Ubuntu's local MariaDB server and an existing non-root panel database account.
This exercises the local account-provisioning path, mismatched saved credentials
and resume after fixing them, in addition to the default separate-database test.
