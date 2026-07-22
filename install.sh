#!/bin/bash
# ================================================================
# 🧹 VulnLab Professional Cleaner & Reinstaller
# - Completely removes all VulnLab components
# - Freshly installs all 11 vulnerable applications
# - Node.js 20.x LTS for Juice Shop compatibility
# Version: 5.1 (Node.js 20 fix)
# ================================================================

set -euo pipefail

# ---------- Colors ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

# ---------- Global Variables ----------
ROOT_PASS="${ROOT_PASS:-}"
BASE_DIR="${BASE_DIR:-/opt/vuln-apps}"
JUICE_PORT="${JUICE_PORT:-3000}"
DVNA_PORT="${DVNA_PORT:-4000}"
WEBGOAT_PORT="${WEBGOAT_PORT:-9090}"
LOG_FILE="/var/log/vulnlab-clean-install.log"
START_TIME=$(date +%s)

# ---------- Helper Functions ----------
print_header() {
    echo -e "\n${CYAN}${BOLD}═══════════════════════════════════════════════════════${NC}"
    echo -e "${MAGENTA}${BOLD}  $1${NC}"
    echo -e "${CYAN}${BOLD}═══════════════════════════════════════════════════════${NC}\n"
}
print_success() { echo -e "${GREEN}✅ $1${NC}"; }
print_error() { echo -e "${RED}❌ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
print_info() { echo -e "${BLUE}ℹ️  $1${NC}"; }
print_danger() { echo -e "${RED}${BOLD}🔥 $1${NC}"; }

die() {
    print_error "$1"
    exit 1
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        die "This script must be run as root. Use: sudo $0"
    fi
}

setup_logging() {
    mkdir -p "$(dirname "$LOG_FILE")"
    exec > >(tee -a "$LOG_FILE") 2>&1
}

trap_error() {
    print_error "An unexpected error occurred on line $1. Check the log: $LOG_FILE"
    exit 1
}
trap 'trap_error $LINENO' ERR

# ---------- Pre-flight Checks ----------
check_root
setup_logging

# Ask for MySQL root password if not set via env
if [[ -z "$ROOT_PASS" ]]; then
    echo -e "${YELLOW}Enter a password for MySQL root (leave empty for 'root'):${NC}"
    read -s -p "Password: " ROOT_PASS
    echo
    ROOT_PASS="${ROOT_PASS:-root}"
fi

# ---------- User Confirmation ----------
print_danger "This script will DELETE all VulnLab-related data from your server:"
echo -e "  - Application folder (${BASE_DIR})"
echo -e "  - Symbolic links in /var/www/html"
echo -e "  - Databases (dvwa, bwapp, ...)"
echo -e "  - PM2 processes (juice-shop, dvna, webgoat)"
echo -e "  - Apache proxy configuration"
echo -e ""
print_warning "After cleanup, it will perform a fresh installation of all services."
echo -e ""
read -p "Are you sure you want to continue? (type 'yes' to proceed): " CONFIRM
if [[ "$CONFIRM" != "yes" ]]; then
    die "Aborted by user."
fi

# ================================================================
# Phase 1: Full Cleanup
# ================================================================
print_header "🧹 Phase 1: Full Cleanup (VulnLab only)"

cleanup_pm2() {
    print_info "Stopping and removing PM2 processes..."
    if command_exists pm2; then
        pm2 delete juice-shop dvna webgoat nakerah nakerah-lab 2>/dev/null || true
        pm2 save 2>/dev/null || true
        pm2 kill 2>/dev/null || true
        print_success "PM2 processes stopped."
    fi
}

cleanup_services() {
    print_info "Stopping system services..."
    systemctl stop apache2 2>/dev/null || true
    systemctl stop mysql 2>/dev/null || true
    systemctl disable apache2 2>/dev/null || true
    systemctl disable mysql 2>/dev/null || true
}

cleanup_apps() {
    print_info "Removing application folder: $BASE_DIR ..."
    [[ -d "$BASE_DIR" ]] && rm -rf "$BASE_DIR" && print_success "Removed $BASE_DIR"

    print_info "Removing symbolic links in /var/www/html..."
    for app in dvwa bwapp xvwa mutillidae hackademic sqli-labs hackazon wackopicko; do
        target="/var/www/html/$app"
        if [[ -L "$target" || -d "$target" ]]; then
            rm -rf "$target"
            print_success "Removed $target"
        fi
    done
}

cleanup_apache_proxy() {
    print_info "Removing Apache proxy configuration..."
    if [[ -f /etc/apache2/sites-available/vuln-proxy.conf ]]; then
        a2dissite vuln-proxy.conf 2>/dev/null || true
        rm -f /etc/apache2/sites-available/vuln-proxy.conf
    fi
    if [[ -f /etc/apache2/sites-available/nakerah.conf ]]; then
        a2dissite nakerah.conf 2>/dev/null || true
        rm -f /etc/apache2/sites-available/nakerah.conf
    fi
    systemctl reload apache2 2>/dev/null || true
}

cleanup_mysql() {
    print_info "Dropping databases and users..."
    if command_exists mysql; then
        systemctl start mysql 2>/dev/null || true
        # Attempt to connect with given password, fallback to no password
        mysql_cmd="mysql -u root -p${ROOT_PASS}"
        if ! echo "SELECT 1" | $mysql_cmd &>/dev/null; then
            print_warning "Could not connect with password, trying without password (may fail)..."
            mysql_cmd="mysql -u root"
        fi
        for db in dvwa bwapp mutillidae sqli_labs hackazon wackopicko hackademic xvwa nakerah_db nakerah; do
            $mysql_cmd -e "DROP DATABASE IF EXISTS $db;" 2>/dev/null || true
            print_success "Dropped database: $db"
        done
        $mysql_cmd -e "DROP USER IF EXISTS 'dvwa'@'localhost';" 2>/dev/null || true
        $mysql_cmd -e "DROP USER IF EXISTS 'bwapp'@'localhost';" 2>/dev/null || true
        $mysql_cmd -e "DROP USER IF EXISTS 'mutillidae'@'localhost';" 2>/dev/null || true
        $mysql_cmd -e "FLUSH PRIVILEGES;" 2>/dev/null || true
        systemctl stop mysql 2>/dev/null || true
    fi
}

cleanup_tmp() {
    print_info "Removing temporary files..."
    rm -f /tmp/bwapp.zip /tmp/*nakerah* 2>/dev/null || true
}

cleanup_pm2_state() {
    print_info "Resetting PM2 state..."
    if [[ -d /root/.pm2 ]]; then
        rm -rf /root/.pm2
        print_success "Removed /root/.pm2"
    fi
}

# Execute cleanup steps
cleanup_pm2
cleanup_services
cleanup_apps
cleanup_apache_proxy
cleanup_mysql
cleanup_tmp
cleanup_pm2_state

print_success "✅ Cleanup completed!"

# ================================================================
# Phase 2: Fresh Installation
# ================================================================
print_header "🚀 Phase 2: Fresh Installation of All 11 Services"

install_dependencies() {
    print_info "Updating system and installing core packages..."
    export DEBIAN_FRONTEND=noninteractive
    apt update && apt upgrade -y
    # Install Node.js 20.x from NodeSource (required for Juice Shop)
    print_info "Installing Node.js 20.x LTS from NodeSource..."
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt install -y nodejs

    # Install other required packages (without nodejs/npm from apt)
    apt install -y --no-install-recommends \
        apache2 mysql-server php libapache2-mod-php \
        php-mysql php-gd php-xml php-mbstring php-curl php-zip php-json \
        unzip git curl wget default-jre default-jdk \
        build-essential python3 make g++ net-tools

    # Verify Node version
    NODE_VERSION=$(node -v | cut -d'v' -f2 | cut -d'.' -f1)
    if [[ $NODE_VERSION -lt 20 ]]; then
        die "Node.js version is $NODE_VERSION, but v20+ is required. Installation failed."
    fi
    print_success "Node.js $(node -v) installed successfully."
}

install_composer_pm2() {
    print_info "Installing Composer..."
    curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer

    print_info "Installing PM2..."
    npm install -g pm2
    print_success "Composer and PM2 installed."
}

start_core_services() {
    print_info "Starting Apache and MySQL..."
    systemctl start apache2
    systemctl enable apache2
    systemctl start mysql
    systemctl enable mysql

    # Set MySQL root password
    mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '${ROOT_PASS}';" 2>/dev/null || true
    mysql -e "FLUSH PRIVILEGES;" 2>/dev/null || true
    print_success "MySQL password set to: ${ROOT_PASS}"

    # Configure Apache
    sed -i 's/AllowOverride None/AllowOverride All/g' /etc/apache2/apache2.conf
    a2enmod rewrite
    systemctl restart apache2
}

# Function to clone with retry
clone_repo() {
    local url="$1"
    local dir="$2"
    if [[ -d "$dir" ]]; then
        print_warning "$dir already exists, skipping."
        return 0
    fi
    print_info "Cloning $url ..."
    for i in {1..3}; do
        if git clone --depth 1 "$url" "$dir"; then
            print_success "Cloned $dir"
            return 0
        fi
        print_warning "Clone attempt $i failed, retrying..."
        sleep 2
    done
    die "Failed to clone $url after 3 attempts."
}

# Improved bWAPP download
download_bwapp() {
    local target_dir="$BASE_DIR/bwapp"
    if [[ -f "$target_dir/bWAPP.sql" || -d "$target_dir/inc" ]]; then
        print_warning "bWAPP already exists, skipping download."
        return 0
    fi
    print_info "Downloading bWAPP from SourceForge..."
    rm -rf "$target_dir" /tmp/bwapp.zip
    wget --timeout=60 --tries=3 https://sourceforge.net/projects/bwapp/files/bWAPP/bWAPP_latest.zip/download -O /tmp/bwapp.zip || die "Failed to download bWAPP."
    unzip -q /tmp/bwapp.zip -d "$BASE_DIR" || die "Failed to unzip bWAPP."
    local extracted=$(find "$BASE_DIR" -maxdepth 1 -type d -name "bWAPP*" | head -n 1)
    if [[ -n "$extracted" ]]; then
        mv "$extracted" "$target_dir"
        rm -f /tmp/bwapp.zip
        print_success "bWAPP installed."
    else
        die "Could not locate extracted bWAPP folder."
    fi
}

clone_apps() {
    print_header "Downloading PHP Applications"
    clone_repo "https://github.com/ethicalhack3r/DVWA" "$BASE_DIR/dvwa"
    download_bwapp
    clone_repo "https://github.com/s4n7h0/xvwa.git" "$BASE_DIR/xvwa"
    clone_repo "https://github.com/webpwnized/mutillidae" "$BASE_DIR/mutillidae"
    clone_repo "https://github.com/Hackademic/hackademic.git" "$BASE_DIR/hackademic"
    clone_repo "https://github.com/Audi-1/sqli-labs" "$BASE_DIR/sqli-labs"
    clone_repo "https://github.com/rapid7/hackazon" "$BASE_DIR/hackazon"
    clone_repo "https://github.com/adamdoupe/WackoPicko" "$BASE_DIR/wackopicko"

    print_header "Downloading Node.js and Java Apps"
    clone_repo "https://github.com/juice-shop/juice-shop" "$BASE_DIR/juice-shop"
    clone_repo "https://github.com/appsecco/dvna.git" "$BASE_DIR/dvna"

    mkdir -p "$BASE_DIR/webgoat"
    cd "$BASE_DIR/webgoat"
    if [[ ! -f webgoat-server-*.jar ]]; then
        wget --timeout=60 --tries=3 https://github.com/WebGoat/WebGoat/releases/download/v8.2.2/webgoat-server-8.2.2.jar || die "Failed to download WebGoat JAR."
    fi
    cd -
}

create_symlinks() {
    print_info "Creating smart symbolic links..."
    local PHP_APPS=("dvwa" "bwapp" "xvwa" "mutillidae" "hackademic" "sqli-labs" "hackazon" "wackopicko")
    for app in "${PHP_APPS[@]}"; do
        local app_dir="$BASE_DIR/$app"
        if [[ -d "$app_dir" ]]; then
            local target
            if [[ -d "$app_dir/public" ]]; then
                target="$app_dir/public"
            elif [[ -d "$app_dir/htdocs" ]]; then
                target="$app_dir/htdocs"
            elif [[ -d "$app_dir/web" ]]; then
                target="$app_dir/web"
            else
                target="$app_dir"
            fi
            rm -rf "/var/www/html/$app" 2>/dev/null
            ln -s "$target" "/var/www/html/$app"
            print_success "Linked $app → $target"
        fi
    done
}

setup_databases() {
    print_info "Creating databases..."
    local mysql_cmd="mysql -u root -p${ROOT_PASS}"
    for db in dvwa bwapp mutillidae sqli_labs hackazon wackopicko hackademic xvwa; do
        $mysql_cmd -e "CREATE DATABASE IF NOT EXISTS $db;" 2>/dev/null || true
    done
}

configure_php_apps() {
    print_info "Configuring PHP applications..."
    local mysql_cmd="mysql -u root -p${ROOT_PASS}"

    # DVWA
    if [[ -f "/var/www/html/dvwa/config/config.inc.php.dist" ]]; then
        cp /var/www/html/dvwa/config/config.inc.php.dist /var/www/html/dvwa/config/config.inc.php
        sed -i "s/p@ssw0rd/${ROOT_PASS}/g" /var/www/html/dvwa/config/config.inc.php
    fi

    # bWAPP
    if [[ -f "/var/www/html/bwapp/inc/connect.inc.php" ]]; then
        sed -i "s/\$db_password = '';/\$db_password = '${ROOT_PASS}';/g" /var/www/html/bwapp/inc/connect.inc.php
    fi
    if [[ -f "/var/www/html/bwapp/bWAPP.sql" ]]; then
        $mysql_cmd bwapp < /var/www/html/bwapp/bWAPP.sql 2>/dev/null || true
    fi

    # Mutillidae
    if [[ -f "/var/www/html/mutillidae/sql/mutillidae.sql" ]]; then
        $mysql_cmd mutillidae < /var/www/html/mutillidae/sql/mutillidae.sql 2>/dev/null || true
    fi
    if [[ -f "/var/www/html/mutillidae/includes/dbConfig.php.sample" ]]; then
        cp /var/www/html/mutillidae/includes/dbConfig.php.sample /var/www/html/mutillidae/includes/dbConfig.php
        sed -i "s/\$dbpass = '';/\$dbpass = '${ROOT_PASS}';/g" /var/www/html/mutillidae/includes/dbConfig.php
    fi

    # sqli-labs
    if [[ -f "/var/www/html/sqli-labs/sql-lab.sql" ]]; then
        $mysql_cmd sqli_labs < /var/www/html/sqli-labs/sql-lab.sql 2>/dev/null || true
    fi
    if [[ -f "/var/www/html/sqli-labs/sql-connections/db-creds.inc" ]]; then
        sed -i "s/\$dbpass = '';/\$dbpass = '${ROOT_PASS}';/g" /var/www/html/sqli-labs/sql-connections/db-creds.inc
    fi

    # Hackazon
    if [[ -f "/var/www/html/hackazon/install/database.sql" ]]; then
        $mysql_cmd hackazon < /var/www/html/hackazon/install/database.sql 2>/dev/null || true
    fi
    if [[ -f "/var/www/html/hackazon/application/config/database.php" ]]; then
        sed -i "s/'password' => ''/'password' => '${ROOT_PASS}'/g" /var/www/html/hackazon/application/config/database.php
    fi
    cd /var/www/html/hackazon && composer install --no-dev --quiet || true && cd -

    # WackoPicko
    if [[ -f "/var/www/html/wackopicko/sql/wackopicko.sql" ]]; then
        $mysql_cmd wackopicko < /var/www/html/wackopicko/sql/wackopicko.sql 2>/dev/null || true
    fi
    if [[ -f "/var/www/html/wackopicko/conf/db.php.sample" ]]; then
        cp /var/www/html/wackopicko/conf/db.php.sample /var/www/html/wackopicko/conf/db.php
        sed -i "s/password/${ROOT_PASS}/g" /var/www/html/wackopicko/conf/db.php
    fi

    # Hackademic
    if [[ -f "/var/www/html/hackademic/db/install.sql" ]]; then
        $mysql_cmd hackademic < /var/www/html/hackademic/db/install.sql 2>/dev/null || true
    fi
    if [[ -f "/var/www/html/hackademic/sql/install.sql" ]]; then
        $mysql_cmd hackademic < /var/www/html/hackademic/sql/install.sql 2>/dev/null || true
    fi

    # xVWA
    if [[ -f "/var/www/html/xvwa/sql/xvwa.sql" ]]; then
        $mysql_cmd xvwa < /var/www/html/xvwa/sql/xvwa.sql 2>/dev/null || true
    fi
}

start_node_java_apps() {
    print_header "Starting standalone apps (Node.js / Java) via PM2"

    # Remove any stale processes
    pm2 delete juice-shop dvna webgoat 2>/dev/null || true

    # Juice Shop
    cd "$BASE_DIR/juice-shop"
    if [[ ! -d "node_modules" ]]; then
        print_info "Installing Juice Shop dependencies (may take a while)..."
        npm install --quiet || die "Juice Shop npm install failed."
    fi
    pm2 start npm --name "juice-shop" -- start -- --port "$JUICE_PORT"
    print_success "Juice Shop started on port $JUICE_PORT"

    # DVNA
    cd "$BASE_DIR/dvna"
    if [[ ! -d "node_modules" ]]; then
        print_info "Installing DVNA dependencies (may take a while)..."
        npm install bcrypt --build-from-source || npm install bcrypt --ignore-scripts
        npm install --quiet || die "DVNA npm install failed."
    fi
    pm2 start npm --name "dvna" -- start -- --port "$DVNA_PORT"
    print_success "DVNA started on port $DVNA_PORT"

    # WebGoat
    cd "$BASE_DIR/webgoat"
    pm2 start java --name "webgoat" -- -jar webgoat-server-*.jar --server.port="$WEBGOAT_PORT"
    print_success "WebGoat started on port $WEBGOAT_PORT"

    pm2 save
    # Enable PM2 startup (automatically run the printed command)
    pm2 startup systemd -u root --hp /root | tail -n 1 | bash
    cd -
}

setup_reverse_proxy() {
    print_info "Configuring Apache reverse proxy..."
    a2enmod proxy proxy_http
    cat > /etc/apache2/sites-available/vuln-proxy.conf <<EOF
# Proxy configuration for VulnLab
ProxyPass /juice-shop http://localhost:${JUICE_PORT}/
ProxyPassReverse /juice-shop http://localhost:${JUICE_PORT}/

ProxyPass /dvna http://localhost:${DVNA_PORT}/
ProxyPassReverse /dvna http://localhost:${DVNA_PORT}/

ProxyPass /webgoat http://localhost:${WEBGOAT_PORT}/WebGoat/
ProxyPassReverse /webgoat http://localhost:${WEBGOAT_PORT}/WebGoat/
EOF
    a2ensite vuln-proxy.conf
    systemctl reload apache2
}

final_permissions() {
    chown -R www-data:www-data /var/www/html/
    systemctl restart apache2
}

# Execute installation steps
install_dependencies
install_composer_pm2
start_core_services
clone_apps
create_symlinks
setup_databases
configure_php_apps
start_node_java_apps
setup_reverse_proxy
final_permissions

# ================================================================
# Final Summary
# ================================================================
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
IP=$(hostname -I | awk '{print $1}')
PHP_APPS=("dvwa" "bwapp" "xvwa" "mutillidae" "hackademic" "sqli-labs" "hackazon" "wackopicko")

clear
print_header "✅ Installation Complete!"
echo -e "${GREEN}⏱️  Time taken: ${BOLD}$((DURATION / 60)) minutes and $((DURATION % 60)) seconds${NC}\n"

echo -e "${CYAN}${BOLD}📂 PHP Apps (Apache - Port 80):${NC}"
for app in "${PHP_APPS[@]}"; do
    echo -e "  - ${GREEN}$app${NC}: http://${IP}/${app}/"
done

echo -e "\n${CYAN}${BOLD}🚀 Standalone Apps (via Reverse Proxy):${NC}"
echo -e "  - ${GREEN}Juice Shop${NC}: http://${IP}/juice-shop/"
echo -e "  - ${GREEN}DVNA${NC}: http://${IP}/dvna/"
echo -e "  - ${GREEN}WebGoat${NC}: http://${IP}/webgoat/"

echo -e "\n${CYAN}${BOLD}🔑 MySQL Credentials:${NC}"
echo -e "  - Username: ${GREEN}root${NC}"
echo -e "  - Password: ${GREEN}${ROOT_PASS}${NC}"

echo -e "\n${CYAN}${BOLD}📊 PM2 Status:${NC}"
pm2 list

echo -e "\n${CYAN}${BOLD}📝 Installation Log:${NC} $LOG_FILE"
echo -e "\n${GREEN}${BOLD}Thank you for using VulnLab Professional Installer! 🎉${NC}"

# Optional firewall opening
if command_exists ufw; then
    print_info "Opening ports in firewall (ufw)..."
    ufw allow 80/tcp
    ufw allow "${JUICE_PORT}"/tcp
    ufw allow "${DVNA_PORT}"/tcp
    ufw allow "${WEBGOAT_PORT}"/tcp
fi

exit 0
