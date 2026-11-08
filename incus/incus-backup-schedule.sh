#!/bin/bash

# Общие функции для планового экспортёра и обработчика UrBackup.
# Правило субботы в 09:00 совпадает с OnCalendar в bt-incus-backup.timer.
WEEK_TIMEZONE="Europe/Paris"
WEEK_START_TIME="09:00:00"
# Каталог создаёт systemd через StateDirectory в сервисе экспортёра.
WEEK_ATTEMPT_FILE="/var/lib/bt-incus-backup/last-attempt"

# Печатаем дату последней наступившей субботы в 09:00 по времени Omega.
# Тело функции работает в отдельной оболочке, поэтому часовой пояс остаётся локальным.
backup_week_slot() (
    local clock now weekday today days_since_saturday saturday deadline
    export TZ="$WEEK_TIMEZONE"

    if ! clock=$(date '+%s %u %F'); then
        exit 1
    fi
    if ! read -r now weekday today <<< "$clock"; then
        exit 1
    fi

    # date нумерует дни с понедельника. Суббота имеет номер 6.
    days_since_saturday=$(( (weekday + 1) % 7 ))
    if ! saturday=$(date -d "$today $days_since_saturday days ago" +%F); then
        exit 1
    fi
    if ! deadline=$(date -d "$saturday $WEEK_START_TIME" +%s); then
        exit 1
    fi

    # Субботним утром до 09:00 текущая плановая дата ещё не наступила.
    if (( now < deadline )); then
        if ! saturday=$(date -d "$saturday 7 days ago" +%F); then
            exit 1
        fi
    fi
    printf '%s\n' "$saturday"
)

# При просроченной попытке печатаем плановую дату и возвращаем 0.
# Код 1 означает, что попытка уже началась, а код 2 означает ошибку проверки.
backup_week_pending() {
    local scheduled_day last_attempt

    if ! scheduled_day=$(backup_week_slot); then
        return 2
    fi

    if [[ -e "$WEEK_ATTEMPT_FILE" ]]; then
        if ! IFS= read -r last_attempt < "$WEEK_ATTEMPT_FILE"; then
            return 2
        fi
        if [[ ! "$last_attempt" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
            return 2
        fi
        # Формат YYYY-MM-DD позволяет сравнить даты по порядку символов.
        if [[ "$last_attempt" == "$scheduled_day" || "$last_attempt" > "$scheduled_day" ]]; then
            return 1
        fi
    fi
    printf '%s\n' "$scheduled_day"
}

# Записываем плановую дату после захвата общей блокировки и до экспорта.
# Это отметка начала попытки. Её результат хранится в отдельном файле статуса.
record_backup_week_attempt() (
    local scheduled_day="$1"
    local temporary

    if ! temporary=$(mktemp -- "$WEEK_ATTEMPT_FILE.part.XXXXXX"); then
        exit 1
    fi
    trap 'rm -f -- "$temporary"' EXIT
    if ! printf '%s\n' "$scheduled_day" > "$temporary"; then
        exit 1
    fi
    mv -fT -- "$temporary" "$WEEK_ATTEMPT_FILE"
)
