# Aquadactyl Standalone Deployment & Management Tooling

A production-ready, single-file automation script for installing, updating, and managing **[Aquadactyl](https://aquadactyl.uk)** (Pterodactyl fork with bundled Blueprint beta-2026-08 integration).

---

## ⚡ Quick Start (One-Liner)

Run the full automated installation with a single command:

```bash
curl -fsSL https://raw.githubusercontent.com/Aquadactyl/Installer/main/deploy.sh | sudo bash -s -- install
```

> **Note:** If `deploy.sh` is already downloaded locally on your server:
>
> ```bash
> sudo bash deploy.sh install
> ```

---

## 🖥️ Supported Operating Systems

To ensure compatibility with modern PHP 8.5 runtimes and current build tooling, only modern distributions are supported:

- **Ubuntu**: `24.04 LTS`, `24.10`, `26.04+ LTS`
- **Debian**: `12 (Bookworm)`, `13 (Trixie)`

_(Older releases such as Debian 11 or Ubuntu 22.04 and older are deprecated and unsupported)._

---

## 🚀 What the Script Does

### 1. Automated Host Provisioning (`setup-host`)

- **PHP 8.5 & FPM**: Configures the official [Ondřej Surý](https://packages.sury.org/php/) Debian/Ubuntu repository with all required extensions (`bcmath`, `curl`, `gd`, `mbstring`, `pdo_mysql`, `posix`, `xml`, `zip`).
- **Node.js & npm**: Idempotently installs NVM `v0.40.8`, Node.js `24`, and the latest `npm` (skips if Node $\ge$ 24 is already present).
- **pnpm**: Installs the pinned `pnpm@12.10.1` package manager.
- **Composer**: Installs Composer 2.
- **Services**: Sets up MariaDB 10.11+, Redis 6+, Nginx, and system utilities (`rsync`, `flock`, `mariadb-client`, etc.).

### 2. Panel Installation (`install`)

- Clones Aquadactyl to `/var/www/aquadactyl`.
- Configures `.env` with interactive terminal prompts (or pre-set environment variables).
- Configures Redis drivers for sessions, caching, and queues.
- Generates secure Laravel `APP_KEY` and 32-hex `HASHIDS_SALT`.
- Automatically executes migrations, seeds Blueprint tables, and seeds default nests & eggs (`DatabaseSeeder`).
- Headlessly bootstraps **Blueprint beta-2026-08** and warms its extension cache (`artisan bp:cache`).
- Compiles production frontend assets (`pnpm run build:production`).
- Deploys the background worker (`pteroq.service`) and the Laravel cron scheduler (`/etc/cron.d/aquadactyl`).
- Normalizes strict least-privilege permissions (`root:www-data`, `0750`/`0640`, only `storage` and `bootstrap/cache` writable by `www-data`).
- Guides you through creating your initial administrator account.

### 3. Managed Zero-Downtime Updates (`update`)

- **Tag-based upgrades**:

  ```bash
  sudo bash deploy.sh update v1.0.0
  ```

- **Local archive upgrades**:

  ```bash
  sudo bash deploy.sh update --archive /path/to/panel.tar.gz <sha256-hash>
  ```

- **Safety First**:
  - Automatically creates a timestamped private backup (`/var/backups/aquadactyl/`) containing a full database SQL dump and compressed file snapshot.
  - Pauses background queues (`pteroq.service`) and enters maintenance mode.
  - Syncs the release archive while strictly preserving `.env`, `.blueprintrc`, and extension data.
  - Re-applies all installed Blueprint extensions non-interactively.
  - Traps failures: keeps maintenance mode active upon any error and outputs step-by-step recovery commands.

### 4. Permissions Repair (`permissions`)

Restore the strict Aquadactyl permission model at any time:

```bash
sudo bash deploy.sh permissions
```

---

## ⚙️ Environment Variables

Customize deployment behavior without modifying the script:

| Variable          | Default                   | Description                                                       |
| :---------------- | :------------------------ | :---------------------------------------------------------------- |
| `PANEL_ROOT`      | `/var/www/aquadactyl`     | Absolute directory path to the panel root.                        |
| `WEB_USER`        | `www-data`                | System user executing PHP-FPM and web workers.                    |
| `WEB_GROUP`       | `www-data`                | System group executing PHP-FPM and web workers.                   |
| `PHP_VERSION`     | `8.5`                     | Target PHP minor version (`8.4` or `8.5`).                        |
| `BACKUP_DIR`      | `/var/backups/aquadactyl` | Directory for update snapshots and SQL dumps.                     |
| `NON_INTERACTIVE` | `0`                       | Set to `1` to bypass all terminal questions for CI/headless runs. |

---

## 🛠️ Restoring a Backup

If an update is interrupted or encounters an unrecoverable error, the script prints the exact backup path. You can restore your previous state with:

```bash
# 1. Stop services
sudo systemctl stop php8.5-fpm pteroq.service

# 2. Extract files
sudo tar -xzf /var/backups/aquadactyl/<TIMESTAMP>/panel.tar.gz -C /var/www/aquadactyl

# 3. Restore database
sudo mariadb -u aquadactyl -p aquadactyl < /var/backups/aquadactyl/<TIMESTAMP>/database.sql

# 4. Normalize permissions and start
sudo bash /var/www/aquadactyl/deploy.sh permissions
sudo systemctl start php8.5-fpm pteroq.service
sudo -u www-data php /var/www/aquadactyl/artisan up
```

---

## 📄 License

This tooling is licensed under the MIT License.
