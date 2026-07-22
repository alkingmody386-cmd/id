#!/bin/bash
# Auto-install script for 11 vulnerable web apps on Ubuntu Server
set -e

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Check for root privileges
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}This script must be run as root. Use sudo.${NC}" 
   exit 1
fi

# ------------------- Configuration -------------------
ROOT_PASS="root"    # MySQL root password (lab environment)
BASE_DIR="/opt/vuln-apps"
PHP_APPS=("dvwa" "bwapp" "xvwa" "mutillidae" "hackademic" "sqli-labs" "hackazon" "wackopicko")
NODE_APPS=("juice-shop" "dvna")
# ----------------------------------------------------

echo -e "${GREEN}[+] Updating system and installing core dependencies...${NC}"
export DEBIAN_FRONTEND=noninteractive
apt update && apt upgrade -y
apt install -y apache2 mysql-server php libapache2-mod-php \
    php-mysql php-gd php-xml php-mbstring php-curl php-zip php-json \
    unzip git curl wget default-jre default-jdk nodejs npm build-essential

# Install Composer globally (needed for Hackazon)
echo -e "${GREEN}[+] Installing Composer...${NC}"
curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer

# Install PM2 globally (process manager for Node/Java apps)
echo -e "${GREEN}[+] Installing PM2...${NC}"
npm install -g pm2

# ------------------- Services Setup -------------------
echo -e "${GREEN}[+] Starting and enabling Apache & MySQL...${NC}"
systemctl start apache2
systemctl enable apache2
systemctl start mysql
systemctl enable mysql

# Set MySQL root password
echo -e "${GREEN}[+] Setting MySQL root password to 'root'...${NC}"
mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '${ROOT_PASS}';" || true

# Configure Apache to allow .htaccess (DVWA requires this)
echo -e "${GREEN}[+] Configuring Apache...${NC}"
sed -i 's/AllowOverride None/AllowOverride All/g' /etc/apache2/apache2.conf
a2enmod rewrite
systemctl restart apache2

# ------------------- Create Base Directory -------------------
mkdir -p $BASE_DIR

# Helper function to clone repos
clone_repo() {
    local url=$1
    local dir=$2
    if [ ! -d "$dir" ]; then
        git clone --depth 1 $url $dir
    else
        echo -e "${YELLOW}[!] $dir already exists, skipping clone.${NC}"
    fi
}

# ------------------- Clone PHP Applications -------------------
echo -e "${GREEN}[+] Cloning PHP-based applications...${NC}"
clone_repo "https://github.com/ethicalhack3r/DVWA" "$BASE_DIR/dvwa"

# --- bWAPP: download from SourceForge ONLY if not already present ---
BWAPP_DIR="$BASE_DIR/bwapp"
# Check if bWAPP is already downloaded and extracted properly (check for key files)
if [ -f "$BWAPP_DIR/bWAPP.sql" ] || [ -d "$BWAPP_DIR/inc" ]; then
    echo -e "${YELLOW}[!] bWAPP already exists in $BWAPP_DIR. Skipping download.${NC}"
else
    echo -e "${GREEN}[+] Downloading bWAPP from SourceForge...${NC}"
    if [ -d "$BWAPP_DIR" ]; then
        rm -rf "$BWAPP_DIR"
    fi
    wget --content-disposition https://sourceforge.net/projects/bwapp/files/bWAPP/bWAPP_latest.zip/download -O /tmp/bwapp.zip
    unzip /tmp/bwapp.zip -d "$BASE_DIR"
    EXTRACTED_DIR=$(find "$BASE_DIR" -maxdepth 1 -type d -name "bWAPP*" | head -n 1)
    if [ -n "$EXTRACTED_DIR" ]; then
        mv "$EXTRACTED_DIR" "$BWAPP_DIR"
    else
        echo -e "${RED}[!] Could not find extracted bWAPP folder. Exiting.${NC}"
        exit 1
    fi
    rm -f /tmp/bwapp.zip
fi
# ----------------------------------------------------------------

