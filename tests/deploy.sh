#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/../deploy.sh"
trap - EXIT HUP INT QUIT TERM
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT
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
git -C "$test_root/origin" add version
git -C "$test_root/origin" commit -qm release
git -C "$test_root/origin" tag v1.0-beta
printf 'unreleased\n' > "$test_root/origin/version"
git -C "$test_root/origin" commit -qam unreleased
REPO_URL="$test_root/origin"
fetch_git_release v1.0-beta "$test_root/fetch"
[[ "$(tar -xOzf "$test_root/fetch/panel.tar.gz" version)" == release ]]
[[ "$(cat "$test_root/fetch/source-commit")" == "$(git -C "$test_root/origin" rev-parse v1.0-beta)" ]]
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
