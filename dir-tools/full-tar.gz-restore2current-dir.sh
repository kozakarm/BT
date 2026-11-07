#!/usr/bin/env bash
set -euo pipefail

# 1. Проверка прав root
if [ "$EUID" -ne 0 ]; then
  echo "Ошибка: скрипт должен быть запущен с правами root (sudo)." >&2
  exit 1
fi

# 2. Проверка передачи параметра
if [ -z "${1:-}" ]; then
  echo "Использование: $0 <путь_к_архиву.tar.gz>" >&2
  echo "Пример:        $0 /root/my-app.tar.gz" >&2
  exit 1
fi

ARCHIVE_PATH="$1"

# 3. Проверка существования архива
if [ ! -f "$ARCHIVE_PATH" ]; then
  echo "Ошибка: Файл архива '$ARCHIVE_PATH' не найден!" >&2
  exit 1
fi

# 4. Проверка наличия pigz
if ! command -v pigz &> /dev/null; then
  echo "Ошибка: утилита 'pigz' не установлена. Установите её (например: apt install pigz)." >&2
  exit 1
fi

echo "=== Распаковка архива ==="
echo "Источник:           $ARCHIVE_PATH"
echo "Целевая директория: $PWD"

# 5. Распаковка со сбросом прав 1-в-1 в текущую папку
tar --use-compress-program="pigz -p 2" \
    --numeric-owner \
    --xattrs \
    --acls \
    -p \
    -xvf "$ARCHIVE_PATH" \
    -C .

echo "---"
echo "Успешно! Проект развернут в $PWD"
echo "Для запуска выполните: docker compose up -d"