clone_repo "https://github.com/s4n7h0/xvwa.git" "$BASE_DIR/xvwa"
clone_repo "https://github.com/webpwnized/mutillidae" "$BASE_DIR/mutillidae"
clone_repo "https://github.com/Hackademic/hackademic.git" "$BASE_DIR/hackademic"
clone_repo "https://github.com/Audi-1/sqli-labs" "$BASE_DIR/sqli-labs"
clone_repo "https://github.com/rapid7/hackazon" "$BASE_DIR/hackazon"
clone_repo "https://github.com/adamdoupe/WackoPicko" "$BASE_DIR/wackopicko"

# ------------------- Clone Node.js Applications -------------------
echo -e "${GREEN}[+] Cloning Node.js applications...${NC}"
clone_repo "https://github.com/juice-shop/juice-shop" "$BASE_DIR/juice-shop"
# --- DVNA: using the new official repository ---
clone_repo "https://github.com/appsecco/dvna.git" "$BASE_DIR/dvna"
# ------------------------------------------------

# ------------------- Download WebGoat (Java JAR) -------------------
echo -e "${GREEN}[+] Downloading WebGoat...${NC}"
mkdir -p "$BASE_DIR/webgoat"
cd "$BASE_DIR/webgoat"
if [ ! -f webgoat-server-*.jar ]; then
    wget https://github.com/WebGoat/WebGoat/releases/download/v8.2.2/webgoat-server-8.2.2.jar
fi
cd -

# ------------------- Symlink PHP Apps to /var/www/html -------------------
echo -e "${GREEN}[+] Symlinking PHP apps to /var/www/html/...${NC}"
for app in "${PHP_APPS[@]}"; do
    if [ -d "$BASE_DIR/$app" ]; then
        ln -sf "$BASE_DIR/$app" "/var/www/html/$app"
    fi
done

# ------------------- Database Setup (Create DBs) -------------------
echo -e "${GREEN}[+] Creating databases...${NC}"
mysql -uroot -p${ROOT_PASS} -e "CREATE DATABASE IF NOT EXISTS dvwa;"
mysql -uroot -p${ROOT_PASS} -e "CREATE DATABASE IF NOT EXISTS bwapp;"
mysql -uroot -p${ROOT_PASS} -e "CREATE DATABASE IF NOT EXISTS mutillidae;"
mysql -uroot -p${ROOT_PASS} -e "CREATE DATABASE IF NOT EXISTS sqli_labs;"
mysql -uroot -p${ROOT_PASS} -e "CREATE DATABASE IF NOT EXISTS hackazon;"
mysql -uroot -p${ROOT_PASS} -e "CREATE DATABASE IF NOT EXISTS wackopicko;"
mysql -uroot -p${ROOT_PASS} -e "CREATE DATABASE IF NOT EXISTS hackademic;"
mysql -uroot -p${ROOT_PASS} -e "CREATE DATABASE IF NOT EXISTS xvwa;"

# ------------------- Configure Individual PHP Apps -------------------
echo -e "${GREEN}[+] Configuring individual PHP apps...${NC}"

# 1. DVWA
if [ -f "/var/www/html/dvwa/config/config.inc.php.dist" ]; then
    cp /var/www/html/dvwa/config/config.inc.php.dist /var/www/html/dvwa/config/config.inc.php
    sed -i "s/p@ssw0rd/${ROOT_PASS}/g" /var/www/html/dvwa/config/config.inc.php
fi

# 2. bWAPP
if [ -f "/var/www/html/bwapp/bWAPP.sql" ]; then
    mysql -uroot -p${ROOT_PASS} bwapp < /var/www/html/bwapp/bWAPP.sql
fi
if [ -f "/var/www/html/bwapp/inc/connect.inc.php" ]; then
    sed -i "s/root/${ROOT_PASS}/g" /var/www/html/bwapp/inc/connect.inc.php
fi

# 3. Mutillidae
if [ -f "/var/www/html/mutillidae/sql/mutillidae.sql" ]; then
    mysql -uroot -p${ROOT_PASS} mutillidae < /var/www/html/mutillidae/sql/mutillidae.sql
    cp /var/www/html/mutillidae/includes/dbConfig.php.sample /var/www/html/mutillidae/includes/dbConfig.php 2>/dev/null || true
    sed -i "s/\$dbpass = '';/\$dbpass = '${ROOT_PASS}';/g" /var/www/html/mutillidae/includes/dbConfig.php 2>/dev/null || true
fi

