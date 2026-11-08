#!/bin/bash

# Записываем результат одного запуска отдельным файлом.
# Первый аргумент задаёт путь, второй задаёт статус OK или ERROR.
# Принимаем также название операции и краткий итог для администратора.
write_backup_status() (
    local destination="$1"
    local state="$2"
    local operation="$3"
    local details="$4"
    local result completed_at temporary

    case "$state" in
        OK) result="успешно" ;;
        ERROR) result="ошибка" ;;
        *) exit 2 ;;
    esac

    if ! completed_at=$(TZ=Europe/Paris date '+%d.%m.%Y %H:%M:%S %Z'); then
        exit 1
    fi

    # Временный файл находится рядом с итоговым для замены одним переименованием.
    if ! temporary=$(mktemp -- "$destination.part.XXXXXX"); then
        exit 1
    fi
    trap 'rm -f -- "$temporary"' EXIT

    if ! printf '%s\n%s — %s · %s · %s\n' \
        "$state" "$operation" "$result" "$completed_at" "$details" > "$temporary"; then
        exit 1
    fi

    if ! chmod 0644 -- "$temporary"; then
        exit 1
    fi
    mv -fT -- "$temporary" "$destination"
)

# Сначала сохраняем результат на Omega, затем отправляем его на остальные ноды.
# Аргументы задают путь, статус, название операции, подробности и список нод.
# Сбой доставки виден в журнале запуска. На удалённой ноде остаётся прежний статус.
publish_backup_status() {
    local destination="$1"
    local state="$2"
    local operation="$3"
    local details="$4"
    local node remote_temporary remote_command
    local ssh_options=(-o BatchMode=yes -o ConnectTimeout=5)
    shift 4

    if ! write_backup_status "$destination" "$state" "$operation" "$details"; then
        printf 'ВНИМАНИЕ: не удалось записать статус в %s.\n' "$destination" >&2
        return 1
    fi

    # Публикуем только полностью переданный файл. Пути задаются в настройках скрипта.
    remote_temporary="$destination.part"
    printf -v remote_command 'mv -fT -- %q %q' "$remote_temporary" "$destination"
    for node in "$@"; do
        if ! timeout --kill-after=5s 20s scp -q "${ssh_options[@]}" \
            "$destination" "root@$node:$remote_temporary"; then
            printf 'ВНИМАНИЕ: не удалось передать статус на %s.\n' "$node" >&2
            continue
        fi
        if ! timeout --kill-after=5s 20s ssh -n "${ssh_options[@]}" "root@$node" "$remote_command"; then
            printf 'ВНИМАНИЕ: не удалось опубликовать статус на %s.\n' "$node" >&2
        fi
    done
}
