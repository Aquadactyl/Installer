#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/../deploy.sh"
trap - EXIT HUP INT QUIT TERM
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

# The default install target follows the current panel release, independently
# of this repository's installer version. Older explicit tags remain supported.
[[ "$RELEASE_TAG" == v1.1-beta.2 ]]

# A failed host repository refresh must preserve its exit code, diagnose the
# actual error, and request strict APT handling rather than accept stale indexes.
(
    initialize_log "$test_root"
    before_log_permissions="$(stat -c %a "$LOG_FILE")"
    apt-get() {
        printf '%s\n' "$@" > "$test_root/apt-arguments"
        printf '%s\n' 'E: https://downloads.plex.tv/repo/deb public Release: 404 Not Found' \
            'W: GPG error: https://dlm.mariadb.com/repo/maxscale/latest/apt jammy InRelease: NO_PUBKEY 5D87FACA8C27D14E'
        return 100
    }
    if refresh_apt_indexes > "$test_root/apt-failure.log" 2>&1; then
        echo 'Accepted failed APT refresh' >&2; exit 1
    else
        [[ "$?" == 100 ]]
    fi
    grep -Fxq 'APT::Update::Error-Mode=any' "$test_root/apt-arguments"
    grep -q 'Package provisioning has stopped' "$test_root/apt-failure.log"
    grep -q 'legacy Plex repository has moved' "$test_root/apt-failure.log"
    grep -q 'signing-key problem' "$test_root/apt-failure.log"
    [[ "$(stat -c %a "$LOG_FILE")" == "$before_log_permissions" && "$before_log_permissions" == 600 ]]
    apt-get() { return 0; }
    refresh_apt_indexes > "$test_root/apt-success.log" 2>&1
    ! grep -q 'could not refresh' "$test_root/apt-success.log"
)

for release in debian:12 debian:12.12 debian:13 ubuntu:22.04 ubuntu:24.04 ubuntu:26.04; do
    is_supported_os "${release%%:*}" "${release#*:}"
done
for release in debian:11 debian:14 ubuntu:20.04 ubuntu:22.10 ubuntu:24.10 ubuntu:25.04 ubuntu:25.10 ubuntu:26.10 linuxmint:22 ':22.04' 'ubuntu:'; do
    if is_supported_os "${release%%:*}" "${release#*:}"; then
        echo "Accepted unsupported OS: $release" >&2; exit 1
    fi
done

# Model a host with tools already installed: OS rejection must still happen
# before inspecting/moving panel files, provisioning or prompting for .env.
if (
    enforce_root_and_utf8() { :; }
    validate_os() { echo 'unsupported-host-check' >&2; exit "$EX_UNAVAILABLE"; }
    check_install_destination() { touch "$test_root/destination-touched"; }
    cmd_setup_host() { touch "$test_root/provisioning-started"; }
    cmd_install v1.0-beta --refresh-source
) > "$test_root/unsupported-os.log" 2>&1; then
    echo 'Install accepted an unsupported host' >&2; exit 1
else
    [[ "$?" == "$EX_UNAVAILABLE" ]]
fi
grep -q 'unsupported-host-check' "$test_root/unsupported-os.log"
[[ ! -e "$test_root/destination-touched" && ! -e "$test_root/provisioning-started" ]]

# Installed commands with incompatible versions must trigger host provisioning,
# rather than passing Step 1 and failing after .env has been changed.
(
    php() { return 0; }
    composer() { echo 'Composer version 2.9.0'; }
    node() { echo v24.22.1; }
    pnpm() { echo "$DEFAULT_PINNED_PNPM"; }
    runuser() { case "${*: -2}" in 'pnpm --version') echo "$DEFAULT_PINNED_PNPM" ;; 'node --version') echo v24.22.1 ;; esac; }
    host_runtimes_ready
    runuser() { return 1; }
    if host_runtimes_ready; then echo 'Accepted a private runtime' >&2; exit 1; fi
    runuser() { case "${*: -2}" in 'pnpm --version') echo "$DEFAULT_PINNED_PNPM" ;; 'node --version') echo v22.0.0 ;; esac; }
    if host_runtimes_ready 1 > "$test_root/old-web-node.log" 2>&1; then echo 'Accepted old web-user Node' >&2; exit 1; fi
    grep -q 'Node.js for .*v22.0.0' "$test_root/old-web-node.log"
    runuser() { case "${*: -2}" in 'pnpm --version') echo "$DEFAULT_PINNED_PNPM" ;; 'node --version') echo v24.22.1 ;; esac; }
    php() { return 1; }
    if host_runtimes_ready 1 > "$test_root/old-php.log" 2>&1; then echo 'Accepted old PHP' >&2; exit 1; fi
    grep -q 'PHP CLI at' "$test_root/old-php.log"
    php() { return 0; }
    node() { echo v22.0.0; }
    if host_runtimes_ready; then echo 'Accepted old Node' >&2; exit 1; fi
    node() { echo v24.22.1; }
    composer() { echo 'Composer version 1.10.0'; }
    if host_runtimes_ready; then echo 'Accepted Composer 1' >&2; exit 1; fi
    composer() { echo 'Composer version 2.9.0'; }
    pnpm() { echo 10.0.0; }
    if host_runtimes_ready; then echo 'Accepted mismatched pnpm' >&2; exit 1; fi
)

