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
sed -i "s/    'version' => 'canary',/    'version' => '1.0-beta',/" config/app.php
sed -i 's|^APP_URL=.*|APP_URL=http://localhost|;s|^DB_HOST=.*|DB_HOST=database|;s|^DB_DATABASE=.*|DB_DATABASE=release_smoke|;s|^DB_USERNAME=.*|DB_USERNAME=root|;s|^DB_PASSWORD=.*|DB_PASSWORD=release-smoke-only|;s|^REDIS_HOST=.*|REDIS_HOST=cache|;s|^SESSION_SECURE_COOKIE=.*|SESSION_SECURE_COOKIE=false|' .env
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
sed -i "s/    'version' => 'canary',/    'version' => '1.0-beta',/" /source-release/config/app.php
git -C /source-release init -q
git -C /source-release config user.name Test
git -C /source-release config user.email test@example.invalid
git -C /source-release add .
git -C /source-release commit -qm release
git -C /source-release tag v1.0-beta
REPO_URL=/source-release bash /tools/deploy.sh install v1.0-beta --refresh-source
# Recovery moved the directory that was this shell's working directory too.
cd "$PANEL_ROOT"
test "$(cat storage/app/public/preinstall.txt)" = 'keep old uploaded data'
find /var/backups/aquadactyl -path '*/panel/local-edits.txt' | grep .
test -s public/build/manifest.json
test -f .blueprint/extensions/blueprint/private/db/is_installed
runuser -u www-data -- php artisan migrate:status
before="$(sha256sum .env)"
printf '\n# Retain operator configuration during updates\nPHP_FPM_SERVICE="php8.5-fpm"\n' >> .blueprintrc
blueprint_before="$(sha256sum .blueprintrc)"
printf 'persistent upload\n' > storage/release-marker
printf 'obsolete core\n' > obsolete-release-file.php
mkdir -p .blueprint/extensions/smoke/fs
printf 'addon data\n' > .blueprint/extensions/smoke/fs/state
REPO_URL=/source-release bash /tools/deploy.sh update v1.0-beta
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
printf 'Unfinished-checkout recovery, Git update, data preservation, backups and login HTTP checks passed.\n'
