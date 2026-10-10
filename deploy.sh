#!/usr/bin/env bash
# ==============================================================================
# Aquadactyl Standalone Deployment & Management Automation Tooling
# ------------------------------------------------------------------------------
# Complete end-to-end installer, updater, and management tool for Aquadactyl
# (Pterodactyl fork with bundled Blueprint beta-2026-08).
#
# Supported Commands:
#   sudo bash deploy.sh setup-host      # Full automated OS provisioning & packages
#   sudo bash deploy.sh install         # Full panel manual install automation
#   sudo bash deploy.sh update <vTag>   # Managed zero-downtime update
#   sudo bash deploy.sh update --archive /path/to/panel.tar.gz <sha256>
#   sudo bash deploy.sh permissions     # Restore strict least-privilege permissions
#
# Can be run directly as a one-liner:
#   curl -fsSL https://.../deploy.sh | sudo bash -s -- install
# ==============================================================================

set -Eeuo pipefail

# ------------------------------------------------------------------------------
# 1. Global Defaults & Configuration
# ------------------------------------------------------------------------------
PANEL_ROOT="${PANEL_ROOT:-/var/www/aquadactyl}"
WEB_USER="${WEB_USER:-www-data}"
WEB_GROUP="${WEB_GROUP:-www-data}"
PHP_VERSION="${PHP_VERSION:-8.5}"
PHP_FPM_SERVICE="${PHP_FPM_SERVICE:-}"
PTEROQ_SERVICE="${PTEROQ_SERVICE:-pteroq.service}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/aquadactyl}"
BLUEPRINT_ENVIRONMENT="${BLUEPRINT_ENVIRONMENT:-ci}"
NON_INTERACTIVE="${NON_INTERACTIVE:-0}"
REPO_URL="${REPO_URL:-https://github.com/Aquadactyl/aquadactyl.git}"
DEFAULT_PINNED_PNPM="12.10.1"

# Internal tracking
WORK=""
BACKUP=""
LOCK_FD=9
LOCK_ACQUIRED=0
MAINTENANCE_ENABLED=0
PTEROQ_WAS_RUNNING=0

# Standard POSIX / sysexits exit codes
EX_OK=0
EX_GENERAL=1
EX_USAGE=64
EX_DATAERR=65
EX_NOINPUT=66
EX_UNAVAILABLE=69
EX_TEMPFAIL=75
EX_NOPERM=77

# Terminal styling
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
    CLR_RESET="$(tput sgr0)"
    CLR_RED="$(tput setaf 1)"
    CLR_GREEN="$(tput setaf 2)"
    CLR_YELLOW="$(tput setaf 3)"
    CLR_BLUE="$(tput setaf 4)"
    CLR_CYAN="$(tput setaf 6)"
    CLR_BOLD="$(tput bold)"
else
    CLR_RESET=""
    CLR_RED=""
    CLR_GREEN=""
    CLR_YELLOW=""
    CLR_BLUE=""
    CLR_CYAN=""
    CLR_BOLD=""
fi

log_info()  { echo -e "${CLR_BLUE}[INFO]${CLR_RESET} $*"; }
log_ok()    { echo -e "${CLR_GREEN}[OK]${CLR_RESET} $*"; }
log_warn()  { echo -e "${CLR_YELLOW}[WARN]${CLR_RESET} $*" >&2; }
log_err()   { echo -e "${CLR_RED}[ERROR]${CLR_RESET} $*" >&2; }
log_fatal() { echo -e "${CLR_RED}${CLR_BOLD}[FATAL]${CLR_RESET} $*" >&2; }

# Overall Progress Bar State
TOTAL_STEPS=10
CURRENT_STEP=0

show_progress() {
    local step_title="$1"
    (( CURRENT_STEP++ )) || true
    if [[ "${CURRENT_STEP}" -gt "${TOTAL_STEPS}" ]]; then
        CURRENT_STEP="${TOTAL_STEPS}"
    fi

    local percent=$(( CURRENT_STEP * 100 / TOTAL_STEPS ))
    local bar_width=28
    local filled=$(( percent * bar_width / 100 ))
    local empty=$(( bar_width - filled ))

    local bar=""
    for (( i=0; i<filled; i++ )); do bar+="#"; done
    for (( i=0; i<empty; i++ )); do bar+="-"; done

    echo ""
    echo -e "${CLR_CYAN}${CLR_BOLD}[STEP ${CURRENT_STEP}/${TOTAL_STEPS}]${CLR_RESET} [${CLR_GREEN}${bar}${CLR_RESET}] ${percent}% - ${CLR_BOLD}${step_title}${CLR_RESET}"
}

# Silent command runner with live terminal animation spinner
LOG_FILE="/tmp/aquadactyl-deploy.log"
run_silent() {
    local cmd_desc="${1:-Executing task}"
    shift

    # Clear task section in log
    echo "=== [$(date)] Starting: ${cmd_desc} ===" >> "${LOG_FILE}"

    # Execute command quietly in background
    "$@" >> "${LOG_FILE}" 2>&1 &
    local cmd_pid=$!

    # Animated spinner frames
    local spin_chars=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local sc_idx=0

    # Hide cursor if supported
    if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
        tput civis 2>/dev/null || true
    fi

    while kill -0 "${cmd_pid}" 2>/dev/null; do
        if [[ -t 1 ]]; then
            local char="${spin_chars[sc_idx]}"
            printf "\r  ${CLR_BLUE}%s${CLR_RESET} %s... " "${char}" "${cmd_desc}"
            sc_idx=$(( (sc_idx + 1) % ${#spin_chars[@]} ))
        fi
        sleep 0.1
    done

    # Restore cursor
    if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
        tput cnorm 2>/dev/null || true
    fi

    local err_code=0
    wait "${cmd_pid}" || err_code=$?

    if [[ "${err_code}" -eq 0 ]]; then
        if [[ -t 1 ]]; then
            printf "\r  ${CLR_GREEN}✓${CLR_RESET} %s [Done]\n" "${cmd_desc}"
        else
            echo "  [OK] ${cmd_desc}"
        fi
        return 0
    else
        if [[ -t 1 ]]; then
            printf "\r  ${CLR_RED}✗${CLR_RESET} %s [Failed]\n" "${cmd_desc}"
        fi
        log_err "${cmd_desc} failed with exit code ${err_code}."
        if [[ -f "${LOG_FILE}" ]]; then
            echo "--- Last 25 lines from ${LOG_FILE} ---" >&2
            tail -n 25 "${LOG_FILE}" >&2
            echo "--------------------------------------" >&2
        fi
        return "${err_code}"
    fi
}

# ------------------------------------------------------------------------------
# 2. Cleanup & Error Trap
# ------------------------------------------------------------------------------
cleanup_and_handle_failure() {
    local exit_code="$1"
    local line_no="$2"

    if [[ "${LOCK_ACQUIRED}" -eq 1 ]]; then
        flock -u "${LOCK_FD}" 2>/dev/null || true
        eval "exec ${LOCK_FD}>&-" 2>/dev/null || true
        LOCK_ACQUIRED=0
    fi

    if [[ -n "${WORK:-}" && -d "${WORK:-}" ]]; then
        rm -rf "${WORK}"
    fi

    if [[ "${exit_code}" -ne 0 ]]; then
        echo ""
        log_fatal "Execution failed at line ${line_no} with exit code ${exit_code}."
        if [[ "${MAINTENANCE_ENABLED}" -eq 1 ]]; then
            echo "================================================================================"
            echo "  APPLICATION MAINTENANCE MODE HAS BEEN LEFT ACTIVE FOR SAFETY."
            echo "================================================================================"
            if [[ -n "${BACKUP:-}" && -d "${BACKUP:-}" ]]; then
                echo "  Pre-update snapshot directory:"
                echo "    Directory: ${BACKUP}"
                [[ -f "${BACKUP}/database.sql" ]] && echo "    Database:  ${BACKUP}/database.sql"
                [[ -f "${BACKUP}/panel.tar.gz" ]] && echo "    Files:     ${BACKUP}/panel.tar.gz"
                echo ""
                echo "  To inspect Laravel logs:"
                echo "    cat \"${PANEL_ROOT}/storage/logs/laravel-\$(date +%F).log\""
                echo ""
                echo "  To restore backup manually:"
                echo "    mariadb -u aquadactyl -p aquadactyl < \"${BACKUP}/database.sql\""
                echo "    tar -xzf \"${BACKUP}/panel.tar.gz\" -C \"${PANEL_ROOT}\""
            fi
            echo "================================================================================"
        fi
    fi

    exit "${exit_code}"
}

trap 'cleanup_and_handle_failure $? $LINENO' EXIT HUP INT QUIT TERM

# ------------------------------------------------------------------------------
# 3. Helpers & Semantic Versioning
# ------------------------------------------------------------------------------
semver_ge() {
    local v1="$1"
    local v2="$2"
    if [[ "$v1" == "$v2" ]]; then
        return 0
    fi
    local lowest
    lowest="$(printf '%s\n%s\n' "$v1" "$v2" | sort -V | head -n1)"
    [[ "$lowest" == "$v2" ]]
}

validate_os() {
    log_info "Verifying host operating system..."
    if [[ ! -f /etc/os-release ]]; then
        log_fatal "Unable to detect host operating system (/etc/os-release missing)."
        exit "${EX_UNAVAILABLE}"
    fi

    # Read OS identifier and version ID
    local os_id os_version_id
    os_id="$(. /etc/os-release && echo "${ID:-}")"
    os_version_id="$(. /etc/os-release && echo "${VERSION_ID:-}")"

    local is_supported=0

    case "${os_id}" in
        debian)
            # Supported: Debian 12 (Bookworm), Debian 13 (Trixie)
            local debian_major="${os_version_id%%.*}"
            if [[ "${debian_major}" == "12" || "${debian_major}" == "13" ]]; then
                is_supported=1
            fi
            ;;
        ubuntu)
            # Supported: Ubuntu 24.04/24.10, Ubuntu 26.04
            local ubuntu_major="${os_version_id%%.*}"
            if [[ "${ubuntu_major}" == "24" || "${ubuntu_major}" == "26" ]]; then
                is_supported=1
            fi
            ;;
        *)
            is_supported=0
            ;;
    esac

    if [[ "${is_supported}" -eq 0 ]]; then
        log_fatal "Unsupported operating system: ${os_id} ${os_version_id}."
        echo "Supported systems are:" >&2
        echo "  - Debian 12 (Bookworm) or Debian 13 (Trixie)" >&2
        echo "  - Ubuntu 24.04+ LTS or Ubuntu 26.04+ LTS" >&2
        echo "Older releases (Debian <= 11, Ubuntu <= 22) are unsupported." >&2
        exit "${EX_UNAVAILABLE}"
    fi

    log_ok "Operating system supported: ${os_id} ${os_version_id}"
}

