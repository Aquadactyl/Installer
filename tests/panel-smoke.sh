#!/usr/bin/env bash
set -Eeuo pipefail
[[ ${AQUADACTYL_INSTALLER_SMOKE:-} == 1 && -f /.dockerenv ]] || { echo "Run only using tests/compose.yaml." >&2; exit 1; }
export PANEL_ROOT=/var/www/aquadactyl NON_INTERACTIVE=1
export PATH="/usr/local/bin:$PATH"
mkdir -p "$PANEL_ROOT" /reports /etc/systemd/system
rsync -a --exclude=.git --exclude=node_modules --exclude=vendor --exclude='.env*' \
  --exclude=storage --exclude=bootstrap/cache --exclude=public/build --exclude=public/hot \
  --exclude='coverage*' /panel-source/ "$PANEL_ROOT/"
cp /panel-source/.env.example "$PANEL_ROOT/.env"
cd "$PANEL_ROOT"
sed -E -i "s/'version' => '[^']*'/'version' => '1.0-beta'/" config/app.php
sed -i 's|^APP_URL=.*|APP_URL=http://localhost|;s|^DB_HOST=.*|DB_HOST=database|;s|^DB_DATABASE=.*|DB_DATABASE=release_smoke|;s|^DB_USERNAME=.*|DB_USERNAME=root|;s|^DB_PASSWORD=.*|DB_PASSWORD=release-smoke-only|;s|^REDIS_HOST=.*|REDIS_HOST=cache|;s|^SESSION_SECURE_COOKIE=.*|SESSION_SECURE_COOKIE=false|' .env

# Exercise Ubuntu's local database provisioning and existing non-root account
# semantics too, rather than testing only a separate database container as root.
if [[ ${AQUADACTYL_INSTALLER_LOCAL_DB:-} == 1 ]]; then
    install -d -o mysql -g mysql /run/mysqld
    mariadbd --user=mysql --bind-address=127.0.0.1 > /reports/local-mariadb.log 2>&1 &
    for attempt in $(seq 1 30); do
        if mariadb-admin --protocol=socket ping --silent >/dev/null 2>&1; then break; fi
        sleep 1
    done
    mariadb --protocol=socket -u root <<'SQL'
CREATE DATABASE release_smoke;
CREATE USER 'aquadactyl'@'127.0.0.1' IDENTIFIED BY 'release-smoke-only';
CREATE USER 'aquadactyl'@'localhost' IDENTIFIED BY 'release-smoke-only';
GRANT ALL PRIVILEGES ON release_smoke.* TO 'aquadactyl'@'127.0.0.1';
GRANT ALL PRIVILEGES ON release_smoke.* TO 'aquadactyl'@'localhost';
CREATE DATABASE unrelated_app;
CREATE TABLE unrelated_app.marker (id INT PRIMARY KEY);
INSERT INTO unrelated_app.marker VALUES (42);
GRANT ALL PRIVILEGES ON unrelated_app.* TO 'aquadactyl'@'127.0.0.1';
SQL
    sed -i 's|^DB_HOST=.*|DB_HOST=127.0.0.1|;s|^DB_USERNAME=.*|DB_USERNAME=aquadactyl|' .env
fi

cat > /usr/local/bin/systemctl <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> /reports/systemctl-calls.txt
case "$1" in is-active|list-unit-files) exit 1 ;; esac
exit 0
EOF
chmod 0755 /usr/local/bin/systemctl
# This disposable image supplies runtimes but has no systemd/FPM. Only service
# control is stubbed; real database, Redis, migrations, Blueprint and builds run.
# Model the reported error: an old, unused canary checkout is already present.
sed -i "s/    'version' => '1.0-beta',/    'version' => 'canary',/" config/app.php
mkdir -p storage/app/public
printf 'keep old uploaded data\n' > storage/app/public/preinstall.txt
printf 'keep old source edits\n' > local-edits.txt
if bash /tools/deploy.sh install v1.0-beta > /reports/source-mismatch.log 2>&1; then
    echo 'Install accepted an unrequested source version.' >&2
    exit 1
fi
grep -q -- '--refresh-source' /reports/source-mismatch.log
test ! -d vendor
test ! -d /var/backups/aquadactyl
mkdir -p /source-release
rsync -a --exclude=.git --exclude=node_modules --exclude=vendor --exclude='.env*' \
  --exclude=storage --exclude=bootstrap/cache --exclude=public/build --exclude=public/hot \
  --exclude='coverage*' /panel-source/ /source-release/
