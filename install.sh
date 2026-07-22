#!/usr/bin/env bash
# ======================================================================
# 🚀 VulnLab Professional Installer v6.1 (Production Release)
# - Fully automated deployment of 11 vulnerable web applications
# - Native PHP 8.x backward-compatibility patching
# - Node.js 20 LTS, PM2, Apache, MySQL / MariaDB
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
readonly SCRIPT_VERSION="6.1"
readonly LOG_FILE="/var/log/vulnlab-installer.log"
readonly CONFIG_DIR="/etc/vulnlab"
readonly CONFIG_FILE="${CONFIG_DIR}/installer.conf"
readonly BACKUP_DIR="/var/backups/vulnlab"

# Default values
DEFAULT_BASE_DIR="/opt/vuln-apps"
DEFAULT_JUICE_PORT=3000
DEFAULT_DVNA_PORT=4000
DEFAULT_WEBGOAT_PORT=9090
DEFAULT_MYSQL_PASS="root"
DEFAULT_APPS="dvwa,bwapp,xvwa,mutillidae,hackademic,sqli-labs,hackazon,wackopicko,juice-shop,dvna,webgoat"

# Runtime variables
BASE_DIR="${BASE_DIR:-$DEFAULT_BASE_DIR}"
JUICE_PORT="${JUICE_PORT:-$DEFAULT_JUICE_PORT}"
DVNA_PORT="${DVNA_PORT:-$DEFAULT_DVNA_PORT}"
WEBGOAT_PORT="${WEBGOAT_PORT:-$DEFAULT_WEBGOAT_PORT}"
MYSQL_PASS="${MYSQL_PASS:-}"
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

die() {
    log_error "$1"
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
            log_warn "Unsupported OS: $ID. Only Ubuntu/Debian are officially supported."
        fi
    else
        log_warn "Cannot detect OS; assuming Debian/Ubuntu."
    fi
}

check_requirements() {
    local missing=()
    for cmd in curl wget unzip git tar; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_info "Installing missing base requirements: ${missing[*]}"
        apt update && apt install -y "${missing[@]}" || die "Failed to install requirements."
    fi
}

# ------------------------- MySQL Helpers -----------------------------
mysql_exec() {
    local sql="$1"
    local pass="${2:-$MYSQL_PASS}"
    if [[ -z "$pass" ]]; then
        mysql -u root -e "$sql" 2>/dev/null
    else
        MYSQL_PWD="$pass" mysql -u root -e "$sql" 2>/dev/null
    fi
}

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

detect_mysql_root_password() {
    if mysql -u root -e "SELECT 1" &>/dev/null; then
        log_info "MySQL root has no password configured."
        MYSQL_PASS=""
        return 0
    fi
    if [[ -n "$MYSQL_PASS" ]]; then
        if MYSQL_PWD="$MYSQL_PASS" mysql -u root -e "SELECT 1" &>/dev/null; then
            log_info "MySQL root password verified."
            return 0
        else
            log_warn "Provided MySQL password is incorrect."
        fi
    fi
    echo -e "${YELLOW}Enter current MySQL root password (if any):${NC}"
    read -s -p "Password: " current_pass
    echo
    if MYSQL_PWD="$current_pass" mysql -u root -e "SELECT 1" &>/dev/null; then
        MYSQL_PASS="$current_pass"
        log_info "MySQL root password accepted."
        return 0
    else
        die "Could not connect to MySQL. Please check your password."
    fi
}

set_mysql_root_password() {
    local new_pass="$1"
    local current_pass="$2"
    local sql="ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '${new_pass}'; FLUSH PRIVILEGES;"
    
    if [[ -z "$current_pass" ]]; then
        mysql -u root -e "$sql" 2>/dev/null || mysql -u root -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${new_pass}'; FLUSH PRIVILEGES;" || die "Failed to set MySQL password."
    else
        MYSQL_PWD="$current_pass" mysql -u root -e "$sql" 2>/dev/null || die "Failed to set MySQL password."
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
    for app in "${SELECTED_APPS[@]}"; do
        if [[ -z "${APP_REPOS[$app]:-}" ]]; then
            log_warn "Unknown app: $app. Skipping."
        fi
    done
    log_info "Selected apps: ${SELECTED_APPS[*]}"
}

