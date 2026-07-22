#!/bin/bash
# ================================================================
# 🧹 VulnLab Complete Cleaner & Reinstaller
# - ينظف كل شيء متعلق بـ VulnLab من السيرفر
# - يعيد تثبيت جميع الخدمات الـ 11 من الصفر
# الإصدار: 4.0 (التنظيف الشامل)
# ================================================================

set -euo pipefail

# ---------- الألوان ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

# ---------- دوال مساعدة ----------
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

# ---------- التحقق من الصلاحيات ----------
if [[ $EUID -ne 0 ]]; then
    print_error "يجب تشغيل السكربت بصلاحيات الجذر (root). استخدم: sudo $0"
    exit 1
fi

# ---------- قراءة المتغيرات ----------
ROOT_PASS="${ROOT_PASS:-root}"
BASE_DIR="${BASE_DIR:-/opt/vuln-apps}"
JUICE_PORT="${JUICE_PORT:-3000}"
DVNA_PORT="${DVNA_PORT:-4000}"
WEBGOAT_PORT="${WEBGOAT_PORT:-9090}"
LOG_FILE="/var/log/vulnlab-clean-install.log"

mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1

START_TIME=$(date +%s)

# ---------- تأكيد المستخدم ----------
print_danger "هذا السكربت سيقوم بحذف كل ما يتعلق بـ VulnLab من السيرفر:"
echo -e "  - مجلدات التطبيقات (${BASE_DIR})"
echo -e "  - الروابط الرمزية في /var/www/html"
echo -e "  - قواعد البيانات (dvwa, bwapp, ...)"
echo -e "  - عمليات PM2 (juice-shop, dvna, webgoat)"
echo -e "  - إعدادات Apache proxy"
echo -e ""
print_warning "سيتم بعدها إعادة تثبيت كل شيء من الصفر."
echo -e ""
read -p "هل أنت متأكد من المتابعة؟ (اكتب 'yes' للمتابعة): " CONFIRM
if [[ "$CONFIRM" != "yes" ]]; then
    print_error "تم الإلغاء."
    exit 0
fi

# ================================================================
# 🧹 المرحلة 1: التنظيف الشامل
# ================================================================
print_header "🧹 المرحلة 1: التنظيف الشامل للسيرفر (خاص بـ VulnLab)"

# 1.1 إيقاف وإزالة عمليات PM2
print_info "إيقاف وإزالة جميع عمليات PM2 الخاصة بـ VulnLab..."
if command -v pm2 &>/dev/null; then
    pm2 delete juice-shop 2>/dev/null || true
    pm2 delete dvna 2>/dev/null || true
    pm2 delete webgoat 2>/dev/null || true
    pm2 delete nakerah 2>/dev/null || true
    pm2 delete nakerah-lab 2>/dev/null || true
    pm2 save 2>/dev/null || true
    pm2 kill 2>/dev/null || true
    print_success "تم إيقاف عمليات PM2."
fi

# 1.2 إيقاف خدمات systemd
print_info "إيقاف خدمات systemd..."
systemctl stop apache2 2>/dev/null || true
systemctl stop mysql 2>/dev/null || true
systemctl disable apache2 2>/dev/null || true
systemctl disable mysql 2>/dev/null || true

# 1.3 حذف مجلد التطبيقات بالكامل
print_info "حذف مجلد التطبيقات: $BASE_DIR ..."
if [ -d "$BASE_DIR" ]; then
    rm -rf "$BASE_DIR"
    print_success "تم حذف $BASE_DIR"
fi

# 1.4 حذف الروابط الرمزية لتطبيقات PHP
print_info "حذف الروابط الرمزية في /var/www/html..."
for app in dvwa bwapp xvwa mutillidae hackademic sqli-labs hackazon wackopicko; do
    if [ -L "/var/www/html/$app" ] || [ -d "/var/www/html/$app" ]; then
        rm -rf "/var/www/html/$app"
        print_success "تم حذف /var/www/html/$app"
    fi
done

# 1.5 حذف إعدادات Apache proxy
print_info "حذف إعدادات Apache proxy..."
if [ -f /etc/apache2/sites-available/vuln-proxy.conf ]; then
    a2dissite vuln-proxy.conf 2>/dev/null || true
    rm -f /etc/apache2/sites-available/vuln-proxy.conf
