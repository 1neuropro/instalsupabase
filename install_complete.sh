#!/usr/bin/env bash

set -euo pipefail

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
  echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} ${GREEN}[$1]${NC} $2"
}

warn() {
  echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} ${YELLOW}[WARNING]${NC} $1"
}

error() {
  echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} ${RED}[ERROR]${NC} $1"
  exit 1
}

# Проверка, что скрипт запущен под root
if [[ $EUID -ne 0 ]]; then
   error "Этот скрипт должен быть запущен от имени root (sudo)"
fi

# Проверка Ubuntu
if ! grep -q "Ubuntu" /etc/os-release; then
    error "Скрипт предназначен для Ubuntu. Обнаружена другая ОС."
fi

log "INFO" "🚀 Запуск полной установки Supabase self-hosted..."

# Сбор пользовательских данных
echo ""

# Проверяем переменные окружения или запрашиваем интерактивно
if [[ -n "${SUPABASE_DOMAIN:-}" ]]; then
    DOMAIN="$SUPABASE_DOMAIN"
    log "INFO" "Используется домен из переменной окружения: $DOMAIN"
else
    read -p "Введите домен (например: supabase.example.com): " DOMAIN
    if [[ -z "$DOMAIN" ]]; then
        error "Домен не может быть пустым"
    fi
fi

if [[ -n "${SUPABASE_EMAIL:-}" ]]; then
    EMAIL="$SUPABASE_EMAIL"
    log "INFO" "Используется email из переменной окружения: $EMAIL"
else
    read -p "Введите email для SSL сертификата: " EMAIL
    if [[ -z "$EMAIL" ]]; then
        error "Email не может быть пустым"
    fi
fi

if [[ -n "${SUPABASE_USERNAME:-}" ]]; then
    DASHBOARD_USERNAME="$SUPABASE_USERNAME"
    log "INFO" "Используется логин из переменной окружения: $DASHBOARD_USERNAME"
else
    read -p "Введите логин для Supabase Studio: " DASHBOARD_USERNAME
    if [[ -z "$DASHBOARD_USERNAME" ]]; then
        error "Логин не может быть пустым"
    fi
fi

if [[ -n "${SUPABASE_PASSWORD:-}" ]]; then
    DASHBOARD_PASSWORD="$SUPABASE_PASSWORD"
    log "INFO" "Используется пароль из переменной окружения"
else
    read -s -p "Введите пароль для Supabase Studio: " DASHBOARD_PASSWORD
    echo ""
    if [[ -z "$DASHBOARD_PASSWORD" ]]; then
        error "Пароль не может быть пустым"
    fi
fi

# Генерация ключей
log "INFO" "🔐 Генерация секретных ключей..."
POSTGRES_PASSWORD=$(openssl rand -hex 16)
JWT_SECRET=$(openssl rand -hex 32)
ANON_KEY=$(openssl rand -hex 32)
SERVICE_ROLE_KEY=$(openssl rand -hex 32)
SITE_URL="https://$DOMAIN"

# Обновление системы
log "INFO" "📦 Обновление системы..."
apt update && apt upgrade -y

# Установка базовых зависимостей
log "INFO" "🛠 Установка базовых зависимостей..."
apt install -y \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    git \
    jq \
    htop \
    net-tools \
    ufw \
    unzip \
    nginx \
    certbot \
    python3-certbot-nginx \
    apache2-utils

# Установка Docker
log "INFO" "🐳 Установка Docker..."
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

ARCH="$(dpkg --print-architecture)"
RELEASE="$(. /etc/os-release && echo "$VERSION_CODENAME")"
echo \
  "deb [arch=$ARCH signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $RELEASE stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

apt update
apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Запуск и автозапуск Docker
systemctl enable docker
systemctl start docker

# Проверка docker compose
log "INFO" "✅ Проверка docker compose..."
docker compose version

# Подготовка директорий
log "INFO" "📁 Подготовка директорий..."
mkdir -p /opt/supabase /opt/supabase-project
cd /opt

# Удаляем старую папку если есть
if [[ -d "/opt/supabase" ]]; then
    rm -rf /opt/supabase
fi

# Клонирование Supabase (sparse clone)
log "INFO" "⬇️ Клонирование репозитория Supabase..."
git clone --depth=1 --filter=blob:none --sparse https://github.com/supabase/supabase.git /opt/supabase
cd /opt/supabase