# ------------------------- Core Functions ---------------------------
install_dependencies() {
    log_info "Updating system and installing base packages..."
    export DEBIAN_FRONTEND=noninteractive
    apt update && apt upgrade -y || die "System update failed."

    log_info "Installing Node.js 20 LTS..."
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash - || die "NodeSource setup failed."
    apt install -y nodejs || die "Node.js installation failed."

    local pkgs=(
        apache2 mysql-server php libapache2-mod-php
        php-mysql php-gd php-xml php-mbstring php-curl php-zip php-json
        unzip git curl wget default-jre default-jdk
        build-essential python3 make g++ net-tools
    )
    apt install -y --no-install-recommends "${pkgs[@]}" || die "Package installation failed."

    local node_ver
    node_ver=$(node -v | cut -d'v' -f2 | cut -d'.' -f1)
    if [[ $node_ver -lt 20 ]]; then
        die "Node.js version is $node_ver, but v20+ is required."
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
}

configure_php_environment() {
    log_info "Optimizing PHP settings for legacy application support..."
    local php_ver
    php_ver=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || echo "8.1")
    local apache_ini="/etc/php/${php_ver}/apache2/php.ini"
    local cli_ini="/etc/php/${php_ver}/cli/php.ini"

    for ini in "$apache_ini" "$cli_ini"; do
        if [[ -f "$ini" ]]; then
            sed -i 's|^display_errors = .*|display_errors = Off|g' "$ini"
            sed -i 's|^error_reporting = .*|error_reporting = E_ALL \& ~E_DEPRECATED \& ~E_STRICT \& ~E_NOTICE|g' "$ini"
            sed -i 's|^short_open_tag = .*|short_open_tag = On|g' "$ini"
            sed -i 's|^mysqli.allow_local_infile = .*|mysqli.allow_local_infile = On|g' "$ini"
        fi
    done
}

start_core_services() {
    log_info "Starting Apache and MySQL services..."
    systemctl start apache2 mysql || die "Failed to start services."
    systemctl enable apache2 mysql || die "Failed to enable services."
    log_success "Core services running."
}

# ------------------------- Application Fetchers --------------------
clone_repo() {
    local url="$1"
    local dir="$2"
    if [[ -d "$dir" ]]; then
        log_warn "$dir already exists. Skipping clone."
        return 0
    fi
    log_info "Cloning $url ..."
    for i in {1..3}; do
        if git clone --depth 1 "$url" "$dir"; then
            log_success "Cloned into $dir"
            return 0
        fi
        log_warn "Clone attempt $i failed, retrying..."
        sleep 2
    done
    die "Failed to clone $url after 3 attempts."
}

