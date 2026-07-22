#!/bin/bash
# ================================================================
# 🚀 VulnLab Auto-Installer - احترافي لتثبيت 11 بيئة اختبار اختراق
# الإصدار: 2.0
# التاريخ: 2026-07-22
# ================================================================
# يتضمن:
#   - bWAPP, xVWA, DVWA, Mutillidae, Hackademic, sqli-labs,
#     Rapid7 Hackazon, WackoPicko, WebGoat, OWASP Juice Shop,
#     Damn Vulnerable NodeJS Application (DVNA)
# ================================================================

set -euo pipefail  # Exit on error, undefined vars, pipe failures

# ---------- الألوان ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ---------- دوال مساعدة ----------
print_header() {
    echo -e "\n${CYAN}${BOLD}═══════════════════════════════════════════════════════${NC}"
    echo -e "${MAGENTA}${BOLD}  $1${NC}"
    echo -e "${CYAN}${BOLD}═══════════════════════════════════════════════════════${NC}\n"
}

print_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

print_error() {
    echo -e "${RED}❌ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

print_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

# ---------- التحقق من صلاحيات الجذر ----------
if [[ $EUID -ne 0 ]]; then
    print_error "يجب تشغيل السكربت بصلاحيات الجذر (root). استخدم: sudo $0"
    exit 1
fi

# ---------- متغيرات قابلة للتخصيص ----------
ROOT_PASS="${ROOT_PASS:-root}"          # كلمة مرور MySQL
BASE_DIR="${BASE_DIR:-/opt/vuln-apps}"  # المجلد الأساسي
JUICE_PORT="${JUICE_PORT:-3000}"        # منفذ Juice Shop
DVNA_PORT="${DVNA_PORT:-4000}"          # منفذ DVNA
WEBGOAT_PORT="${WEBGOAT_PORT:-9090}"    # منفذ WebGoat
LOG_FILE="/var/log/vulnlab-install.log" # ملف السجل

# ---------- تهيئة السجل ----------
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1

# ---------- الوقت الحالي ----------
START_TIME=$(date +%s)

print_header "بدء تثبيت VulnLab - ${BOLD}الوقت: $(date)"

# ---------- 1. تحديث النظام وتثبيت التبعيات ----------
print_info "تحديث النظام وتثبيت الحزم الأساسية..."
export DEBIAN_FRONTEND=noninteractive
apt update && apt upgrade -y
apt install -y \
    apache2 mysql-server php libapache2-mod-php \
    php-mysql php-gd php-xml php-mbstring php-curl php-zip php-json \
    unzip git curl wget default-jre default-jdk nodejs npm \
    build-essential python3 make g++ \
    net-tools

print_success "تم تثبيت جميع الحزم الأساسية."

# ---------- 2. تثبيت Composer و PM2 ----------
print_info "تثبيت Composer (مدير حزم PHP)..."
curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer

print_info "تثبيت PM2 (مدير العمليات لـ Node.js و Java)..."
npm install -g pm2

print_success "تم تثبيت الأدوات الإضافية."

# ---------- 3. تشغيل الخدمات الأساسية ----------
print_info "تشغيل Apache و MySQL..."
systemctl start apache2
systemctl enable apache2
systemctl start mysql
systemctl enable mysql

# تعيين كلمة مرور MySQL
mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '${ROOT_PASS}';" 2>/dev/null || true
print_success "تم تعيين كلمة مرور MySQL إلى: ${ROOT_PASS}"

# تهيئة Apache
sed -i 's/AllowOverride None/AllowOverride All/g' /etc/apache2/apache2.conf
a2enmod rewrite
systemctl restart apache2

# ---------- 4. إنشاء المجلدات ----------
mkdir -p "$BASE_DIR"

# ---------- 5. دوال الاستنساخ والتحميل ----------
clone_repo() {
    local url="$1"
    local dir="$2"
    if [ ! -d "$dir" ]; then
        print_info "استنساخ $url إلى $dir ..."
        git clone --depth 1 "$url" "$dir"
    else
        print_warning "المجلد $dir موجود بالفعل، تخطي الاستنساخ."
    fi
}

download_bwapp() {
    local target_dir="$BASE_DIR/bwapp"
    if [ -f "$target_dir/bWAPP.sql" ] || [ -d "$target_dir/inc" ]; then
        print_warning "bWAPP موجود بالفعل، تخطي التحميل."
        return 0
    fi
    print_info "تحميل bWAPP من SourceForge..."
    rm -rf "$target_dir"
    wget --content-disposition https://sourceforge.net/projects/bwapp/files/bWAPP/bWAPP_latest.zip/download -O /tmp/bwapp.zip
    unzip /tmp/bwapp.zip -d "$BASE_DIR"
    local extracted=$(find "$BASE_DIR" -maxdepth 1 -type d -name "bWAPP*" | head -n 1)
    if [ -n "$extracted" ]; then
        mv "$extracted" "$target_dir"
        rm -f /tmp/bwapp.zip
        print_success "تم تحميل bWAPP."
    else
        print_error "فشل تحميل bWAPP."
        return 1
    fi
}

# ---------- 6. تحميل جميع التطبيقات ----------
print_header "تحميل تطبيقات PHP"

clone_repo "https://github.com/ethicalhack3r/DVWA" "$BASE_DIR/dvwa"
download_bwapp
clone_repo "https://github.com/s4n7h0/xvwa.git" "$BASE_DIR/xvwa"
clone_repo "https://github.com/webpwnized/mutillidae" "$BASE_DIR/mutillidae"
clone_repo "https://github.com/Hackademic/hackademic.git" "$BASE_DIR/hackademic"
clone_repo "https://github.com/Audi-1/sqli-labs" "$BASE_DIR/sqli-labs"
clone_repo "https://github.com/rapid7/hackazon" "$BASE_DIR/hackazon"
clone_repo "https://github.com/adamdoupe/WackoPicko" "$BASE_DIR/wackopicko"

print_header "تحميل تطبيقات Node.js"
clone_repo "https://github.com/juice-shop/juice-shop" "$BASE_DIR/juice-shop"
clone_repo "https://github.com/appsecco/dvna.git" "$BASE_DIR/dvna"

print_header "تحميل WebGoat (Java)"
mkdir -p "$BASE_DIR/webgoat"
cd "$BASE_DIR/webgoat"
if [ ! -f webgoat-server-*.jar ]; then
    wget https://github.com/WebGoat/WebGoat/releases/download/v8.2.2/webgoat-server-8.2.2.jar
fi
cd -

# ---------- 7. إنشاء الروابط الرمزية لتطبيقات PHP ----------
print_info "إنشاء روابط رمزية لتطبيقات PHP في /var/www/html/ ..."
PHP_APPS=("dvwa" "bwapp" "xvwa" "mutillidae" "hackademic" "sqli-labs" "hackazon" "wackopicko")
for app in "${PHP_APPS[@]}"; do
    if [ -d "$BASE_DIR/$app" ]; then
        rm -rf "/var/www/html/$app" 2>/dev/null
        ln -s "$BASE_DIR/$app" "/var/www/html/$app"
        print_success "تم ربط $app"
    else
        print_warning "المجلد $app غير موجود، تخطي الربط."
    fi
done

# ---------- 8. إعداد قواعد البيانات ----------
print_info "إنشاء قواعد البيانات..."
mysql -uroot -p${ROOT_PASS} -e "CREATE DATABASE IF NOT EXISTS dvwa;"
mysql -uroot -p${ROOT_PASS} -e "CREATE DATABASE IF NOT EXISTS bwapp;"
mysql -uroot -p${ROOT_PASS} -e "CREATE DATABASE IF NOT EXISTS mutillidae;"
mysql -uroot -p${ROOT_PASS} -e "CREATE DATABASE IF NOT EXISTS sqli_labs;"
mysql -uroot -p${ROOT_PASS} -e "CREATE DATABASE IF NOT EXISTS hackazon;"
mysql -uroot -p${ROOT_PASS} -e "CREATE DATABASE IF NOT EXISTS wackopicko;"
mysql -uroot -p${ROOT_PASS} -e "CREATE DATABASE IF NOT EXISTS hackademic;"
mysql -uroot -p${ROOT_PASS} -e "CREATE DATABASE IF NOT EXISTS xvwa;"

# ---------- 9. تهيئة كل تطبيق PHP ----------
print_info "تهيئة إعدادات PHP apps..."

# DVWA
if [ -f "/var/www/html/dvwa/config/config.inc.php.dist" ]; then
    cp /var/www/html/dvwa/config/config.inc.php.dist /var/www/html/dvwa/config/config.inc.php
    sed -i "s/p@ssw0rd/${ROOT_PASS}/g" /var/www/html/dvwa/config/config.inc.php
fi

# bWAPP
if [ -f "/var/www/html/bwapp/bWAPP.sql" ]; then
    mysql -uroot -p${ROOT_PASS} bwapp < /var/www/html/bwapp/bWAPP.sql
fi
if [ -f "/var/www/html/bwapp/inc/connect.inc.php" ]; then
    sed -i "s/root/${ROOT_PASS}/g" /var/www/html/bwapp/inc/connect.inc.php
fi

# Mutillidae
if [ -f "/var/www/html/mutillidae/sql/mutillidae.sql" ]; then
    mysql -uroot -p${ROOT_PASS} mutillidae < /var/www/html/mutillidae/sql/mutillidae.sql
    cp /var/www/html/mutillidae/includes/dbConfig.php.sample /var/www/html/mutillidae/includes/dbConfig.php 2>/dev/null || true
    sed -i "s/\$dbpass = '';/\$dbpass = '${ROOT_PASS}';/g" /var/www/html/mutillidae/includes/dbConfig.php 2>/dev/null || true
fi

# sqli-labs
if [ -f "/var/www/html/sqli-labs/sql-lab.sql" ]; then
    mysql -uroot -p${ROOT_PASS} sqli_labs < /var/www/html/sqli-labs/sql-lab.sql
    sed -i "s/\$dbpass = '';/\$dbpass = '${ROOT_PASS}';/g" /var/www/html/sqli-labs/sql-connections/db-creds.inc
fi

# Hackazon
if [ -f "/var/www/html/hackazon/install/database.sql" ]; then
    mysql -uroot -p${ROOT_PASS} hackazon < /var/www/html/hackazon/install/database.sql
    sed -i "s/'password' => ''/'password' => '${ROOT_PASS}'/g" /var/www/html/hackazon/application/config/database.php
    cd /var/www/html/hackazon
    composer install --no-dev --quiet || print_warning "فشل composer في Hackazon"
    cd -
fi

# WackoPicko
if [ -f "/var/www/html/wackopicko/sql/wackopicko.sql" ]; then
    mysql -uroot -p${ROOT_PASS} wackopicko < /var/www/html/wackopicko/sql/wackopicko.sql
    cp /var/www/html/wackopicko/conf/db.php.sample /var/www/html/wackopicko/conf/db.php 2>/dev/null || true
    sed -i "s/password/${ROOT_PASS}/g" /var/www/html/wackopicko/conf/db.php
fi

# Hackademic
if [ -f "/var/www/html/hackademic/db/install.sql" ]; then
    mysql -uroot -p${ROOT_PASS} hackademic < /var/www/html/hackademic/db/install.sql
elif [ -f "/var/www/html/hackademic/sql/install.sql" ]; then
    mysql -uroot -p${ROOT_PASS} hackademic < /var/www/html/hackademic/sql/install.sql
fi

# xVWA
if [ -f "/var/www/html/xvwa/sql/xvwa.sql" ]; then
    mysql -uroot -p${ROOT_PASS} xvwa < /var/www/html/xvwa/sql/xvwa.sql
fi

# ---------- 10. تشغيل تطبيقات Node.js و Java عبر PM2 ----------
print_header "تشغيل التطبيقات المستقلة (Node.js / Java) عبر PM2"

# إزالة أي عمليات سابقة لتجنب التكرار
pm2 delete juice-shop 2>/dev/null || true
pm2 delete dvna 2>/dev/null || true
pm2 delete webgoat 2>/dev/null || true

# Juice Shop
cd "$BASE_DIR/juice-shop"
if [ ! -d "node_modules" ]; then
    print_info "تثبيت تبعيات Juice Shop..."
    npm install --quiet
fi
pm2 start npm --name "juice-shop" -- start -- --port "$JUICE_PORT"
print_success "تم تشغيل Juice Shop على المنفذ $JUICE_PORT"

# DVNA
cd "$BASE_DIR/dvna"
if [ ! -d "node_modules" ]; then
    print_info "تثبيت تبعيات DVNA (قد يستغرق وقتاً)..."
    npm install bcrypt --build-from-source || npm install bcrypt --ignore-scripts
    npm install --quiet
fi
pm2 start npm --name "dvna" -- start -- --port "$DVNA_PORT"
print_success "تم تشغيل DVNA على المنفذ $DVNA_PORT"

# WebGoat
cd "$BASE_DIR/webgoat"
pm2 start java --name "webgoat" -- -jar webgoat-server-*.jar --server.port="$WEBGOAT_PORT"
print_success "تم تشغيل WebGoat على المنفذ $WEBGOAT_PORT"

# حفظ قائمة PM2
pm2 save
pm2 startup systemd -u root --hp /root | tail -n 1

cd -

# ---------- 11. إعداد الوكيل العكسي (Reverse Proxy) ----------
print_info "تهيئة الوكيل العكسي في Apache..."
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

# ---------- 12. صلاحيات وإعادة تشغيل نهائية ----------
chown -R www-data:www-data /var/www/html/
systemctl restart apache2

# ---------- 13. عرض الملخص النهائي ----------
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
IP=$(hostname -I | awk '{print $1}')

clear
print_header "✅ اكتمل التثبيت بنجاح!"
echo -e "${GREEN}⏱️  الوقت المستغرق: ${BOLD}$((DURATION / 60)) دقيقة و $((DURATION % 60)) ثانية${NC}\n"

echo -e "${CYAN}${BOLD}📂 تطبيقات PHP (Apache - المنفذ 80):${NC}"
for app in "${PHP_APPS[@]}"; do
    echo -e "  - ${GREEN}$app${NC}: http://${IP}/${app}/"
done

echo -e "\n${CYAN}${BOLD}🚀 التطبيقات المستقلة (عبر الوكيل العكسي):${NC}"
echo -e "  - ${GREEN}Juice Shop${NC}: http://${IP}/juice-shop/"
echo -e "  - ${GREEN}DVNA${NC}: http://${IP}/dvna/"
echo -e "  - ${GREEN}WebGoat${NC}: http://${IP}/webgoat/"

echo -e "\n${CYAN}${BOLD}🔑 بيانات الدخول إلى MySQL:${NC}"
echo -e "  - المستخدم: ${GREEN}root${NC}"
echo -e "  - كلمة المرور: ${GREEN}${ROOT_PASS}${NC}"

echo -e "\n${CYAN}${BOLD}📊 حالة الخدمات (PM2):${NC}"
pm2 list

echo -e "\n${CYAN}${BOLD}📝 سجل التثبيت:${NC} $LOG_FILE"

echo -e "\n${GREEN}${BOLD}شكراً لاستخدامك VulnLab Installer! 🎉${NC}"

# ---------- 14. فتح المنافذ في جدار الحماية (اختياري) ----------
if command -v ufw &>/dev/null; then
    print_info "فتح المنافذ في جدار الحماية (ufw)..."
    ufw allow 80/tcp
    ufw allow "${JUICE_PORT}"/tcp
    ufw allow "${DVNA_PORT}"/tcp
    ufw allow "${WEBGOAT_PORT}"/tcp
fi

exit 0
