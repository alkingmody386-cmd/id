#!/usr/bin/env bash
# ======================================================================
# 🚀 VulnLab Professional Installer v7.0 (Enhanced Release)
# - Fully automated deployment of 11 vulnerable web applications
# - Native PHP 8.x backward-compatibility patching
# - Node.js 20 LTS, PM2, Apache, MySQL / MariaDB
# - Enhanced error handling, logging, and modularity
# ======================================================================

set -euo pipefail

# ------------------------------ Colors ------------------------------
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly MAGENTA='\033[0;35m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

# --------------------------- Global Config --------------------------
readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_VERSION="7.0"
readonly LOG_FILE="/var/log/vulnlab-installer.log"
readonly CONFIG_DIR="/etc/vulnlab"
readonly CONFIG_FILE="${CONFIG_DIR}/installer.conf"
readonly BACKUP_DIR="/var/backups/vulnlab"

# Default values
DEFAULT_BASE_DIR="/opt/vuln-apps"
DEFAULT_JUICE_PORT=3000
DEFAULT_DVNA_PORT=4000
DEFAULT_WEBGOAT_PORT=9090
DEFAULT_MYSQL_PASS="vulnlabpass"
DEFAULT_APPS="dvwa,bwapp,xvwa,mutillidae,hackademic,sqli-labs,hackazon,wackopicko,juice-shop,dvna,webgoat"

# Runtime variables
BASE_DIR="${BASE_DIR:-$DEFAULT_BASE_DIR}"
JUICE_PORT="${JUICE_PORT:-$DEFAULT_JUICE_PORT}"
DVNA_PORT="${DVNA_PORT:-$DEFAULT_DVNA_PORT}"
WEBGOAT_PORT="${WEBGOAT_PORT:-$DEFAULT_WEBGOAT_PORT}"
MYSQL_PASS="${MYSQL_PASS:-$DEFAULT_MYSQL_PASS}"
SELECTED_APPS=()
SKIP_CLEANUP=false
NO_PROXY=false
ROLLBACK_ON_FAILURE=true
FORCE=false
VERBOSE=false

# ----------------------------- Logging ------------------------------
_log() {
    local level="$1"
    local msg="$2"
    local color=""
    local prefix=""
    case "$level" in
        INFO)    color="$BLUE"; prefix="INFO";;
        SUCCESS) color="$GREEN"; prefix="SUCCESS";;
        WARN)    color="$YELLOW"; prefix="WARN";;
        ERROR)   color="$RED"; prefix="ERROR";;
        DEBUG)   color="$CYAN"; prefix="DEBUG";;
        *)       color="$NC"; prefix="LOG";;
    esac
    local timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    echo -e "${color}[${timestamp}] [${prefix}] ${msg}${NC}" | tee -a "$LOG_FILE"
}

log_info()    { _log "INFO" "$1"; }
log_success() { _log "SUCCESS" "$1"; }
log_warn()    { _log "WARN" "$1"; }
log_error()   { _log "ERROR" "$1"; }
log_debug()   { [[ "$VERBOSE" == true ]] && _log "DEBUG" "$1"; }

# Exit function with error message and optional rollback
die() {
    local msg="$1"
    log_error "Fatal Error: $msg"
    if [[ "$ROLLBACK_ON_FAILURE" == true ]]; then
        log_info "Attempting rollback due to failure."
        rollback
    fi
    exit 1
}

# --------------------------- Help & Version -------------------------
show_help() {
    cat <<EOF
${BOLD}${MAGENTA}VulnLab Professional Installer v${SCRIPT_VERSION}${NC}
Usage: ${SCRIPT_NAME} [OPTIONS]
Options:
  --help                 Show this help message
  --version              Show version
  --base-dir DIR         Installation directory (default: ${DEFAULT_BASE_DIR})
  --mysql-pass PASS      Set MySQL root password (default: ${DEFAULT_MYSQL_PASS})
  --juice-port PORT      Juice Shop port (default: ${DEFAULT_JUICE_PORT})
  --dvna-port PORT       DVNA port (default: ${DEFAULT_DVNA_PORT})
  --webgoat-port PORT    WebGoat port (default: ${DEFAULT_WEBGOAT_PORT})
  --apps LIST            Comma-separated list of apps to install (default: all)
  --skip-cleanup         Skip removing existing installation
  --no-proxy             Do not configure Apache reverse proxy
  --no-rollback          Disable rollback on failure
  --force                Force installation without confirmation
  --verbose              Enable debug output
  --load-config FILE     Load configuration from file
Available apps: dvwa, bwapp, xvwa, mutillidae, hackademic, sqli-labs,
                hackazon, wackopicko, juice-shop, dvna, webgoat
EOF
}

show_version() {
    echo "VulnLab Professional Installer v${SCRIPT_VERSION}"
    echo "License: MIT"
}