download_bwapp() {
    local target_dir="$BASE_DIR/bwapp"
    if [[ -f "$target_dir/bWAPP.sql" || -d "$target_dir/inc" ]]; then
        log_warn "bWAPP directory exists. Skipping download."
        return 0
    fi
    log_info "Downloading bWAPP from SourceForge..."
    rm -rf "$target_dir" /tmp/bwapp.zip
    local api_url="https://sourceforge.net/projects/bwapp/files/bWAPP/bWAPP_latest.zip/download"
    if wget --timeout=60 --tries=3 -O /tmp/bwapp.zip "$api_url"; then
        unzip -q /tmp/bwapp.zip -d "$BASE_DIR" || die "Unzip failed."
        local extracted
        extracted=$(find "$BASE_DIR" -maxdepth 1 -type d -name "bWAPP*" | head -n 1)
        if [[ -n "$extracted" ]]; then
            mv "$extracted" "$target_dir"
            rm -f /tmp/bwapp.zip
            log_success "bWAPP downloaded successfully."
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
    download_url=$(curl -s https://api.github.com/repos/juice-shop/juice-shop/releases/latest | grep "browser_download_url.*node20.*tgz" | cut -d '"' -f 4 | head -n 1 || true)
    
    if [[ -z "$download_url" ]]; then
        download_url="https://github.com/juice-shop/juice-shop/releases/download/v17.1.1/juice-shop-17.1.1_node20_x64.tgz"
    fi

    curl -sSL "$download_url" | tar -xz -C "$target_dir" --strip-components=1 || die "Juice Shop download failed."
    log_success "Juice Shop downloaded and uncompressed."
}

download_webgoat() {
    local target_dir="$BASE_DIR/webgoat"
    mkdir -p "$target_dir"
    cd "$target_dir"
    local jar_file="webgoat-server-8.2.2.jar"
    if [[ -f "$jar_file" ]]; then
        log_warn "WebGoat JAR already present."
        cd - >/dev/null
        return 0
    fi
    log_info "Downloading WebGoat 8.2.2 JAR..."
    wget --timeout=60 --tries=3 -O "$jar_file" "https://github.com/WebGoat/WebGoat/releases/download/v8.2.2/webgoat-server-8.2.2.jar" || die "WebGoat download failed."
    cd - >/dev/null
    log_success "WebGoat downloaded."
}

# ------------------------- Install Handlers -------------------------
install_php_app() {
    local app="$1"
    local src_dir="$BASE_DIR/$app"
    local webroot="/var/www/html/$app"

    if [[ ! -d "$src_dir" ]]; then
        log_warn "Source directory for $app not found. Skipping."
        return 1
    fi

    local target="$src_dir"
    for sub in public htdocs web; do
        if [[ -d "$src_dir/$sub" ]]; then
            target="$src_dir/$sub"
            break
        fi
    done

    rm -rf "$webroot" 2>/dev/null
    ln -s "$target" "$webroot"
    log_success "Linked $app -> $target"
    return 0
}

install_node_app() {
    local app="$1"
    local dir="$BASE_DIR/$app"
    local port

    case "$app" in
        juice-shop) port="$JUICE_PORT" ;;
        dvna)       port="$DVNA_PORT" ;;
        *)          port="3000" ;;
    esac

    if [[ ! -d "$dir" ]]; then
        log_warn "Directory $dir not found. Skipping $app."
        return 1
    fi

    cd "$dir"
    if [[ "$app" == "dvna" && ! -d "node_modules" ]]; then
        log_info "Installing npm dependencies for $app..."
        npm install --quiet --no-audit --no-fund || log_warn "npm install finished with warnings for $app"
    fi

    pm2 delete "$app" 2>/dev/null || true
    if [[ "$app" == "juice-shop" ]]; then
        PORT="$port" NODE_ENV=production pm2 start build/app.js --name "$app"
    elif [[ "$app" == "dvna" ]]; then
        PORT="$port" pm2 start server.js --name "$app"
    fi

    log_success "$app started on port $port via PM2"
    cd - >/dev/null
}

install_java_app() {
    local app="webgoat"
    local dir="$BASE_DIR/webgoat"
    local port="$WEBGOAT_PORT"
    if [[ ! -d "$dir" ]]; then
        log_warn "WebGoat directory missing."
        return 1
    fi
    cd "$dir"
    local jar_file
    jar_file=$(ls webgoat-server-*.jar 2>/dev/null | head -n 1)
    if [[ -z "$jar_file" ]]; then
        log_warn "WebGoat JAR not found."
        cd - >/dev/null
        return 1
    fi
    pm2 delete "$app" 2>/dev/null || true
    pm2 start java --name "$app" -- -jar "$jar_file" --server.port="$port"
    log_success "WebGoat started on port $port via PM2"
    cd - >/dev/null
}

# ------------------------- Database Configurations ------------------
create_databases() {
    log_info "Creating application databases..."
    local php_dbs=("dvwa" "bwapp" "mutillidae" "sqli_labs" "hackazon" "wackopicko" "hackademic" "xvwa")
    for db in "${php_dbs[@]}"; do
        mysql_exec "CREATE DATABASE IF NOT EXISTS \`${db}\`;" || log_warn "Failed to create DB: $db"
    done
    log_success "Databases created."
}