cp /panel-source/.env.example /source-release/.env.example
sed -E -i "s/'version' => '[^']*'/'version' => '1.0-beta'/" /source-release/config/app.php
# Linux bind mounts retain the runner UID. The disposable release repository
# belongs to its root-run Git commands; do not disable Git's ownership checks.
chown -R root:root /source-release
git -C /source-release init -q
git -C /source-release config user.name Test
git -C /source-release config user.email test@example.invalid
git -C /source-release add .
git -C /source-release commit -qm release
git -C /source-release tag v1.0-beta

# A saved password from an earlier attempt can disagree with an existing DB
# account. Fail before maintenance or key generation, then resume in place.
sed -i 's|^DB_PASSWORD=.*|DB_PASSWORD=incorrect-saved-password|' .env
if REPO_URL=/source-release bash /tools/deploy.sh install v1.0-beta --refresh-source > /reports/database-mismatch.log 2>&1; then
    echo 'Install accepted invalid database credentials.' >&2; exit 1
else
    test "$?" = 69
fi
# Recovery moved the directory that was this shell's working directory too.
cd "$PANEL_ROOT"
grep -q 'cannot connect using its saved database configuration' /reports/database-mismatch.log
grep -q -- '--resume' /reports/database-mismatch.log
test ! -f storage/framework/down
test ! -f .blueprint/extensions/blueprint/private/db/is_installed
test -d vendor

php artisan key:generate --force
sed -i 's|^HASHIDS_SALT=.*|HASHIDS_SALT=preserve-resume-test-salt|' .env
php artisan down --retry=60
if [[ ${AQUADACTYL_INSTALLER_LOCAL_DB:-} == 1 ]]; then
    old_auth="$(mariadb -u root --batch --skip-column-names -e "SELECT SHA2(authentication_string, 256) FROM mysql.user WHERE User='aquadactyl' AND Host='127.0.0.1'")"
    RELEASE_TAG=v1.0-beta bash /tools/deploy.sh repair-database
    test "$old_auth" = "$(mariadb -u root --batch --skip-column-names -e "SELECT SHA2(authentication_string, 256) FROM mysql.user WHERE User='aquadactyl' AND Host='127.0.0.1'")"
    test "$(mariadb -u root --batch --skip-column-names -e 'SELECT id FROM unrelated_app.marker')" = 42
    php <<'PHP'
<?php
require 'vendor/autoload.php';
$settings = Dotenv\Dotenv::parse(file_get_contents('.env'));
$pdo = new PDO('mysql:host=127.0.0.1;dbname=release_smoke', $settings['DB_USERNAME'], $settings['DB_PASSWORD']);
try {
    $pdo->query('SELECT * FROM unrelated_app.marker');
    throw new RuntimeException('Repair account could access another database.');
} catch (PDOException) {
    echo "Repair account cannot read the unrelated database.\n";
}
PHP
else
    rejected_env="$(sha256sum .env)"
    if RELEASE_TAG=v1.0-beta bash /tools/deploy.sh repair-database > /reports/remote-repair-rejected.log 2>&1; then
        echo 'Accepted local repair for a remote database.' >&2; exit 1
    else
        test "$?" = 69
    fi
    test "$rejected_env" = "$(sha256sum .env)"
    test -z "$(find /var/backups/aquadactyl -maxdepth 1 -name 'database-auth-*' -print -quit)"
    sed -i 's|^DB_PASSWORD=.*|DB_PASSWORD=release-smoke-only|' .env
fi
resume_env="$(sha256sum .env)"
REPO_URL=/source-release bash /tools/deploy.sh install v1.0-beta --resume
test "$resume_env" = "$(sha256sum .env)"
test "$(cat storage/app/public/preinstall.txt)" = 'keep old uploaded data'
find /var/backups/aquadactyl -path '*/panel/local-edits.txt' | grep .
test -s public/build/manifest.json
test -f .blueprint/extensions/blueprint/private/db/is_installed
runuser -u www-data -- php artisan migrate:status
before="$(sha256sum .env)"
printf '\n# Retain operator configuration during updates\nPHP_FPM_SERVICE="php8.5-fpm"\nIgnoreRebuild=true\n' >> .blueprintrc
blueprint_before="$(sha256sum .blueprintrc)"
printf 'persistent upload\n' > storage/release-marker
printf 'obsolete core\n' > obsolete-release-file.php
mkdir -p .blueprint/extensions/smoke/fs
printf 'addon data\n' > .blueprint/extensions/smoke/fs/state

# Use real addons and Blueprint, not just the inventory audit. One original
# package stays in the panel root; the other exists only in its build directory.
addon_work="$(mktemp -d)"
for addon in rootsmoke storedsmoke; do
    mkdir -p "$addon_work/$addon/data" "$addon_work/$addon/components"
    cat > "$addon_work/$addon/conf.yml" <<YAML
info:
  name: Installer $addon
  identifier: $addon
  description: Managed update regression fixture
  version: 1.0.0
  target: beta-2026-08