enforce_root_and_utf8() {
    # 1. Enforce root execution
    if [[ "${EUID}" -ne 0 ]]; then
        log_fatal "This script must be executed as root (e.g. 'sudo bash $0' or as root user)."
        exit "${EX_NOPERM}"
    fi

    # 2. Enforce UTF-8 in environment
    export LC_ALL="C.UTF-8"
    export LANG="C.UTF-8"

    # 3. Enforce UTF-8 in .bashrc for root and default user if present
    local bashrc_targets=("/root/.bashrc")
    [[ -n "${HOME:-}" && -f "${HOME}/.bashrc" && "${HOME}" != "/root" ]] && bashrc_targets+=("${HOME}/.bashrc")

    for brc in "${bashrc_targets[@]}"; do
        if [[ -f "${brc}" ]]; then
            local modified=0
            if ! grep -q "LC_ALL=.*UTF-8" "${brc}"; then
                echo 'export LC_ALL="C.UTF-8"' >> "${brc}"
                modified=1
            fi
            if ! grep -q "LANG=.*UTF-8" "${brc}"; then
                echo 'export LANG="C.UTF-8"' >> "${brc}"
                modified=1
            fi
            # Source bashrc to apply changes immediately
            if [[ "${modified}" -eq 1 ]]; then
                # shellcheck source=/dev/null
                \. "${brc}" 2>/dev/null || true
            fi
        else
            echo 'export LC_ALL="C.UTF-8"' > "${brc}"
            echo 'export LANG="C.UTF-8"' >> "${brc}"
            # shellcheck source=/dev/null
            \. "${brc}" 2>/dev/null || true
        fi
    done
}

detect_php_fpm() {
    if [[ -n "${PHP_FPM_SERVICE}" ]]; then
        return 0
    fi

    local ver
    ver="$(php -r 'echo PHP_MAJOR_VERSION . "." . PHP_MINOR_VERSION;' 2>/dev/null || echo "${PHP_VERSION}")"
    local candidates=(
        "php${ver}-fpm"
        "php8.5-fpm"
        "php8.4-fpm"
        "php-fpm"
    )

    if command -v systemctl >/dev/null 2>&1; then
        for cand in "${candidates[@]}"; do
            if systemctl list-unit-files "${cand}.service" 2>/dev/null | grep -q "${cand}"; then
                PHP_FPM_SERVICE="${cand}"
                return 0
            fi
        done
    fi

    PHP_FPM_SERVICE="php${ver}-fpm"
}

