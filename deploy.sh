#!/usr/bin/env bash
# ==============================================================================
# Aquadactyl Standalone Deployment & Management Automation Tooling
# ------------------------------------------------------------------------------
# Combines common deployment library routines, initial installation, and
# zero-downtime updates with Blueprint preservation into a single file.
#
# Supported Usage Modes:
#   sudo bash deploy.sh install
#   sudo bash deploy.sh update <release-tag> [owner/repository]
#   sudo bash deploy.sh update --archive /path/to/panel.tar.gz <sha256-checksum>
# ==============================================================================

set -Eeuo pipefail

# ------------------------------------------------------------------------------
# 1. Configuration & Default Environment Variables
# ------------------------------------------------------------------------------
PANEL_ROOT="${PANEL_ROOT:-}"
if [[ -z "$PANEL_ROOT" ]]; then
    if [[ -f "./artisan" && -f "./composer.lock" ]]; then
        PANEL_ROOT="$(pwd)"
    elif [[ -f "../artisan" && -f "../composer.lock" ]]; then
        PANEL_ROOT="$(cd .. && pwd)"
    else
        PANEL_ROOT="/var/www/aquadactyl"
    fi
fi

WEB_USER="${WEB_USER:-www-data}"
WEB_GROUP="${WEB_GROUP:-www-data}"
PHP_FPM_SERVICE="${PHP_FPM_SERVICE:-}"
PTEROQ_SERVICE="${PTEROQ_SERVICE:-pteroq.service}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/aquadactyl}"
BLUEPRINT_ENVIRONMENT="${BLUEPRINT_ENVIRONMENT:-ci}"
NON_INTERACTIVE="${NON_INTERACTIVE:-0}"

# Internal state tracking
WORK=""
BACKUP=""
LOCK_FD=9
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

# Terminal styling helpers
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
    CLR_RESET="$(tput sgr0)"
    CLR_RED="$(tput setaf 1)"
    CLR_GREEN="$(tput setaf 2)"
    CLR_YELLOW="$(tput setaf 3)"
    CLR_BLUE="$(tput setaf 4)"
    CLR_BOLD="$(tput bold)"
else
    CLR_RESET=""
    CLR_RED=""
    CLR_GREEN=""
    CLR_YELLOW=""
    CLR_BLUE=""
    CLR_BOLD=""
fi

log_info()  { echo -e "${CLR_BLUE}[INFO]${CLR_RESET} $*"; }
log_ok()    { echo -e "${CLR_GREEN}[OK]${CLR_RESET} $*"; }
log_warn()  { echo -e "${CLR_YELLOW}[WARN]${CLR_RESET} $*" >&2; }
log_err()   { echo -e "${CLR_RED}[ERROR]${CLR_RESET} $*" >&2; }
log_fatal() { echo -e "${CLR_RED}${CLR_BOLD}[FATAL]${CLR_RESET} $*" >&2; }

# ------------------------------------------------------------------------------
# 2. Cleanup & Error Traps
# ------------------------------------------------------------------------------
cleanup_and_handle_failure() {
    local exit_code="$1"
    local line_no="$2"

    # Release file lock if descriptor exists
    if { true >&"${LOCK_FD}"; } 2>/dev/null; then
        flock -u "${LOCK_FD}" 2>/dev/null || true
        eval "exec ${LOCK_FD}>&-" 2>/dev/null || true
    fi

    # Clean up temporary work directory if created
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
                echo "    cat \"${PANEL_ROOT}/storage/logs/laravel.log\""
                echo ""
                echo "  To restore backup manually:"
                echo "    mysql -u root -p < \"${BACKUP}/database.sql\""
                echo "    tar -xzf \"${BACKUP}/panel.tar.gz\" -C \"${PANEL_ROOT}\""
            fi
            echo "================================================================================"
        fi
    fi

    exit "${exit_code}"
}

trap 'cleanup_and_handle_failure $? $LINENO' EXIT HUP INT QUIT TERM

# ------------------------------------------------------------------------------
# 3. Common Deployment Routines
# ------------------------------------------------------------------------------

semver_ge() {
    # Returns 0 if $1 >= $2
    local v1="$1"
    local v2="$2"
    if [[ "$v1" == "$v2" ]]; then
        return 0
    fi
    local lowest
    lowest="$(printf '%s\n%s\n' "$v1" "$v2" | sort -V | head -n1)"
    [[ "$lowest" == "$v2" ]]
}

