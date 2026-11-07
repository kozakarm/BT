#!/usr/bin/env bash
set -euo pipefail

# 1. Проверка прав root (необходимы для корректной работы с xattrs, acls и UID/GID)
if [ "$EUID" -ne 0 ]; then
  echo "Ошибка: скрипт должен быть запущен с правами root (sudo)." >&2
  exit 1
fi

# 2. Проверка наличия pigz
if ! command -v pigz &> /dev/null; then
  echo "Ошибка: утилита 'pigz' не установлена. Установите её (например: apt install pigz)." >&2
  exit 1
fi

# 3. Определение имени текущей папки и пути к архиву
FOLDER_NAME=$(basename "$PWD")
ARCHIVE_PATH="/root/${FOLDER_NAME}.tar.gz"

echo "=== Создание бэкапа проекта: ${FOLDER_NAME} ==="
echo "Исходная директория: $PWD"
echo "Целевой архив:       $ARCHIVE_PATH"

# (Опционально) Остановка контейнеров для консистентности данных
if [ -f "docker-compose.yaml" ] || [ -f "docker-compose.yml" ]; then
    echo "Обнаружен docker-compose, останавливаем контейнеры..."
    docker compose stop || true
fi

# 4. Архивация со всеми системными атрибутами
tar --use-compress-program="pigz -p 2" \
    --numeric-owner \
    --xattrs \
    --acls \
    -p \
    -cvf "$ARCHIVE_PATH" .

# (Опционально) Запуск контейнеров обратно
if [ -f "docker-compose.yaml" ] || [ -f "docker-compose.yml" ]; then
    echo "Запускаем контейнеры обратно..."
    docker compose start || true
fi

echo "---"
echo "Успешно! Архив создан: $ARCHIVE_PATH"