# ------------------------- Parse Arguments --------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help) show_help; exit 0 ;;
            --version) show_version; exit 0 ;;
            --base-dir) BASE_DIR="$2"; shift 2 ;;
            --mysql-pass) MYSQL_PASS="$2"; shift 2 ;;
            --juice-port) JUICE_PORT="$2"; shift 2 ;;
            --dvna-port) DVNA_PORT="$2"; shift 2 ;;
            --webgoat-port) WEBGOAT_PORT="$2"; shift 2 ;;
            --apps) IFS=',' read -ra SELECTED_APPS <<< "$2"; shift 2 ;;
            --skip-cleanup) SKIP_CLEANUP=true; shift ;;
            --no-proxy) NO_PROXY=true; shift ;;
            --no-rollback) ROLLBACK_ON_FAILURE=false; shift ;;
            --force) FORCE=true; shift ;;
            --verbose) VERBOSE=true; shift ;;
            --load-config) source "$2" || die "Cannot load config $2"; shift 2 ;;
            *) die "Unknown option: $1 (use --help for usage)" ;;
        esac
    done
}

# ------------------------- Pre-flight Checks -------------------------
check_root() {
    [[ $EUID -ne 0 ]] && die "This script must be run as root. Use: sudo $0"
}

check_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        if [[ "$ID" != "ubuntu" && "$ID" != "debian" ]]; then
            log_warn "Unsupported OS: $ID. Only Ubuntu/Debian are officially supported. Proceeding with caution."
        fi
    else
        log_warn "Cannot detect OS; assuming Debian/Ubuntu. Proceeding with caution."
    fi
}

check_requirements() {
    log_info "Checking and installing base requirements..."
    local missing=()
    for cmd in curl wget unzip git tar; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_info "Installing missing base requirements: ${missing[*]}"
        apt update && apt install -y "${missing[@]}" || die "Failed to install base requirements."
    fi
    log_success "Base requirements met."
}

# ------------------------- MySQL Helpers -----------------------------
# Executes a MySQL command, handling password securely
mysql_exec() {
    local sql="$1"
    local pass="${2:-$MYSQL_PASS}"
    if [[ -z "$pass" ]]; then
        mysql -u root -e "$sql" 2>/dev/null
    else
        MYSQL_PWD="$pass" mysql -u root -e "$sql" 2>/dev/null
    fi
}

# Imports an SQL file into a database
mysql_import() {
    local db="$1"
    local file="$2"
    local pass="${3:-$MYSQL_PASS}"
    if [[ -z "$pass" ]]; then
        mysql -u root "$db" < "$file" 2>/dev/null
    else
        MYSQL_PWD="$pass" mysql -u root "$db" < "$file" 2>/dev/null
    fi
}

# Detects if MySQL root has a password and prompts if necessary
detect_mysql_root_password() {
    log_info "Detecting current MySQL root password status..."
    if mysql -u root -e "SELECT 1" &>/dev/null; then
        log_info "MySQL root has no password configured."
        MYSQL_PASS=""
        return 0
    fi

    if [[ -n "$MYSQL_PASS" ]]; then
        if MYSQL_PWD="$MYSQL_PASS" mysql -u root -e "SELECT 1" &>/dev/null; then
            log_info "Provided MySQL root password verified."
            return 0
        else
            log_warn "Provided MySQL password is incorrect or not set. Will attempt to set a new one."
            MYSQL_PASS=""
        fi
    fi

    # If no password provided or incorrect, try to set a new one
    log_info "Attempting to set a new MySQL root password."
    set_mysql_root_password "$DEFAULT_MYSQL_PASS" ""
    MYSQL_PASS="$DEFAULT_MYSQL_PASS"
    log_success "MySQL root password set to default: $DEFAULT_MYSQL_PASS"
    return 0
}

# Sets the MySQL root password
set_mysql_root_password() {
    local new_pass="$1"
    local current_pass="$2"
    local sql_cmd="ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '${new_pass}'; FLUSH PRIVILEGES;"
    
    if [[ -z "$current_pass" ]]; then
        # No current password, try to set directly
        mysql -u root -e "$sql_cmd" || die "Failed to set MySQL password without current password."
    else
        # Current password provided, use it to authenticate
        MYSQL_PWD="$current_pass" mysql -u root -e "$sql_cmd" || die "Failed to set MySQL password with provided current password."
    fi
    MYSQL_PASS="$new_pass"
    log_success "MySQL root password configured."
}