(
    mkdir -p "$test_root/private-bin"
    printf '#!/bin/sh\nprintf "private-node\\n"\n' > "$test_root/private-bin/node"
    chmod 0755 "$test_root/private-bin/node"
    export PATH="$test_root/private-bin:$PATH"
    [[ "$(command -v node)" == "$test_root/private-bin/node" ]]
    prefer_system_tools
    [[ "$(command -v node)" != "$test_root/private-bin/node" ]]
    preferred_path="$PATH"
    prefer_system_tools
    [[ "$PATH" == "$preferred_path" ]]
)

(
    umask 077
    npm() { [[ "$(umask)" == 0022 && "$*" == "install --global --prefix /usr/local/lib/aquadactyl-tools pnpm@$DEFAULT_PINNED_PNPM" ]]; }
    ln() { [[ "$*" == '-sfn /usr/local/lib/aquadactyl-tools/bin/pnpm /usr/local/bin/pnpm' ]]; }
    install_pinned_pnpm "$DEFAULT_PINNED_PNPM"
    [[ "$(umask)" == 0077 ]]
)

for tag in v1.0-beta v1 v1.0.0 v2.3.4-rc.1; do validate_release_tag "$tag"; done
for tag in '' v1.0beta v01.0 v1..2 'v1.0;id' $'v1.0\nx=1' '../v1'; do
    if validate_release_tag "$tag" >/dev/null 2>&1; then echo "Accepted unsafe tag: $tag" >&2; exit 1; fi
done
for path in / /var/www /tmp/../etc /opt; do
    if (PANEL_ROOT="$path"; validate_panel_root) >/dev/null 2>&1; then echo 'Accepted unsafe root' >&2; exit 1; fi
done
PANEL_ROOT="$test_root/panel"; validate_panel_root
mkdir -p "$test_root/origin" "$test_root/fetch"
git -C "$test_root/origin" init -q
git -C "$test_root/origin" config user.name Test
git -C "$test_root/origin" config user.email test@example.invalid
printf 'release\n' > "$test_root/origin/version"
mkdir -p "$test_root/origin/config"
printf "<?php\n  'version'  =>  '1.0-beta',\n" > "$test_root/origin/config/app.php"
touch "$test_root/origin/"{artisan,composer.lock,package.json,blueprint.sh}
git -C "$test_root/origin" add .
git -C "$test_root/origin" commit -qm release
git -C "$test_root/origin" tag v1.0-beta
printf 'unreleased\n' > "$test_root/origin/version"
git -C "$test_root/origin" commit -qam unreleased
REPO_URL="$test_root/origin"
fetch_git_release v1.0-beta "$test_root/fetch"
[[ "$(tar -xOzf "$test_root/fetch/panel.tar.gz" version)" == release ]]
[[ "$(cat "$test_root/fetch/source-commit")" == "$(git -C "$test_root/origin" rev-parse v1.0-beta)" ]]

# A stale source checkout is rejected before host setup and remains unchanged.
PANEL_ROOT="$test_root/unfinished"
BACKUP_DIR="$test_root/backups"
mkdir -p "$PANEL_ROOT/config" "$PANEL_ROOT/storage/app/public"
touch "$PANEL_ROOT/artisan"
printf "<?php\n  'version' => 'canary',\n" > "$PANEL_ROOT/config/app.php"
printf 'APP_KEY=keep-this-key\nHASHIDS_SALT=keep-this-salt\n' > "$PANEL_ROOT/.env"
printf 'PHP_FPM_SERVICE=keep-this-service\n' > "$PANEL_ROOT/.blueprintrc"
printf 'keep this upload\n' > "$PANEL_ROOT/storage/app/public/upload.txt"
printf 'keep edited source\n' > "$PANEL_ROOT/local-edits.txt"
before="$(sha256sum "$PANEL_ROOT/.env")"
if check_install_destination v1.0-beta 0 > "$test_root/rejection.log" 2>&1; then echo 'Accepted stale source without recovery' >&2; exit 1; fi
grep -q -- '--refresh-source' "$test_root/rejection.log"
[[ ! -e "$BACKUP_DIR" && "$before" == "$(sha256sum "$PANEL_ROOT/.env")" ]]
check_install_destination v1.0-beta 1