fi
if [ -f /etc/apache2/sites-available/nakerah.conf ]; then
    a2dissite nakerah.conf 2>/dev/null || true
    rm -f /etc/apache2/sites-available/nakerah.conf
fi
systemctl reload apache2 2>/dev/null || true

# 1.6 حذف قواعد البيانات
print_info "حذف قواعد البيانات..."
if command -v mysql &>/dev/null; then
    # بدء MySQL مؤقتاً إذا لم يكن يعمل
    systemctl start mysql 2>/dev/null || true
    for db in dvwa bwapp mutillidae sqli_labs hackazon wackopicko hackademic xvwa nakerah_db nakerah; do
        mysql -u root -p${ROOT_PASS} -e "DROP DATABASE IF EXISTS $db;" 2>/dev/null || true
        print_success "تم حذف قاعدة البيانات: $db"
    done
    # حذف مستخدمي MySQL المرتبطين (إن وجدوا)
    mysql -u root -p${ROOT_PASS} -e "DROP USER IF EXISTS 'dvwa'@'localhost';" 2>/dev/null || true
    mysql -u root -p${ROOT_PASS} -e "DROP USER IF EXISTS 'bwapp'@'localhost';" 2>/dev/null || true
    mysql -u root -p${ROOT_PASS} -e "DROP USER IF EXISTS 'mutillidae'@'localhost';" 2>/dev/null || true
    mysql -u root -p${ROOT_PASS} -e "FLUSH PRIVILEGES;" 2>/dev/null || true
    systemctl stop mysql 2>/dev/null || true
fi