configure_php_apps() {
    local webroot="/var/www/html"

    # DVWA
    if [[ -f "$webroot/dvwa/config/config.inc.php.dist" ]]; then
        cp "$webroot/dvwa/config/config.inc.php.dist" "$webroot/dvwa/config/config.inc.php"
        sed -i "s|p@ssw0rd|${MYSQL_PASS}|g" "$webroot/dvwa/config/config.inc.php"
        sed -i "s|'db_user']     = 'dvwa'|'db_user']     = 'root'|g" "$webroot/dvwa/config/config.inc.php"
    fi

    # bWAPP
    if [[ -f "$webroot/bwapp/inc/connect.inc.php" ]]; then
        sed -i "s|\$db_password = '.*';|\$db_password = '${MYSQL_PASS}';|g" "$webroot/bwapp/inc/connect.inc.php"
    fi
    if [[ -f "$webroot/bwapp/bWAPP.sql" ]]; then
        mysql_import "bwapp" "$webroot/bwapp/bWAPP.sql" || log_warn "bWAPP SQL import failed."
    fi

    # Mutillidae
    if [[ -f "$webroot/mutillidae/sql/mutillidae.sql" ]]; then
        mysql_import "mutillidae" "$webroot/mutillidae/sql/mutillidae.sql" || log_warn "Mutillidae SQL import failed."
    fi
    if [[ -f "$webroot/mutillidae/includes/dbConfig.php.sample" ]]; then
        cp "$webroot/mutillidae/includes/dbConfig.php.sample" "$webroot/mutillidae/includes/dbConfig.php"
        sed -i "s|\$dbpass = '.*';|\$dbpass = '${MYSQL_PASS}';|g" "$webroot/mutillidae/includes/dbConfig.php"
    fi

    # SQLi-Labs
    if [[ -f "$webroot/sqli-labs/sql-lab.sql" ]]; then
        mysql_import "sqli_labs" "$webroot/sqli-labs/sql-lab.sql" || log_warn "sqli-labs SQL import failed."
    fi
    if [[ -f "$webroot/sqli-labs/sql-connections/db-creds.inc" ]]; then
        sed -i "s|\$dbpass = '.*';|\$dbpass = '${MYSQL_PASS}';|g" "$webroot/sqli-labs/sql-connections/db-creds.inc"
        sed -i "s|\$dbname = '.*';|\$dbname = 'sqli_labs';|g" "$webroot/sqli-labs/sql-connections/db-creds.inc"
    fi

    # Hackazon
    if [[ -f "$webroot/hackazon/install/database.sql" ]]; then
        mysql_import "hackazon" "$webroot/hackazon/install/database.sql" || log_warn "Hackazon SQL import failed."
    fi
    if [[ -f "$webroot/hackazon/application/config/database.php" ]]; then
        sed -i "s|'password' => '.*'|'password' => '${MYSQL_PASS}'|g" "$webroot/hackazon/application/config/database.php"
    fi
    if [[ -d "$webroot/hackazon" ]]; then
        (cd "$webroot/hackazon" && composer install --no-dev --quiet --no-interaction --ignore-platform-reqs) || log_warn "Composer execution for Hackazon failed."
    fi

    # WackoPicko
    if [[ -f "$webroot/wackopicko/sql/wackopicko.sql" ]]; then
        mysql_import "wackopicko" "$webroot/wackopicko/sql/wackopicko.sql" || log_warn "WackoPicko SQL import failed."
    fi
    if [[ -f "$webroot/wackopicko/conf/db.php.sample" ]]; then
        cp "$webroot/wackopicko/conf/db.php.sample" "$webroot/wackopicko/conf/db.php"
        sed -i "s|password|${MYSQL_PASS}|g" "$webroot/wackopicko/conf/db.php"
    fi

    # Hackademic
    for sql in "$webroot/hackademic/db/install.sql" "$webroot/hackademic/sql/install.sql"; do
        if [[ -f "$sql" ]]; then
            mysql_import "hackademic" "$sql" || log_warn "Hackademic SQL import failed."
        fi
    done

    # XVWA
    if [[ -f "$webroot/xvwa/sql/xvwa.sql" ]]; then
        mysql_import "xvwa" "$webroot/xvwa/sql/xvwa.sql" || log_warn "xVWA SQL import failed."
    fi

    log_success "PHP applications successfully configured."
}

# ------------------------- Reverse Proxy ----------------------------
configure_proxy() {
    if [[ "$NO_PROXY" == true ]]; then
        log_info "Skipping reverse proxy configuration."
        return 0
    fi
    log_info "Configuring Apache reverse proxy..."
    cat > /etc/apache2/sites-available/vuln-proxy.conf <<EOF
# VulnLab Reverse Proxy Configuration
ProxyPreserveHost On
ProxyPass /juice-shop http://localhost:${JUICE_PORT}/
ProxyPassReverse /juice-shop http://localhost:${JUICE_PORT}/
ProxyPass /dvna http://localhost:${DVNA_PORT}/
ProxyPassReverse /dvna http://localhost:${DVNA_PORT}/
ProxyPass /webgoat http://localhost:${WEBGOAT_PORT}/WebGoat/
ProxyPassReverse /webgoat http://localhost:${WEBGOAT_PORT}/WebGoat/
EOF
    a2ensite vuln-proxy.conf || die "Failed to enable proxy site."
    systemctl reload apache2 || die "Failed to reload Apache."
    log_success "Reverse proxy active."
}

