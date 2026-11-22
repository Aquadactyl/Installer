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
#   sudo bash deploy.sh update <vTag>   # Managed update with a maintenance window
#   sudo bash deploy.sh update --archive /path/to/panel.tar.gz <sha256>
#   sudo bash deploy.sh permissions     # Restore strict least-privilege permissions
#
# Fetch a reviewed installer release through Git before running it:
#   git clone --depth 1 --branch v1.5-beta https://github.com/Aquadactyl/Installer.git /opt/aquadactyl-installer
#   sudo bash /opt/aquadactyl-installer/deploy.sh install v1.3-beta
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
AQUAQ_SERVICE="${AQUAQ_SERVICE:-aquaq.service}"
PTEROQ_SERVICE="${PTEROQ_SERVICE:-pteroq.service}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/aquadactyl}"
BLUEPRINT_ENVIRONMENT="${BLUEPRINT_ENVIRONMENT:-ci}"
NON_INTERACTIVE="${NON_INTERACTIVE:-0}"
REPO_URL="${REPO_URL:-https://github.com/Aquadactyl/aquadactyl.git}"
DEFAULT_PINNED_PNPM="12.15.0"
RELEASE_TAG="${RELEASE_TAG:-v1.3-beta}"

# Internal tracking
WORK=""
BACKUP=""
LOCK_FD=9
LOCK_ACQUIRED=0
MAINTENANCE_ENABLED=0
AQUAQ_WAS_RUNNING=0
PTEROQ_WAS_RUNNING=0
BLUEPRINT_WAS_RUNNING=0

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
LOG_FILE=""
initialize_log() {
    # Never append privileged output to a predictable file in a shared directory.
    umask 077
    LOG_FILE="$(mktemp "${1:-/var/log}/aquadactyl-deploy-XXXXXXXX.log")"
    chmod 0600 "${LOG_FILE}"
}
run_silent() {
    local cmd_desc="${1:-Executing task}"
    shift

    # Clear task section in log
    echo "=== [$(date)] Starting: ${cmd_desc} ===" >> "${LOG_FILE}"

    # Execute command quietly in background with disconnected stdin to prevent hung prompts
    "$@" < /dev/null >> "${LOG_FILE}" 2>&1 &
    local cmd_pid=$!

    # Animated spinner frames
    local spin_chars=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local sc_idx=0
    local elapsed=0
    local tick=0

    # Hide cursor if supported
    if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
        tput civis 2>/dev/null || true
    fi

    while kill -0 "${cmd_pid}" 2>/dev/null; do
        if [[ -t 1 ]]; then
            local char="${spin_chars[sc_idx]}"
            printf "\r\033[K  ${CLR_BLUE}%s${CLR_RESET} %s... (%ds) " "${char}" "${cmd_desc}" "${elapsed}"
            sc_idx=$(( (sc_idx + 1) % ${#spin_chars[@]} ))
        fi
        sleep 0.1
        (( tick++ )) || true
        if (( tick % 10 == 0 )); then
            (( elapsed++ )) || true
        fi
    done

    # Restore cursor
    if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
        tput cnorm 2>/dev/null || true
    fi

    local err_code=0
    wait "${cmd_pid}" || err_code=$?

    if [[ "${err_code}" -eq 0 ]]; then
        if [[ -t 1 ]]; then
            printf "\r\033[K  ${CLR_GREEN}✓${CLR_RESET} %s (%ds) [Done]\n" "${cmd_desc}" "${elapsed}"
        else
            echo "  [OK] ${cmd_desc} (${elapsed}s)"
        fi
        return 0
    else
        if [[ -t 1 ]]; then
            printf "\r\033[K  ${CLR_RED}✗${CLR_RESET} %s (%ds) [Failed]\n" "${cmd_desc}" "${elapsed}"
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
        if [[ -n "${BACKUP:-}" && -d "${BACKUP}/panel" ]]; then
            log_info "Original unfinished checkout remains at ${BACKUP}/panel. Configuration and uploads are retained there."
        fi
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
                [[ ! -f "${BACKUP}/database.sql" ]] || echo "    mariadb -u aquadactyl -p aquadactyl < \"${BACKUP}/database.sql\""
                [[ ! -f "${BACKUP}/panel.tar.gz" ]] || echo "    tar -xzf \"${BACKUP}/panel.tar.gz\" -C \"${PANEL_ROOT}\""
            fi
            echo "================================================================================"
        fi
    fi

    exit "${exit_code}"
}

trap 'cleanup_and_handle_failure $? $LINENO' EXIT
trap 'exit 130' HUP INT QUIT
trap 'exit 143' TERM

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

validate_release_tag() {
    [[ ${#1} -le 100 && "$1" =~ ^v(0|[1-9][0-9]*)(\.(0|[1-9][0-9]*)){0,2}(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$ ]] || {
        log_fatal "Use a versioned release tag, for example v1.3-beta."
        return "${EX_USAGE}"
    }
}

validate_panel_root() {
    PANEL_ROOT="$(realpath -m "${PANEL_ROOT}")"
    case "${PANEL_ROOT}" in
        /|/var|/var/www|/etc|/usr|/home|/root|/opt|/srv|/tmp)
            log_fatal "PANEL_ROOT must be a dedicated panel directory."
            return "${EX_DATAERR}"
            ;;
    esac
    [[ "${PANEL_ROOT}" =~ ^/[a-zA-Z0-9_./-]+$ ]] || return "${EX_DATAERR}"
}

set_env_value() {
    local key="$1" value="$2"
    [[ "${key}" =~ ^[A-Z_]+$ && "${value}" != *$'\n'* && "${value}" != *$'\r'* ]] || return "${EX_DATAERR}"
    # Quote dotenv values as data, including $, #, &, quotes and backslashes.
    ENV_KEY="${key}" ENV_VALUE="${value}" php -r '
        $path = ".env";
        $key = getenv("ENV_KEY");
        $value = "\"" . str_replace(["\\", "\"", "$"], ["\\\\", "\\\"", "\\$"], getenv("ENV_VALUE")) . "\"";
        $lines = file($path, FILE_IGNORE_NEW_LINES);
        $found = false;
        foreach ($lines as &$line) {
            if (str_starts_with($line, $key . "=")) { $line = $key . "=" . $value; $found = true; }
        }
        if (!$found) { $lines[] = $key . "=" . $value; }
        if (file_put_contents($path, implode("\n", $lines) . "\n") === false) { exit(1); }
    '
}

dotenv_value() {
    php -r 'require "vendor/autoload.php"; $values = Dotenv\Dotenv::parse(file_get_contents(".env")); echo $values[$argv[1]] ?? "";' "$1"
}

fetch_git_release() {
    local tag="$1" destination="$2"
    validate_release_tag "${tag}"
    git init --bare "${destination}/source.git" >/dev/null
    git -C "${destination}/source.git" remote add origin "${REPO_URL}"
    git -C "${destination}/source.git" fetch --depth=1 origin "refs/tags/${tag}:refs/tags/${tag}"
    git -C "${destination}/source.git" archive --format=tar.gz "refs/tags/${tag}" > "${destination}/panel.tar.gz"
    git -C "${destination}/source.git" rev-parse "refs/tags/${tag}^{commit}" > "${destination}/source-commit"
}

panel_source_version() {
    [[ -f "$1/config/app.php" ]] || return 0
    # Read the version as data; never execute an existing checkout's PHP.
    sed -nE "s/^[[:space:]]*['\"]version['\"][[:space:]]*=>[[:space:]]*['\"]([^'\"]*)['\"].*/\\1/p" "$1/config/app.php"
}

check_install_destination() {
    local tag="$1" refresh_source="$2" resume_install="${3:-0}" detected
    if [[ -f "${PANEL_ROOT}/.blueprint/extensions/blueprint/private/db/is_installed" || -s "${PANEL_ROOT}/.blueprint/extensions/blueprint/private/db/installed_extensions" ]]; then
        log_fatal "An initialized panel exists at ${PANEL_ROOT}. Use deploy.sh update ${tag}; installation recovery never replaces an initialized panel."
        return "${EX_DATAERR}"
    fi
    if [[ "${resume_install}" == 1 ]]; then
        if [[ "${refresh_source}" == 1 || ! -f "${PANEL_ROOT}/artisan" || ! -f "${PANEL_ROOT}/.env" || ! -d "${PANEL_ROOT}/vendor" ]]; then
            log_fatal "--resume requires the matching unfinished checkout, its existing .env and installed dependencies; it cannot be combined with --refresh-source."
            return "${EX_DATAERR}"
        fi
    elif [[ -d "${PANEL_ROOT}/vendor" ]]; then
        log_fatal "Dependencies already exist at ${PANEL_ROOT}. For this unfinished installation only, repair its configuration and run: sudo bash deploy.sh install ${tag} --resume"
        log_info "Use update for a working panel. --refresh-source never replaces dependency-installed source."
        return "${EX_DATAERR}"
    fi
    [[ -f "${PANEL_ROOT}/artisan" ]] || return 0
    detected="$(panel_source_version "${PANEL_ROOT}")"
    if [[ "${detected}" != "${tag#v}" && "${refresh_source}" != 1 ]]; then
        log_fatal "Unfinished panel source at ${PANEL_ROOT} reports '${detected:-unknown}', not '${tag#v}'."
        log_info "For an unused checkout, run: sudo bash deploy.sh install ${tag} --refresh-source"
        log_info "This fetches the release first, then privately backs up the old directory and preserves configuration and uploads. No panel files were changed."
        return "${EX_DATAERR}"
    fi
}

verify_database_connection() {
    log_info "Checking the panel's configured database connection before migrations..."
    if php <<'PHP'
<?php
try {
    require 'vendor/autoload.php';
    $app = require 'bootstrap/app.php';
    $app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();
    $app->make('db')->connection()->select('SELECT 1');
    fwrite(STDOUT, "[OK] Panel database connection verified.\n");
} catch (Throwable $exception) {
    // Do not print credentials, connection URLs or arbitrary bootstrap errors.
    fwrite(STDERR, "[ERROR] The panel cannot connect using its saved database configuration.\n");
    fwrite(STDERR, "Verify the database endpoint, account host, password and grants. Existing database-account passwords are never reset automatically.\n");
    exit(69);
}
PHP
    then
        return 0
    fi
    log_info "Repair the saved configuration, then run: sudo bash deploy.sh install ${RELEASE_TAG} --resume"
    return "${EX_UNAVAILABLE}"
}

refresh_install_source() {
    local tag="$1" backup_root source_commit file
    check_install_destination "${tag}" 1 || return "$?"
    [[ -f "${PANEL_ROOT}/artisan" ]] || { log_fatal "Source recovery requires an unfinished panel checkout."; return "${EX_DATAERR}"; }
    backup_root="$(realpath -m "${BACKUP_DIR}")"
    case "${backup_root}/" in
        "${PANEL_ROOT}/"*) log_fatal "BACKUP_DIR must be outside PANEL_ROOT."; return "${EX_DATAERR}" ;;
    esac
    [[ -n "${WORK}" ]] || WORK="$(mktemp -d -t aquadactyl-install-XXXXXX)"
    # Do all network and version checks before moving the existing checkout.
    git -c advice.detachedHead=false clone --quiet --depth=1 --branch "${tag}" -- "${REPO_URL}" "${WORK}/release" || return "$?"
    for file in artisan composer.lock package.json blueprint.sh; do
        [[ -f "${WORK}/release/${file}" ]] || { log_fatal "Release is missing ${file}."; return "${EX_DATAERR}"; }
    done
    [[ "$(panel_source_version "${WORK}/release")" == "${tag#v}" ]] || {
        log_fatal "Fetched source does not report the requested release. Original files are unchanged."
        return "${EX_DATAERR}"
    }
    source_commit="$(git -C "${WORK}/release" rev-parse HEAD)" || return "$?"
    # Fetching may take time; recheck initialization immediately before moving.
    check_install_destination "${tag}" 1 || return "$?"
    mkdir -p "${backup_root}"
    BACKUP="$(mktemp -d "${backup_root}/preinstall-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")"
    chmod 0700 "${BACKUP}"
    mv -- "${PANEL_ROOT}" "${BACKUP}/panel"
    log_ok "Original unfinished checkout saved at ${BACKUP}/panel"
    mkdir -p "${PANEL_ROOT}"
    rsync -a --exclude='.git/' "${WORK}/release/" "${PANEL_ROOT}/"
    for file in .env .blueprintrc; do
        if [[ -e "${BACKUP}/panel/${file}" ]]; then
            cp --preserve=mode -- "${BACKUP}/panel/${file}" "${PANEL_ROOT}/${file}"
            chmod 0640 "${PANEL_ROOT}/${file}"
        fi
    done
    if [[ -d "${BACKUP}/panel/storage/app" ]]; then
        mkdir -p "${PANEL_ROOT}/storage/app"
        rsync -a -- "${BACKUP}/panel/storage/app/" "${PANEL_ROOT}/storage/app/"
    fi
    printf '%s\n' "${source_commit}" > "${PANEL_ROOT}/.installed-commit"
    chmod 0750 "${PANEL_ROOT}"
}

is_supported_os() {
    # Explicit releases only: an interim Ubuntu release is not an LTS release.
    local version="$2"
    [[ "$1" != debian ]] || version="${version%%.*}"
    case "$1:${version}" in
        debian:12|debian:13|ubuntu:22.04|ubuntu:24.04|ubuntu:26.04) return 0 ;;
        *) return 1 ;;
    esac
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

    if ! is_supported_os "${os_id}" "${os_version_id}"; then
        log_fatal "Unsupported operating system: ${os_id} ${os_version_id}."
        echo "Supported systems are:" >&2
        echo "  - Debian 12 (Bookworm) or Debian 13 (Trixie)" >&2
        echo "  - Ubuntu 22.04, 24.04 or 26.04 LTS" >&2
        echo "Use a supported host; this installer never upgrades the operating system." >&2
        exit "${EX_UNAVAILABLE}"
    fi

    log_ok "Operating system supported: ${os_id} ${os_version_id}"
}

host_runtimes_ready() {
    local diagnose="${1:-0}" bin node_version web_node_version detected
    for bin in php composer node npm pnpm git curl tar zip unzip rsync flock runuser sha256sum grep sed awk mktemp; do
        if ! command -v "$bin" >/dev/null 2>&1; then
            runtime_failure "${diagnose}" "Missing required command: ${bin}."; return 1
        fi
    done
    if ! php -r 'exit(PHP_VERSION_ID >= 80400 && PHP_VERSION_ID < 80600 ? 0 : 1);' 2>/dev/null; then
        detected="$(php -r 'echo PHP_VERSION;' 2>/dev/null || true)"
        runtime_failure "${diagnose}" "PHP CLI at $(command -v php) reports '${detected:-unavailable}'; PHP 8.4.x or 8.5.x is required. Check any manually selected PHP alternative or executable overriding /usr/bin/php."; return 1
    fi
    detected="$(composer --no-ansi --version 2>/dev/null || true)"
    if [[ ! "${detected}" =~ ^Composer[[:space:]]version[[:space:]]2\. ]]; then
        runtime_failure "${diagnose}" "Composer at $(command -v composer) reports '${detected:-unavailable}'; Composer 2 is required."; return 1
    fi
    node_version="$(node --version 2>/dev/null || true)"
    if [[ ! "${node_version}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || ! semver_ge "${node_version#v}" 24.22.1; then
        runtime_failure "${diagnose}" "Node.js at $(command -v node) reports '${node_version:-unavailable}'; >= 24.22.1 is required."; return 1
    fi
    detected="$(cd / && pnpm --version 2>/dev/null || true)"
    if [[ "${detected}" != "${DEFAULT_PINNED_PNPM}" ]]; then
        runtime_failure "${diagnose}" "pnpm at $(command -v pnpm) reports '${detected:-unavailable}'; ${DEFAULT_PINNED_PNPM} is required."; return 1
    fi
    # Check in a public directory so an operator's private working directory or
    # project packageManager setting cannot affect this runtime-only probe.
    web_node_version="$(cd / && runuser -u "${WEB_USER}" -- node --version 2>/dev/null || true)"
    if [[ ! "${web_node_version}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || ! semver_ge "${web_node_version#v}" 24.22.1; then
        runtime_failure "${diagnose}" "Node.js for ${WEB_USER} reports '${web_node_version:-unavailable}'; >= 24.22.1 is required for that user too. Check system PATH and public runtime permissions."; return 1
    fi
    detected="$(cd / && runuser -u "${WEB_USER}" -- pnpm --version 2>/dev/null || true)"
    if [[ "${detected}" != "${DEFAULT_PINNED_PNPM}" ]]; then
        runtime_failure "${diagnose}" "pnpm for ${WEB_USER} reports '${detected:-unavailable}'; ${DEFAULT_PINNED_PNPM} is required. Check that pnpm and its Node executable are outside private home directories."; return 1
    fi
}

runtime_failure() {
    [[ "$1" != 1 ]] || log_err "$2"
    return 0
}

prefer_system_tools() {
    # Never load an operator's NVM shell code in a privileged installer. Queue
    # and web processes need public binaries, independent of login-shell state.
    local system_path=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    case "${PATH}" in
        "${system_path}"|"${system_path}:"*) ;;
        *) export PATH="${system_path}:${PATH}" ;;
    esac
    hash -r
}

install_pinned_pnpm() {
    # Public runtime files must be usable by the unprivileged web/queue user.
    # Keep the caller's restrictive umask for logs, backups and configuration.
    # An operator's .npmrc may set a private global prefix. Use a dedicated
    # public prefix without changing their npm configuration or other packages.
    (
        umask 022
        npm install --global --prefix /usr/local/lib/aquadactyl-tools "pnpm@$1" || exit "$?"
        ln -sfn /usr/local/lib/aquadactyl-tools/bin/pnpm /usr/local/bin/pnpm
    )
}

enforce_root_and_utf8() {
    # 1. Enforce root execution
    if [[ "${EUID}" -ne 0 ]]; then
        log_fatal "This script must be executed as root (e.g. 'sudo bash $0' or as root user)."
        exit "${EX_NOPERM}"
    fi

    # 2. Enforce UTF-8 & non-interactive package handling
    export LC_ALL="C.UTF-8"
    export LANG="C.UTF-8"
    export DEBIAN_FRONTEND="noninteractive"
    export NEEDRESTART_MODE="a"

    prefer_system_tools
    validate_panel_root
}

ensure_apt_unlocked() {
    # APT waits for its own lock. Killing package managers or unlinking their
    # lock files can corrupt a host being updated by unattended-upgrades.
    [[ -n "${WORK}" ]] || WORK="$(mktemp -d -t aquadactyl-host-XXXXXX)"
    export APT_CONFIG="${WORK}/apt.conf"
    printf 'DPkg::Lock::Timeout "300";\n' > "${APT_CONFIG}"
}

refresh_apt_indexes() {
    local description="${1:-apt-get update}" exit_code
    # APT otherwise reports some signature/network failures as warnings and may
    # continue with old indexes. Require every configured repository to refresh.
    if run_silent "${description}" apt-get -o Acquire::Retries=3 -o APT::Update::Error-Mode=any update; then
        return 0
    else
        exit_code=$?
    fi
    log_err "APT could not refresh all configured host repositories. Package provisioning has stopped."
    log_info "Repair the failing repository URLs or signing keys, then verify 'sudo apt-get -o APT::Update::Error-Mode=any update' succeeds before retrying."
    log_info "Repository definitions are in /etc/apt/sources.list and /etc/apt/sources.list.d/*.list or *.sources."
    log_info "Repository definitions and signing keys have not been changed by this failed refresh."
    log_info "Do not use trusted=yes, --allow-unauthenticated or insecure-repository options to bypass these errors."
    if [[ -f "${LOG_FILE}" ]] && grep -q 'downloads\.plex\.tv/repo/deb' "${LOG_FILE}"; then
        log_info "The legacy Plex repository has moved. Follow https://support.plex.tv/articles/235974187-enable-repository-updating-for-supported-linux-server-distributions/"
    fi
    if [[ -f "${LOG_FILE}" ]] && grep -q 'NO_PUBKEY\|EXPKEYSIG\|BADSIG' "${LOG_FILE}"; then
        log_info "APT reported a signing-key problem. Obtain the current key from that repository's vendor and retain signature verification."
    fi
    return "${exit_code}"
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

    # Match the panel's current engine floor.
    local node_ver
    node_ver="$(node -v 2>/dev/null | sed 's/^v//' || echo "0.0.0")"
    if ! semver_ge "${node_ver}" "24.22.1"; then
        log_fatal "Unsupported Node.js version (v${node_ver}). Minimum required is >= 24.22.1."
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
            install_pinned_pnpm "${pinned_pnpm}"
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
    local web_node_version
    web_node_version="$(cd / && runuser -u "${WEB_USER}" -- node --version 2>/dev/null || true)"
    if [[ ! "${web_node_version}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || ! semver_ge "${web_node_version#v}" 24.22.1; then
        log_fatal "Node.js for ${WEB_USER} reports '${web_node_version:-unavailable}'; >= 24.22.1 is required outside private root/NVM directories."
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
    chmod 0750 "${PANEL_ROOT}"

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

    # ExtensionFS holds addon data, never executable addon source. Preserve its
    # writable ownership just as Blueprint's own lifecycle command does.
    if [[ -d "${PANEL_ROOT}/.blueprint/extensions" ]]; then
        local extension_fs
        while IFS= read -r -d '' extension_fs; do
            chown -R "${WEB_USER}:${WEB_GROUP}" "${extension_fs}"
            find "${extension_fs}" -type d -exec chmod 0750 {} +
            find "${extension_fs}" -type f -exec chmod 0640 {} +
        done < <(find "${PANEL_ROOT}/.blueprint/extensions" -mindepth 2 -maxdepth 2 -type d -name fs -print0)
    fi

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

    # Generate defaults only for new installs. Updates retain custom CLI flags,
    # PHP-FPM service names and extension lifecycle configuration.
    if [[ ! -f "${PANEL_ROOT}/.blueprintrc" ]]; then
        cat > "${PANEL_ROOT}/.blueprintrc" <<EOF
WEBUSER="${WEB_USER}"
OWNERSHIP="root:${WEB_GROUP}"
USERSHELL="/bin/bash"
EOF
    fi
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

sync_cookie_and_url_security() {
    if [[ ! -f "${PANEL_ROOT}/.env" ]]; then
        return 0
    fi

    local app_url
    app_url="$(grep -E '^APP_URL=' "${PANEL_ROOT}/.env" | cut -d'=' -f2- | tr -d '"'"'" | tr -d '\r' || echo "http://localhost")"

    if [[ "${app_url}" =~ ^https:// ]]; then
        log_info "Configuring secure cookies for HTTPS (SESSION_SECURE_COOKIE=true)..."
        if grep -q "^SESSION_SECURE_COOKIE=" "${PANEL_ROOT}/.env"; then
            sed -i "s|^SESSION_SECURE_COOKIE=.*|SESSION_SECURE_COOKIE=true|" "${PANEL_ROOT}/.env"
        else
            echo "SESSION_SECURE_COOKIE=true" >> "${PANEL_ROOT}/.env"
        fi
    else
        log_info "Configuring cookies for plain HTTP (SESSION_SECURE_COOKIE=false)..."
        if grep -q "^SESSION_SECURE_COOKIE=" "${PANEL_ROOT}/.env"; then
            sed -i "s|^SESSION_SECURE_COOKIE=.*|SESSION_SECURE_COOKIE=false|" "${PANEL_ROOT}/.env"
        else
            echo "SESSION_SECURE_COOKIE=false" >> "${PANEL_ROOT}/.env"
        fi
    fi
}

configure_nginx() {
    if ! command -v nginx >/dev/null 2>&1 || [[ ! -d /etc/nginx/sites-available ]]; then
        return 0
    fi

    log_info "Configuring Nginx web server..."
    local app_url domain_name is_https=0
    app_url="$(grep -E '^APP_URL=' "${PANEL_ROOT}/.env" | cut -d'=' -f2- | tr -d '"'"'" | tr -d '\r' || echo "http://_")"
    [[ "${app_url}" =~ ^https:// ]] && is_https=1

    domain_name="$(echo "${app_url}" | sed -e 's|^[^/]*//||' -e 's|/.*$||' -e 's|:[0-9]*$||')"
    [[ "${domain_name}" =~ ^[a-zA-Z0-9.-]+$ ]] || { log_fatal "Invalid panel hostname."; exit "${EX_DATAERR}"; }
    [[ "${domain_name}" != panel.example.com ]] || { log_fatal "Configure your real APP_URL before installing."; exit "${EX_DATAERR}"; }

    local fpm_sock="/run/php/php${PHP_VERSION}-fpm.sock"
    [[ ! -e "${fpm_sock}" && -e "/run/php/php8.5-fpm.sock" ]] && fpm_sock="/run/php/php8.5-fpm.sock"
    [[ ! -e "${fpm_sock}" && -e "/run/php/php8.4-fpm.sock" ]] && fpm_sock="/run/php/php8.4-fpm.sock"

    local target_conf="/etc/nginx/sites-available/aquadactyl.conf"

    if [[ "${is_https}" -eq 1 ]]; then
        log_info "Setting up Nginx configuration for HTTPS (${domain_name})..."

        local ssl_cert="/etc/letsencrypt/live/${domain_name}/fullchain.pem"
        local ssl_key="/etc/letsencrypt/live/${domain_name}/privkey.pem"

        if [[ ! -f "${ssl_cert}" || ! -f "${ssl_key}" ]]; then
            ssl_cert="/etc/ssl/certs/aquadactyl.crt"
            ssl_key="/etc/ssl/private/aquadactyl.key"
            if [[ ! -f "${ssl_cert}" || ! -f "${ssl_key}" ]]; then
                log_info "Generating temporary SSL certificate for ${domain_name}..."
                mkdir -p /etc/ssl/certs /etc/ssl/private
                openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
                    -keyout "${ssl_key}" \
                    -out "${ssl_cert}" \
                    -subj "/CN=${domain_name}" >> "${LOG_FILE}" 2>&1 || true
                chmod 0600 "${ssl_key}" 2>/dev/null || true
            fi
        fi

        cat > "${target_conf}" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${domain_name};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${domain_name};

    root ${PANEL_ROOT}/public;
    index index.html index.htm index.php;
    charset utf-8;

    ssl_certificate ${ssl_cert};
    ssl_certificate_key ${ssl_key};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;

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
    else
        log_info "Setting up Nginx configuration for HTTP (${domain_name})..."
        cat > "${target_conf}" <<EOF
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

    # Disable default nginx site and enable aquadactyl
    rm -f /etc/nginx/sites-enabled/default
    ln -sf "${target_conf}" /etc/nginx/sites-enabled/aquadactyl.conf
    nginx -t >> "${LOG_FILE}" 2>&1
    systemctl reload nginx >> "${LOG_FILE}" 2>&1
}

finish_deployment() {
    log_info "Finalizing deployment and warming caches..."

    permissions

    sync_cookie_and_url_security

    log_info "Caching Laravel configuration, routes, and views..."
    run_silent "artisan config:cache" artisan config:cache
    run_silent "artisan route:cache" artisan route:cache
    run_silent "artisan view:cache" artisan view:cache
    run_silent "artisan queue:restart" artisan queue:restart

    detect_php_fpm
    if command -v systemctl >/dev/null 2>&1; then
        log_info "Reloading PHP-FPM service (${PHP_FPM_SERVICE})..."
        systemctl reload "${PHP_FPM_SERVICE}" >> "${LOG_FILE}" 2>&1 || systemctl restart "${PHP_FPM_SERVICE}" >> "${LOG_FILE}" 2>&1
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

    export DEBIAN_FRONTEND=noninteractive
    ensure_apt_unlocked

    log_info "Updating system packages and installing prerequisites..."
    refresh_apt_indexes || return "$?"
    run_silent "apt-get install base packages" apt-get -o Acquire::Retries=3 install -y lsb-release ca-certificates curl apt-transport-https gnupg

    local os_id
    os_id="$(. /etc/os-release && echo "${ID}")"
    if [[ "${os_id}" == ubuntu ]]; then
        run_silent "install repository tools" apt-get -o Acquire::Retries=3 install -y software-properties-common
        run_silent "add Ubuntu PHP repository" add-apt-repository -y ppa:ondrej/php
    else
        run_silent "download sury keyring" curl -fSsL -o "${WORK}/keyring.deb" https://packages.sury.org/debsuryorg-archive-keyring.deb
        run_silent "install sury keyring" dpkg -i "${WORK}/keyring.deb"
        printf 'deb [signed-by=/usr/share/keyrings/debsuryorg-archive-keyring.gpg] https://packages.sury.org/php/ %s main\n' "$(lsb_release -sc)" > /etc/apt/sources.list.d/php.list
    fi
    refresh_apt_indexes "apt-get update (PHP repository)" || return "$?"

    log_info "Installing PHP ${PHP_VERSION}, MariaDB, Nginx, Redis, zip, and system tools..."
    run_silent "apt-get install server stack" apt-get -o Acquire::Retries=3 install -y \
        "php${PHP_VERSION}" "php${PHP_VERSION}-cli" "php${PHP_VERSION}-fpm" "php${PHP_VERSION}-gd" \
        "php${PHP_VERSION}-mysql" "php${PHP_VERSION}-mbstring" "php${PHP_VERSION}-bcmath" \
        "php${PHP_VERSION}-xml" "php${PHP_VERSION}-curl" "php${PHP_VERSION}-zip" "php${PHP_VERSION}-posix" \
        "php${PHP_VERSION}-intl" "php${PHP_VERSION}-redis" \
        mariadb-server mariadb-client nginx redis-server cron git tar zip unzip rsync util-linux xz-utils certbot python3-certbot-nginx

    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable --now cron >> "${LOG_FILE}" 2>&1 || systemctl enable --now crond >> "${LOG_FILE}" 2>&1 || true
    fi

    # Install Composer 2 if not already present
    if ! command -v composer >/dev/null 2>&1 || ! composer --version 2>/dev/null | grep -q '^Composer version 2\.'; then
        log_info "Installing Composer 2..."
        local composer_checksum
        composer_checksum="$(curl -fSsL https://composer.github.io/installer.sig)"
        [[ "${composer_checksum}" =~ ^[a-f0-9]{96}$ ]] || exit "${EX_DATAERR}"
        curl -fSsL https://getcomposer.org/installer -o "${WORK}/composer-setup.php"
        [[ "$(sha384sum "${WORK}/composer-setup.php" | awk '{print $1}')" == "${composer_checksum}" ]] || {
            log_fatal "Composer installer checksum mismatch."
            exit "${EX_DATAERR}"
        }
        run_silent "install composer" php "${WORK}/composer-setup.php" --2 --install-dir=/usr/local/bin --filename=composer
    else
        log_ok "Composer is already installed ($(composer --version 2>/dev/null | head -n1)). Skipping."
    fi

    local existing_node_ver="0.0.0"
    if command -v node >/dev/null 2>&1; then existing_node_ver="$(node -v | sed 's/^v//')"; fi
    local web_node_ver
    web_node_ver="$(cd / && runuser -u "${WEB_USER}" -- node --version 2>/dev/null || true)"
    if ! semver_ge "${existing_node_ver}" "24.22.1" || [[ ! "${web_node_ver}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || ! semver_ge "${web_node_ver#v}" "24.22.1"; then
        local node_arch node_file node_dir
        case "$(uname -m)" in
            x86_64) node_arch=x64 ;;
            aarch64|arm64) node_arch=arm64 ;;
            *) log_fatal "Node automatic setup supports amd64 and arm64."; exit "${EX_UNAVAILABLE}" ;;
        esac
        [[ -n "${WORK}" ]] || WORK="$(mktemp -d -t aquadactyl-host-XXXXXX)"
        curl -fSsL https://nodejs.org/dist/latest-v24.x/SHASUMS256.txt -o "${WORK}/node-shasums"
        node_file="$(awk -v suffix="-linux-${node_arch}.tar.xz" 'substr($2,length($2)-length(suffix)+1)==suffix { print $2 }' "${WORK}/node-shasums")"
        [[ "${node_file}" =~ ^node-v24\.[0-9]+\.[0-9]+-linux-(x64|arm64)\.tar\.xz$ ]] || exit "${EX_DATAERR}"
        curl -fSsL "https://nodejs.org/dist/latest-v24.x/${node_file}" -o "${WORK}/${node_file}"
        (cd "${WORK}" && grep -F "  ${node_file}" node-shasums | sha256sum --check --status)
        node_dir="/usr/local/lib/nodejs/${node_file%.tar.xz}"
        # initialize_log sets umask 077; runtime directories must remain public.
        install -d -m 0755 /usr/local/lib/nodejs "${node_dir}"
        tar -xJf "${WORK}/${node_file}" --strip-components=1 -C "${node_dir}"
        for tool in node npm npx; do ln -sfn "${node_dir}/bin/${tool}" "/usr/local/bin/${tool}"; done
        export PATH="/usr/local/bin:${PATH}"
        hash -r
    fi

    # Check if pnpm is already installed matching pinned version
    local current_pnpm=""
    if command -v pnpm >/dev/null 2>&1; then
        current_pnpm="$(cd / && pnpm -v)"
    fi

    if [[ "${current_pnpm}" == "${DEFAULT_PINNED_PNPM}" ]] && [[ "$(cd / && runuser -u "${WEB_USER}" -- pnpm --version 2>/dev/null)" == "${DEFAULT_PINNED_PNPM}" ]]; then
        log_ok "pnpm@${current_pnpm} is already installed. Skipping pnpm installation."
    else
        log_info "Installing pinned pnpm@${DEFAULT_PINNED_PNPM}..."
        run_silent "install pnpm" install_pinned_pnpm "${DEFAULT_PINNED_PNPM}"
        hash -r
    fi

    log_ok "Host packages installed successfully."
}

# ------------------------------------------------------------------------------
# 6. Full Installation Workflow (Manual Install Docs Steps 2-11)
# ------------------------------------------------------------------------------
cmd_repair_database() {
    enforce_root_and_utf8
    check_install_destination "${RELEASE_TAG}" 0 1
    local installer_dir backup_root
    installer_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
    backup_root="$(realpath -m "${BACKUP_DIR}")"
    case "${backup_root}/" in
        "${PANEL_ROOT}/"*) log_fatal "BACKUP_DIR must be outside PANEL_ROOT."; return "${EX_DATAERR}" ;;
    esac
    log_info "Creating a dedicated account limited to the saved local panel database, with a private .env backup."
    php "${installer_dir}/scripts/repair-database.php" "${PANEL_ROOT}" "${backup_root}"
}

cmd_install() {
    echo -e "${CLR_CYAN}${CLR_BOLD}=== Aquadactyl Panel Full Automated Installation ===${CLR_RESET}"

    enforce_root_and_utf8
    local refresh_source=0 resume_install=0 tag_seen=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --refresh-source) refresh_source=1 ;;
            --resume) resume_install=1 ;;
            v*)
                [[ "${tag_seen}" == 0 ]] || { log_fatal "Supply one release tag."; exit "${EX_USAGE}"; }
                RELEASE_TAG="$1"; tag_seen=1 ;;
            *) log_fatal "Usage: deploy.sh install [v1.3-beta] [--refresh-source | --resume]"; exit "${EX_USAGE}" ;;
        esac
        shift
    done
    validate_release_tag "${RELEASE_TAG}"
    # Always reject unsupported hosts before package provisioning, moving an
    # unfinished checkout or changing its .env, even if runtimes already exist.
    validate_os
    check_install_destination "${RELEASE_TAG}" "${refresh_source}" "${resume_install}"

    TOTAL_STEPS=10
    CURRENT_STEP=0

    # Step 1: System Prerequisites
    if ! host_runtimes_ready; then
        show_progress "Installing Host Prerequisites & Build Tools"
        cmd_setup_host
    else
        show_progress "Checking Host Prerequisites"
        log_ok "Required host tools and runtime versions verified."
    fi
    if ! host_runtimes_ready 1; then
        log_fatal "Required runtimes are still unavailable after host setup. Check PHP CLI, Composer 2, Node.js >= 24.22.1 and pnpm ${DEFAULT_PINNED_PNPM}."
        exit "${EX_UNAVAILABLE}"
    fi

    # Step 2: Clone panel repository
    show_progress "Setting up Panel Filesystem"
    if [[ "${refresh_source}" == 1 && -f "${PANEL_ROOT}/artisan" ]]; then
        refresh_install_source "${RELEASE_TAG}"
    fi
    if [[ ! -d "${PANEL_ROOT}" || ! -f "${PANEL_ROOT}/artisan" ]]; then
        log_info "Preparing panel directory at ${PANEL_ROOT}..."
        mkdir -p "${PANEL_ROOT}"
        if [[ -z "$(ls -A "${PANEL_ROOT}")" ]]; then
            run_silent "cloning release ${RELEASE_TAG}" git clone --depth=1 --branch "${RELEASE_TAG}" -- "${REPO_URL}" "${PANEL_ROOT}"
        elif [[ -f "${PANEL_ROOT}/.env" && -z "$(find "${PANEL_ROOT}" -mindepth 1 -maxdepth 1 ! -name .env -print -quit)" ]]; then
            WORK="$(mktemp -d -t aquadactyl-install-XXXXXX)"
            run_silent "cloning release ${RELEASE_TAG}" git clone --depth=1 --branch "${RELEASE_TAG}" -- "${REPO_URL}" "${WORK}/release"
            rsync -a --exclude='.git/' --exclude='.env' "${WORK}/release/" "${PANEL_ROOT}/"
            git -C "${WORK}/release" rev-parse HEAD > "${PANEL_ROOT}/.installed-commit"
        else
            log_fatal "${PANEL_ROOT} exists and is not empty, but does not contain a valid Aquadactyl repository."
            exit "${EX_DATAERR}"
        fi
    fi

    cd "${PANEL_ROOT}"

    if [[ "$(panel_source_version "${PANEL_ROOT}")" != "${RELEASE_TAG#v}" ]]; then
        log_fatal "Fetched source does not match ${RELEASE_TAG}. Original configuration has been preserved."
        exit "${EX_DATAERR}"
    fi

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
    if [[ "${resume_install}" != 1 && "${NON_INTERACTIVE}" != "1" && "${NON_INTERACTIVE}" != "true" ]]; then
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
                [[ "${input_url}" =~ ^https?://[a-zA-Z0-9.-]+(:[0-9]+)?/?$ ]] || { log_fatal "Enter a valid HTTP(S) panel origin."; exit "${EX_DATAERR}"; }
                set_env_value APP_URL "${input_url}"

                read -rp "Enter Database Name [panel]: " input_dbname < /dev/tty
                input_dbname="${input_dbname:-panel}"
                set_env_value DB_DATABASE "${input_dbname}"

                read -rp "Enter Database User [aquadactyl]: " input_dbuser < /dev/tty
                input_dbuser="${input_dbuser:-aquadactyl}"
                set_env_value DB_USERNAME "${input_dbuser}"

                read -rsp "Enter Database Password (leave empty to auto-generate): " input_dbpass < /dev/tty
                echo ""
                if [[ -n "${input_dbpass}" ]]; then
                    set_env_value DB_PASSWORD "${input_dbpass}"
                fi
            else
                read -rp "Enter Panel Domain/URL [https://panel.example.com]: " input_url
                input_url="${input_url:-https://panel.example.com}"
                [[ "${input_url}" =~ ^https?://[a-zA-Z0-9.-]+(:[0-9]+)?/?$ ]] || { log_fatal "Enter a valid HTTP(S) panel origin."; exit "${EX_DATAERR}"; }
                set_env_value APP_URL "${input_url}"

                read -rp "Enter Database Name [panel]: " input_dbname
                input_dbname="${input_dbname:-panel}"
                set_env_value DB_DATABASE "${input_dbname}"

                read -rp "Enter Database User [aquadactyl]: " input_dbuser
                input_dbuser="${input_dbuser:-aquadactyl}"
                set_env_value DB_USERNAME "${input_dbuser}"

                read -rsp "Enter Database Password (leave empty to auto-generate): " input_dbpass
                echo ""
                if [[ -n "${input_dbpass}" ]]; then
                    set_env_value DB_PASSWORD "${input_dbpass}"
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
    if [[ "${resume_install}" != 1 && ( "${db_host}" == "localhost" || -z "${db_host}" ) ]]; then
        sed -i "s|^DB_HOST=.*|DB_HOST=127.0.0.1|" .env
        db_host="127.0.0.1"
    fi

    # If DB password is empty or default, generate a secure random one
    if [[ "${resume_install}" != 1 && ( -z "${db_pass}" || "${db_pass}" == "your_secure_password" || "${db_pass}" == "secret" ) ]]; then
        db_pass="$(head -c 16 /dev/urandom | sha256sum | head -c 24)"
        if grep -q "^DB_PASSWORD=" .env; then
            sed -i "s|^DB_PASSWORD=.*|DB_PASSWORD=${db_pass}|" .env
        else
            echo "DB_PASSWORD=${db_pass}" >> .env
        fi
    fi

    # Synchronize session cookie security based on APP_URL protocol (http vs https)
    sync_cookie_and_url_security

    # Ensure MariaDB server is running
    if command -v systemctl >/dev/null 2>&1; then
        systemctl start mariadb >> "${LOG_FILE}" 2>&1 || systemctl start mysql >> "${LOG_FILE}" 2>&1 || true
    fi

    # Re-read resolved DB parameters from .env
    db_name="$(grep -E '^DB_DATABASE=' .env | cut -d'=' -f2- | tr -d '"'"'" | tr -d '\r' || echo "panel")"
    db_user="$(grep -E '^DB_USERNAME=' .env | cut -d'=' -f2- | tr -d '"'"'" | tr -d '\r' || echo "aquadactyl")"
    db_pass="$(grep -E '^DB_PASSWORD=' .env | cut -d'=' -f2- | tr -d '"'"'" | tr -d '\r' || echo "")"

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

    # Provision only a local database. Never drop existing users, grant remote
    # access, or interpolate unvalidated identifiers into SQL.
    db_name="$(dotenv_value DB_DATABASE)"
    db_user="$(dotenv_value DB_USERNAME)"
    db_pass="$(dotenv_value DB_PASSWORD)"
    db_host="$(dotenv_value DB_HOST)"
    local db_client=""
    if command -v mariadb >/dev/null 2>&1; then
        db_client="mariadb"
    elif command -v mysql >/dev/null 2>&1; then
        db_client="mysql"
    fi

    if [[ -n "${db_client}" && "${db_host}" == "127.0.0.1" ]]; then
        [[ "${db_name}" =~ ^[a-zA-Z0-9_]+$ && "${db_user}" =~ ^[a-zA-Z0-9_]+$ ]] || {
            log_fatal "Local database name and user may contain only letters, digits and underscores."
            exit "${EX_DATAERR}"
        }
        local sql_password
        sql_password="${db_pass//\\/\\\\}"
        sql_password="${sql_password//\'/\'\'}"
        # Pass SQL over stdin so a database password never appears in process arguments.
        "${db_client}" -u root >> "${LOG_FILE}" 2>&1 <<SQL
            CREATE DATABASE IF NOT EXISTS \`${db_name}\`;
            CREATE USER IF NOT EXISTS '${db_user}'@'127.0.0.1' IDENTIFIED BY '${sql_password}';
            GRANT ALL PRIVILEGES ON \`${db_name}\`.* TO '${db_user}'@'127.0.0.1';
SQL
    fi

    verify_database_connection

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
    show_progress "Configuring Permissions & Services (aquaq/cron/nginx)"
    permissions

    # Configure Nginx site according to HTTP/HTTPS protocol
    configure_nginx

    # Clean up legacy pteroq service if migrating from upstream Pterodactyl
    if systemctl is-active --quiet pteroq.service 2>/dev/null; then
        systemctl stop pteroq.service >> "${LOG_FILE}" 2>&1 || true
    fi
    if systemctl list-unit-files pteroq.service 2>/dev/null | grep -q "pteroq.service"; then
        systemctl disable pteroq.service >> "${LOG_FILE}" 2>&1 || true
    fi
    rm -f /etc/systemd/system/pteroq.service

    if [[ -f "${PANEL_ROOT}/deploy/systemd/aquaq.service" ]]; then
        cp "${PANEL_ROOT}/deploy/systemd/aquaq.service" /etc/systemd/system/aquaq.service
    elif [[ -f "${PANEL_ROOT}/deploy/systemd/pteroq.service" ]]; then
        cp "${PANEL_ROOT}/deploy/systemd/pteroq.service" /etc/systemd/system/aquaq.service
    else
        cat > /etc/systemd/system/aquaq.service <<EOF
[Unit]
Description=Aquadactyl Queue Worker
After=network-online.target mariadb.service redis-server.service
Wants=network-online.target

[Service]
User=${WEB_USER}
Group=${WEB_GROUP}
WorkingDirectory=${PANEL_ROOT}
ExecStart=$(command -v php || echo "/usr/bin/php") ${PANEL_ROOT}/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3 --timeout=120 --max-time=3600
Restart=always
RestartSec=5
TimeoutStopSec=180
KillSignal=SIGTERM
UMask=0027
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF
    fi
    run_silent "reload systemd" systemctl daemon-reload
    systemctl enable --now aquaq.service >> "${LOG_FILE}" 2>&1

    # Install standard Laravel / Pterodactyl cron schedule
    local php_bin
    php_bin="$(command -v php || echo "/usr/bin/php")"

    # Add directly into crontab for web user (matching Pterodactyl documentation)
    if command -v crontab >/dev/null 2>&1; then
        (crontab -u "${WEB_USER}" -l 2>/dev/null | grep -F -v "artisan schedule:run" || true; echo "* * * * * ${php_bin} ${PANEL_ROOT}/artisan schedule:run >> /dev/null 2>&1") | crontab -u "${WEB_USER}" - 2>/dev/null || true
        rm -f /etc/cron.d/aquadactyl
    else
        cat > /etc/cron.d/aquadactyl <<EOF
* * * * * ${WEB_USER} ${php_bin} ${PANEL_ROOT}/artisan schedule:run >> /dev/null 2>&1
EOF
        chmod 0644 /etc/cron.d/aquadactyl
    fi

    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable --now cron >> "${LOG_FILE}" 2>&1 || systemctl enable --now crond >> "${LOG_FILE}" 2>&1 || true
    fi

    # Step 10: Finalize & Cache
    show_progress "Finalizing Production Caches"
    finish_deployment

    artisan up >> "${LOG_FILE}" 2>&1
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
read_installed_blueprint_extensions() {
    local inventory_file="$1"
    local -n inventory_result="$2"
    local inventory_line identifier
    local inventory_records=() parsed_inventory=()
    local -A seen_identifiers=()

    if [[ ! -e "${inventory_file}" && ! -L "${inventory_file}" ]]; then
        inventory_result=()
        return 0
    fi
    if [[ ! -f "${inventory_file}" || -L "${inventory_file}" ]]; then
        log_fatal "Blueprint extension inventory must be a regular file."
        return "${EX_DATAERR}"
    fi

    while IFS= read -r inventory_line || [[ -n "${inventory_line}" ]]; do
        inventory_line="${inventory_line%$'\r'}"
        [[ -n "${inventory_line}" ]] || continue
        IFS=',' read -r -a inventory_records <<< "${inventory_line}"
        for identifier in "${inventory_records[@]}"; do
            # Blueprint stores |identifier, records. Also accept older plain
            # identifiers, but never strip embedded/repeated marker characters.
            identifier="${identifier#|}"
            if [[ ! "${identifier}" =~ ^[a-zA-Z0-9_-]+$ || "${identifier}" == blueprint ]]; then
                log_fatal "Invalid installed extension identifier in Blueprint inventory."
                return "${EX_DATAERR}"
            fi
            if [[ ! -v "seen_identifiers[${identifier}]" ]]; then
                seen_identifiers["${identifier}"]=1
                parsed_inventory+=("${identifier}")
            fi
        done
    done < "${inventory_file}" || return "${EX_DATAERR}"

    inventory_result=("${parsed_inventory[@]}")
}

reapply_blueprint_extension() (
    local identifier="$1" source_package staged_package="" status=0
    trap 'if [[ -n "${staged_package}" ]]; then rm -f -- "${staged_package}"; fi' EXIT
    [[ "${identifier}" =~ ^[a-zA-Z0-9_-]+$ && "${identifier}" != blueprint ]] || exit "${EX_DATAERR}"

    if [[ -f "${PANEL_ROOT}/${identifier}.blueprint" ]]; then
        source_package="${PANEL_ROOT}/${identifier}.blueprint"
    elif [[ -f "${PANEL_ROOT}/.blueprint/extensions/${identifier}/build/${identifier}.blueprint" ]]; then
        source_package="${PANEL_ROOT}/.blueprint/extensions/${identifier}/build/${identifier}.blueprint"
    else
        log_fatal "Package for ${identifier} is no longer available; stopping addon reapplication."
        exit "${EX_NOINPUT}"
    fi

    # Blueprint requires a basename: its import guard rejects absolute paths,
    # and its extractor cannot handle nested package paths either. Use a private
    # root-level copy for either source location and always remove that copy.
    staged_package="$(mktemp --tmpdir="${PANEL_ROOT}" --suffix=.blueprint "${identifier}-reapply-XXXXXXXX")" || exit "$?"
    cp -- "${source_package}" "${staged_package}" || exit "$?"
    cd -- "${PANEL_ROOT}" || exit "$?"
    bash "${PANEL_ROOT}/blueprint.sh" -bash -i "${staged_package##*/}" || status=$?
    exit "${status}"
)

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
                mode="git"
                release_tag="$1"
                validate_release_tag "${release_tag}"
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
    if [[ "${mode}" == "git" ]]; then
        validate_release_tag "${release_tag}"
        [[ "${repo_owner}" =~ ^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$ ]] || exit "${EX_USAGE}"
        if [[ "${repo_owner}" != Aquadactyl/aquadactyl ]]; then
            REPO_URL="https://github.com/${repo_owner}.git"
        fi
        run_silent "fetch Git release ${release_tag}" fetch_git_release "${release_tag}" "${WORK}"
        expected_hash="$(sha256sum "${WORK}/panel.tar.gz" | awk '{print $1}')"
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
        ".blueprint/extensions/blueprint/private/extensionfs.php"
    )
    for crf in "${required_release_files[@]}"; do
        if [[ ! -e "${WORK}/release/${crf}" ]]; then
            log_fatal "Archive is missing critical panel component: ${crf}"
            exit "${EX_DATAERR}"
        fi
    done

    if [[ -f "${WORK}/source-commit" ]]; then
        cp "${WORK}/source-commit" "${WORK}/release/.installed-commit"
    fi

    # Step 4: Extension Inventory Pre-flight
    show_progress "Auditing Installed Blueprint Extensions"
    local installed_ext_file="${PANEL_ROOT}/.blueprint/extensions/blueprint/private/db/installed_extensions"
    local extensions=()
    read_installed_blueprint_extensions "${installed_ext_file}" extensions || return "$?"

    if [[ ${#extensions[@]} -gt 0 ]]; then
        log_info "Detected installed Blueprint extensions: ${extensions[*]}"
        for ext in "${extensions[@]}"; do
            local found=0
            if [[ -f "${PANEL_ROOT}/${ext}.blueprint" || -f "${PANEL_ROOT}/.blueprint/extensions/${ext}/build/${ext}.blueprint" ]]; then
                found=1
            fi
            if [[ "${found}" -eq 0 ]]; then
                log_fatal "Keep ${ext}.blueprint in the panel root before updating. No panel files have been replaced."
                exit "${EX_NOINPUT}"
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

    artisan down --retry=60 >> "${LOG_FILE}" 2>&1
    MAINTENANCE_ENABLED=1

    if command -v systemctl >/dev/null 2>&1; then
        if systemctl is-active --quiet aquadactyl-blueprint-installer.service; then
            systemctl stop aquadactyl-blueprint-installer.service >> "${LOG_FILE}" 2>&1
            BLUEPRINT_WAS_RUNNING=1
        fi
        if systemctl is-active --quiet "${AQUAQ_SERVICE}"; then
            systemctl stop "${AQUAQ_SERVICE}" >> "${LOG_FILE}" 2>&1
            AQUAQ_WAS_RUNNING=1
        fi
        if systemctl is-active --quiet "${PTEROQ_SERVICE}"; then
            systemctl stop "${PTEROQ_SERVICE}" >> "${LOG_FILE}" 2>&1
            PTEROQ_WAS_RUNNING=1
        fi
    fi

    # The snapshot directory is root-only. Run this bounded maintenance command
    # as the deployment owner rather than making secrets readable to the web user.
    run_silent "database backup" php "${PANEL_ROOT}/artisan" p:maintenance:backup-database "${BACKUP}/database.sql"

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
    run_silent "rsync release files" rsync -a --delete --no-owner --no-group \
        --exclude='.git/' --exclude='.panel-deploy.lock' \
        --exclude='vendor/' --exclude='node_modules/' --exclude='*.blueprint' \
        --include='.blueprint/extensions/blueprint/' --exclude='.blueprint/extensions/*/' \
        --exclude='public/extensions/' \
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
            log_info "Reapplying Blueprint extension: ${ext}..."
            run_silent "reapply extension ${ext}" reapply_blueprint_extension "${ext}"
        done
    fi

    # Step 8: Build Frontend & Bring Online
    show_progress "Building Frontend & Finalizing Deployment"
    build_frontend
    finish_deployment

    [[ "${AQUAQ_WAS_RUNNING}" -ne 1 ]] || systemctl start "${AQUAQ_SERVICE}" >> "${LOG_FILE}" 2>&1
    [[ "${PTEROQ_WAS_RUNNING}" -ne 1 ]] || systemctl start "${PTEROQ_SERVICE}" >> "${LOG_FILE}" 2>&1
    [[ "${BLUEPRINT_WAS_RUNNING}" -ne 1 ]] || systemctl start aquadactyl-blueprint-installer.service >> "${LOG_FILE}" 2>&1

    artisan up >> "${LOG_FILE}" 2>&1
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
        for svc in "${AQUAQ_SERVICE}" "${PTEROQ_SERVICE}"; do
            if systemctl is-active --quiet "${svc}" 2>/dev/null; then
                run_silent "stop ${svc}" systemctl stop "${svc}"
            fi
            if systemctl list-unit-files "${svc}" 2>/dev/null | grep -q "${svc}"; then
                systemctl disable "${svc}" >> "${LOG_FILE}" 2>&1 || true
            fi
            rm -f "/etc/systemd/system/${svc}"
        done
        run_silent "reload systemd" systemctl daemon-reload
    fi
    rm -f /etc/cron.d/aquadactyl
    if command -v crontab >/dev/null 2>&1; then
        (crontab -u "${WEB_USER}" -l 2>/dev/null | grep -F -v "artisan schedule:run" || true) | crontab -u "${WEB_USER}" - 2>/dev/null || true
    fi

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
        if command -v systemctl >/dev/null 2>&1; then
            if ! systemctl is-active --quiet mariadb 2>/dev/null && ! systemctl is-active --quiet mysql 2>/dev/null; then
                systemctl start mariadb 2>/dev/null || systemctl start mysql 2>/dev/null || true
            fi
        fi
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
        log_info "Releasing any lingering package locks..."
        ensure_apt_unlocked

        log_info "Stopping database and web server daemons..."
        if command -v systemctl >/dev/null 2>&1; then
            systemctl stop nginx redis-server mariadb mysql "php${PHP_VERSION}-fpm" php-fpm 2>/dev/null || true
        fi

        # Preseed debconf so MariaDB/MySQL removal never blocks waiting for confirmation
        if command -v debconf-set-selections >/dev/null 2>&1; then
            debconf-set-selections <<EOF 2>/dev/null || true
mariadb-server/really_remove_database boolean true
mariadb-server-10.11/really_remove_database boolean true
mariadb-server-10.5/really_remove_database boolean true
mariadb-server-10.6/really_remove_database boolean true
mysql-server/really_remove_database boolean true
EOF
        fi

        # Dynamically discover installed packages to prevent apt erroring on uninstalled packages
        local pkgs_to_purge=()
        for p in mariadb-server mariadb-client mariadb-common redis-server nginx nginx-common certbot python3-certbot-nginx; do
            if dpkg -s "${p}" >/dev/null 2>&1; then
                pkgs_to_purge+=("${p}")
            fi
        done
        while IFS= read -r p; do
            [[ -n "${p}" ]] && pkgs_to_purge+=("${p}")
        done < <(dpkg-query -W -f='${binary:Package}\n' "php*" 2>/dev/null || true)

        if [[ ${#pkgs_to_purge[@]} -gt 0 ]]; then
            log_info "Purging ${#pkgs_to_purge[@]} packages..."
            run_silent "purge packages" apt-get purge -y \
                -o Dpkg::Options::="--force-confdef" \
                -o Dpkg::Options::="--force-confold" \
                "${pkgs_to_purge[@]}"
        fi

        run_silent "autoremove" apt-get autoremove -y --purge

        # Remove Sury repository files
        rm -f /etc/apt/sources.list.d/php.list
        rm -f /usr/share/keyrings/debsuryorg-archive-keyring.gpg
        rm -f /etc/apt/trusted.gpg.d/php.gpg

        # Remove NVM directories
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

Git Installation:
  git clone --depth 1 --branch v1.5-beta https://github.com/Aquadactyl/Installer.git /opt/aquadactyl-installer
  cd /opt/aquadactyl-installer
  sudo bash deploy.sh install v1.3-beta

Commands:
  install             Full panel automated install (dependencies, clone, .env, DB, Blueprint, build).
  setup-host          Install system packages (PHP 8.5, MariaDB, Node 24, pnpm 12.15.0, Composer).
  repair-database     Configure a new dedicated local DB login for an unfinished install.
  update              Fetch a Git release tag, back up and update during maintenance.
  permissions         Restore strict least-privilege permissions across PANEL_ROOT.
  remove              Complete uninstallation & rollback (stops services, drops DB, deletes panel).

Unfinished Checkout Recovery:
  sudo bash deploy.sh install v1.3-beta --refresh-source
  Fetch the release before backing up unfinished source; preserve .env and uploads.
  Initialized panels are refused even with --refresh-source; use update instead.

Resume a Failed Installation:
  sudo bash deploy.sh install v1.3-beta --resume
  Keep matching source, existing .env and keys after dependencies are installed.
  Repair database credentials first. Initialized panels must use update.

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
        initialize_log
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
        repair-database)
            cmd_repair_database "$@"
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

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