# 1.7 حذف ملفات مؤقتة
print_info "حذف الملفات المؤقتة..."
rm -f /tmp/bwapp.zip 2>/dev/null || true
rm -f /tmp/*nakerah* 2>/dev/null || true

# 1.8 إعادة ضبط PM2 (حذف ملفات الحالة)
print_info "إعادة ضبط PM2..."
if [ -d /root/.pm2 ]; then
    rm -rf /root/.pm2
    print_success "تم حذف /root/.pm2"
fi

print_success "✅ اكتمل التنظيف الشامل!"

# ================================================================
# 🚀 المرحلة 2: إعادة التثبيت من الصفر
# ================================================================
print_header "🚀 المرحلة 2: إعادة تثبيت جميع الخدمات الـ 11 من الصفر"

# 2.1 تحديث النظام وتثبيت التبعيات (مرة أخرى للتأكد من النظافة)
print_info "تحديث النظام وتثبيت الحزم الأساسية..."
export DEBIAN_FRONTEND=noninteractive
apt update && apt upgrade -y
apt install -y \
    apache2 mysql-server php libapache2-mod-php \
    php-mysql php-gd php-xml php-mbstring php-curl php-zip php-json \
    unzip git curl wget default-jre default-jdk nodejs npm \
    build-essential python3 make g++ net-tools

# 2.2 إعادة تثبيت Composer و PM2
print_info "تثبيت Composer..."
curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer

print_info "تثبيت PM2..."
npm install -g pm2

# 2.3 تشغيل الخدمات الأساسية
print_info "تشغيل Apache و MySQL..."
systemctl start apache2
systemctl enable apache2
systemctl start mysql
systemctl enable mysql

# تعيين كلمة مرور MySQL (نظيفة)
mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '${ROOT_PASS}';" 2>/dev/null || true
mysql -e "FLUSH PRIVILEGES;" 2>/dev/null || true
print_success "MySQL password: ${ROOT_PASS}"

# تهيئة Apache
sed -i 's/AllowOverride None/AllowOverride All/g' /etc/apache2/apache2.conf
a2enmod rewrite
systemctl restart apache2

mkdir -p "$BASE_DIR"

# 2.4 دوال الاستنساخ والتحميل
clone_repo() {
    local url="$1"
    local dir="$2"
    if [ ! -d "$dir" ]; then
        print_info "استنساخ $url ..."
        git clone --depth 1 "$url" "$dir"
    else
        print_warning "المجلد $dir موجود، تخطي."
    fi
}

download_bwapp() {
    local target_dir="$BASE_DIR/bwapp"
    if [ -f "$target_dir/bWAPP.sql" ] || [ -d "$target_dir/inc" ]; then
        print_warning "bWAPP موجود، تخطي التحميل."
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

# 2.5 تحميل التطبيقات
print_header "تحميل تطبيقات PHP"
clone_repo "https://github.com/ethicalhack3r/DVWA" "$BASE_DIR/dvwa"
download_bwapp
clone_repo "https://github.com/s4n7h0/xvwa.git" "$BASE_DIR/xvwa"
clone_repo "https://github.com/webpwnized/mutillidae" "$BASE_DIR/mutillidae"
clone_repo "https://github.com/Hackademic/hackademic.git" "$BASE_DIR/hackademic"
clone_repo "https://github.com/Audi-1/sqli-labs" "$BASE_DIR/sqli-labs"
clone_repo "https://github.com/rapid7/hackazon" "$BASE_DIR/hackazon"
clone_repo "https://github.com/adamdoupe/WackoPicko" "$BASE_DIR/wackopicko"

print_header "تحميل Node.js و Java"
clone_repo "https://github.com/juice-shop/juice-shop" "$BASE_DIR/juice-shop"
clone_repo "https://github.com/appsecco/dvna.git" "$BASE_DIR/dvna"

mkdir -p "$BASE_DIR/webgoat"
cd "$BASE_DIR/webgoat"
[ ! -f webgoat-server-*.jar ] && wget https://github.com/WebGoat/WebGoat/releases/download/v8.2.2/webgoat-server-8.2.2.jar
cd -

# 2.6 الروابط الرمزية الذكية (دعم public)
print_info "إنشاء روابط رمزية ذكية..."
PHP_APPS=("dvwa" "bwapp" "xvwa" "mutillidae" "hackademic" "sqli-labs" "hackazon" "wackopicko")
for app in "${PHP_APPS[@]}"; do
    if [ -d "$BASE_DIR/$app" ]; then
        if [ -d "$BASE_DIR/$app/public" ]; then
            TARGET="$BASE_DIR/$app/public"
        elif [ -d "$BASE_DIR/$app/htdocs" ]; then
            TARGET="$BASE_DIR/$app/htdocs"
        elif [ -d "$BASE_DIR/$app/web" ]; then
            TARGET="$BASE_DIR/$app/web"
        else
            TARGET="$BASE_DIR/$app"
        fi
        rm -rf "/var/www/html/$app" 2>/dev/null
        ln -s "$TARGET" "/var/www/html/$app"
        print_success "ربط $app → $TARGET"
    fi
done

# 2.7 قواعد البيانات
print_info "إنشاء قواعد البيانات..."
for db in dvwa bwapp mutillidae sqli_labs hackazon wackopicko hackademic xvwa; do
    mysql -uroot -p${ROOT_PASS} -e "CREATE DATABASE IF NOT EXISTS $db;"
done

# 2.8 تهيئة PHP apps
print_info "تهيئة الإعدادات..."

# DVWA
[ -f "/var/www/html/dvwa/config/config.inc.php.dist" ] && \
    cp /var/www/html/dvwa/config/config.inc.php.dist /var/www/html/dvwa/config/config.inc.php && \
    sed -i "s/p@ssw0rd/${ROOT_PASS}/g" /var/www/html/dvwa/config/config.inc.php

# bWAPP
[ -f "/var/www/html/bwapp/inc/connect.inc.php" ] && \
    sed -i "s/\$db_password = '';/\$db_password = '${ROOT_PASS}';/g" /var/www/html/bwapp/inc/connect.inc.php
[ -f "/var/www/html/bwapp/bWAPP.sql" ] && mysql -uroot -p${ROOT_PASS} bwapp < /var/www/html/bwapp/bWAPP.sql

# Mutillidae
[ -f "/var/www/html/mutillidae/sql/mutillidae.sql" ] && mysql -uroot -p${ROOT_PASS} mutillidae < /var/www/html/mutillidae/sql/mutillidae.sql
[ -f "/var/www/html/mutillidae/includes/dbConfig.php.sample" ] && \
    cp /var/www/html/mutillidae/includes/dbConfig.php.sample /var/www/html/mutillidae/includes/dbConfig.php && \
    sed -i "s/\$dbpass = '';/\$dbpass = '${ROOT_PASS}';/g" /var/www/html/mutillidae/includes/dbConfig.php

# sqli-labs
[ -f "/var/www/html/sqli-labs/sql-lab.sql" ] && mysql -uroot -p${ROOT_PASS} sqli_labs < /var/www/html/sqli-labs/sql-lab.sql
[ -f "/var/www/html/sqli-labs/sql-connections/db-creds.inc" ] && \
    sed -i "s/\$dbpass = '';/\$dbpass = '${ROOT_PASS}';/g" /var/www/html/sqli-labs/sql-connections/db-creds.inc

# Hackazon
[ -f "/var/www/html/hackazon/install/database.sql" ] && mysql -uroot -p${ROOT_PASS} hackazon < /var/www/html/hackazon/install/database.sql
[ -f "/var/www/html/hackazon/application/config/database.php" ] && \
    sed -i "s/'password' => ''/'password' => '${ROOT_PASS}'/g" /var/www/html/hackazon/application/config/database.php
cd /var/www/html/hackazon && composer install --no-dev --quiet || true && cd -

# WackoPicko
[ -f "/var/www/html/wackopicko/sql/wackopicko.sql" ] && mysql -uroot -p${ROOT_PASS} wackopicko < /var/www/html/wackopicko/sql/wackopicko.sql
[ -f "/var/www/html/wackopicko/conf/db.php.sample" ] && \
    cp /var/www/html/wackopicko/conf/db.php.sample /var/www/html/wackopicko/conf/db.php && \
    sed -i "s/password/${ROOT_PASS}/g" /var/www/html/wackopicko/conf/db.php

# Hackademic
[ -f "/var/www/html/hackademic/db/install.sql" ] && mysql -uroot -p${ROOT_PASS} hackademic < /var/www/html/hackademic/db/install.sql
[ -f "/var/www/html/hackademic/sql/install.sql" ] && mysql -uroot -p${ROOT_PASS} hackademic < /var/www/html/hackademic/sql/install.sql

# xVWA
[ -f "/var/www/html/xvwa/sql/xvwa.sql" ] && mysql -uroot -p${ROOT_PASS} xvwa < /var/www/html/xvwa/sql/xvwa.sql

# 2.9 تشغيل Node.js و Java عبر PM2
print_header "تشغيل التطبيقات المستقلة"

# إزالة أي عمليات قديمة (للتأكد)
pm2 delete juice-shop dvna webgoat 2>/dev/null || true

# Juice Shop
cd "$BASE_DIR/juice-shop"
[ ! -d "node_modules" ] && npm install --quiet
pm2 start npm --name "juice-shop" -- start -- --port "$JUICE_PORT"
print_success "Juice Shop على المنفذ $JUICE_PORT"

# DVNA
cd "$BASE_DIR/dvna"
if [ ! -d "node_modules" ]; then
    print_info "تثبيت تبعيات DVNA (قد يستغرق وقتاً)..."
    npm install bcrypt --build-from-source || npm install bcrypt --ignore-scripts
    npm install --quiet
fi
pm2 start npm --name "dvna" -- start -- --port "$DVNA_PORT"
print_success "DVNA على المنفذ $DVNA_PORT"

# WebGoat
cd "$BASE_DIR/webgoat"
pm2 start java --name "webgoat" -- -jar webgoat-server-*.jar --server.port="$WEBGOAT_PORT"
print_success "WebGoat على المنفذ $WEBGOAT_PORT"

pm2 save
pm2 startup systemd -u root --hp /root | tail -n 1
cd -

# 2.10 الوكيل العكسي
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

# 2.11 الصلاحيات النهائية
chown -R www-data:www-data /var/www/html/
systemctl restart apache2

# ================================================================
# 📊 الملخص النهائي
# ================================================================
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

echo -e "\n${CYAN}${BOLD}🔑 بيانات MySQL:${NC}"
echo -e "  - المستخدم: ${GREEN}root${NC}"
echo -e "  - كلمة المرور: ${GREEN}${ROOT_PASS}${NC}"

echo -e "\n${CYAN}${BOLD}📊 حالة الخدمات (PM2):${NC}"
pm2 list

echo -e "\n${CYAN}${BOLD}📝 سجل التثبيت:${NC} $LOG_FILE"
echo -e "\n${GREEN}${BOLD}شكراً لاستخدامك VulnLab Clean Installer! 🎉${NC}"

# فتح المنافذ (اختياري)
if command -v ufw &>/dev/null; then
    print_info "فتح المنافذ في جدار الحماية (ufw)..."
    ufw allow 80/tcp
    ufw allow "${JUICE_PORT}"/tcp
    ufw allow "${DVNA_PORT}"/tcp
    ufw allow "${WEBGOAT_PORT}"/tcp
fi

exit 0