# ------------------------- Cleanup -----------------------------------
cleanup_previous() {
    if [[ "$SKIP_CLEANUP" == true ]]; then
        log_info "Skipping cleanup."
        return 0
    fi
    log_info "Cleaning up previous VulnLab installation..."

    if command -v pm2 &>/dev/null; then
        pm2 delete juice-shop dvna webgoat 2>/dev/null || true
        pm2 save 2>/dev/null || true
    fi

    systemctl stop apache2 mysql 2>/dev/null || true

    if [[ -d "$BASE_DIR" ]]; then
        rm -rf "$BASE_DIR"
        log_success "Removed $BASE_DIR"
    fi

    for app in dvwa bwapp xvwa mutillidae hackademic sqli-labs hackazon wackopicko; do
        rm -rf "/var/www/html/$app" 2>/dev/null || true
    done

    if [[ -f "/etc/apache2/sites-available/vuln-proxy.conf" ]]; then
        a2dissite vuln-proxy.conf 2>/dev/null || true
        rm -f "/etc/apache2/sites-available/vuln-proxy.conf"
    fi

    detect_mysql_root_password || true
    for db in dvwa bwapp mutillidae sqli_labs hackazon wackopicko hackademic xvwa; do
        mysql_exec "DROP DATABASE IF EXISTS \`${db}\`;" || true
    done
    mysql_exec "FLUSH PRIVILEGES;" || true

    log_success "Cleanup complete."
}

# ------------------------- Rollback ----------------------------------
rollback() {
    if [[ "$ROLLBACK_ON_FAILURE" == false ]]; then
        log_warn "Rollback disabled."
        return 0
    fi
    log_info "Initiating rollback procedure..."
    pm2 delete juice-shop dvna webgoat 2>/dev/null || true
    systemctl stop apache2 mysql 2>/dev/null || true
    for app in dvwa bwapp xvwa mutillidae hackademic sqli-labs hackazon wackopicko; do
        rm -rf "/var/www/html/$app" 2>/dev/null || true
    done
    a2dissite vuln-proxy.conf 2>/dev/null || true
    rm -f /etc/apache2/sites-available/vuln-proxy.conf
    systemctl reload apache2 2>/dev/null || true
    log_warn "Rollback finalized. Reverted to baseline."
}

# ------------------------- Finalization -----------------------------
final_permissions() {
    chown -R www-data:www-data /var/www/html/
    systemctl restart apache2 || die "Failed to restart Apache."
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
    pm2 list

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

    mkdir -p "$(dirname "$LOG_FILE")" "$BACKUP_DIR" "$CONFIG_DIR"

    if [[ -f "$CONFIG_FILE" ]]; then
        cp "$CONFIG_FILE" "$BACKUP_DIR/installer.conf.$(date +%Y%m%d_%H%M%S)"
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

    if [[ "$FORCE" != true ]]; then
        echo -e "${YELLOW}${BOLD}The following targets will be installed:${NC}"
        echo -e "  ${SELECTED_APPS[*]}"
        echo -e "Target Directory: ${BASE_DIR}"
        read -p "Proceed with deployment? (yes/no): " confirm
        [[ "$confirm" != "yes" ]] && die "Operation aborted by user."
    fi

    trap 'rollback; exit 1' ERR INT TERM

    # Execute Deployment Phases
    cleanup_previous
    install_dependencies
    configure_php_environment
    start_core_services

    detect_mysql_root_password
    if [[ -z "$MYSQL_PASS" ]]; then
        set_mysql_root_password "$DEFAULT_MYSQL_PASS" ""
    else
        log_info "Using existing MySQL root password."
    fi

    mkdir -p "$BASE_DIR"
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
                log_warn "Unknown target: $app. Skipping."
                ;;
        esac
    done

    create_databases
    configure_php_apps
    configure_proxy
    final_permissions

    pm2 save
    pm2 startup systemd -u root --hp /root | tail -n 1 | bash || log_warn "PM2 startup integration skipped."

    print_summary
}

main "$@"