admin:
  view: view.blade.php
dashboard:
  components: components
data:
  directory: data
YAML
    printf '<p>Installer %s fixture</p>\n' "$addon" > "$addon_work/$addon/view.blade.php"
    addon_slot=AfterEntryName
    [[ "$addon" != storedsmoke ]] || addon_slot=BeforeEntryName
    cat > "$addon_work/$addon/components/Components.yml" <<YAML
Dashboard:
  Serverlist:
    ServerRow:
      $addon_slot: Fixture
YAML
    cat > "$addon_work/$addon/components/Fixture.tsx" <<TSX
import React from 'react';
export default function Fixture() { return <span>installer-$addon-frontend</span>; }
TSX
    printf 'seed data\n' > "$addon_work/$addon/data/seed.txt"
    (cd "$addon_work/$addon" && zip -qr "$PANEL_ROOT/$addon.blueprint" .)
done
bash blueprint.sh -bash -i rootsmoke.blueprint storedsmoke.blueprint
for addon in rootsmoke storedsmoke; do
    printf 'preserved %s data\n' "$addon" > ".blueprint/extensions/$addon/private/preserved.txt"
    grep -Fq "|$addon," .blueprint/extensions/blueprint/private/db/installed_extensions
done
mkdir -p .blueprint/extensions/storedsmoke/build
mv storedsmoke.blueprint .blueprint/extensions/storedsmoke/build/storedsmoke.blueprint
root_package_before="$(sha256sum rootsmoke.blueprint)"
stored_package_before="$(sha256sum .blueprint/extensions/storedsmoke/build/storedsmoke.blueprint)"

# A failed reapplication must preserve maintenance and its snapshot. Retrying
# the same release must then reapply both addons and finish the production build.
cp rootsmoke.blueprint "$addon_work/rootsmoke-original.blueprint"
sed -i 's/identifier: rootsmoke/identifier: "[identifier]"/' "$addon_work/rootsmoke/conf.yml"
(cd "$addon_work/rootsmoke" && zip -qr "$PANEL_ROOT/rootsmoke.blueprint" .)
if REPO_URL=/source-release bash /tools/deploy.sh update v1.0-beta > /reports/expected-addon-failure.log 2>&1; then
    echo 'Ignored an invalid addon package during reapplication.' >&2; exit 1
else
    test "$?" = 1
fi
test -f storage/framework/down
grep -Fq 'APPLICATION MAINTENANCE MODE HAS BEEN LEFT ACTIVE' /reports/expected-addon-failure.log
failed_snapshot="$(find /var/backups/aquadactyl -mindepth 2 -maxdepth 2 -name database.sql -print -quit)"
test -s "$failed_snapshot"
cp "$addon_work/rootsmoke-original.blueprint" rootsmoke.blueprint
REPO_URL=/source-release bash /tools/deploy.sh update v1.0-beta

test -s "$failed_snapshot"
test "$root_package_before" = "$(sha256sum rootsmoke.blueprint)"
test "$stored_package_before" = "$(sha256sum .blueprint/extensions/storedsmoke/build/storedsmoke.blueprint)"
test -z "$(find "$PANEL_ROOT" -maxdepth 1 -name '*-reapply-*.blueprint' -print -quit)"
for addon in rootsmoke storedsmoke; do
    test "$(cat ".blueprint/extensions/$addon/private/preserved.txt")" = "preserved $addon data"
    grep -Fq "|$addon," .blueprint/extensions/blueprint/private/db/installed_extensions
    grep -RFq "installer-$addon-frontend" public/build/assets
    php artisan route:list --path="admin/extensions/$addon" --except-vendor --no-ansi | grep -q "$addon"
done
test "$before" = "$(sha256sum .env)"
test "$blueprint_before" = "$(sha256sum .blueprintrc)"
test "$(cat storage/release-marker)" = 'persistent upload'
test "$(cat .blueprint/extensions/smoke/fs/state)" = 'addon data'
test ! -f obsolete-release-file.php
test -s .installed-commit
test -s public/build/manifest.json
test ! -f storage/framework/down
find /var/backups/aquadactyl -name database.sql -size +0c | grep .
runuser -u www-data -- php artisan migrate:status
php artisan serve --host=0.0.0.0 --port=8080 > /reports/http.log 2>&1 &
server_pid=$!
trap 'kill "$server_pid" 2>/dev/null || true' EXIT
for attempt in $(seq 1 30); do
  if curl -fs http://127.0.0.1:8080/auth/login -o /reports/login.html; then break; fi
  sleep 1
done
grep -q '<html' /reports/login.html
printf 'Unfinished-checkout recovery, failed database authentication, resume, real addon reapplication from both package locations, failed-update recovery, production build, data preservation, backups and login HTTP checks passed.\n'