# ------------------------- App Repositories ----------------------------
declare -A APP_REPOS=(
    ["dvwa"]="https://github.com/digininja/DVWA.git"
    ["bwapp"]="sourceforge"
    ["xvwa"]="https://github.com/s4n7h0/xvwa.git"
    ["mutillidae"]="https://github.com/webpwnized/mutillidae.git"
    ["hackademic"]="https://github.com/Hackademic/hackademic.git"
    ["sqli-labs"]="https://github.com/Audi-1/sqli-labs.git"
    ["hackazon"]="https://github.com/rapid7/hackazon.git"
    ["wackopicko"]="https://github.com/adamdoupe/WackoPicko.git"
    ["juice-shop"]="release_download"
    ["dvna"]="https://github.com/appsecco/dvna.git"
    ["webgoat"]="webgoat"
)

resolve_apps() {
    if [[ ${#SELECTED_APPS[@]} -eq 0 ]]; then
        IFS=',' read -ra SELECTED_APPS <<< "$DEFAULT_APPS"
    fi
    local valid_apps=()
    for app in "${SELECTED_APPS[@]}"; do
        if [[ -n "${APP_REPOS[$app]:-}" ]]; then
            valid_apps+=("$app")
        else
            log_warn "Unknown app: $app. Skipping."
        fi
    done
    SELECTED_APPS=("${valid_apps[@]}")
    if [[ ${#SELECTED_APPS[@]} -eq 0 ]]; then
        die "No valid applications selected for installation."
    fi
    log_info "Selected apps for installation: ${SELECTED_APPS[*]}"
}

# ------------------------- Core Functions ---------------------------
install_dependencies() {
    log_info "Updating system and installing base packages..."
    export DEBIAN_FRONTEND=noninteractive
    apt update || die "System update failed."
    apt upgrade -y || log_warn "System upgrade encountered issues, continuing."

    log_info "Installing Node.js 20 LTS..."
    # Add Node.js 20 LTS repository securely
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.d/nodesource-repo.gpg | gpg --dearmor | tee /etc/apt/keyrings/nodesource.gpg >/dev/null
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main" | tee /etc/apt/sources.list.d/nodesource.list >/dev/null
    apt update || die "NodeSource repository update failed."
    apt install -y nodejs || die "Node.js installation failed."
    
    local pkgs=(
        apache2 mysql-server php libapache2-mod-php
        php-mysql php-gd php-xml php-mbstring php-curl php-zip php-json
        unzip git curl wget default-jre default-jdk
        build-essential python3 make g++ net-tools
    )
    log_info "Installing core packages: ${pkgs[*]}"
    apt install -y --no-install-recommends "${pkgs[@]}" || die "Core package installation failed."

    local node_ver
    node_ver=$(node -v | cut -d'v' -f2 | cut -d'.' -f1)
    if [[ $node_ver -lt 20 ]]; then
        die "Node.js version is $node_ver, but v20+ is required. Please check installation."
    fi
    log_success "Node.js $(node -v) verified."

    if ! command -v composer &>/dev/null; then
        log_info "Installing Composer..."
        curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer || die "Composer installation failed."
    fi

    if ! command -v pm2 &>/dev/null; then
        log_info "Installing PM2..."
        npm install -g pm2 || die "PM2 installation failed."
    fi

    a2enmod rewrite proxy proxy_http || die "Apache modules configuration failed."
    log_success "All dependencies installed and configured."
}

configure_php_environment() {
    log_info "Optimizing PHP settings for legacy application support..."
    local php_ver
    php_ver=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || echo "8.1") # Fallback if php command fails
    local apache_ini="/etc/php/${php_ver}/apache2/php.ini"
    local cli_ini="/etc/php/${php_ver}/cli/php.ini"

    for ini in "$apache_ini" "$cli_ini"; do
        if [[ -f "$ini" ]]; then
            log_debug "Configuring PHP INI: $ini"
            sed -i 's|^display_errors = .*|display_errors = Off|g' "$ini"
            sed -i 's|^error_reporting = .*|error_reporting = E_ALL \& ~E_DEPRECATED \& ~E_STRICT \& ~E_NOTICE|g' "$ini"
            sed -i 's|^short_open_tag = .*|short_open_tag = On|g' "$ini"
            sed -i 's|^mysqli.allow_local_infile = .*|mysqli.allow_local_infile = On|g' "$ini"
        else
            log_warn "PHP INI file not found: $ini. Skipping configuration for this file."
        fi
    done
    log_success "PHP environment configured."
}

start_core_services() {
    log_info "Starting and enabling Apache and MySQL services..."
    systemctl start apache2 || die "Failed to start Apache."
    systemctl enable apache2 || die "Failed to enable Apache."
    systemctl start mysql || die "Failed to start MySQL."
    systemctl enable mysql || die "Failed to enable MySQL."
    log_success "Core services running and enabled."
}

# ------------------------- Application Fetchers --------------------
clone_repo() {
    local url="$1"
    local dir="$2"
    local app_name="$(basename "$dir")"

    if [[ -d "$dir" ]]; then
        log_warn "$app_name directory ($dir) already exists. Skipping clone."
        return 0
    fi
    log_info "Cloning $url into $dir ..."
    for i in {1..3}; do
        if git clone --depth 1 "$url" "$dir"; then
            log_success "Cloned $app_name into $dir"
            return 0
        fi
        log_warn "Clone attempt $i for $app_name failed, retrying..."
        sleep 5
    done
    die "Failed to clone $app_name from $url after 3 attempts."
}

download_bwapp() {
    local target_dir="$BASE_DIR/bwapp"
    if [[ -f "$target_dir/bWAPP.sql" || -d "$target_dir/inc" ]]; then
        log_warn "bWAPP directory exists. Skipping download."
        return 0
    fi
    log_info "Downloading bWAPP from SourceForge..."
    mkdir -p "$BASE_DIR" # Ensure base dir exists before downloading
    rm -rf "$target_dir" /tmp/bwapp.zip
    local api_url="https://sourceforge.net/projects/bwapp/files/bWAPP/bWAPP_latest.zip/download"
    if wget --timeout=60 --tries=3 -O /tmp/bwapp.zip "$api_url"; then
        unzip -q /tmp/bwapp.zip -d "$BASE_DIR" || die "Unzip failed for bWAPP."
        local extracted
        extracted=$(find "$BASE_DIR" -maxdepth 1 -type d -name "bWAPP*" | head -n 1)
        if [[ -n "$extracted" ]]; then
            mv "$extracted" "$target_dir" || die "Failed to move extracted bWAPP directory."
            rm -f /tmp/bwapp.zip
            log_success "bWAPP downloaded and extracted successfully."
            return 0
        fi
    fi
    die "bWAPP download failed."
}

download_juice_shop() {
    local target_dir="$BASE_DIR/juice-shop"
    if [[ -d "$target_dir" && -f "$target_dir/build/app.js" ]]; then
        log_warn "Juice Shop already installed. Skipping download."
        return 0
    fi
    log_info "Downloading pre-built OWASP Juice Shop release..."
    mkdir -p "$target_dir"
    local download_url
    # Attempt to get latest release, fallback to a known good version
    download_url=$(curl -s https://api.github.com/repos/juice-shop/juice-shop/releases/latest | grep "browser_download_url.*node20.*tgz" | cut -d '"' -f 4 | head -n 1 || true)
    
    if [[ -z "$download_url" ]]; then
        log_warn "Could not find latest Juice Shop Node.js 20 release. Falling back to v17.1.1."
        download_url="https://github.com/juice-shop/juice-shop/releases/download/v17.1.1/juice-shop-17.1.1_node20_x64.tgz"
    fi

    curl -sSL "$download_url" | tar -xz -C "$target_dir" --strip-components=1 || die "Juice Shop download failed."
    log_success "Juice Shop downloaded and uncompressed."
}

download_webgoat() {
    local target_dir="$BASE_DIR/webgoat"
    mkdir -p "$target_dir"
    cd "$target_dir" || die "Failed to change directory to $target_dir."
    local jar_file="webgoat-server-8.2.2.jar"
    if [[ -f "$jar_file" ]]; then
        log_warn "WebGoat JAR already present. Skipping download."
        cd - >/dev/null || true
        return 0
    fi
    log_info "Downloading WebGoat 8.2.2 JAR..."
    wget --timeout=60 --tries=3 -O "$jar_file" "https://github.com/WebGoat/WebGoat/releases/download/v8.2.2/webgoat-server-8.2.2.jar" || die "WebGoat download failed."
    cd - >/dev/null || true
    log_success "WebGoat downloaded."
}

# ------------------------- Install Handlers -------------------------
install_php_app() {
    local app="$1"
    local src_dir="$BASE_DIR/$app"
    local webroot="/var/www/html/$app"

    if [[ ! -d "$src_dir" ]]; then
        log_warn "Source directory for $app not found ($src_dir). Skipping installation."
        return 1
    fi

    log_info "Installing PHP application: $app"
    # Determine the actual webroot within the cloned directory
    local app_webroot="$src_dir"
    for sub in public htdocs web; do
        if [[ -d "$src_dir/$sub" ]]; then
            app_webroot="$src_dir/$sub"
            break
        fi
    done

    # Create symlink or copy to Apache webroot
    if [[ -d "$webroot" ]]; then
        log_warn "Apache webroot for $app already exists ($webroot). Removing and recreating."
        rm -rf "$webroot" || die "Failed to remove existing webroot for $app."
    fi
    ln -sfn "$app_webroot" "$webroot" || die "Failed to create symlink for $app."
    log_success "PHP app $app linked to $webroot."

    # Specific configurations for PHP apps
    case "$app" in
        dvwa)
            log_info "Configuring DVWA..."
            if [[ -f "$webroot/config/config.inc.php.dist" ]]; then
                cp "$webroot/config/config.inc.php.dist" "$webroot/config/config.inc.php"
                sed -i "s|\$_DVWA[ 'db_password' ] = '.*';|\$_DVWA[ 'db_password' ] = '${MYSQL_PASS}';|g" "$webroot/config/config.inc.php"
                sed -i "s|\$_DVWA[ 'recaptcha_public_key' ] = '.*';|\$_DVWA[ 'recaptcha_public_key' ] = '6LdK7xITAAzzAAJQTfL7fu6I-0aPl8KXXXXXXXXX';|g" "$webroot/config/config.inc.php"
                sed -i "s|\$_DVWA[ 'recaptcha_private_key' ] = '.*';|\$_DVWA[ 'recaptcha_private_key' ] = '6LdK7xITAzzAAJQTfL7fu6I-0aPl8KXXXXXXXXX';|g" "$webroot/config/config.inc.php"
            fi
            ;; 
        bwapp)
            log_info "Configuring bWAPP..."
            if [[ -f "$webroot/admin/settings.php" ]]; then
                sed -i "s|\$db_password = '.*';|\$db_password = '${MYSQL_PASS}';|g" "$webroot/admin/settings.php"
            fi
            ;; 
        mutillidae)
            log_info "Configuring Mutillidae..."
            if [[ -f "$webroot/includes/db-config.inc" ]]; then
                sed -i "s|\$dbname = '.*';|\$dbname = 'owasp10';|g" "$webroot/includes/db-config.inc"
                sed -i "s|\$dbuser = '.*';|\$dbuser = 'root';|g" "$webroot/includes/db-config.inc"
                sed -i "s|\$dbpass = '.*';|\$dbpass = '${MYSQL_PASS}';|g" "$webroot/includes/db-config.inc"
            fi
            ;; 
        sqli-labs)
            log_info "Configuring SQLi-Labs..."
            if [[ -f "$webroot/sql-connections/db-creds.inc" ]]; then
                sed -i "s|\$dbpass = '.*';|\$dbpass = '${MYSQL_PASS}';|g" "$webroot/sql-connections/db-creds.inc"
                sed -i "s|\$dbname = '.*';|\$dbname = 'security';|g" "$webroot/sql-connections/db-creds.inc"
            fi
            ;; 
        hackazon)
            log_info "Configuring Hackazon..."
            if [[ -f "$webroot/application/config/database.php" ]]; then
                sed -i "s|'password' => '.*'|'password' => '${MYSQL_PASS}'|g" "$webroot/application/config/database.php"
            fi
            (cd "$webroot" && composer install --no-dev --quiet --no-interaction --ignore-platform-reqs) || log_warn "Composer execution for Hackazon failed. Manual intervention might be needed."
            ;; 
        wackopicko)
            log_info "Configuring WackoPicko..."
            if [[ -f "$webroot/conf/db.php.sample" ]]; then
                cp "$webroot/conf/db.php.sample" "$webroot/conf/db.php"
                sed -i "s|password|${MYSQL_PASS}|g" "$webroot/conf/db.php"
            fi
            ;; 
        hackademic)
            log_info "Configuring Hackademic..."
            # Hackademic often needs manual setup or specific database import
            ;; 
        xvwa)
            log_info "Configuring XVWA..."
            # XVWA typically works out of the box with default MySQL
            ;; 
    esac
    log_success "PHP app $app configured."
}

