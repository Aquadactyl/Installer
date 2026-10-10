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

# Silent command runner: suppresses output unless an error occurs
LOG_FILE="/tmp/aquadactyl-deploy-$(date +%s).log"
run_silent() {
    local cmd_desc="${1:-Executing task}"
    shift
    if ! "$@" >> "${LOG_FILE}" 2>&1; then
        local err_code=$?
        log_err "${cmd_desc} failed with exit code ${err_code}."
        echo "--- Last 25 lines of output from ${LOG_FILE} ---" >&2
        tail -n 25 "${LOG_FILE}" >&2
        echo "------------------------------------------------" >&2
        return ${err_code}
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
    runuser -u "${WEB_USER}" -- php "${PANEL_ROOT}/artisan" "$@"
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

    log_ok "Host packages installed successfully."
}

# ------------------------------------------------------------------------------
# 6. Full Installation Workflow (Manual Install Docs Steps 2-11)
# ------------------------------------------------------------------------------
cmd_install() {
    echo -e "${CLR_CYAN}${CLR_BOLD}=== Aquadactyl Panel Full Automated Installation ===${CLR_RESET}"

    enforce_root_and_utf8

    # If prerequisites missing, offer or perform host setup
    if ! command -v php >/dev/null 2>&1 || ! command -v composer >/dev/null 2>&1 || ! command -v pnpm >/dev/null 2>&1; then
        log_info "Required dependencies missing. Auto-installing system prerequisites..."
        cmd_setup_host
    fi

    # Step 3: Clone panel code if PANEL_ROOT is empty or missing
    if [[ ! -d "${PANEL_ROOT}" || ! -f "${PANEL_ROOT}/artisan" ]]; then
        log_info "Preparing panel directory at ${PANEL_ROOT}..."
        mkdir -p "${PANEL_ROOT}"
        if [[ -z "$(ls -A "${PANEL_ROOT}")" ]]; then
            log_info "Cloning Aquadactyl repository from ${REPO_URL}..."
            git clone "${REPO_URL}" "${PANEL_ROOT}"
        else
            log_fatal "${PANEL_ROOT} exists and is not empty, but does not contain a valid Aquadactyl repository."
            exit "${EX_DATAERR}"
        fi
    fi

    cd "${PANEL_ROOT}"

    # Step 4: Configure Environment (.env)
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

    # Interactive or environment prompt for database and domain if defaults present
    local app_url db_name db_user db_pass
    app_url="$(grep -E '^APP_URL=' .env | cut -d'=' -f2- | tr -d '"'"'" || echo "")"
    db_name="$(grep -E '^DB_DATABASE=' .env | cut -d'=' -f2- | tr -d '"'"'" || echo "")"
    db_user="$(grep -E '^DB_USERNAME=' .env | cut -d'=' -f2- | tr -d '"'"'" || echo "")"
    db_pass="$(grep -E '^DB_PASSWORD=' .env | cut -d'=' -f2- | tr -d '"'"'" || echo "")"

    if [[ -z "${app_url}" || "${app_url}" == "http://localhost" || "${app_url}" == "https://panel.example.com" ]]; then
        if [[ "${NON_INTERACTIVE}" != "1" && "${NON_INTERACTIVE}" != "true" && -t 0 ]]; then
            echo ""
            echo "--- Panel Configuration ---"
            read -rp "Enter Panel Domain/URL [https://panel.example.com]: " input_url
            input_url="${input_url:-https://panel.example.com}"
            sed -i "s|^APP_URL=.*|APP_URL=${input_url}|" .env

            read -rp "Enter Database Name [aquadactyl]: " input_dbname
            input_dbname="${input_dbname:-aquadactyl}"
            sed -i "s|^DB_DATABASE=.*|DB_DATABASE=${input_dbname}|" .env

            read -rp "Enter Database User [aquadactyl]: " input_dbuser
            input_dbuser="${input_dbuser:-aquadactyl}"
            sed -i "s|^DB_USERNAME=.*|DB_USERNAME=${input_dbuser}|" .env

            read -rsp "Enter Database Password: " input_dbpass
            echo ""
            sed -i "s|^DB_PASSWORD=.*|DB_PASSWORD=${input_dbpass}|" .env

            # Configure Redis by default as specified in documentation
            sed -i "s|^CACHE_DRIVER=.*|CACHE_DRIVER=redis|" .env
            sed -i "s|^SESSION_DRIVER=.*|SESSION_DRIVER=redis|" .env
            sed -i "s|^QUEUE_CONNECTION=.*|QUEUE_CONNECTION=redis|" .env
        fi
    fi

    # Automated MariaDB provisioning if root MariaDB access is available
    db_name="$(grep -E '^DB_DATABASE=' .env | cut -d'=' -f2- | tr -d '"'"'" || echo "aquadactyl")"
    db_user="$(grep -E '^DB_USERNAME=' .env | cut -d'=' -f2- | tr -d '"'"'" || echo "aquadactyl")"
    db_pass="$(grep -E '^DB_PASSWORD=' .env | cut -d'=' -f2- | tr -d '"'"'" || echo "")"

    if command -v mariadb >/dev/null 2>&1 && [[ -n "${db_pass}" ]]; then
        log_info "Testing/provisioning MariaDB database and user '${db_user}'..."
        mariadb -u root -e "
            CREATE DATABASE IF NOT EXISTS \`${db_name}\`;
            CREATE USER IF NOT EXISTS '${db_user}'@'127.0.0.1' IDENTIFIED BY '${db_pass}';
            ALTER USER '${db_user}'@'127.0.0.1' IDENTIFIED BY '${db_pass}';
            GRANT ALL PRIVILEGES ON \`${db_name}\`.* TO '${db_user}'@'127.0.0.1' WITH GRANT OPTION;
            FLUSH PRIVILEGES;
        " 2>/dev/null || log_warn "Could not auto-configure MariaDB as root. Proceeding with existing database."
    fi

    # Now execute standard preflight checks and acquire lock
    preflight

    # Safety check: Prevent re-installing over existing initialized Blueprint
    if [[ -f "${PANEL_ROOT}/.blueprint/extensions/blueprint/private/db/is_installed" ]]; then
        log_fatal "Blueprint is already initialized in this installation."
        echo "Please use 'deploy.sh update' to update or manage this installation." >&2
        exit "${EX_DATAERR}"
    fi

    # Step 5: Install dependencies
    dependencies

    # Step 6: Generate Encryption Keys and Salt
    log_info "Configuring encryption keys and salts..."
    local app_key
    app_key="$(grep -E '^APP_KEY=' .env | cut -d'=' -f2- || echo "")"
    if [[ -z "${app_key}" || "${app_key}" == "base64:" || "${app_key}" == "SomeRandomString" ]]; then
        artisan key:generate --force
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
    log_info "Entering temporary maintenance mode..."
    artisan down --retry=60 >> "${LOG_FILE}" 2>&1 || true
    MAINTENANCE_ENABLED=1

    log_info "Running database migrations..."
    run_silent "database migrations" artisan migrate --force

    log_info "Seeding Blueprint database tables..."
    run_silent "blueprint seeder" artisan db:seed --class=BlueprintSeeder --force

    log_info "Seeding default nests and eggs (DatabaseSeeder)..."
    run_silent "database seeder" artisan db:seed --class=DatabaseSeeder --force

    # Step 8: Initialize Blueprint & Build Frontend
    initialize_blueprint
    build_frontend

    # Step 9: Configure File Permissions
    permissions

    # Step 10: Configure Background Worker (pteroq.service) & Cron Scheduler
    if [[ -f "${PANEL_ROOT}/deploy/systemd/pteroq.service" ]]; then
        log_info "Installing pteroq.service systemd unit..."
        cp "${PANEL_ROOT}/deploy/systemd/pteroq.service" /etc/systemd/system/pteroq.service
        systemctl daemon-reload
        systemctl enable --now pteroq.service || log_warn "Could not immediately start pteroq.service."
    fi

    log_info "Configuring Laravel scheduler in /etc/cron.d/aquadactyl..."
    echo "* * * * * ${WEB_USER} cd ${PANEL_ROOT} && /usr/bin/php artisan schedule:run >> /dev/null 2>&1" > /etc/cron.d/aquadactyl
    chmod 0644 /etc/cron.d/aquadactyl

    # Step 11: Finalize & Cache
    finish_deployment

    # Disable maintenance mode
    artisan up
    MAINTENANCE_ENABLED=0

    # Step 12: Administrative user creation
    echo ""
    echo "================================================================================"
    log_ok "Aquadactyl installation completed successfully!"
    echo "================================================================================"
    if [[ "${NON_INTERACTIVE}" != "1" && "${NON_INTERACTIVE}" != "true" && -t 0 ]]; then
        echo ""
        log_info "Prompting to create the primary administrator account..."
        artisan p:user:make
    else
        echo "  To create the administrator account, run:"
        echo "    sudo -u ${WEB_USER} php ${PANEL_ROOT}/artisan p:user:make"
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

    log_info "Beginning Aquadactyl update process..."
    preflight

    WORK="$(mktemp -d -t aquadactyl-update-XXXXXX)"
    chmod 0700 "${WORK}"

    if [[ "${mode}" == "release" ]]; then
        log_info "Fetching release '${release_tag}' from '${repo_owner}'..."
        local tarball_url="https://github.com/${repo_owner}/releases/download/${release_tag}/panel.tar.gz"
        local checksums_url="https://github.com/${repo_owner}/releases/download/${release_tag}/SHA256SUMS"

        curl -fSL "${tarball_url}" -o "${WORK}/panel.tar.gz" || {
            log_fatal "Failed to download panel archive from: ${tarball_url}"
            exit "${EX_GENERAL}"
        }

        curl -fSL "${checksums_url}" -o "${WORK}/SHA256SUMS" || {
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

    log_info "Verifying SHA256 digest..."
    local actual_hash
    actual_hash="$(sha256sum "${WORK}/panel.tar.gz" | awk '{print $1}')"
    if [[ "${actual_hash}" != "${expected_hash}" ]]; then
        log_fatal "Checksum mismatch! Expected: ${expected_hash}, Calculated: ${actual_hash}"
        exit "${EX_DATAERR}"
    fi
    log_ok "Checksum verified (${actual_hash})."

    log_info "Auditing archive structure..."
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
    tar -xzf "${WORK}/panel.tar.gz" --no-same-owner --no-same-permissions -C "${WORK}/release"

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

    # Extension inventory pre-flight
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

    # Backup Creation
    log_info "Creating snapshot backup..."
    BACKUP_DIR="$(realpath -m "${BACKUP_DIR}")"
    if [[ "${BACKUP_DIR}" == "${PANEL_ROOT}"* ]]; then
        log_fatal "BACKUP_DIR (${BACKUP_DIR}) cannot be located within PANEL_ROOT (${PANEL_ROOT})."
        exit "${EX_DATAERR}"
    fi

    mkdir -p "${BACKUP_DIR}"
    BACKUP="$(mktemp -d "${BACKUP_DIR}/$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")"
    chmod 0700 "${BACKUP}"

    artisan down --retry=60 || true
    MAINTENANCE_ENABLED=1

    if command -v systemctl >/dev/null 2>&1; then
        if systemctl is-active --quiet "${PTEROQ_SERVICE}"; then
            log_info "Stopping queue service: ${PTEROQ_SERVICE}..."
            systemctl stop "${PTEROQ_SERVICE}"
            PTEROQ_WAS_RUNNING=1
        fi
    fi

    log_info "Exporting database backup..."
    local db_dump_ok=0
    if artisan p:maintenance:backup-database "${BACKUP}/database.sql" 2>/dev/null; then
        db_dump_ok=1
    fi

    if [[ "${db_dump_ok}" -eq 0 ]]; then
        log_info "Falling back to direct mariadb-dump / mysqldump..."
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

        "${dump_tool}" --host="${db_host}" --port="${db_port}" --user="${db_user}" --password="${db_pass}" \
            --single-transaction --quick --routines "${db_name}" > "${BACKUP}/database.sql"
    fi

    if [[ ! -s "${BACKUP}/database.sql" ]]; then
        log_fatal "Database dump failed or produced an empty backup."
        exit "${EX_GENERAL}"
    fi

    log_info "Archiving panel filesystem..."
    tar --exclude='./node_modules' \
        --exclude='./.git' \
        --exclude='./storage/logs/*.log' \
        --exclude='./storage/framework/cache/data/*' \
        -czf "${BACKUP}/panel.tar.gz" -C "${PANEL_ROOT}" .

    chmod 0600 "${BACKUP}/database.sql" "${BACKUP}/panel.tar.gz"
    log_ok "Backup created at: ${BACKUP}"

    # Sync release files
    log_info "Synchronizing updated release files..."
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

    log_info "Migrating database..."
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

    build_frontend
    finish_deployment

    if [[ "${PTEROQ_WAS_RUNNING}" -eq 1 ]]; then
        log_info "Restarting background queue worker: ${PTEROQ_SERVICE}..."
        systemctl start "${PTEROQ_SERVICE}" || log_warn "Failed to start ${PTEROQ_SERVICE}."
    fi

    log_info "Bringing panel back online..."
    artisan up
    MAINTENANCE_ENABLED=0

    echo ""
    echo "================================================================================"
    log_ok "Aquadactyl update completed successfully!"
    echo "  Backup stored at: ${BACKUP}"
    echo "================================================================================"
}

# ------------------------------------------------------------------------------
# 8. CLI Usage & Entrypoint
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
