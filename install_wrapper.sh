#!/usr/bin/env bash

echo "🚀 Скачивание и запуск установщика Supabase..."

# Скачиваем основной скрипт
curl -fsSL https://raw.githubusercontent.com/1neuropro/instalsupabase/main/install_complete.sh -o /tmp/install_complete.sh

# Проверяем, что скрипт скачался
if [[ ! -f "/tmp/install_complete.sh" ]]; then
    echo "❌ Ошибка: не удалось скачать скрипт установки"
    exit 1
fi

# Делаем исполняемым
chmod +x /tmp/install_complete.sh

# Запускаем интерактивно
exec /tmp/install_complete.sh 