install_node_app() {
    local app="$1"
    local app_dir="$BASE_DIR/$app"
    local app_port

    case "$app" in
        juice-shop) app_port="$JUICE_PORT";; 
        dvna) app_port="$DVNA_PORT";; 
        *) die "Unknown Node.js app: $app";; 
    esac

    log_info "Installing Node.js application: $app"
    cd "$app_dir" || die "Failed to change directory to $app_dir."

    if [[ "$app" == "juice-shop" ]]; then
        # Juice Shop is downloaded as a pre-built release, no npm install needed
        log_info "Starting Juice Shop with PM2 on port $app_port..."
        pm2 start "$app_dir/dist/server.js" --name "juice-shop" -- --port "$app_port" || die "Failed to start Juice Shop with PM2."
    else
        npm install --production || log_warn "npm install for $app failed. Continuing, but app might not function correctly."
        log_info "Starting $app with PM2 on port $app_port..."
        pm2 start "$app_dir/app.js" --name "$app" -- --port "$app_port" || die "Failed to start $app with PM2."
    fi
    pm2 save || log_warn "PM2 save failed."
    cd - >/dev/null || true
    log_success "Node.js app $app installed and started on port $app_port."
}

install_java_app() {
    local app="webgoat"
    local app_dir="$BASE_DIR/$app"
    local app_port="$WEBGOAT_PORT"
    local jar_file="webgoat-server-8.2.2.jar"

    log_info "Installing Java application: $app"
    cd "$app_dir" || die "Failed to change directory to $app_dir."

    log_info "Starting WebGoat with PM2 on port $app_port..."
    pm2 start "java" --name "webgoat" -- -jar "$jar_file" --server.port="$app_port" || die "Failed to start WebGoat with PM2."
    pm2 save || log_warn "PM2 save failed."
    cd - >/dev/null || true
    log_success "Java app $app installed and started on port $app_port."
}