# Download/validation errors must never move the original directory.
WORK="$(mktemp -d "$test_root/fetch-fail-XXXXXX")"
if refresh_install_source v9.9.9 > "$test_root/fetch-failure.log" 2>&1; then echo 'Accepted missing tag' >&2; exit 1; fi
[[ ! -e "$BACKUP_DIR" && -f "$PANEL_ROOT/local-edits.txt" ]]
git -C "$test_root/origin" tag v9.9.8
WORK="$(mktemp -d "$test_root/wrong-version-XXXXXX")"
if refresh_install_source v9.9.8 > "$test_root/version-failure.log" 2>&1; then echo 'Accepted a tag with the wrong source version' >&2; exit 1; fi
[[ ! -e "$BACKUP_DIR" && -f "$PANEL_ROOT/local-edits.txt" ]]
WORK="$(mktemp -d "$test_root/recovery-XXXXXX")"
refresh_install_source v1.0-beta
[[ "$(panel_source_version "$PANEL_ROOT")" == 1.0-beta ]]
[[ "$before" == "$(sha256sum "$PANEL_ROOT/.env")" ]]
[[ "$(cat "$PANEL_ROOT/.blueprintrc")" == PHP_FPM_SERVICE=keep-this-service ]]
[[ "$(cat "$PANEL_ROOT/storage/app/public/upload.txt")" == 'keep this upload' ]]
[[ -f "$BACKUP/panel/local-edits.txt" && ! -e "$PANEL_ROOT/local-edits.txt" ]]
[[ "$(stat -c %a "$BACKUP")" == 700 && -s "$PANEL_ROOT/.installed-commit" ]]

# A real release checkout may use different whitespace, but an initialized
# panel can never be replaced by the recovery flag.
check_install_destination v1.0-beta 0
mkdir -p "$PANEL_ROOT/vendor"
if check_install_destination v1.0-beta 1 >/dev/null 2>&1; then echo 'Accepted initialized panel recovery' >&2; exit 1; fi
check_install_destination v1.0-beta 0 1
if check_install_destination v1.0-beta 1 1 >/dev/null 2>&1; then echo 'Accepted conflicting resume/replacement' >&2; exit 1; fi
if check_install_destination v2.0-beta 0 1 >/dev/null 2>&1; then echo 'Accepted mismatched resume source' >&2; exit 1; fi
mv "$PANEL_ROOT/.env" "$PANEL_ROOT/.env.saved"
if check_install_destination v1.0-beta 0 1 >/dev/null 2>&1; then echo 'Accepted resume without existing configuration' >&2; exit 1; fi
mv "$PANEL_ROOT/.env.saved" "$PANEL_ROOT/.env"
rm -d "$PANEL_ROOT/vendor"
mkdir -p "$PANEL_ROOT/.blueprint/extensions/blueprint/private/db"
touch "$PANEL_ROOT/.blueprint/extensions/blueprint/private/db/is_installed"
if check_install_destination v1.0-beta 1 >/dev/null 2>&1; then echo 'Accepted initialized Blueprint recovery' >&2; exit 1; fi
if check_install_destination v1.0-beta 0 1 >/dev/null 2>&1; then echo 'Accepted initialized Blueprint resume' >&2; exit 1; fi
rm "$PANEL_ROOT/.blueprint/extensions/blueprint/private/db/is_installed"
printf 'an-existing-addon\n' > "$PANEL_ROOT/.blueprint/extensions/blueprint/private/db/installed_extensions"
if check_install_destination v1.0-beta 1 >/dev/null 2>&1; then echo 'Accepted installed addon recovery' >&2; exit 1; fi

cd "$test_root"
printf 'DB_PASSWORD=before\nAPP_NAME=original\n' > .env
set_env_value DB_PASSWORD 'dollar$and&quote"slash\hash#'
grep -Fq 'DB_PASSWORD="dollar\$and&quote\"slash\\hash#"' .env
grep -Fxq 'APP_NAME=original' .env
if set_env_value APP_NAME $'injected\nAPP_DEBUG=true'; then echo 'Accepted newline injection' >&2; exit 1; fi
initialize_log "${test_root}"
[[ "$(stat -c %a "$LOG_FILE")" == 600 ]]
rm -f -- "$LOG_FILE"
printf 'Deployment safety checks passed.\n'