# Sparse checkout только docker
git sparse-checkout init --cone
git sparse-checkout set docker

# Копирование файлов
cp -r /opt/supabase/docker/* /opt/supabase-project/
cd /opt/supabase-project

# Создание .env файла
log "INFO" "✍️ Создание .env конфигурации..."
cat > .env << EOF
############
# Secrets
############
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
JWT_SECRET=$JWT_SECRET
ANON_KEY=$ANON_KEY
SERVICE_ROLE_KEY=$SERVICE_ROLE_KEY

############
# Database
############
POSTGRES_HOST=db
POSTGRES_DB=postgres
POSTGRES_PORT=5432

############
# API Proxy
############
KONG_HTTP_PORT=8000
KONG_HTTPS_PORT=8443

############
# API
############
API_EXTERNAL_URL=$SITE_URL
API_PORT=54321

############
# Auth
############
AUTH_EXTERNAL_URL=$SITE_URL/auth/v1
AUTH_JWT_EXP=3600
AUTH_SITE_URL=$SITE_URL
DISABLE_SIGNUP=false

############
# Studio
############
STUDIO_DEFAULT_ORGANIZATION=Default Organization
STUDIO_DEFAULT_PROJECT=Default Project
STUDIO_PORT=3000

############
# Inbucket
############
INBUCKET_PORT=54324
INBUCKET_SMTP_PORT=54325

############
# Storage
############
STORAGE_BACKEND=file
STORAGE_FILE_SIZE_LIMIT=52428800
STORAGE_S3_REGION=us-east-1

############
# Analytics
############
LOGFLARE_API_KEY=
LOGFLARE_URL=

############
# Functions
############
FUNCTIONS_VERIFY_JWT=false

############
# Realtime
############
REALTIME_EXTERNAL_URL=$SITE_URL/realtime/v1

############
# Dashboard
############
DASHBOARD_USERNAME=$DASHBOARD_USERNAME
DASHBOARD_PASSWORD=$DASHBOARD_PASSWORD

############
# Email
############
SMTP_ADMIN_EMAIL=$EMAIL
SMTP_HOST=
SMTP_PORT=
SMTP_USER=
SMTP_PASS=
SMTP_SENDER_NAME=
EOF

# Настройка Nginx
log "INFO" "🌐 Настройка Nginx..."

# Создание конфига для домена
cat > /etc/nginx/sites-available/$DOMAIN << EOF
server {
    listen 80;
    server_name $DOMAIN;
    
    # Временная заглушка для получения SSL
    location / {
        return 200 'Nginx is working!';
        add_header Content-Type text/plain;
    }
    
    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }
}
EOF

# Активация сайта
ln -sf /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

# Тест конфига nginx
nginx -t
systemctl reload nginx

# Получение SSL сертификата
log "INFO" "🔒 Получение SSL сертификата..."
certbot --nginx -d $DOMAIN --email $EMAIL --agree-tos --non-interactive

# Настройка финального конфига Nginx с проксированием
log "INFO" "🔧 Настройка финального конфига Nginx..."
cat > /etc/nginx/sites-available/$DOMAIN << EOF
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    # Security headers
    add_header X-Frame-Options DENY;
    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection "1; mode=block";
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

    # Client max body size
    client_max_body_size 100M;

    # Studio with Basic Auth
    location / {
        auth_basic "Supabase Studio";
        auth_basic_user_file /etc/nginx/.htpasswd;
        
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 90;
    }

    # API endpoints (без basic auth)
    location ~ ^/(rest|auth|realtime|storage|edge-functions)/ {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 90;
        
        # WebSocket support for realtime
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF

# Создание файла паролей для Basic Auth
log "INFO" "🔐 Настройка Basic Auth..."
htpasswd -cb /etc/nginx/.htpasswd "$DASHBOARD_USERNAME" "$DASHBOARD_PASSWORD"

# Тест и перезагрузка nginx
nginx -t
systemctl reload nginx

# Настройка firewall
log "INFO" "🛡 Настройка firewall..."
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

# Запуск Supabase
log "INFO" "🚀 Запуск Supabase..."
cd /opt/supabase-project
docker compose up -d

# Ожидание запуска сервисов
log "INFO" "⏳ Ожидание запуска сервисов..."
sleep 30

# Проверка статуса
log "INFO" "📋 Проверка статуса сервисов..."
docker compose ps

# Создание скриптов управления
log "INFO" "📝 Создание скриптов управления..."

# Скрипт backup
cat > /opt/supabase-project/backup.sh << 'EOF'
#!/bin/bash
cd /opt/supabase-project

BACKUP_DIR="/opt/supabase-backups"
mkdir -p $BACKUP_DIR

TIMESTAMP=$(date +%F_%H-%M-%S)
BACKUP_FILE="$BACKUP_DIR/supabase_backup_$TIMESTAMP.sql"

echo "Создание резервной копии..."
docker exec supabase-db pg_dump -U postgres -d postgres > "$BACKUP_FILE"

# Сжатие
gzip "$BACKUP_FILE"

echo "✅ Резервная копия создана: $BACKUP_FILE.gz"

# Удаление старых бэкапов (старше 7 дней)
find $BACKUP_DIR -name "*.gz" -mtime +7 -delete
echo "🗑 Старые бэкапы удалены"
EOF

# Скрипт update
cat > /opt/supabase-project/update.sh << 'EOF'
#!/bin/bash
cd /opt/supabase-project

echo "🔄 Создание бэкапа перед обновлением..."
./backup.sh

echo "🛑 Остановка сервисов..."
docker compose down

echo "📥 Обновление образов..."
docker compose pull

echo "🚀 Запуск обновленных сервисов..."
docker compose up -d

echo "✅ Обновление завершено"
EOF

# Скрипт restart
cat > /opt/supabase-project/restart.sh << 'EOF'
#!/bin/bash
cd /opt/supabase-project

echo "🔄 Перезапуск Supabase..."
docker compose restart

echo "✅ Перезапуск завершен"
EOF

# Скрипт logs
cat > /opt/supabase-project/logs.sh << 'EOF'
#!/bin/bash
cd /opt/supabase-project

if [ -z "$1" ]; then
    echo "📋 Показать логи всех сервисов:"
    docker compose logs -f
else
    echo "📋 Показать логи сервиса: $1"
    docker compose logs -f "$1"
fi
EOF

# Делаем скрипты исполняемыми
chmod +x /opt/supabase-project/*.sh

# Настройка автозапуска
log "INFO" "🔄 Настройка автозапуска..."
cat > /etc/systemd/system/supabase.service << EOF
[Unit]
Description=Supabase Docker Compose
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/supabase-project
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF

systemctl enable supabase.service

# Автообновление SSL сертификатов
log "INFO" "🔄 Настройка автообновления SSL..."
echo "0 12 * * * /usr/bin/certbot renew --quiet && systemctl reload nginx" | crontab -

# Автоматический бэкап
log "INFO" "📅 Настройка автоматического бэкапа..."
echo "0 2 * * * /opt/supabase-project/backup.sh" | crontab -

# Очистка
log "INFO" "🧹 Очистка..."
apt autoremove -y
docker system prune -f

# Вывод информации
log "INFO" "✅ Установка завершена!"
echo ""
echo "🎯 ==================== ИНФОРМАЦИЯ ===================="
echo ""
echo "🌐 Supabase Studio: https://$DOMAIN"
echo "🔑 Логин: $DASHBOARD_USERNAME"
echo "🔑 Пароль: $DASHBOARD_PASSWORD"
echo ""
echo "🔗 API URL: https://$DOMAIN"
echo "🔑 Anon Key: $ANON_KEY"
echo "🔑 Service Role Key: $SERVICE_ROLE_KEY"
echo ""
echo "📁 Директория проекта: /opt/supabase-project"
echo "📄 Конфигурация: /opt/supabase-project/.env"
echo ""
echo "🛠 Команды управления:"
echo "   Backup: /opt/supabase-project/backup.sh"
echo "   Update: /opt/supabase-project/update.sh"
echo "   Restart: /opt/supabase-project/restart.sh"
echo "   Logs: /opt/supabase-project/logs.sh [service_name]"
echo ""
echo "📋 Статус сервисов: docker compose ps"
echo "📋 Логи: docker compose logs -f"
echo ""
echo "🎉 Supabase готов к использованию!"
echo "==================================================" 