create_databases() {
    log_info "Creating databases for applications..."
    local dbs=("dvwa" "bwapp" "owasp10" "security" "hackazon" "wackopicko" "hackademic" "xvwa")
    for db in "${dbs[@]}"; do
        log_debug "Creating database: $db"
        mysql_exec "CREATE DATABASE IF NOT EXISTS \`${db}\`;" || log_warn "Failed to create database $db. Continuing."
    done
    log_success "Databases created."
}

configure_php_apps_db_import() {
    log_info "Importing SQL data and configuring PHP app database connections..."
    local webroot
    for app in "${SELECTED_APPS[@]}"; do
        webroot="/var/www/html/$app"
        case "$app" in
            dvwa)
                log_info "Importing DVWA database..."
                mysql_import "dvwa" "$webroot/dvwa.sql" || log_warn "DVWA SQL import failed. Manual setup might be required."
                ;; 
            bwapp)
                log_info "Importing bWAPP database..."
                mysql_import "bwapp" "$webroot/bWAPP.sql" || log_warn "bWAPP SQL import failed. Manual setup might be required."
                ;; 
            mutillidae)
                log_info "Importing Mutillidae database..."
                mysql_import "owasp10" "$webroot/sql/owasp10.sql" || log_warn "Mutillidae SQL import failed. Manual setup might be required."
                ;; 
            sqli-labs)
                log_info "Importing SQLi-Labs database..."
                mysql_import "security" "$webroot/sql-lab.sql" || log_warn "SQLi-Labs SQL import failed. Manual setup might be required."
                ;; 
            hackazon)
                log_info "Importing Hackazon database..."
                mysql_import "hackazon" "$webroot/install/database.sql" || log_warn "Hackazon SQL import failed. Manual setup might be required."
                ;; 
            wackopicko)
                log_info "Importing WackoPicko database..."
                mysql_import "wackopicko" "$webroot/sql/wackopicko.sql" || log_warn "WackoPicko SQL import failed. Manual setup might be required."
                ;; 
            hackademic)
                log_info "Importing Hackademic database..."
                # Hackademic might have different SQL file names
                for sql_file in "$webroot/db/install.sql" "$webroot/sql/install.sql"; do
                    if [[ -f "$sql_file" ]]; then
                        mysql_import "hackademic" "$sql_file" && log_info "Hackademic SQL import successful from $sql_file." && break
                    fi
                done || log_warn "Hackademic SQL import failed. Manual setup might be required."
                ;; 
            xvwa)
                log_info "Importing XVWA database..."
                mysql_import "xvwa" "$webroot/sql/xvwa.sql" || log_warn "XVWA SQL import failed. Manual setup might be required."
                ;; 
        esac
    done
    log_success "PHP application databases configured and imported."
}