# 4. sqli-labs
if [ -f "/var/www/html/sqli-labs/sql-lab.sql" ]; then
    mysql -uroot -p${ROOT_PASS} sqli_labs < /var/www/html/sqli-labs/sql-lab.sql
    sed -i "s/\$dbpass = '';/\$dbpass = '${ROOT_PASS}';/g" /var/www/html/sqli-labs/sql-connections/db-creds.inc
fi

# 5. Hackazon (Rapid7) - needs Composer
if [ -f "/var/www/html/hackazon/install/database.sql" ]; then
    mysql -uroot -p${ROOT_PASS} hackazon < /var/www/html/hackazon/install/database.sql
    sed -i "s/'password' => ''/'password' => '${ROOT_PASS}'/g" /var/www/html/hackazon/application/config/database.php
    cd /var/www/html/hackazon
    composer install --no-dev --quiet
    cd -
fi

# 6. WackoPicko
if [ -f "/var/www/html/wackopicko/sql/wackopicko.sql" ]; then
    mysql -uroot -p${ROOT_PASS} wackopicko < /var/www/html/wackopicko/sql/wackopicko.sql
    cp /var/www/html/wackopicko/conf/db.php.sample /var/www/html/wackopicko/conf/db.php 2>/dev/null || true
    sed -i "s/password/${ROOT_PASS}/g" /var/www/html/wackopicko/conf/db.php
fi

# 7. Hackademic
if [ -f "/var/www/html/hackademic/db/install.sql" ]; then
    mysql -uroot -p${ROOT_PASS} hackademic < /var/www/html/hackademic/db/install.sql
elif [ -f "/var/www/html/hackademic/sql/install.sql" ]; then
    mysql -uroot -p${ROOT_PASS} hackademic < /var/www/html/hackademic/sql/install.sql
else
    echo -e "${YELLOW}[!] Hackademic SQL file not found. Skipping DB import.${NC}"
fi

# 8. xVWA
if [ -f "/var/www/html/xvwa/sql/xvwa.sql" ]; then
    mysql -uroot -p${ROOT_PASS} xvwa < /var/www/html/xvwa/sql/xvwa.sql
fi

# ------------------- Setup Node.js Apps with PM2 -------------------
echo -e "${GREEN}[+] Setting up Node.js applications (Juice Shop & DVNA)...${NC}"

# Juice Shop (port 3000)
cd $BASE_DIR/juice-shop
if [ ! -d "node_modules" ]; then
    npm install --quiet
fi
pm2 start npm --name "juice-shop" -- start -- --port 3000
cd -

# Damn Vulnerable NodeJS Application - DVNA (port 4000)
cd $BASE_DIR/dvna
if [ ! -d "node_modules" ]; then
    npm install --quiet
fi
pm2 start npm --name "dvna" -- start -- --port 4000
cd -

# ------------------- Setup WebGoat (Java) with PM2 -------------------
echo -e "${GREEN}[+] Setting up WebGoat (port 9090)...${NC}"
cd $BASE_DIR/webgoat
pm2 start java --name "webgoat" -- -jar webgoat-server-8.2.2.jar --server.port=9090
cd -

# Save PM2 processes and enable startup
pm2 save
pm2 startup systemd -u root --hp /root | tail -n 1

# ------------------- Final Permissions & Restart -------------------
chown -R www-data:www-data /var/www/html/
systemctl restart apache2

# ------------------- Output Summary -------------------
IP=$(hostname -I | awk '{print $1}')
echo -e "\n${GREEN}========================================${NC}"
echo -e "${GREEN}✅ INSTALLATION COMPLETE!${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "${YELLOW}📂 PHP Apps (Apache - Port 80):${NC}"
for app in "${PHP_APPS[@]}"; do
    echo -e "  - $app: http://${IP}/${app}/"
done
echo -e "${YELLOW}🚀 Standalone Apps (Managed by PM2):${NC}"
echo -e "  - Juice Shop: http://${IP}:3000/"
echo -e "  - DVNA: http://${IP}:4000/"
echo -e "  - WebGoat: http://${IP}:9090/WebGoat/"
echo -e "${YELLOW}🔑 MySQL Credentials:${NC}"
echo -e "  - Username: root"
echo -e "  - Password: root"
echo -e "${GREEN}========================================${NC}"