detect_php_fpm() {
    if [[ -n "${PHP_FPM_SERVICE}" ]]; then
        return 0
    fi

    local php_version
    php_version="$(php -r 'echo PHP_MAJOR_VERSION . "." . PHP_MINOR_VERSION;' 2>/dev/null || echo "")"
    local candidates=(
        "php${php_version}-fpm"
        "php-fpm"
        "php-fpm.service"
        "php8.5-fpm"
        "php8.4-fpm"
    )

    if command -v systemctl >/dev/null 2>&1; then
        for cand in "${candidates[@]}"; do
            if systemctl list-unit-files "${cand}.service" 2>/dev/null | grep -q "${cand}"; then
                PHP_FPM_SERVICE="${cand}"
                log_info "Detected PHP-FPM service: ${PHP_FPM_SERVICE}"
                return 0
            fi
        done
    fi

    PHP_FPM_SERVICE="php-fpm"
    log_info "Defaulting PHP-FPM service to: ${PHP_FPM_SERVICE}"
}

preflight() {
    log_info "Running environment preflight checks..."

    # 1. Validate root privileges
    if [[ "${EUID}" -ne 0 ]]; then
        log_fatal "This script must be executed as root (e.g. using sudo)."
        exit "${EX_NOPERM}"
    fi

    # 2. Canonicalize and validate PANEL_ROOT path
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

    # 3. Validate existence of essential files
    local required_panel_files=("artisan" "composer.lock" ".env")
    for file in "${required_panel_files[@]}"; do
        if [[ ! -f "${PANEL_ROOT}/${file}" ]]; then
            log_fatal "Missing required panel file: ${PANEL_ROOT}/${file}"
            exit "${EX_NOINPUT}"
        fi
    done

    # 4. Check all required binaries
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

    # 5. Engine versions check
    # Check PHP version (8.4.x or 8.5.x)
    if ! php -r 'exit(PHP_VERSION_ID >= 80400 && PHP_VERSION_ID < 80600 ? 0 : 1);' 2>/dev/null; then
        local current_php
        current_php="$(php -r 'echo PHP_VERSION;' 2>/dev/null || echo 'unknown')"
        log_fatal "Unsupported PHP version (${current_php}). Aquadactyl requires PHP 8.4.x or 8.5.x."
        exit "${EX_UNAVAILABLE}"
    fi

    # Check Node.js version (>= 22.13.0)
    local node_ver
    node_ver="$(node -v 2>/dev/null | sed 's/^v//' || echo "0.0.0")"
    if ! semver_ge "${node_ver}" "22.13.0"; then
        log_fatal "Unsupported Node.js version (v${node_ver}). Minimum required is >= 22.13.0."
        exit "${EX_UNAVAILABLE}"
    fi

    # Check pnpm matches package.json pinned packageManager if present
    if [[ -f "${PANEL_ROOT}/package.json" ]]; then
        local pinned_pnpm
        pinned_pnpm="$(grep -oE '"packageManager":\s*"pnpm@[^"]+"' "${PANEL_ROOT}/package.json" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "")"
        if [[ -n "${pinned_pnpm}" ]]; then
            local current_pnpm
            current_pnpm="$(pnpm -v 2>/dev/null || echo "")"
            local pinned_major="${pinned_pnpm%%.*}"
            local current_major="${current_pnpm%%.*}"
            if [[ -n "${current_pnpm}" && "${current_major}" != "${pinned_major}" ]]; then
                log_warn "pnpm version mismatch: installed is ${current_pnpm}, package.json requests ${pinned_pnpm}."
            fi
        fi
    fi

    # 6. Verify web user and group exist
    if ! getent passwd "${WEB_USER}" >/dev/null 2>&1; then
        log_fatal "Configured WEB_USER '${WEB_USER}' does not exist on the host system."
        exit "${EX_UNAVAILABLE}"
    fi
    if ! getent group "${WEB_GROUP}" >/dev/null 2>&1; then
        log_fatal "Configured WEB_GROUP '${WEB_GROUP}' does not exist on the host system."
        exit "${EX_UNAVAILABLE}"
    fi

    # 7. Concurrency lock
    eval "exec ${LOCK_FD}>\"${PANEL_ROOT}/.panel-deploy.lock\""
    if ! flock -n "${LOCK_FD}"; then
        log_fatal "Another deployment or management process is active on ${PANEL_ROOT} (lock held on .panel-deploy.lock)."
        exit "${EX_TEMPFAIL}"
    fi
    chmod 0600 "${PANEL_ROOT}/.panel-deploy.lock" 2>/dev/null || true

    # 8. Switch CWD to panel root
    cd "${PANEL_ROOT}"
    log_ok "Preflight checks passed. Concurrency lock acquired."
}

artisan() {
    runuser -u "${WEB_USER}" -- php "${PANEL_ROOT}/artisan" "$@"
}

permissions() {
    log_info "Normalizing least-privilege filesystem permissions..."

    # 1. Base ownership
    chown -R "root:${WEB_GROUP}" "${PANEL_ROOT}"

    # 2. General permissions (excluding node_modules and .git)
    find "${PANEL_ROOT}" -mindepth 1 \
        \( -path "${PANEL_ROOT}/node_modules" -o -path "${PANEL_ROOT}/node_modules/*" \
           -o -path "${PANEL_ROOT}/.git" -o -path "${PANEL_ROOT}/.git/*" \) -prune \
        -o -type d -exec chmod 0750 {} + \
        -o -type f -exec chmod 0640 {} +

    # 3. Executable permissions
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

    # 4. Ensure required runtime storage and cache directories exist
    mkdir -p "${PANEL_ROOT}/storage/framework/cache/data" \
             "${PANEL_ROOT}/storage/framework/sessions" \
             "${PANEL_ROOT}/storage/framework/views" \
             "${PANEL_ROOT}/storage/logs" \
             "${PANEL_ROOT}/bootstrap/cache"

    # 5. Ownership for writable directories
    chown -R "${WEB_USER}:${WEB_GROUP}" "${PANEL_ROOT}/storage" "${PANEL_ROOT}/bootstrap/cache"

    # 6. Perms for writable directories
    find "${PANEL_ROOT}/storage" "${PANEL_ROOT}/bootstrap/cache" -type d -exec chmod 0750 {} +
    find "${PANEL_ROOT}/storage" "${PANEL_ROOT}/bootstrap/cache" -type f -exec chmod 0640 {} +

    # 7. Protect .env specifically
    if [[ -f "${PANEL_ROOT}/.env" ]]; then
        chown "root:${WEB_GROUP}" "${PANEL_ROOT}/.env"
        chmod 0640 "${PANEL_ROOT}/.env"
    fi

    log_ok "Permissions successfully updated."
}

dependencies() {
    log_info "Installing and verifying dependencies..."

    # 1. Clear cached manifests
    rm -f "${PANEL_ROOT}/bootstrap/cache/"{config,packages,services,events,routes-v7}.php

    # 2. PHP dependencies
    log_info "Running composer install..."
    COMPOSER_ALLOW_SUPERUSER=1 composer install \
        --no-dev \
        --prefer-dist \
        --no-interaction \
        --no-progress \
        --no-scripts \
        --optimize-autoloader

    COMPOSER_ALLOW_SUPERUSER=1 composer check-platform-reqs --no-dev

    # 3. Node/Frontend dependencies
    log_info "Running pnpm install..."
    pnpm install --frozen-lockfile

    # 4. Re-enforce permissions
    permissions

    # 5. Laravel package discovery
    log_info "Discovering packages..."
    artisan package:discover --ansi

    log_ok "Dependencies successfully synchronized."
}

initialize_blueprint() {
    log_info "Initializing Blueprint environment..."

    # 1. Remove stale installation flag
    rm -f "${PANEL_ROOT}/.blueprint/extensions/blueprint/private/db/is_installed" \
          "${PANEL_ROOT}/.blueprint/extensions/blueprint/private/db/version"

    # 2. Ensure .blueprintrc exists with normalized settings
    cat > "${PANEL_ROOT}/.blueprintrc" <<EOF
WEBUSER="${WEB_USER}"
OWNERSHIP="root:${WEB_GROUP}"
USERSHELL="/bin/bash"
EOF
    chown "root:${WEB_GROUP}" "${PANEL_ROOT}/.blueprintrc"
    chmod 0640 "${PANEL_ROOT}/.blueprintrc"

    # 3. Run initialization non-interactively
    if [[ ! -f "${PANEL_ROOT}/blueprint.sh" ]]; then
        log_fatal "blueprint.sh not found in panel root."
        exit "${EX_NOINPUT}"
    fi
    chmod 0750 "${PANEL_ROOT}/blueprint.sh"

    BLUEPRINT_ENVIRONMENT="${BLUEPRINT_ENVIRONMENT}" bash "${PANEL_ROOT}/blueprint.sh"

    # 4. Verify installation flag was created
    if [[ ! -f "${PANEL_ROOT}/.blueprint/extensions/blueprint/private/db/is_installed" ]]; then
        log_fatal "Blueprint initialization failed: is_installed flag was not generated."
        exit "${EX_GENERAL}"
    fi

    # 5. Normalize permissions and warm cache
    permissions
    artisan bp:cache

    log_ok "Blueprint initialized and cached."
}

finish_deployment() {
    log_info "Finalizing deployment..."

    permissions

    log_info "Warming Laravel production caches..."
    artisan config:cache
    artisan route:cache
    artisan view:cache
    artisan queue:restart

    detect_php_fpm
    if command -v systemctl >/dev/null 2>&1; then
        log_info "Reloading PHP-FPM service: ${PHP_FPM_SERVICE}..."
        systemctl reload "${PHP_FPM_SERVICE}" || {
            log_warn "Failed to reload ${PHP_FPM_SERVICE}. Attempting restart..."
            systemctl restart "${PHP_FPM_SERVICE}" || log_warn "Could not restart ${PHP_FPM_SERVICE}."
        }
    fi

    log_ok "Deployment finalized."
}

# ------------------------------------------------------------------------------
# 4. Installation Workflow
# ------------------------------------------------------------------------------
cmd_install() {
    log_info "Beginning Aquadactyl installation..."

    preflight

    # Safety Check: Blueprint not already installed
    if [[ -f "${PANEL_ROOT}/.blueprint/extensions/blueprint/private/db/is_installed" ]]; then
        log_fatal "Blueprint is already initialized in this installation."
        echo "Please use 'deploy.sh update' to update or manage this installation." >&2
        exit "${EX_DATAERR}"
    fi

    dependencies

    # Clear stale configs
    artisan config:clear || true
    artisan route:clear || true

    # Key & Salt generation
    log_info "Checking encryption keys and salts in .env..."
    local app_key
    app_key="$(grep -E '^APP_KEY=' "${PANEL_ROOT}/.env" | cut -d'=' -f2- || echo "")"
    if [[ -z "${app_key}" || "${app_key}" == "base64:" || "${app_key}" == "SomeRandomString" ]]; then
        log_info "Generating Laravel APP_KEY..."
        artisan key:generate --force
    fi

    local hashids_salt
    hashids_salt="$(grep -E '^HASHIDS_SALT=' "${PANEL_ROOT}/.env" | cut -d'=' -f2- || echo "")"
    if [[ -z "${hashids_salt}" ]]; then
        log_info "Generating HASHIDS_SALT..."
        local new_salt
        if command -v openssl >/dev/null 2>&1; then
            new_salt="$(openssl rand -hex 16)"
        else
            new_salt="$(head -c 16 /dev/urandom | sha256sum | head -c 32)"
        fi
        if grep -q "^HASHIDS_SALT=" "${PANEL_ROOT}/.env"; then
            sed -i "s/^HASHIDS_SALT=.*/HASHIDS_SALT=${new_salt}/" "${PANEL_ROOT}/.env"
        else
            echo "HASHIDS_SALT=${new_salt}" >> "${PANEL_ROOT}/.env"
        fi
    fi

    # Enable maintenance mode
    log_info "Enabling maintenance mode..."
    artisan down --retry=60
    MAINTENANCE_ENABLED=1

    # Migrate & seed
    log_info "Migrating database..."
    artisan migrate --force

    log_info "Seeding Blueprint database tables..."
    artisan db:seed --class=BlueprintSeeder --force

    # Blueprint initialization
    initialize_blueprint

    # Frontend build
    log_info "Building production frontend assets..."
    pnpm run build

    # Finalize
    finish_deployment

    # Disable maintenance mode
    log_info "Disabling maintenance mode..."
    artisan up
    MAINTENANCE_ENABLED=0

    echo ""
    echo "================================================================================"
    log_ok "Aquadactyl installation completed successfully!"
    echo "  To create the initial administrative user, execute:"
    echo "    php ${PANEL_ROOT}/artisan p:user:make"
    echo "================================================================================"
}

# ------------------------------------------------------------------------------
# 5. Update Workflow
# ------------------------------------------------------------------------------
cmd_update() {
    local mode=""
    local release_tag=""
    local repo_owner="Aquadactyl/aquadactyl"
    local archive_path=""
    local expected_hash=""

    # Parse arguments
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

    # 1. Prepare temporary workspace
    WORK="$(mktemp -d -t aquadactyl-update-XXXXXX)"
    chmod 0700 "${WORK}"

    # 2. Retrieve & Verify Archive
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

    # Checksum digest validation
    log_info "Verifying SHA256 digest..."
    local actual_hash
    actual_hash="$(sha256sum "${WORK}/panel.tar.gz" | awk '{print $1}')"
    if [[ "${actual_hash}" != "${expected_hash}" ]]; then
        log_fatal "Checksum mismatch! Expected: ${expected_hash}, Calculated: ${actual_hash}"
        exit "${EX_DATAERR}"
    fi
    log_ok "Checksum verified (${actual_hash})."

    # Security Audit of Archive Contents
    log_info "Auditing archive structure..."
    tar -tzf "${WORK}/panel.tar.gz" > "${WORK}/archive_index.txt"

    # Check for path traversal or absolute paths
    if grep -E '(^/|\.\./)' "${WORK}/archive_index.txt"; then
        log_fatal "Archive security audit failed: archive contains absolute paths or path traversal (../)."
        exit "${EX_DATAERR}"
    fi

    # Check for forbidden configuration files
    if grep -E '(^\./\.env$|^\.env$|^\./\.blueprintrc$|^\.blueprintrc$)' "${WORK}/archive_index.txt"; then
        log_fatal "Archive security audit failed: archive contains sensitive host configurations (.env / .blueprintrc)."
        exit "${EX_DATAERR}"
    fi

    # Check for illegal file types (block devices, character devices, FIFOs, sockets)
    # Using tar -tvzf output: 1st column file type must be '-' or 'd' or 'l'
    if tar -tvzf "${WORK}/panel.tar.gz" | grep -vE '^[dl-]' | grep -q .; then
        log_fatal "Archive security audit failed: archive contains forbidden file types (devices, sockets, or pipes)."
        exit "${EX_DATAERR}"
    fi

    # Unpack archive
    mkdir -p "${WORK}/release"
    tar -xzf "${WORK}/panel.tar.gz" --no-same-owner --no-same-permissions -C "${WORK}/release"

    # Verify critical release files
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

    # 3. Extension Inventory Pre-flight
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
                log_warn "Archive package for extension '${ext}' was not found in panel root or build directory."
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

    # 4. Backup Creation
    log_info "Creating snapshot backup..."
    BACKUP_DIR="$(realpath -m "${BACKUP_DIR}")"
    if [[ "${BACKUP_DIR}" == "${PANEL_ROOT}"* ]]; then
        log_fatal "BACKUP_DIR (${BACKUP_DIR}) cannot be located within PANEL_ROOT (${PANEL_ROOT})."
        exit "${EX_DATAERR}"
    fi

    mkdir -p "${BACKUP_DIR}"
    BACKUP="$(mktemp -d "${BACKUP_DIR}/$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")"
    chmod 0700 "${BACKUP}"

    # Check down state and enter maintenance mode
    if [[ -f "${PANEL_ROOT}/storage/framework/down" ]]; then
        log_warn "Application is already in maintenance mode."
    fi
    artisan down --retry=60
    MAINTENANCE_ENABLED=1

    # Pause background queue worker
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl is-active --quiet "${PTEROQ_SERVICE}"; then
            log_info "Stopping queue service: ${PTEROQ_SERVICE}..."
            systemctl stop "${PTEROQ_SERVICE}"
            PTEROQ_WAS_RUNNING=1
        fi
    fi

    # Database backup
    log_info "Exporting database backup..."
    local db_dump_ok=0
    if artisan p:maintenance:backup-database "${BACKUP}/database.sql" 2>/dev/null; then
        db_dump_ok=1
    fi

    if [[ "${db_dump_ok}" -eq 0 ]]; then
        log_info "Artisan internal backup command not found. Falling back to direct database dump..."
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

    # Snapshot panel files
    log_info "Archiving panel filesystem..."
    tar --exclude='./node_modules' \
        --exclude='./.git' \
        --exclude='./storage/logs/*.log' \
        --exclude='./storage/framework/cache/data/*' \
        -czf "${BACKUP}/panel.tar.gz" -C "${PANEL_ROOT}" .

    chmod 0600 "${BACKUP}/database.sql" "${BACKUP}/panel.tar.gz"
    log_ok "Backup created at: ${BACKUP}"

    # 5. Sync release files over PANEL_ROOT
    log_info "Synchronizing updated release files..."
    rsync -a --no-owner --no-group \
        --exclude='.env' \
        --exclude='.blueprintrc' \
        --exclude='storage/' \
        --exclude='bootstrap/cache/' \
        --exclude='.blueprint/dev/' \
        --exclude='.blueprint/tmp/' \
        --exclude='.blueprint/extensions/blueprint/private/db/' \
        --exclude='.blueprint/extensions/blueprint/private/debug/' \
        "${WORK}/release/" "${PANEL_ROOT}/"

    # Reinstall dependencies
    dependencies

    # Database migration & seed
    log_info "Running database migrations..."
    artisan migrate --force
    artisan db:seed --class=BlueprintSeeder --force

    # Re-initialize Blueprint
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
                bash "${PANEL_ROOT}/blueprint.sh" -bash -i "${ext_path}" || {
                    log_warn "Failed to reapply extension '${ext}'. Continuing..."
                }
            fi
        done
    fi

    # Compile frontend
    log_info "Compiling frontend assets..."
    pnpm run build

    # Finalize deployment
    finish_deployment

    # Restart background worker if it was running
    if [[ "${PTEROQ_WAS_RUNNING}" -eq 1 ]]; then
        log_info "Restarting background queue worker: ${PTEROQ_SERVICE}..."
        systemctl start "${PTEROQ_SERVICE}" || log_warn "Failed to start ${PTEROQ_SERVICE}."
    fi

    # Disable maintenance mode
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
# 6. Usage & CLI Dispatcher
# ------------------------------------------------------------------------------
usage() {
    cat <<EOF
Aquadactyl Deployment & Management Automation Tooling

Usage:
  sudo bash $(basename "$0") install
  sudo bash $(basename "$0") update <release-tag> [owner/repository]
  sudo bash $(basename "$0") update --archive /path/to/panel.tar.gz <sha256-checksum>
  sudo bash $(basename "$0") permissions
  sudo bash $(basename "$0") -h | --help

Commands:
  install             Initial setup of Aquadactyl after repository extraction and .env configuration.
  update              Safe, zero-downtime panel update preserving database and Blueprint extensions.
  permissions         Normalize least-privilege filesystem permissions across PANEL_ROOT.

Options:
  <release-tag>       GitHub release version tag starting with 'v' (e.g. v1.2.3).
  [owner/repository]  Optional GitHub repository slug (defaults to 'Aquadactyl/aquadactyl').
  --archive <file>    Path to local panel.tar.gz archive.
  <sha256-checksum>   Expected SHA256 checksum for the archive.

Environment Variables:
  PANEL_ROOT          Path to panel root (default: current directory or /var/www/aquadactyl)
  WEB_USER            Web server user (default: www-data)
  WEB_GROUP           Web server group (default: www-data)
  PHP_FPM_SERVICE     PHP-FPM service name to reload (default: auto-detected)
  PTEROQ_SERVICE      Queue worker service name (default: pteroq.service)
  BACKUP_DIR          Directory for update snapshots (default: /var/backups/aquadactyl)
  NON_INTERACTIVE     Set to 1 to skip interactive prompts

EOF
}

main() {
    if [[ $# -eq 0 ]]; then
        usage
        exit "${EX_USAGE}"
    fi

    local action="$1"
    shift

    case "${action}" in
        install)
            cmd_install "$@"
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
            log_fatal "Unknown command: ${action}"
            usage
            exit "${EX_USAGE}"
            ;;
    esac
}

main "$@"