# ------------------------- Reverse Proxy ----------------------------
configure_proxy() {
    if [[ "$NO_PROXY" == true ]]; then
        log_info "Skipping reverse proxy configuration as requested."
        return 0
    fi
    log_info "Configuring Apache reverse proxy..."

    local proxy_conf_file="/etc/apache2/sites-available/vuln-proxy.conf"
    cat > "$proxy_conf_file" <<EOF
# VulnLab Reverse Proxy Configuration
<VirtualHost *:80>
    ServerName localhost
    ProxyPreserveHost On
    ProxyRequests Off
    ProxyPass /juice-shop http://localhost:${JUICE_PORT}/
    ProxyPassReverse /juice-shop http://localhost:${JUICE_PORT}/
    ProxyPass /dvna http://localhost:${DVNA_PORT}/
    ProxyPassReverse /dvna http://localhost:${DVNA_PORT}/
    ProxyPass /webgoat http://localhost:${WEBGOAT_PORT}/WebGoat/
    ProxyPassReverse /webgoat http://localhost:${WEBGOAT_PORT}/WebGoat/
    ErrorLog ${APACHE_LOG_DIR}/vuln-proxy-error.log
    CustomLog ${APACHE_LOG_DIR}/vuln-proxy-access.log combined
</VirtualHost>
EOF
    a2ensite vuln-proxy.conf || die "Failed to enable proxy site."
    systemctl reload apache2 || die "Failed to reload Apache after proxy config."
    log_success "Reverse proxy active."
}

