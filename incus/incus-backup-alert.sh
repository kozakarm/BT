#!/bin/sh

# Показываем на интерактивном SSH-входе последние результаты двух операций Incus.
# Читаем текстовые файлы в /var/log. Цвет добавляем только при выводе в терминал.

# Скобки ограничивают видимость переменных и функций этим приветствием.
(
    case "$-" in
        *i*) ;;
        *) exit 0 ;;
    esac
    if [ -z "${SSH_CONNECTION:-}" ] || [ ! -t 1 ]; then
        exit 0
    fi

    # Синхронизация и экспорт хранят последний результат в отдельных файлах.
    sync_status_file="/var/log/incus-backup-alert.txt"
    export_status_file="/var/log/incus-backup-export-status.txt"

    # Первый аргумент задаёт путь к статусу, второй разрешает прежний формат
    # ошибки синхронизации. Современный файл содержит код OK или ERROR и строку
    # сообщения. Старый файл синхронизации содержит только текст ошибки.
    render_backup_status() {
        if [ ! -s "$1" ] || [ ! -r "$1" ]; then
            return 0
        fi

        {
            if ! IFS= read -r backup_status; then
                return 0
            fi
            case "$backup_status" in
                OK) backup_color='\033[1;32m' ;;
                ERROR) backup_color='\033[1;31m' ;;
                *)
                    # Действующая синхронизация ещё может записать старый формат.
                    if [ "$2" = legacy ]; then
                        printf '\033[1;31m%s\n%s\n' 'Синхронизация Incus — ошибка' "$backup_status"
                        cat
                        printf '%s\033[0m\n' 'Журнал на Omega — /var/log/incus-backup-sync.log'
                    fi
                    return 0
                    ;;
            esac

            # Передаём сообщение как текст и сбрасываем цвет после каждой строки.
            if IFS= read -r backup_message && [ -n "$backup_message" ]; then
                printf '%b%s\033[0m\n' "$backup_color" "$backup_message"
            fi
        } < "$1"
    }

    render_backup_status "$sync_status_file" legacy
    render_backup_status "$export_status_file" current
)
