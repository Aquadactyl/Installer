#!/usr/bin/env bash
set -Eeuo pipefail
[[ $EUID == 0 && ( -f /.dockerenv || ${AQUADACTYL_RUNTIME_SMOKE:-} == 1 ) ]] || { echo 'Run in the disposable host test image.' >&2; exit 1; }
source "$(dirname "$0")/../deploy.sh"
trap - EXIT HUP INT QUIT TERM
fixture="$(mktemp -d)"
trap 'rm -rf -- "$fixture"' EXIT

# Root's private directory and a conflicting project package manager must not
# affect version checks for public system tools or the unprivileged web user.
mkdir -p "$fixture/operator/bin" "$fixture/private-project"
printf '#!/bin/sh\nprintf "v22.0.0\\n"\n' > "$fixture/operator/bin/node"
chmod 0755 "$fixture/operator/bin/node"
printf '{"packageManager":"pnpm@0.0.0"}\n' > "$fixture/private-project/package.json"
export PATH="$fixture/operator/bin:$PATH"
[[ "$(node --version)" == v22.0.0 ]]
prefer_system_tools
cd "$fixture/private-project"
host_runtimes_ready 1

# A pre-existing npm configuration pointing at a private home directory must
# not send the panel's pnpm installation into that directory.
export npm_config_prefix="$fixture/private-prefix"
install_pinned_pnpm "$DEFAULT_PINNED_PNPM"
[[ ! -e "$fixture/private-prefix" ]]
[[ "$(readlink /usr/local/bin/pnpm)" == /usr/local/lib/aquadactyl-tools/bin/pnpm ]]
host_runtimes_ready 1
unset npm_config_prefix

# A manually pinned PHP executable produces a precise, actionable error.
mkdir -p "$fixture/pinned-php"
cat > "$fixture/pinned-php/php" <<'EOF'
#!/bin/sh
case "$*" in *PHP_VERSION_ID*) exit 1 ;; *) printf '8.3.30' ;; esac
EOF
chmod 0755 "$fixture/pinned-php/php"
export PATH="$fixture/pinned-php:$PATH"
if host_runtimes_ready 1 > "$fixture/php-error.log" 2>&1; then
    echo 'Accepted incompatible PHP CLI' >&2; exit 1
fi
grep -q 'PHP CLI at .*pinned-php/php.*8.3.30' "$fixture/php-error.log"
prefer_system_tools
host_runtimes_ready 1
printf 'System runtime selection, private-directory probes and precise PHP diagnostics passed.\n'