# ------------------------- Cleanup -----------------------------------
cleanup_previous() {
    if [[ "$SKIP_CLEANUP" == true ]]; then
        log_info "Skipping cleanup of previous installation as requested."
        return 0
    fi
    log_info "Cleaning up previous VulnLab installation components..."

    # Stop and delete PM2 processes
    if command -v pm2 &>/dev/null; then
        pm2 delete juice-shop dvna webgoat 2>/dev/null || true
        pm2 save 2>/dev/null || true
        log_debug "PM2 processes stopped and deleted."
    fi

    # Stop core services
    systemctl stop apache2 mysql 2>/dev/null || true
    log_debug "Apache and MySQL services stopped."

    # Remove application directories
    if [[ -d "$BASE_DIR" ]]; then
        rm -rf "$BASE_DIR" || log_warn "Failed to remove $BASE_DIR. Manual cleanup might be needed."
        log_success "Removed $BASE_DIR"
    fi

    # Remove Apache webroots
    for app in dvwa bwapp xvwa mutillidae hackademic sqli-labs hackazon wackopicko; do
        if [[ -L "/var/www/html/$app" || -d "/var/www/html/$app" ]]; then
            rm -rf "/var/www/html/$app" 2>/dev/null || log_warn "Failed to remove /var/www/html/$app."
        fi
    done
    log_debug "Apache webroots cleaned."

    # Disable and remove Apache proxy config
    if [[ -f "/etc/apache2/sites-available/vuln-proxy.conf" ]]; then
        a2dissite vuln-proxy.conf 2>/dev/null || true
        rm -f "/etc/apache2/sites-available/vuln-proxy.conf" 2>/dev/null || true
        systemctl reload apache2 2>/dev/null || true
        log_debug "Apache proxy config removed."
    fi

    # Drop MySQL databases
    # Re-detect password in case it was changed externally
    local current_mysql_pass="$MYSQL_PASS"
    if ! mysql -u root -e "SELECT 1" &>/dev/null && [[ -z "$current_mysql_pass" ]]; then
        log_warn "Cannot connect to MySQL as root without password for cleanup. Skipping database cleanup."
    else
        for db in dvwa bwapp owasp10 security hackazon wackopicko hackademic xvwa; do
            mysql_exec "DROP DATABASE IF EXISTS \`${db}\`;" "$current_mysql_pass" || log_warn "Failed to drop database $db during cleanup."
        done
        mysql_exec "FLUSH PRIVILEGES;" "$current_mysql_pass" || log_warn "Failed to flush MySQL privileges during cleanup."
        log_debug "MySQL databases dropped."
    fi

    log_success "Cleanup complete."
}

# ------------------------- Rollback ----------------------------------
rollback() {
    if [[ "$ROLLBACK_ON_FAILURE" == false ]]; then
        log_warn "Rollback disabled. Skipping rollback procedure."
        return 0
    fi
    log_error "Initiating rollback procedure due to error..."
    
    # Stop and delete PM2 processes
    if command -v pm2 &>/dev/null; then
        pm2 delete juice-shop dvna webgoat 2>/dev/null || true
        pm2 save 2>/dev/null || true
    fi

    # Stop core services
    systemctl stop apache2 mysql 2>/dev/null || true

    # Remove Apache webroots
    for app in dvwa bwapp xvwa mutillidae hackademic sqli-labs hackazon wackopicko; do
        if [[ -L "/var/www/html/$app" || -d "/var/www/html/$app" ]]; then
            rm -rf "/var/www/html/$app" 2>/dev/null || true
        fi
    done

    # Disable and remove Apache proxy config
    if [[ -f "/etc/apache2/sites-available/vuln-proxy.conf" ]]; then
        a2dissite vuln-proxy.conf 2>/dev/null || true
        rm -f "/etc/apache2/sites-available/vuln-proxy.conf" 2>/dev/null || true
        systemctl reload apache2 2>/dev/null || true
    fi

    # Attempt to remove base directory if it was created by this script
    if [[ -d "$BASE_DIR" ]]; then
        rm -rf "$BASE_DIR" 2>/dev/null || true
    fi

    log_warn "Rollback finalized. System reverted to a cleaner state. Manual inspection recommended."
}

# ------------------------- Finalization -----------------------------
final_permissions() {
    log_info "Setting final permissions for web directories..."
    chown -R www-data:www-data /var/www/html/ || log_warn "Failed to set permissions for /var/www/html. Manual fix might be needed."
    systemctl restart apache2 || die "Failed to restart Apache after permission changes."
    log_success "Permissions set and Apache restarted."
}