# ------------------------------------------------------------------------------
# 4. Common Library Routines
# ------------------------------------------------------------------------------
preflight() {
    log_info "Running environment preflight checks..."

    enforce_root_and_utf8
    validate_os

    # Source NVM environment if installed in root/home
    if [[ -s "${HOME}/.nvm/nvm.sh" ]]; then
        # shellcheck source=/dev/null
        \. "${HOME}/.nvm/nvm.sh"
    elif [[ -s "/root/.nvm/nvm.sh" ]]; then
        # shellcheck source=/dev/null
        \. "/root/.nvm/nvm.sh"
    fi

    if ! command -v realpath >/dev/null 2>&1; then
        log_fatal "Required command 'realpath' is missing."
        exit "${EX_UNAVAILABLE}"
    fi

    if [[ ! -d "${PANEL_ROOT}" ]]; then
        log_fatal "PANEL_ROOT directory does not exist: ${PANEL_ROOT}"
        exit "${EX_NOINPUT}"
    fi

    PANEL_ROOT="$(realpath "${PANEL_ROOT}")"
    if [[ ! "${PANEL_ROOT}" =~ ^/[a-zA-Z0-9_./-]+$ ]]; then
        log_fatal "PANEL_ROOT path contains invalid characters or spaces: ${PANEL_ROOT}"
        exit "${EX_DATAERR}"
    fi

    local required_panel_files=("artisan" "composer.lock" ".env")
    for file in "${required_panel_files[@]}"; do
        if [[ ! -f "${PANEL_ROOT}/${file}" ]]; then
            log_fatal "Missing required panel file: ${PANEL_ROOT}/${file}"
            exit "${EX_NOINPUT}"
        fi
    done

    local required_bins=(
        "php" "composer" "node" "pnpm" "git" "curl" "tar" "zip" "unzip"
        "rsync" "flock" "runuser" "sha256sum" "grep" "sed" "awk" "mktemp"
    )
    for bin in "${required_bins[@]}"; do
        if ! command -v "${bin}" >/dev/null 2>&1; then
            log_fatal "Required binary dependency is missing: ${bin}"
            exit "${EX_UNAVAILABLE}"
        fi
    done

    # Validate PHP version 8.4.x or 8.5.x
    if ! php -r 'exit(PHP_VERSION_ID >= 80400 && PHP_VERSION_ID < 80600 ? 0 : 1);' 2>/dev/null; then
        local current_php
        current_php="$(php -r 'echo PHP_VERSION;' 2>/dev/null || echo 'unknown')"
        log_fatal "Unsupported PHP version (${current_php}). Aquadactyl requires PHP 8.4.x or 8.5.x (PHP 8.2 & 8.3 are unsupported)."
        exit "${EX_UNAVAILABLE}"
    fi

    # Validate Node.js version >= 22.13.0
    local node_ver
    node_ver="$(node -v 2>/dev/null | sed 's/^v//' || echo "0.0.0")"
    if ! semver_ge "${node_ver}" "22.13.0"; then
        log_fatal "Unsupported Node.js version (v${node_ver}). Minimum required is >= 22.13.0."
        exit "${EX_UNAVAILABLE}"
    fi

    # Validate pnpm version matches pinned requirement
    if [[ -f "${PANEL_ROOT}/package.json" ]]; then
        local pinned_pnpm
        pinned_pnpm="$(grep -oE '"packageManager":\s*"pnpm@[^"]+"' "${PANEL_ROOT}/package.json" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "${DEFAULT_PINNED_PNPM}")"
        local current_pnpm
        current_pnpm="$(pnpm -v 2>/dev/null || echo "")"
        if [[ -n "${current_pnpm}" && "${current_pnpm}" != "${pinned_pnpm}" ]]; then
            log_warn "Installed pnpm (${current_pnpm}) does not match pinned version (${pinned_pnpm}). Re-installing pinned pnpm..."
            npm install --global "pnpm@${pinned_pnpm}" || true
        fi
    fi

    if ! getent passwd "${WEB_USER}" >/dev/null 2>&1; then
        log_fatal "Configured WEB_USER '${WEB_USER}' does not exist on the host system."
        exit "${EX_UNAVAILABLE}"
    fi
    if ! getent group "${WEB_GROUP}" >/dev/null 2>&1; then
        log_fatal "Configured WEB_GROUP '${WEB_GROUP}' does not exist on the host system."
        exit "${EX_UNAVAILABLE}"
    fi

    # Acquire exclusive non-blocking deployment lock
    eval "exec ${LOCK_FD}>\"${PANEL_ROOT}/.panel-deploy.lock\""
    if ! flock -n "${LOCK_FD}"; then
        log_fatal "Another deployment or management process is active on ${PANEL_ROOT} (lock held on .panel-deploy.lock)."
        exit "${EX_TEMPFAIL}"
    fi
    LOCK_ACQUIRED=1
    chmod 0600 "${PANEL_ROOT}/.panel-deploy.lock" 2>/dev/null || true

    cd "${PANEL_ROOT}"
    log_ok "Preflight checks passed. Concurrency lock acquired."
}

artisan() {
    if command -v runuser >/dev/null 2>&1; then
        runuser -u "${WEB_USER}" -- php "${PANEL_ROOT}/artisan" "$@"
    elif command -v su >/dev/null 2>&1; then
        su -s /bin/sh "${WEB_USER}" -c "php \"${PANEL_ROOT}/artisan\" \"$*\""
    else
        php "${PANEL_ROOT}/artisan" "$@"
    fi
}

permissions() {
    log_info "Enforcing strict least-privilege permissions across panel..."

    # Source files owned by root:www-data
    chown -R "root:${WEB_GROUP}" "${PANEL_ROOT}"

    # Default: dirs 0750, files 0640 (excluding node_modules and .git)
    find "${PANEL_ROOT}" -mindepth 1 \
        \( -path "${PANEL_ROOT}/node_modules" -o -path "${PANEL_ROOT}/node_modules/*" \
           -o -path "${PANEL_ROOT}/.git" -o -path "${PANEL_ROOT}/.git/*" \) -prune \
        -o -type d -exec chmod 0750 {} + \
        -o -type f -exec chmod 0640 {} +

    # Executable permissions
    if [[ -d "${PANEL_ROOT}/scripts" ]]; then
        find "${PANEL_ROOT}/scripts" -type f -name "*.sh" -exec chmod 0750 {} +
    fi
    [[ -f "${PANEL_ROOT}/blueprint.sh" ]] && chmod 0750 "${PANEL_ROOT}/blueprint.sh"
    [[ -f "${PANEL_ROOT}/artisan" ]] && chmod 0750 "${PANEL_ROOT}/artisan"

    if [[ -d "${PANEL_ROOT}/vendor/bin" ]]; then
        find "${PANEL_ROOT}/vendor/bin" -type f -exec chmod 0750 {} +
    fi
    if [[ -d "${PANEL_ROOT}/node_modules/.bin" ]]; then
        find "${PANEL_ROOT}/node_modules/.bin" -type f -exec chmod 0750 {} +
    fi

    # Ensure writable directories exist
    mkdir -p "${PANEL_ROOT}/storage/framework/cache/data" \
             "${PANEL_ROOT}/storage/framework/sessions" \
             "${PANEL_ROOT}/storage/framework/views" \
             "${PANEL_ROOT}/storage/logs" \
             "${PANEL_ROOT}/bootstrap/cache"

    # Writable directories owned by www-data:www-data
    chown -R "${WEB_USER}:${WEB_GROUP}" "${PANEL_ROOT}/storage" "${PANEL_ROOT}/bootstrap/cache"
    find "${PANEL_ROOT}/storage" "${PANEL_ROOT}/bootstrap/cache" -type d -exec chmod 0750 {} +
    find "${PANEL_ROOT}/storage" "${PANEL_ROOT}/bootstrap/cache" -type f -exec chmod 0640 {} +

    # Enforce strict permissions on .env
    if [[ -f "${PANEL_ROOT}/.env" ]]; then
        chown "root:${WEB_GROUP}" "${PANEL_ROOT}/.env"
        chmod 0640 "${PANEL_ROOT}/.env"
    fi

    log_ok "Permissions successfully normalized."
}

dependencies() {
    log_info "Synchronizing dependencies..."

    # Clear cached manifests
    rm -f "${PANEL_ROOT}/bootstrap/cache/"{config,packages,services,events,routes-v7}.php

    # Composer packages
    log_info "Installing Composer dependencies..."
    run_silent "composer install" env COMPOSER_ALLOW_SUPERUSER=1 composer install \
        --no-dev \
        --prefer-dist \
        --no-interaction \
        --no-progress \
        --no-scripts \
        --optimize-autoloader

    run_silent "composer platform check" env COMPOSER_ALLOW_SUPERUSER=1 composer check-platform-reqs --no-dev

    # Node packages
    log_info "Installing frontend dependencies via pnpm..."
    run_silent "pnpm install" pnpm install --frozen-lockfile
    run_silent "npm allow-scripts=pnpm" npm config set allow-scripts=pnpm --location=user || true

    permissions

    log_info "Discovering packages..."
    run_silent "artisan package:discover" artisan package:discover --ansi

    log_ok "Dependencies synchronized."
}

initialize_blueprint() {
    log_info "Initializing Blueprint beta-2026-08 integration..."

    # Remove stale flags
    rm -f "${PANEL_ROOT}/.blueprint/extensions/blueprint/private/db/is_installed" \
          "${PANEL_ROOT}/.blueprint/extensions/blueprint/private/db/version"

    # Generate .blueprintrc
    cat > "${PANEL_ROOT}/.blueprintrc" <<EOF
WEBUSER="${WEB_USER}"
OWNERSHIP="root:${WEB_GROUP}"
USERSHELL="/bin/bash"
EOF
    chown "root:${WEB_GROUP}" "${PANEL_ROOT}/.blueprintrc"
    chmod 0640 "${PANEL_ROOT}/.blueprintrc"

    if [[ ! -f "${PANEL_ROOT}/blueprint.sh" ]]; then
        log_fatal "blueprint.sh not found in panel root."
        exit "${EX_NOINPUT}"
    fi
    chmod 0750 "${PANEL_ROOT}/blueprint.sh"

    # Non-interactive initialization (suppressed output)
    run_silent "blueprint initialization" env BLUEPRINT_ENVIRONMENT="${BLUEPRINT_ENVIRONMENT}" bash "${PANEL_ROOT}/blueprint.sh"

    # Verify installation flag was created
    if [[ ! -f "${PANEL_ROOT}/.blueprint/extensions/blueprint/private/db/is_installed" ]]; then
        log_fatal "Blueprint initialization failed: is_installed flag was not generated."
        exit "${EX_GENERAL}"
    fi

    permissions

    log_info "Warming Blueprint extension cache..."
    run_silent "artisan bp:cache" artisan bp:cache

    log_ok "Blueprint successfully initialized and cached."
}

build_frontend() {
    log_info "Building production frontend assets..."
    if grep -q '"build:production"' "${PANEL_ROOT}/package.json"; then
        run_silent "pnpm build" pnpm run build:production
    else
        run_silent "pnpm build" pnpm run build
    fi
    log_ok "Frontend assets compiled."
}

finish_deployment() {
    log_info "Finalizing deployment and warming caches..."

    permissions

    log_info "Caching Laravel configuration, routes, and views..."
    run_silent "artisan config:cache" artisan config:cache
    run_silent "artisan route:cache" artisan route:cache
    run_silent "artisan view:cache" artisan view:cache
    run_silent "artisan queue:restart" artisan queue:restart || true

    detect_php_fpm
    if command -v systemctl >/dev/null 2>&1; then
        log_info "Reloading PHP-FPM service (${PHP_FPM_SERVICE})..."
        systemctl reload "${PHP_FPM_SERVICE}" >> "${LOG_FILE}" 2>&1 || systemctl restart "${PHP_FPM_SERVICE}" >> "${LOG_FILE}" 2>&1 || log_warn "Could not reload ${PHP_FPM_SERVICE}."
    fi

    log_ok "Deployment completed."
}

# ------------------------------------------------------------------------------
# 5. Host Setup Routine (Step 1 of Manual Install Docs)
# ------------------------------------------------------------------------------
cmd_setup_host() {
    log_info "Beginning system prerequisites installation (Debian/Ubuntu)..."

    enforce_root_and_utf8
    validate_os

    # Source NVM environment if already installed
    if [[ -s "${HOME}/.nvm/nvm.sh" ]]; then
        # shellcheck source=/dev/null
        \. "${HOME}/.nvm/nvm.sh"
    elif [[ -s "/root/.nvm/nvm.sh" ]]; then
        # shellcheck source=/dev/null
        \. "/root/.nvm/nvm.sh"
    fi

    export DEBIAN_FRONTEND=noninteractive

    log_info "Updating system packages and installing prerequisites..."
    run_silent "apt-get update" apt-get update
    run_silent "apt-get install base packages" apt-get install -y lsb-release ca-certificates curl apt-transport-https gnupg

    log_info "Adding Sury PHP repository (Debian & Ubuntu)..."
    run_silent "download sury keyring" curl -sSLo /tmp/debsuryorg-archive-keyring.deb https://packages.sury.org/debsuryorg-archive-keyring.deb
    run_silent "install sury keyring" dpkg -i /tmp/debsuryorg-archive-keyring.deb
    rm -f /tmp/debsuryorg-archive-keyring.deb
    sh -c 'echo "deb [signed-by=/usr/share/keyrings/debsuryorg-archive-keyring.gpg] https://packages.sury.org/php/ $(lsb_release -sc) main" > /etc/apt/sources.list.d/php.list'
    run_silent "apt-get update (sury)" apt-get update

    log_info "Installing PHP ${PHP_VERSION}, MariaDB, Nginx, Redis, zip, and system tools..."
    run_silent "apt-get install server stack" apt-get install -y \
        "php${PHP_VERSION}" "php${PHP_VERSION}-cli" "php${PHP_VERSION}-fpm" "php${PHP_VERSION}-gd" \
        "php${PHP_VERSION}-mysql" "php${PHP_VERSION}-mbstring" "php${PHP_VERSION}-bcmath" \
        "php${PHP_VERSION}-xml" "php${PHP_VERSION}-curl" "php${PHP_VERSION}-zip" "php${PHP_VERSION}-posix" \
        mariadb-server mariadb-client nginx redis-server git tar zip unzip rsync util-linux certbot python3-certbot-nginx

    # Install Composer 2 if not already present
    if ! command -v composer >/dev/null 2>&1; then
        log_info "Installing Composer 2..."
        run_silent "install composer" sh -c "curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer"
    else
        log_ok "Composer is already installed ($(composer --version 2>/dev/null | head -n1)). Skipping."
    fi

    # Check if Node.js >= 24 is already installed
    local existing_node_ver=""
    if command -v node >/dev/null 2>&1; then
        existing_node_ver="$(node -v | sed 's/^v//')"
    fi

    if [[ -n "${existing_node_ver}" ]] && semver_ge "${existing_node_ver}" "24.0.0"; then
        log_ok "Node.js v${existing_node_ver} (>= 24.0.0) is already installed. Skipping Node installation."
    else
        log_info "Installing NVM v0.40.8 and Node.js 24..."
        run_silent "install nvm" sh -c "curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.8/install.sh | bash"

        # In lieu of restarting the shell
        if [[ -s "${HOME}/.nvm/nvm.sh" ]]; then
            # shellcheck source=/dev/null
            \. "${HOME}/.nvm/nvm.sh"
        elif [[ -s "/root/.nvm/nvm.sh" ]]; then
            # shellcheck source=/dev/null
            \. "/root/.nvm/nvm.sh"
        fi

        # Download and install Node.js:
        run_silent "nvm install 24" nvm install 24
        nvm use 24 >> "${LOG_FILE}" 2>&1 || true

        # Update npm to latest version
        log_info "Updating npm to latest version..."
        run_silent "npm update" npm i -g npm@latest

        # Make Node & npm available system-wide for all users (e.g., www-data)
        local nvm_bin_dir
        nvm_bin_dir="$(dirname "$(command -v node)")"
        if [[ -n "${nvm_bin_dir}" && -d "${nvm_bin_dir}" ]]; then
            ln -sf "${nvm_bin_dir}/node" /usr/local/bin/node
            ln -sf "${nvm_bin_dir}/npm" /usr/local/bin/npm
            ln -sf "${nvm_bin_dir}/npx" /usr/local/bin/npx
        fi
    fi

    # Check if pnpm is already installed matching pinned version
    local current_pnpm=""
    if command -v pnpm >/dev/null 2>&1; then
        current_pnpm="$(pnpm -v)"
    fi

    if [[ "${current_pnpm}" == "${DEFAULT_PINNED_PNPM}" ]]; then
        log_ok "pnpm@${current_pnpm} is already installed. Skipping pnpm installation."
    else
        log_info "Installing pinned pnpm@${DEFAULT_PINNED_PNPM}..."
        run_silent "install pnpm" npm install --global "pnpm@${DEFAULT_PINNED_PNPM}"
        local node_bin_loc
        node_bin_loc="$(dirname "$(command -v node 2>/dev/null || echo '/usr/local/bin/node')")"
        if [[ -f "${node_bin_loc}/pnpm" ]]; then
            ln -sf "${node_bin_loc}/pnpm" /usr/local/bin/pnpm
        fi
    fi

    # Allow pnpm lifecycle scripts
    run_silent "npm allow-scripts=pnpm" npm config set allow-scripts=pnpm --location=user || true

    log_ok "Host packages installed successfully."
}

# ------------------------------------------------------------------------------
# 6. Full Installation Workflow (Manual Install Docs Steps 2-11)
# ------------------------------------------------------------------------------
cmd_install() {
    echo -e "${CLR_CYAN}${CLR_BOLD}=== Aquadactyl Panel Full Automated Installation ===${CLR_RESET}"

    enforce_root_and_utf8

    TOTAL_STEPS=10
    CURRENT_STEP=0

    # Step 1: System Prerequisites
    if ! command -v php >/dev/null 2>&1 || ! command -v composer >/dev/null 2>&1 || ! command -v pnpm >/dev/null 2>&1; then
        show_progress "Installing Host Prerequisites & Build Tools"
        cmd_setup_host
    else
        show_progress "Checking Host Prerequisites"
        log_ok "Host tools and runtimes verified."
    fi

    # Step 2: Clone panel repository
    show_progress "Setting up Panel Filesystem"
    if [[ ! -d "${PANEL_ROOT}" || ! -f "${PANEL_ROOT}/artisan" ]]; then
        log_info "Preparing panel directory at ${PANEL_ROOT}..."
        mkdir -p "${PANEL_ROOT}"
        if [[ -z "$(ls -A "${PANEL_ROOT}")" ]]; then
            run_silent "cloning repository" git clone "${REPO_URL}" "${PANEL_ROOT}"
        else
            log_fatal "${PANEL_ROOT} exists and is not empty, but does not contain a valid Aquadactyl repository."
            exit "${EX_DATAERR}"
        fi
    fi

    cd "${PANEL_ROOT}"

    # Step 3: Configure Environment (.env)
    show_progress "Configuring Environment (.env)"
    if [[ ! -f "${PANEL_ROOT}/.env" ]]; then
        if [[ -f "${PANEL_ROOT}/.env.example" ]]; then
            log_info "Creating .env from .env.example..."
            cp "${PANEL_ROOT}/.env.example" "${PANEL_ROOT}/.env"
            chmod 0640 "${PANEL_ROOT}/.env"
        else
            log_fatal ".env not found and .env.example is missing."
            exit "${EX_NOINPUT}"
        fi
    fi

    # Interactive configuration prompt (reads from /dev/tty so curl | bash can ask questions)
    if [[ "${NON_INTERACTIVE}" != "1" && "${NON_INTERACTIVE}" != "true" ]]; then
        local tty_in=""
        if [[ -e /dev/tty ]]; then
            tty_in="/dev/tty"
        elif [[ -t 0 ]]; then
            tty_in="-"
        fi

        if [[ -n "${tty_in}" ]]; then
            echo ""
            echo "--- Panel Configuration ---"
            if [[ "${tty_in}" == "/dev/tty" ]]; then
                read -rp "Enter Panel Domain/URL [https://panel.example.com]: " input_url < /dev/tty
                input_url="${input_url:-https://panel.example.com}"
                sed -i "s|^APP_URL=.*|APP_URL=${input_url}|" .env

                read -rp "Enter Database Name [panel]: " input_dbname < /dev/tty
                input_dbname="${input_dbname:-panel}"
                sed -i "s|^DB_DATABASE=.*|DB_DATABASE=${input_dbname}|" .env

                read -rp "Enter Database User [aquadactyl]: " input_dbuser < /dev/tty
                input_dbuser="${input_dbuser:-aquadactyl}"
                sed -i "s|^DB_USERNAME=.*|DB_USERNAME=${input_dbuser}|" .env

                read -rsp "Enter Database Password (leave empty to auto-generate): " input_dbpass < /dev/tty
                echo ""
                if [[ -n "${input_dbpass}" ]]; then
                    sed -i "s|^DB_PASSWORD=.*|DB_PASSWORD=${input_dbpass}|" .env
                fi
            else
                read -rp "Enter Panel Domain/URL [https://panel.example.com]: " input_url
                input_url="${input_url:-https://panel.example.com}"
                sed -i "s|^APP_URL=.*|APP_URL=${input_url}|" .env

                read -rp "Enter Database Name [panel]: " input_dbname
                input_dbname="${input_dbname:-panel}"
                sed -i "s|^DB_DATABASE=.*|DB_DATABASE=${input_dbname}|" .env

                read -rp "Enter Database User [aquadactyl]: " input_dbuser
                input_dbuser="${input_dbuser:-aquadactyl}"
                sed -i "s|^DB_USERNAME=.*|DB_USERNAME=${input_dbuser}|" .env

                read -rsp "Enter Database Password (leave empty to auto-generate): " input_dbpass
                echo ""
                if [[ -n "${input_dbpass}" ]]; then
                    sed -i "s|^DB_PASSWORD=.*|DB_PASSWORD=${input_dbpass}|" .env
                fi
            fi

            # Configure Redis by default as specified in documentation
            sed -i "s|^CACHE_DRIVER=.*|CACHE_DRIVER=redis|" .env
            sed -i "s|^SESSION_DRIVER=.*|SESSION_DRIVER=redis|" .env
            sed -i "s|^QUEUE_CONNECTION=.*|QUEUE_CONNECTION=redis|" .env
        fi
    fi

    # Check if DB credentials are default or unset
    local db_host db_name db_user db_pass
    db_host="$(grep -E '^DB_HOST=' .env | cut -d'=' -f2- | tr -d '"'"'" | tr -d '\r' || echo "127.0.0.1")"
    db_name="$(grep -E '^DB_DATABASE=' .env | cut -d'=' -f2- | tr -d '"'"'" | tr -d '\r' || echo "panel")"
    db_user="$(grep -E '^DB_USERNAME=' .env | cut -d'=' -f2- | tr -d '"'"'" | tr -d '\r' || echo "aquadactyl")"
    db_pass="$(grep -E '^DB_PASSWORD=' .env | cut -d'=' -f2- | tr -d '"'"'" | tr -d '\r' || echo "")"

    # Ensure DB_HOST is explicitly 127.0.0.1 (not localhost) to use TCP loopback port 3306
    if [[ "${db_host}" == "localhost" || -z "${db_host}" ]]; then
        sed -i "s|^DB_HOST=.*|DB_HOST=127.0.0.1|" .env
        db_host="127.0.0.1"
    fi

    # If DB password is empty or default, generate a secure random one
    if [[ -z "${db_pass}" || "${db_pass}" == "your_secure_password" || "${db_pass}" == "secret" ]]; then
        db_pass="$(head -c 16 /dev/urandom | sha256sum | head -c 24)"
        if grep -q "^DB_PASSWORD=" .env; then
            sed -i "s|^DB_PASSWORD=.*|DB_PASSWORD=${db_pass}|" .env
        else
            echo "DB_PASSWORD=${db_pass}" >> .env
        fi
    fi

    # Ensure MariaDB server is running
    if command -v systemctl >/dev/null 2>&1; then
        systemctl start mariadb >> "${LOG_FILE}" 2>&1 || systemctl start mysql >> "${LOG_FILE}" 2>&1 || true
    fi

    # Re-read resolved DB parameters from .env
    db_name="$(grep -E '^DB_DATABASE=' .env | cut -d'=' -f2- | tr -d '"'"'" | tr -d '\r' || echo "panel")"
    db_user="$(grep -E '^DB_USERNAME=' .env | cut -d'=' -f2- | tr -d '"'"'" | tr -d '\r' || echo "aquadactyl")"
    db_pass="$(grep -E '^DB_PASSWORD=' .env | cut -d'=' -f2- | tr -d '"'"'" | tr -d '\r' || echo "")"

    # Automated MariaDB provisioning
    local db_client=""
    if command -v mariadb >/dev/null 2>&1; then
        db_client="mariadb"
    elif command -v mysql >/dev/null 2>&1; then
        db_client="mysql"
    fi

    if [[ -n "${db_client}" ]]; then
        "${db_client}" -u root -e "
            CREATE DATABASE IF NOT EXISTS \`${db_name}\`;

            DROP USER IF EXISTS '${db_user}'@'127.0.0.1';
            DROP USER IF EXISTS '${db_user}'@'localhost';
            DROP USER IF EXISTS '${db_user}'@'%';

            CREATE USER '${db_user}'@'127.0.0.1' IDENTIFIED BY '${db_pass}';
            GRANT ALL PRIVILEGES ON \`${db_name}\`.* TO '${db_user}'@'127.0.0.1' WITH GRANT OPTION;

            CREATE USER '${db_user}'@'localhost' IDENTIFIED BY '${db_pass}';
            GRANT ALL PRIVILEGES ON \`${db_name}\`.* TO '${db_user}'@'localhost' WITH GRANT OPTION;

            CREATE USER '${db_user}'@'%' IDENTIFIED BY '${db_pass}';
            GRANT ALL PRIVILEGES ON \`${db_name}\`.* TO '${db_user}'@'%' WITH GRANT OPTION;

            FLUSH PRIVILEGES;
        " >> "${LOG_FILE}" 2>&1 || true
    fi

    # Step 4: Preflight checks & Locking
    show_progress "Validating System & Concurrency Lock"
    preflight

    if [[ -f "${PANEL_ROOT}/.blueprint/extensions/blueprint/private/db/is_installed" ]]; then
        log_fatal "Blueprint is already initialized in this installation."
        echo "Please use 'deploy.sh update' to update or manage this installation." >&2
        exit "${EX_DATAERR}"
    fi

    # Step 5: Install dependencies
    show_progress "Installing Composer & PNPM Dependencies"
    dependencies

    # Step 6: Generate Encryption Keys and Salt
    show_progress "Generating Application Keys & Hashids Salt"
    local app_key
    app_key="$(grep -E '^APP_KEY=' .env | cut -d'=' -f2- || echo "")"
    if [[ -z "${app_key}" || "${app_key}" == "base64:" || "${app_key}" == "SomeRandomString" ]]; then
        # Ensure .env is writable
        chmod 0660 "${PANEL_ROOT}/.env" 2>/dev/null || true
        run_silent "generate app key" php "${PANEL_ROOT}/artisan" key:generate --force
        chmod 0640 "${PANEL_ROOT}/.env" 2>/dev/null || true
    fi

    local hashids_salt
    hashids_salt="$(grep -E '^HASHIDS_SALT=' .env | cut -d'=' -f2- || echo "")"
    if [[ -z "${hashids_salt}" ]]; then
        local new_salt
        if command -v openssl >/dev/null 2>&1; then
            new_salt="$(openssl rand -hex 16)"
        else
            new_salt="$(head -c 16 /dev/urandom | sha256sum | head -c 32)"
        fi
        if grep -q "^HASHIDS_SALT=" .env; then
            sed -i "s/^HASHIDS_SALT=.*/HASHIDS_SALT=${new_salt}/" .env
        else
            echo "HASHIDS_SALT=${new_salt}" >> .env
        fi
    fi

    # Step 7: Database migrations & seeders
    show_progress "Running Database Migrations & Seeders"
    php "${PANEL_ROOT}/artisan" down --retry=60 >> "${LOG_FILE}" 2>&1 || true
    MAINTENANCE_ENABLED=1

    run_silent "database migrations" php "${PANEL_ROOT}/artisan" migrate --force
    run_silent "blueprint seeder" php "${PANEL_ROOT}/artisan" db:seed --class=BlueprintSeeder --force
    run_silent "database seeder" php "${PANEL_ROOT}/artisan" db:seed --class=DatabaseSeeder --force

    # Step 8: Initialize Blueprint & Build Frontend
    show_progress "Initializing Blueprint & Building Frontend"
    initialize_blueprint
    build_frontend

    # Step 9: Configure File Permissions & Daemons
    show_progress "Configuring Permissions & Services (pteroq/cron/nginx)"
    permissions

    # Configure Nginx site
    if command -v nginx >/dev/null 2>&1 && [[ -d /etc/nginx/sites-available ]]; then
        log_info "Configuring Nginx web server..."
        local domain_name
        domain_name="$(grep -E '^APP_URL=' .env | cut -d'=' -f2- | sed -e 's|^[^/]*//||' -e 's|/.*$||' -e 's|:[0-9]*$||' | tr -d '"'"'" || echo "_")"
        [[ -z "${domain_name}" || "${domain_name}" == "panel.example.com" ]] && domain_name="_"

        local fpm_sock="/run/php/php${PHP_VERSION}-fpm.sock"
        [[ ! -e "${fpm_sock}" && -e "/run/php/php8.5-fpm.sock" ]] && fpm_sock="/run/php/php8.5-fpm.sock"
        [[ ! -e "${fpm_sock}" && -e "/run/php/php8.4-fpm.sock" ]] && fpm_sock="/run/php/php8.4-fpm.sock"

        if [[ -f "${PANEL_ROOT}/deploy/nginx/panel.conf" ]]; then
            cp "${PANEL_ROOT}/deploy/nginx/panel.conf" /etc/nginx/sites-available/aquadactyl.conf
            sed -i "s|<domain>|${domain_name}|g" /etc/nginx/sites-available/aquadactyl.conf
            sed -i "s|/var/www/aquadactyl|${PANEL_ROOT}|g" /etc/nginx/sites-available/aquadactyl.conf
        else
            cat > /etc/nginx/sites-available/aquadactyl.conf <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${domain_name};

    root ${PANEL_ROOT}/public;
    index index.html index.htm index.php;
    charset utf-8;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ^~ /assets/ {
        location ~ /\. {
            deny all;
        }
        try_files \$uri =404;
    }

    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt  { access_log off; log_not_found off; }

    access_log off;
    error_log  /var/log/nginx/aquadactyl.app-error.log error;

    client_max_body_size 100m;
    client_body_timeout 120s;
    sendfile off;

    location ~ \.php\$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)\$;
        fastcgi_pass unix:${fpm_sock};
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param PHP_VALUE "upload_max_filesize = 100M \n post_max_size=100M";
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param HTTP_PROXY "";
        fastcgi_intercept_errors off;
        fastcgi_buffer_size 16k;
        fastcgi_buffers 4 16k;
        fastcgi_connect_timeout 300;
        fastcgi_send_timeout 300;
        fastcgi_read_timeout 300;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF
        fi

        # Remove default nginx site and enable aquadactyl
        rm -f /etc/nginx/sites-enabled/default
        ln -sf /etc/nginx/sites-available/aquadactyl.conf /etc/nginx/sites-enabled/aquadactyl.conf
        nginx -t >> "${LOG_FILE}" 2>&1 && systemctl reload nginx >> "${LOG_FILE}" 2>&1 || systemctl restart nginx >> "${LOG_FILE}" 2>&1 || true
    fi

    if [[ -f "${PANEL_ROOT}/deploy/systemd/pteroq.service" ]]; then
        cp "${PANEL_ROOT}/deploy/systemd/pteroq.service" /etc/systemd/system/pteroq.service
        run_silent "reload systemd" systemctl daemon-reload
        systemctl enable --now pteroq.service >> "${LOG_FILE}" 2>&1 || log_warn "Could not immediately start pteroq.service."
    fi

    echo "* * * * * ${WEB_USER} cd ${PANEL_ROOT} && /usr/bin/php artisan schedule:run >> /dev/null 2>&1" > /etc/cron.d/aquadactyl
    chmod 0644 /etc/cron.d/aquadactyl

    # Step 10: Finalize & Cache
    show_progress "Finalizing Production Caches"
    finish_deployment

    artisan up >> "${LOG_FILE}" 2>&1 || true
    MAINTENANCE_ENABLED=0

    # Step 12: Administrative user creation
    echo ""
    echo "================================================================================"
    log_ok "Aquadactyl installation completed successfully!"
    echo "================================================================================"
    if [[ "${NON_INTERACTIVE}" != "1" && "${NON_INTERACTIVE}" != "true" ]]; then
        if [[ -e /dev/tty ]]; then
            echo ""
            log_info "Prompting to create the primary administrator account..."
            php "${PANEL_ROOT}/artisan" p:user:make < /dev/tty
        elif [[ -t 0 ]]; then
            echo ""
            log_info "Prompting to create the primary administrator account..."
            php "${PANEL_ROOT}/artisan" p:user:make
        else
            echo "  To create the administrator account, run:"
            echo "    sudo php ${PANEL_ROOT}/artisan p:user:make"
        fi
    else
        echo "  To create the administrator account, run:"
        echo "    sudo php ${PANEL_ROOT}/artisan p:user:make"
    fi
    echo "================================================================================"
}

# ------------------------------------------------------------------------------
# 7. Update Workflow
# ------------------------------------------------------------------------------
cmd_update() {
    local mode=""
    local release_tag=""
    local repo_owner="Aquadactyl/aquadactyl"
    local archive_path=""
    local expected_hash=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --archive)
                mode="archive"
                archive_path="$2"
                expected_hash="$3"
                shift 3
                ;;
            -h|--help)
                usage
                exit "${EX_OK}"
                ;;
            v*)
                mode="release"
                release_tag="$1"
                if [[ $# -ge 2 && ! "$2" =~ ^- ]]; then
                    repo_owner="$2"
                    shift
                fi
                shift
                ;;
            *)
                log_fatal "Unrecognized parameter: $1"
                usage
                exit "${EX_USAGE}"
                ;;
        esac
    done

    if [[ -z "${mode}" ]]; then
        log_fatal "No update source specified."
        usage
        exit "${EX_USAGE}"
    fi

    TOTAL_STEPS=8
    CURRENT_STEP=0

    # Step 1: Preflight
    show_progress "Running Preflight Checks"
    preflight

    WORK="$(mktemp -d -t aquadactyl-update-XXXXXX)"
    chmod 0700 "${WORK}"

    # Step 2: Retrieve & Verify Release Archive
    show_progress "Downloading & Verifying Release Archive"
    if [[ "${mode}" == "release" ]]; then
        log_info "Fetching release '${release_tag}' from '${repo_owner}'..."
        local tarball_url="https://github.com/${repo_owner}/releases/download/${release_tag}/panel.tar.gz"
        local checksums_url="https://github.com/${repo_owner}/releases/download/${release_tag}/SHA256SUMS"

        run_silent "download panel.tar.gz" curl -fSL "${tarball_url}" -o "${WORK}/panel.tar.gz" || {
            log_fatal "Failed to download panel archive from: ${tarball_url}"
            exit "${EX_GENERAL}"
        }

        run_silent "download SHA256SUMS" curl -fSL "${checksums_url}" -o "${WORK}/SHA256SUMS" || {
            log_fatal "Failed to download SHA256SUMS from: ${checksums_url}"
            exit "${EX_GENERAL}"
        }

        expected_hash="$(grep "panel.tar.gz" "${WORK}/SHA256SUMS" | awk '{print $1}' || echo "")"
        if [[ -z "${expected_hash}" ]]; then
            log_fatal "Unable to locate panel.tar.gz checksum in SHA256SUMS."
            exit "${EX_DATAERR}"
        fi
    elif [[ "${mode}" == "archive" ]]; then
        if [[ ! -f "${archive_path}" ]]; then
            log_fatal "Archive file not found: ${archive_path}"
            exit "${EX_NOINPUT}"
        fi
        if [[ -z "${expected_hash}" ]]; then
            log_fatal "Checksum not provided for local archive."
            exit "${EX_USAGE}"
        fi
        cp "${archive_path}" "${WORK}/panel.tar.gz"
    fi

    local actual_hash
    actual_hash="$(sha256sum "${WORK}/panel.tar.gz" | awk '{print $1}')"
    if [[ "${actual_hash}" != "${expected_hash}" ]]; then
        log_fatal "Checksum mismatch! Expected: ${expected_hash}, Calculated: ${actual_hash}"
        exit "${EX_DATAERR}"
    fi

    # Step 3: Security audit & extraction
    show_progress "Auditing & Extracting Archive"
    tar -tzf "${WORK}/panel.tar.gz" > "${WORK}/archive_index.txt"

    if grep -E '(^/|\.\./)' "${WORK}/archive_index.txt"; then
        log_fatal "Archive security audit failed: archive contains absolute paths or path traversal (../)."
        exit "${EX_DATAERR}"
    fi

    if grep -E '(^\./\.env$|^\.env$|^\./\.blueprintrc$|^\.blueprintrc$)' "${WORK}/archive_index.txt"; then
        log_fatal "Archive security audit failed: archive contains sensitive host configurations (.env / .blueprintrc)."
        exit "${EX_DATAERR}"
    fi

    if tar -tvzf "${WORK}/panel.tar.gz" | grep -vE '^[dl-]' | grep -q .; then
        log_fatal "Archive security audit failed: archive contains forbidden file types."
        exit "${EX_DATAERR}"
    fi

    mkdir -p "${WORK}/release"
    run_silent "extracting release archive" tar -xzf "${WORK}/panel.tar.gz" --no-same-owner --no-same-permissions -C "${WORK}/release"

    local required_release_files=(
        "artisan"
        "package.json"
        "composer.lock"
        "pnpm-lock.yaml"
        "pnpm-workspace.yaml"
        ".blueprint/extensions/blueprint/private/extensionfs.php"
    )
    for crf in "${required_release_files[@]}"; do
        if [[ ! -e "${WORK}/release/${crf}" ]]; then
            log_fatal "Archive is missing critical panel component: ${crf}"
            exit "${EX_DATAERR}"
        fi
    done

    # Step 4: Extension Inventory Pre-flight
    show_progress "Auditing Installed Blueprint Extensions"
    local installed_ext_file="${PANEL_ROOT}/.blueprint/extensions/blueprint/private/db/installed_extensions"
    local extensions=()
    if [[ -f "${installed_ext_file}" ]]; then
        local raw_ext
        raw_ext="$(cat "${installed_ext_file}" | tr -d '\r\n')"
        if [[ -n "${raw_ext}" ]]; then
            IFS=',' read -r -a extensions <<< "${raw_ext}"
        fi
    fi

    if [[ ${#extensions[@]} -gt 0 ]]; then
        log_info "Detected installed Blueprint extensions: ${extensions[*]}"
        for ext in "${extensions[@]}"; do
            local found=0
            if [[ -f "${PANEL_ROOT}/${ext}.blueprint" || -f "${PANEL_ROOT}/.blueprint/extensions/${ext}/build/${ext}.blueprint" ]]; then
                found=1
            fi
            if [[ "${found}" -eq 0 ]]; then
                log_warn "Archive package for extension '${ext}' was not found on disk."
                if [[ "${NON_INTERACTIVE}" != "1" && "${NON_INTERACTIVE}" != "true" ]]; then
                    read -rp "Continue update without automated reapplication of '${ext}'? [y/N]: " choice
                    if [[ ! "${choice}" =~ ^[Yy]$ ]]; then
                        log_fatal "Update aborted by user due to missing extension package."
                        exit "${EX_GENERAL}"
                    fi
                fi
            fi
        done
    fi

    # Step 5: Backup Creation
    show_progress "Creating Database & Filesystem Snapshots"
    BACKUP_DIR="$(realpath -m "${BACKUP_DIR}")"
    if [[ "${BACKUP_DIR}" == "${PANEL_ROOT}"* ]]; then
        log_fatal "BACKUP_DIR (${BACKUP_DIR}) cannot be located within PANEL_ROOT (${PANEL_ROOT})."
        exit "${EX_DATAERR}"
    fi

    mkdir -p "${BACKUP_DIR}"
    BACKUP="$(mktemp -d "${BACKUP_DIR}/$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")"
    chmod 0700 "${BACKUP}"

    artisan down --retry=60 >> "${LOG_FILE}" 2>&1 || true
    MAINTENANCE_ENABLED=1

    if command -v systemctl >/dev/null 2>&1; then
        if systemctl is-active --quiet "${PTEROQ_SERVICE}"; then
            systemctl stop "${PTEROQ_SERVICE}" >> "${LOG_FILE}" 2>&1 || true
            PTEROQ_WAS_RUNNING=1
        fi
    fi

    local db_dump_ok=0
    if run_silent "database backup" artisan p:maintenance:backup-database "${BACKUP}/database.sql"; then
        db_dump_ok=1
    fi

    if [[ "${db_dump_ok}" -eq 0 ]]; then
        local db_host db_port db_name db_user db_pass
        db_host="$(grep -E '^DB_HOST=' "${PANEL_ROOT}/.env" | cut -d'=' -f2- | tr -d '"'"'" || echo "127.0.0.1")"
        db_port="$(grep -E '^DB_PORT=' "${PANEL_ROOT}/.env" | cut -d'=' -f2- | tr -d '"'"'" || echo "3306")"
        db_name="$(grep -E '^DB_DATABASE=' "${PANEL_ROOT}/.env" | cut -d'=' -f2- | tr -d '"'"'" || echo "")"
        db_user="$(grep -E '^DB_USERNAME=' "${PANEL_ROOT}/.env" | cut -d'=' -f2- | tr -d '"'"'" || echo "")"
        db_pass="$(grep -E '^DB_PASSWORD=' "${PANEL_ROOT}/.env" | cut -d'=' -f2- | tr -d '"'"'" || echo "")"

        local dump_tool=""
        if command -v mariadb-dump >/dev/null 2>&1; then
            dump_tool="mariadb-dump"
        elif command -v mysqldump >/dev/null 2>&1; then
            dump_tool="mysqldump"
        else
            log_fatal "Neither mariadb-dump nor mysqldump is installed on this host."
            exit "${EX_UNAVAILABLE}"
        fi

        run_silent "database sql dump" "${dump_tool}" --host="${db_host}" --port="${db_port}" --user="${db_user}" --password="${db_pass}" \
            --single-transaction --quick --routines "${db_name}" > "${BACKUP}/database.sql"
    fi

    if [[ ! -s "${BACKUP}/database.sql" ]]; then
        log_fatal "Database dump failed or produced an empty backup."
        exit "${EX_GENERAL}"
    fi

    run_silent "archiving panel directory" tar --exclude='./node_modules' \
        --exclude='./.git' \
        --exclude='./storage/logs/*.log' \
        --exclude='./storage/framework/cache/data/*' \
        -czf "${BACKUP}/panel.tar.gz" -C "${PANEL_ROOT}" .

    chmod 0600 "${BACKUP}/database.sql" "${BACKUP}/panel.tar.gz"
    log_ok "Backup created at: ${BACKUP}"

    # Step 6: Sync Files & Dependencies
    show_progress "Synchronizing Release Files & Dependencies"
    run_silent "rsync release files" rsync -a --no-owner --no-group \
        --exclude='.env' \
        --exclude='.blueprintrc' \
        --exclude='storage/' \
        --exclude='bootstrap/cache/' \
        --exclude='.blueprint/dev/' \
        --exclude='.blueprint/tmp/' \
        --exclude='.blueprint/extensions/blueprint/private/db/' \
        --exclude='.blueprint/extensions/blueprint/private/debug/' \
        "${WORK}/release/" "${PANEL_ROOT}/"

    dependencies

    # Step 7: Migrations & Extensions
    show_progress "Running Migrations & Reapplying Extensions"
    run_silent "database migrations" artisan migrate --force
    run_silent "blueprint seeder" artisan db:seed --class=BlueprintSeeder --force

    initialize_blueprint

    # Reinstall extensions
    if [[ ${#extensions[@]} -gt 0 ]]; then
        for ext in "${extensions[@]}"; do
            local ext_path=""
            if [[ -f "${PANEL_ROOT}/${ext}.blueprint" ]]; then
                ext_path="${PANEL_ROOT}/${ext}.blueprint"
            elif [[ -f "${PANEL_ROOT}/.blueprint/extensions/${ext}/build/${ext}.blueprint" ]]; then
                ext_path="${PANEL_ROOT}/.blueprint/extensions/${ext}/build/${ext}.blueprint"
            fi

            if [[ -n "${ext_path}" ]]; then
                log_info "Reapplying Blueprint extension: ${ext}..."
                run_silent "reapply extension ${ext}" bash "${PANEL_ROOT}/blueprint.sh" -bash -i "${ext_path}" || {
                    log_warn "Failed to reapply extension '${ext}'. Continuing..."
                }
            fi
        done
    fi

    # Step 8: Build Frontend & Bring Online
    show_progress "Building Frontend & Finalizing Deployment"
    build_frontend
    finish_deployment

    if [[ "${PTEROQ_WAS_RUNNING}" -eq 1 ]]; then
        systemctl start "${PTEROQ_SERVICE}" >> "${LOG_FILE}" 2>&1 || log_warn "Failed to start ${PTEROQ_SERVICE}."
    fi

    artisan up >> "${LOG_FILE}" 2>&1 || true
    MAINTENANCE_ENABLED=0

    echo ""
    echo "================================================================================"
    log_ok "Aquadactyl update completed successfully!"
    echo "  Backup stored at: ${BACKUP}"
    echo "================================================================================"
}

# ------------------------------------------------------------------------------
# 8. Uninstallation / Removal Workflow
# ------------------------------------------------------------------------------
cmd_remove() {
    echo -e "${CLR_RED}${CLR_BOLD}=== Aquadactyl Complete Uninstallation & Removal ===${CLR_RESET}"
    enforce_root_and_utf8

    if [[ "${NON_INTERACTIVE}" != "1" && "${NON_INTERACTIVE}" != "true" ]]; then
        echo -e "${CLR_YELLOW}${CLR_BOLD}WARNING:${CLR_RESET} This will permanently delete the panel directory, drop the database, stop services, and remove web server configurations!"
        local confirm=""
        if [[ -e /dev/tty ]]; then
            read -rp "Are you absolutely sure you want to remove Aquadactyl? [type 'yes' to proceed]: " confirm < /dev/tty
        else
            read -rp "Are you absolutely sure you want to remove Aquadactyl? [type 'yes' to proceed]: " confirm
        fi
        if [[ "${confirm}" != "yes" ]]; then
            log_info "Uninstallation aborted."
            return 0
        fi
    fi

    TOTAL_STEPS=6
    CURRENT_STEP=0

    # Step 1: Stop and disable background worker and cron
    show_progress "Stopping and Removing Services"
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl is-active --quiet "${PTEROQ_SERVICE}" 2>/dev/null; then
            run_silent "stop pteroq" systemctl stop "${PTEROQ_SERVICE}"
        fi
        systemctl disable "${PTEROQ_SERVICE}" >> "${LOG_FILE}" 2>&1 || true
        rm -f "/etc/systemd/system/${PTEROQ_SERVICE}"
        run_silent "reload systemd" systemctl daemon-reload
    fi
    rm -f /etc/cron.d/aquadactyl

    # Step 2: Remove Nginx configuration
    show_progress "Removing Web Server Configuration"
    rm -f /etc/nginx/sites-enabled/aquadactyl.conf
    rm -f /etc/nginx/sites-available/aquadactyl.conf
    if [[ -f /etc/nginx/sites-available/default && ! -e /etc/nginx/sites-enabled/default ]]; then
        ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
    fi
    if command -v nginx >/dev/null 2>&1; then
        nginx -t >> "${LOG_FILE}" 2>&1 && systemctl reload nginx >> "${LOG_FILE}" 2>&1 || true
    fi

    # Step 3: Drop database and database user
    show_progress "Dropping Database & Credentials"
    local db_name="panel"
    local db_user="aquadactyl"
    if [[ -f "${PANEL_ROOT}/.env" ]]; then
        db_name="$(grep -E '^DB_DATABASE=' "${PANEL_ROOT}/.env" | cut -d'=' -f2- | tr -d '"'"'" | tr -d '\r' || echo "panel")"
        db_user="$(grep -E '^DB_USERNAME=' "${PANEL_ROOT}/.env" | cut -d'=' -f2- | tr -d '"'"'" | tr -d '\r' || echo "aquadactyl")"
    fi

    local db_client=""
    if command -v mariadb >/dev/null 2>&1; then
        db_client="mariadb"
    elif command -v mysql >/dev/null 2>&1; then
        db_client="mysql"
    fi

    if [[ -n "${db_client}" ]]; then
        "${db_client}" -u root -e "
            DROP DATABASE IF EXISTS \`${db_name}\`;
            DROP USER IF EXISTS '${db_user}'@'127.0.0.1';
            DROP USER IF EXISTS '${db_user}'@'localhost';
            DROP USER IF EXISTS '${db_user}'@'%';
            FLUSH PRIVILEGES;
        " >> "${LOG_FILE}" 2>&1 || true
    fi

    # Step 4: Remove panel files
    show_progress "Removing Panel Directory (${PANEL_ROOT})"
    if [[ -d "${PANEL_ROOT}" ]]; then
        rm -rf "${PANEL_ROOT}"
    fi

    # Step 5: Clean up global bin symlinks
    show_progress "Removing Symlinks & Global Binaries"
    rm -f /usr/local/bin/blueprint
    rm -f /usr/local/bin/node
    rm -f /usr/local/bin/npm
    rm -f /usr/local/bin/npx
    rm -f /usr/local/bin/pnpm

    # Step 6: Option to purge packages or finish
    show_progress "Finalizing System Cleanup"
    local purge_pkgs=0
    if [[ "${NON_INTERACTIVE}" != "1" && "${NON_INTERACTIVE}" != "true" ]]; then
        local purge_choice=""
        if [[ -e /dev/tty ]]; then
            read -rp "Do you also want to purge installed packages (PHP, MariaDB, Redis, Nginx)? [y/N]: " purge_choice < /dev/tty
        else
            read -rp "Do you also want to purge installed packages (PHP, MariaDB, Redis, Nginx)? [y/N]: " purge_choice
        fi
        [[ "${purge_choice}" =~ ^[Yy]$ ]] && purge_pkgs=1
    fi

    if [[ "${purge_pkgs}" -eq 1 ]]; then
        log_info "Purging system packages..."
        run_silent "purge packages" apt-get purge -y \
            "php${PHP_VERSION}*" mariadb-server mariadb-client redis-server nginx
        run_silent "autoremove" apt-get autoremove -y
        rm -rf "${HOME}/.nvm" /root/.nvm
    fi

    echo ""
    echo "================================================================================"
    log_ok "Aquadactyl has been completely removed from this system."
    echo "================================================================================"
}

# ------------------------------------------------------------------------------
# 9. CLI Usage & Entrypoint
# ------------------------------------------------------------------------------
usage() {
    cat <<EOF
Aquadactyl Deployment & Management Automation Tooling

One-Liner Usage:
  curl -fsSL https://raw.githubusercontent.com/.../deploy.sh | sudo bash -s -- install
  sudo bash deploy.sh install

Commands:
  install             Full panel automated install (dependencies, clone, .env, DB, Blueprint, build).
  setup-host          Install system packages only (PHP 8.5, MariaDB, Node 22, pnpm 12.10.1, Composer).
  update              Managed zero-downtime update from GitHub release tag or local archive.
  permissions         Restore strict least-privilege permissions across PANEL_ROOT.
  remove              Complete uninstallation & rollback (stops services, drops DB, deletes panel).

Update Usage:
  sudo bash deploy.sh update <release-tag> [owner/repository]
  sudo bash deploy.sh update --archive /path/to/panel.tar.gz <sha256-checksum>

Options / Environment Variables:
  PANEL_ROOT          Path to panel root (default: /var/www/aquadactyl)
  WEB_USER            Web server user (default: www-data)
  WEB_GROUP           Web server group (default: www-data)
  PHP_VERSION         PHP minor version (default: 8.5)
  BACKUP_DIR          Directory for update snapshots (default: /var/backups/aquadactyl)
  NON_INTERACTIVE     Set to 1 to bypass interactive prompts

EOF
}

main() {
    # Immediately enforce root user privileges and UTF-8 environment
    if [[ "${1:-}" != "-h" && "${1:-}" != "--help" && "${1:-}" != "help" ]]; then
        enforce_root_and_utf8
    fi

    if [[ $# -eq 0 ]]; then
        # Default action when run without arguments is full automated install
        cmd_install
        return 0
    fi

    local action="$1"
    shift

    case "${action}" in
        install)
            cmd_install "$@"
            ;;
        setup-host)
            cmd_setup_host "$@"
            ;;
        update)
            cmd_update "$@"
            ;;
        permissions)
            preflight
            permissions
            ;;
        remove|uninstall)
            cmd_remove "$@"
            ;;
        -h|--help|help)
            usage
            exit "${EX_OK}"
            ;;
        *)
            # If user passes release tag directly (e.g. `sudo bash deploy.sh v0.2.0`)
            if [[ "${action}" =~ ^v[0-9] ]]; then
                cmd_update "${action}" "$@"
            else
                log_fatal "Unknown command: ${action}"
                usage
                exit "${EX_USAGE}"
            fi
            ;;
    esac
}

main "$@"