print_summary() {
    local ip
    ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1")
    local php_apps=("dvwa" "bwapp" "xvwa" "mutillidae" "hackademic" "sqli-labs" "hackazon" "wackopicko")
    clear
    echo -e "\n${MAGENTA}${BOLD}=======================================================${NC}"
    echo -e "${GREEN}${BOLD}   ✅ VulnLab Professional Installation Complete!${NC}"
    echo -e "${MAGENTA}${BOLD}=======================================================${NC}\n"

    echo -e "${CYAN}${BOLD}📂 PHP Apps (Apache - Port 80):${NC}"
    for app in "${php_apps[@]}"; do
        if [[ -d "/var/www/html/$app" || -L "/var/www/html/$app" ]]; then
            echo -e "  - ${GREEN}$app${NC}: http://${ip}/${app}/"
        fi
    done

    echo -e "\n${CYAN}${BOLD}🚀 Standalone Apps (via Reverse Proxy):${NC}"
    for app in juice-shop dvna webgoat; do
        if pm2 list 2>/dev/null | grep -q "$app"; then
            echo -e "  - ${GREEN}$app${NC}: http://${ip}/${app}/"
        fi
    done

    echo -e "\n${CYAN}${BOLD}🔑 Database Credentials:${NC}"
    echo -e "  - Username: ${GREEN}root${NC}"
    echo -e "  - Password: ${GREEN}${MYSQL_PASS}${NC}"

    echo -e "\n${CYAN}${BOLD}📊 PM2 Active Services:${NC}"
    pm2 list || echo "  No PM2 processes running."

    echo -e "\n${CYAN}${BOLD}📝 Installation Log:${NC} $LOG_FILE"
    echo -e "\n${GREEN}${BOLD}Deployment completed successfully! 🎉${NC}\n"
}

# ------------------------- Main Routine -----------------------------
main() {
    parse_args "$@"
    check_root
    check_os
    check_requirements
    resolve_apps

    mkdir -p "$(dirname "$LOG_FILE")" "$BACKUP_DIR" "$CONFIG_DIR" || die "Failed to create essential directories."

    # Backup existing config if any, then save current config
    if [[ -f "$CONFIG_FILE" ]]; then
        cp "$CONFIG_FILE" "$BACKUP_DIR/installer.conf.$(date +%Y%m%d_%H%M%S)" || log_warn "Failed to backup existing config file."
    fi
    cat > "$CONFIG_FILE" <<EOF
BASE_DIR="$BASE_DIR"
MYSQL_PASS="$MYSQL_PASS"
JUICE_PORT="$JUICE_PORT"
DVNA_PORT="$DVNA_PORT"
WEBGOAT_PORT="$WEBGOAT_PORT"
SELECTED_APPS=(${SELECTED_APPS[*]})
NO_PROXY=$NO_PROXY
EOF
    log_info "Configuration saved to $CONFIG_FILE."

    if [[ "$FORCE" != true ]]; then
        echo -e "\n${YELLOW}${BOLD}The following targets will be installed:${NC}"
        echo -e "  ${SELECTED_APPS[*]}"
        echo -e "Target Installation Directory: ${BASE_DIR}"
        echo -e "MySQL Root Password: ${MYSQL_PASS}"
        read -r -p "Proceed with deployment? (yes/no): " confirm
        [[ "$confirm" != "yes" ]] && die "Operation aborted by user."
    fi

    # Set trap for robust error handling and rollback
    trap 'die "Script interrupted or failed. See log for details."' ERR INT TERM

    log_info "Starting VulnLab installation process..."

    # Execute Deployment Phases
    cleanup_previous
    install_dependencies
    configure_php_environment
    start_core_services

    detect_mysql_root_password # Ensure MySQL password is set or detected
    # If MYSQL_PASS is still empty after detection, set default
    if [[ -z "$MYSQL_PASS" ]]; then
        set_mysql_root_password "$DEFAULT_MYSQL_PASS" ""
    fi

    mkdir -p "$BASE_DIR" || die "Failed to create base application directory: $BASE_DIR."
    log_info "Fetching and installing applications..."
    for app in "${SELECTED_APPS[@]}"; do
        case "$app" in
            dvwa|xvwa|mutillidae|hackademic|sqli-labs|hackazon|wackopicko)
                clone_repo "${APP_REPOS[$app]}" "$BASE_DIR/$app"
                install_php_app "$app"
                ;;
            bwapp)
                download_bwapp
                install_php_app "bwapp"
                ;;
            juice-shop)
                download_juice_shop
                install_node_app "juice-shop"
                ;;
            dvna)
                clone_repo "${APP_REPOS[$app]}" "$BASE_DIR/$app"
                install_node_app "dvna"
                ;;
            webgoat)
                download_webgoat
                install_java_app
                ;;
            *)
                log_warn "Unknown target: $app. Skipping installation."
                ;;
        esac
    done

    create_databases
    configure_php_apps_db_import
    configure_proxy
    final_permissions

    # Configure PM2 to start on boot
    pm2 save || log_warn "PM2 save failed. PM2 processes might not restart on reboot."
    pm2 startup systemd -u root --hp /root | tail -n 1 | bash || log_warn "PM2 startup integration failed. Manual PM2 startup might be required."

    log_success "VulnLab installation process completed."
    print_summary

    trap - ERR INT TERM # Clear trap on successful completion
}

main "$@"
