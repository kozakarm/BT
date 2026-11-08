#!/bin/bash
# ==============================================================================
# Скрипт инкрементного резервного копирования и ротации инстансов Incus на OMEGA
# Архитектура: Холодный консистентный снапшот (stop -> snapshot & refresh -> start)
#              1 якорный снапшот на источнике + 30-дневный архив Btrfs на OMEGA
#              Встроенное самолечение (Self-Healing) дисков и снапшотов
#              Защита от сетевых зависаний (timeout wrappers)
# ==============================================================================

set -u
set -o pipefail
exec < /dev/null

# === КОНФИГУРАЦИЯ ===
RETENTION_DAYS=30

# Последний результат синхронизации хранится на Omega и отправляется на эти ноды.
ALERT_NODES=("xi.lan" "sigma.lan")
ALERT_FILE="/var/log/incus-backup-alert.txt"

PROD_NODES=("xi" "sigma")
STOP_TIMEOUT=120

# Таймауты для защиты от зависания сетевых вызовов Incus CLI
SNAPSHOT_TIMEOUT="45s"    # CoW снапшот + Dqlite коммит
COPY_TIMEOUT="3600s"      # Запас 60 минут на первичную прокачку до 150 ГБ по 1GbE
CLI_TIMEOUT="30s"         # Таймаут на служебные операции (query, set, delete)

SOURCE_PROJECT="default"
BACKUP_PROJECT="backup"
TARGET_NODE="omega"

POOL_PATH="/opt/incus-storage/fast-pool"
ARCHIVE_DIR="${POOL_PATH}/archive-snapshots"
CONFIG_DUMP_DIR="${POOL_PATH}/cluster-configs"

SNAP_PREFIX="sync-anchor-"

LOG_FILE="/var/log/incus-backup-sync.log"
LOCK_FILE="/var/run/incus-backup-sync.lock"
# ====================

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ОШИБКА: Скрипт уже запущен (заблокирован $LOCK_FILE)." | tee -a "$LOG_FILE"
    exit 1
fi

# Пишем сообщение с меткой времени в журнал синхронизации и вывод запуска.
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

# При запуске через симлинк ищем функции оповещения рядом с оригиналом скрипта.
if ! script_path=$(readlink -f -- "${BASH_SOURCE[0]}"); then
    log "ОШИБКА: Не удалось определить путь к скрипту."
    exit 2
fi
script_directory=${script_path%/*}
if ! source "$script_directory/incus-backup-status.sh"; then
    log "ОШИБКА: Не удалось загрузить функции оповещения."
    exit 2
fi

# Принимаем код статуса OK или ERROR и краткий итог для SSH-приветствия.
# Предупреждения о доставке записываем в журнал на Omega.
publish_sync_status() {
    publish_backup_status "$ALERT_FILE" "$1" "Синхронизация Incus" "$2" "${ALERT_NODES[@]}" \
        2>&1 | tee -a "$LOG_FILE"
}

# Добавляем имя экземпляра к каждой непустой строке вывода команды.
# Пустая строка не должна превращать успешный вызов Incus в сбой конвейера.
log_cmd_output() {
    local prefix="$1"
    while IFS= read -r line; do
        if [ -n "$line" ]; then
            log "[${prefix}] ${line}"
        fi
    done
}

CURRENT_STOPPED_INST=""
cleanup_on_signal() {
    if [ -n "$CURRENT_STOPPED_INST" ]; then
        log "ВНИМАНИЕ: Получен сигнал прерывания! Запускаем обратно ${CURRENT_STOPPED_INST}..."
        timeout --kill-after=5s "$CLI_TIMEOUT" incus start "$CURRENT_STOPPED_INST" --project "$SOURCE_PROJECT" >> "$LOG_FILE" 2>&1 || true
    fi
    exit 130
}
trap cleanup_on_signal INT TERM

# Принудительное удаление сломанного инстанса в проекте backup
force_reset_target() {
    local inst_name="$1"
    local inst_type="$2"
    local subvol_dir snap_dir

    if [ "$inst_type" = "virtual-machine" ]; then
        subvol_dir="${POOL_PATH}/virtual-machines/${BACKUP_PROJECT}_${inst_name}"
        snap_dir="${POOL_PATH}/virtual-machines-snapshots/${BACKUP_PROJECT}_${inst_name}"
    else
        subvol_dir="${POOL_PATH}/containers/${BACKUP_PROJECT}_${inst_name}"
        snap_dir="${POOL_PATH}/containers-snapshots/${BACKUP_PROJECT}_${inst_name}"
    fi

    if timeout "$CLI_TIMEOUT" incus query "/1.0/instances/${inst_name}?project=${BACKUP_PROJECT}" >/dev/null 2>&1; then
        # Гарантируем сабвольюм (inode 256), чтобы incus delete не упал с "Not a Btrfs subvolume"
        if [ "$(stat -c %i "$subvol_dir" 2>/dev/null)" != "256" ]; then
            rm -rf "$subvol_dir" 2>/dev/null || true
            btrfs subvolume create "$subvol_dir" >/dev/null 2>&1 || true
        fi
        local db_snaps
        mapfile -t db_snaps < <(timeout "$CLI_TIMEOUT" incus query "/1.0/instances/${inst_name}/snapshots?project=${BACKUP_PROJECT}&recursion=1" 2>/dev/null | jq -r '.[].name' || true)
        for s_name in "${db_snaps[@]}"; do
            [ -z "$s_name" ] && continue
            mkdir -p "$snap_dir"
            if [ "$(stat -c %i "${snap_dir}/${s_name}" 2>/dev/null)" != "256" ]; then
                rm -rf "${snap_dir}/${s_name}" 2>/dev/null || true
                btrfs subvolume create "${snap_dir}/${s_name}" >/dev/null 2>&1 || true
            fi
        done

        timeout "$CLI_TIMEOUT" incus config set "$inst_name" security.protection.delete=false --project "$BACKUP_PROJECT" 2>/dev/null || true
        timeout --kill-after=10s 60s incus delete "$inst_name" --force --project "$BACKUP_PROJECT" 2>&1 | log_cmd_output "$inst_name" || true
    fi

    # Зачистка файловой системы
    if [ -d "$subvol_dir" ]; then
        btrfs property set -ts "$subvol_dir" ro false 2>/dev/null || true
        btrfs subvolume delete "$subvol_dir" >/dev/null 2>&1 || rm -rf "$subvol_dir" 2>/dev/null || true
    fi
    if [ -d "$snap_dir" ]; then
        for s in "$snap_dir"/*; do
            [ -e "$s" ] || continue
            btrfs property set -ts "$s" ro false 2>/dev/null || true
            btrfs subvolume delete "$s" >/dev/null 2>&1 || rm -rf "$s" 2>/dev/null || true
        done
        rm -rf "$snap_dir" 2>/dev/null || true
    fi
}

# Функция самолечения целевого инстанса в проекте backup перед копированием
self_heal_target() {
    local inst_name="$1"
    local inst_type="$2"
    local subvol_dir snap_dir

    if [ "$inst_type" = "virtual-machine" ]; then
        subvol_dir="${POOL_PATH}/virtual-machines/${BACKUP_PROJECT}_${inst_name}"
        snap_dir="${POOL_PATH}/virtual-machines-snapshots/${BACKUP_PROJECT}_${inst_name}"
    else
        subvol_dir="${POOL_PATH}/containers/${BACKUP_PROJECT}_${inst_name}"
        snap_dir="${POOL_PATH}/containers-snapshots/${BACKUP_PROJECT}_${inst_name}"
    fi

    if ! timeout "$CLI_TIMEOUT" incus query "/1.0/instances/${inst_name}?project=${BACKUP_PROJECT}" >/dev/null 2>&1; then
        force_reset_target "$inst_name" "$inst_type"
        return 0
    fi

    # 1. Восстановление пропавшего сабвольюма из снапшота
    if [ "$(stat -c %i "$subvol_dir" 2>/dev/null)" != "256" ]; then
        log "[${inst_name}] SELF-HEAL: Основной сабвольюм ${subvol_dir} поврежден или отсутствует. Восстанавливаем..."
        rm -rf "$subvol_dir" 2>/dev/null || true
        local restored=0
        if [ -d "$snap_dir" ]; then
            local latest_snap
            latest_snap=$(find "$snap_dir" -mindepth 1 -maxdepth 1 -type d | sort | tail -n 1)
            if [ -n "$latest_snap" ] && [ "$(stat -c %i "$latest_snap" 2>/dev/null)" = "256" ]; then
                if btrfs subvolume snapshot "$latest_snap" "$subvol_dir" >/dev/null 2>&1; then
                    btrfs property set -ts "$subvol_dir" ro false 2>/dev/null || true
                    log "[${inst_name}] SELF-HEAL: Сабвольюм восстановлен из снапшота ${latest_snap}"
                    restored=1
                fi
            fi
        fi
        if [ "$restored" -eq 0 ]; then
            log "[${inst_name}] SELF-HEAL: Снапшотов нет, сбрасываем целевую копию в ${BACKUP_PROJECT} для чистого копирования..."
            force_reset_target "$inst_name" "$inst_type"
            return 0
        fi
    fi

    # 2. Удаление из БД backup снапшотов sync-anchor-*, которых нет в default
    local src_snaps dst_snaps
    src_snaps=$(timeout "$CLI_TIMEOUT" incus query "/1.0/instances/${inst_name}/snapshots?project=${SOURCE_PROJECT}&recursion=1" 2>/dev/null | jq -r '.[].name' || true)
    mapfile -t dst_snaps < <(
        timeout "$CLI_TIMEOUT" incus query "/1.0/instances/${inst_name}/snapshots?project=${BACKUP_PROJECT}&recursion=1" 2>/dev/null | \
        jq -r --arg pref "$SNAP_PREFIX" '.[] | .name | select(startswith($pref))'
    )
    for b_snap in "${dst_snaps[@]}"; do
        [ -z "$b_snap" ] && continue
        if ! grep -Fxq "$b_snap" <<< "$src_snaps"; then
            log "[${inst_name}] SELF-HEAL: Удаление лишнего снапшота ${b_snap} из БД ${BACKUP_PROJECT}..."
            mkdir -p "$snap_dir"
            if [ "$(stat -c %i "${snap_dir}/${b_snap}" 2>/dev/null)" != "256" ]; then
                rm -rf "${snap_dir}/${b_snap}" 2>/dev/null || true
                btrfs subvolume create "${snap_dir}/${b_snap}" >/dev/null 2>&1 || true
            fi
            timeout --kill-after=5s "$CLI_TIMEOUT" incus snapshot delete "$inst_name" "$b_snap" --project "$BACKUP_PROJECT" >/dev/null 2>&1 || true
        fi
    done

    # 3. Удаление осиротевших сабвольюмов с диска OMEGA (защита от "file exists")
    if [ -d "$snap_dir" ]; then
        local valid_b_snaps
        valid_b_snaps=$(timeout "$CLI_TIMEOUT" incus query "/1.0/instances/${inst_name}/snapshots?project=${BACKUP_PROJECT}&recursion=1" 2>/dev/null | jq -r '.[].name' || true)
        for disk_snap_path in "$snap_dir"/*; do
            [ -e "$disk_snap_path" ] || continue
            local disk_snap_name
            disk_snap_name=$(basename "$disk_snap_path")
            if ! grep -Fxq "$disk_snap_name" <<< "$valid_b_snaps"; then
                log "[${inst_name}] SELF-HEAL: Удаление осиротевшего Btrfs-сабвольюма: ${disk_snap_path}"
                btrfs property set -ts "$disk_snap_path" ro false 2>/dev/null || true
                btrfs subvolume delete "$disk_snap_path" >/dev/null 2>&1 || rm -rf "$disk_snap_path" 2>/dev/null || true
            fi
        done
    fi
}

TIMESTAMP="$(date '+%Y-%m-%d_%H%M%S')"
START_TIME=$(date +%s)

log "======================================================================"
log "СТАРТ РЕЗЕРВНОГО КОПИРОВАНИЯ INCUS (Горизонт хранения: ${RETENTION_DAYS} дн.)"
log "Целевые ноды источника: ${PROD_NODES[*]}"
log "Таймауты: snapshot=${SNAPSHOT_TIMEOUT}, copy=${COPY_TIMEOUT}"
log "======================================================================"

# Если целевые каталоги недоступны, публикуем ошибку до работы с экземплярами.
if ! mkdir -p "$ARCHIVE_DIR" "$CONFIG_DUMP_DIR"; then
    log "ОШИБКА: Не удалось подготовить каталоги хранения синхронизации."
    publish_sync_status ERROR "не удалось подготовить каталоги хранения на Omega"
    exit 2
fi

# ------------------------------------------------------------------------------
# 1. Экспорт конфигураций кластера и простановка optional=true
# ------------------------------------------------------------------------------
CURRENT_CFG_DIR="${CONFIG_DUMP_DIR}/cfg-${TIMESTAMP}"
mkdir -p "$CURRENT_CFG_DIR"
log "[ШАГ 1/4] Сохранение конфигураций кластера и подготовка профилей..."

timeout "$CLI_TIMEOUT" incus cluster list > "${CURRENT_CFG_DIR}/cluster-list.txt" 2>/dev/null || true
timeout "$CLI_TIMEOUT" incus list --project "$SOURCE_PROJECT" > "${CURRENT_CFG_DIR}/instances-default.txt" 2>/dev/null || true
timeout "$CLI_TIMEOUT" incus storage show fast-pool > "${CURRENT_CFG_DIR}/storage-fast-pool.yaml" 2>/dev/null || true

for net in $(timeout "$CLI_TIMEOUT" incus network list -f csv -c n); do
    timeout "$CLI_TIMEOUT" incus network show "$net" > "${CURRENT_CFG_DIR}/network-${net}.yaml" 2>/dev/null || true
done

for prof in $(timeout "$CLI_TIMEOUT" incus profile list --project "$SOURCE_PROJECT" -f csv -c n); do
    timeout "$CLI_TIMEOUT" incus profile show "$prof" --project "$SOURCE_PROJECT" > "${CURRENT_CFG_DIR}/profile-${prof}.yaml" 2>/dev/null || true

    mapfile -t prof_disks < <(
        timeout "$CLI_TIMEOUT" incus query "/1.0/profiles/${prof}?project=${SOURCE_PROJECT}" 2>/dev/null | \
        jq -r '.devices | to_entries[] | select(.value.type == "disk" and (.value.pool == null or .value.pool == "") and (.value.source != null and (.value.source | startswith("/"))) and .value.optional != "true") | .key'
    )
    for p_dev in "${prof_disks[@]}"; do
        [ -z "$p_dev" ] && continue
        log "[ПРОФИЛЬ ${prof}] Установка optional=true для хост-диска '${p_dev}'..."
        timeout "$CLI_TIMEOUT" incus profile device set "$prof" "$p_dev" optional=true --project "$SOURCE_PROJECT" 2>/dev/null || true
    done
done

# ------------------------------------------------------------------------------
# 2. Репликация инстансов с нод PROD_NODES
# ------------------------------------------------------------------------------
log "[ШАГ 2/4] Получение списка инстансов из проекта '${SOURCE_PROJECT}'..."

NODES_JSON=$(printf '%s\n' "${PROD_NODES[@]}" | jq -R . | jq -s .)

# Сначала проверяем результат запроса. mapfile сам не передаёт код команды внутри < <(...).
if ! instance_rows=$(timeout 60s incus list --project "$SOURCE_PROJECT" --format=json | \
    jq -r --argjson nodes "$NODES_JSON" '
        if type != "array" then
            error("Ожидался массив экземпляров Incus")
        else
            .[] | select(.location as $loc | $nodes | index($loc))
            | "\(.name)|\(.type)|\(.location)"
        end
    '); then
    log "ОШИБКА: Не удалось получить список инстансов из проекта ${SOURCE_PROJECT}."
    publish_sync_status ERROR "не удалось получить список экземпляров проекта $SOURCE_PROJECT"
    exit 2
fi

INSTANCES=()
if [ -n "$instance_rows" ]; then
    mapfile -t INSTANCES <<< "$instance_rows"
fi

TOTAL_COUNT=${#INSTANCES[@]}
SUCCESS_COUNT=0
FAIL_COUNT=0
FAILURE_DETAILS=()

log "Найдено инстансов для синхронизации: ${TOTAL_COUNT}"

for entry in "${INSTANCES[@]}"; do
    IFS='|' read -r inst_name inst_type inst_loc <<< "$entry"
    INST_START=$(date +%s)
    NEW_ANCHOR="${SNAP_PREFIX}${TIMESTAMP}"
    WAS_RUNNING=0
    instance_failed=0

    # Если состояние источника неизвестно, пропускаем экземпляр до любых действий с ним.
    if ! inst_status=$(timeout "$CLI_TIMEOUT" \
        incus query "/1.0/instances/${inst_name}?project=${SOURCE_PROJECT}" | \
        jq -er '.status | strings | select(length > 0)'); then
        log "[${inst_name}] ОШИБКА: Не удалось определить состояние исходного экземпляра."
        FAILURE_DETAILS+=("$inst_name — не удалось определить состояние источника")
        ((FAIL_COUNT++))
        continue
    fi

    log "----------------------------------------------------------------------"
    log ">>> Обработка: ${inst_name} (Тип: ${inst_type}, Нода: ${inst_loc}, Статус: ${inst_status})"

    timeout "$CLI_TIMEOUT" incus config show "$inst_name" --expanded --project "$SOURCE_PROJECT" \
        > "${CURRENT_CFG_DIR}/instance-${inst_name}.yaml" 2>/dev/null || true

    mapfile -t inst_host_disks < <(
        timeout "$CLI_TIMEOUT" incus query "/1.0/instances/${inst_name}?project=${SOURCE_PROJECT}" | \
        jq -r '.devices | to_entries[] | select(.value.type == "disk" and (.value.pool == null or .value.pool == "") and (.value.source != null and (.value.source | startswith("/"))) and .value.optional != "true") | .key'
    )
    for d_name in "${inst_host_disks[@]}"; do
        [ -z "$d_name" ] && continue
        log "[${inst_name}] Установка optional=true для проброшенного диска '${d_name}'..."
        timeout "$CLI_TIMEOUT" incus config device set "$inst_name" "$d_name" optional=true --project "$SOURCE_PROJECT" 2>&1 | log_cmd_output "$inst_name" || true
    done

    if [ "$inst_type" = "container" ]; then
        idmap_cur=$(timeout "$CLI_TIMEOUT" incus config get "$inst_name" volatile.idmap.current --project "$SOURCE_PROJECT" 2>/dev/null || true)
        if [ -n "$idmap_cur" ]; then
            idmap_next=$(timeout "$CLI_TIMEOUT" incus config get "$inst_name" volatile.idmap.next --project "$SOURCE_PROJECT" 2>/dev/null || true)
            idmap_last=$(timeout "$CLI_TIMEOUT" incus config get "$inst_name" volatile.last_state.idmap --project "$SOURCE_PROJECT" 2>/dev/null || true)
            [ -z "$idmap_next" ] && timeout "$CLI_TIMEOUT" incus config set "$inst_name" volatile.idmap.next="$idmap_cur" --project "$SOURCE_PROJECT" 2>/dev/null || true
            [ -z "$idmap_last" ] && timeout "$CLI_TIMEOUT" incus config set "$inst_name" volatile.last_state.idmap="$idmap_cur" --project "$SOURCE_PROJECT" 2>/dev/null || true
        fi
    fi

    self_heal_target "$inst_name" "$inst_type"

    if [ "$inst_status" = "Running" ]; then
        WAS_RUNNING=1
        CURRENT_STOPPED_INST="$inst_name"
        log "[${inst_name}] Штатная остановка инстанса (таймаут ${STOP_TIMEOUT}с)..."
        if ! timeout --kill-after=10s "$((STOP_TIMEOUT + 30))s" incus stop "$inst_name" --project "$SOURCE_PROJECT" --timeout "$STOP_TIMEOUT" 2>&1 | log_cmd_output "$inst_name"; then
            log "[${inst_name}] ВНИМАНИЕ: Не остановился за ${STOP_TIMEOUT}с, применяем --force..."
            if ! timeout --kill-after=5s 30s incus stop "$inst_name" --project "$SOURCE_PROJECT" \
                --force 2>&1 | log_cmd_output "$inst_name"; then
                log "[${inst_name}] ОШИБКА: Не удалось остановить экземпляр."
                FAILURE_DETAILS+=("$inst_name — не удалось остановить источник")
                instance_failed=1
            fi
        fi
    fi

    log "[${inst_name}] Создание якорного снапшота ${NEW_ANCHOR} в проекте ${SOURCE_PROJECT}..."
    if ! timeout --kill-after=10s "$SNAPSHOT_TIMEOUT" incus snapshot create "$inst_name" "$NEW_ANCHOR" --project "$SOURCE_PROJECT" 2>&1 | log_cmd_output "$inst_name"; then
        log "[${inst_name}] ОШИБКА: Не удалось создать снапшот ${NEW_ANCHOR} на источнике (или превышен таймаут ${SNAPSHOT_TIMEOUT})."
        FAILURE_DETAILS+=("$inst_name — не удалось создать якорный снапшот")
        if [ "$WAS_RUNNING" -eq 1 ]; then
            log "[${inst_name}] Возврат инстанса в состояние Running..."
            if timeout --kill-after=10s 60s incus start "$inst_name" --project "$SOURCE_PROJECT" \
                2>&1 | log_cmd_output "$inst_name"; then
                CURRENT_STOPPED_INST=""
            else
                log "[${inst_name}] КРИТИЧЕСКАЯ ОШИБКА: Не удалось запустить инстанс обратно!"
                FAILURE_DETAILS+=("$inst_name — не удалось запустить источник обратно")
            fi
        fi
        ((FAIL_COUNT++))
        continue
    fi

    log "[${inst_name}] Запуск incus copy --refresh на ${TARGET_NODE} (проект ${BACKUP_PROJECT})..."
    COPY_OK=1
    if ! timeout --kill-after=30s "$COPY_TIMEOUT" incus copy "$inst_name" "$inst_name" \
        --project "$SOURCE_PROJECT" \
        --target "$TARGET_NODE" \
        --target-project "$BACKUP_PROJECT" \
        --refresh \
        --stateless 2>&1 | log_cmd_output "$inst_name"; then

        log "[${inst_name}] ВНИМАНИЕ: Первая попытка --refresh не удалась. Пересоздаем целевую копию в проекте ${BACKUP_PROJECT}..."
        force_reset_target "$inst_name" "$inst_type"

        if ! timeout --kill-after=30s "$COPY_TIMEOUT" incus copy "$inst_name" "$inst_name" \
            --project "$SOURCE_PROJECT" \
            --target "$TARGET_NODE" \
            --target-project "$BACKUP_PROJECT" \
            --refresh \
            --stateless 2>&1 | log_cmd_output "$inst_name"; then
            COPY_OK=0
            log "[${inst_name}] ОШИБКА: Повторное копирование также завершилось сбоем (или превышен таймаут ${COPY_TIMEOUT})!"
            FAILURE_DETAILS+=("$inst_name — повторное копирование завершилось сбоем")
            timeout --kill-after=5s "$CLI_TIMEOUT" incus snapshot delete "$inst_name" "$NEW_ANCHOR" --project "$SOURCE_PROJECT" >/dev/null 2>&1 || true
        else
            log "[${inst_name}] SELF-HEAL: Целевая копия в ${BACKUP_PROJECT} успешно пересоздана с нуля."
        fi
    fi

    if [ "$WAS_RUNNING" -eq 1 ]; then
        log "[${inst_name}] Запуск инстанса обратно на ноде ${inst_loc}..."
        if timeout --kill-after=10s 60s incus start "$inst_name" --project "$SOURCE_PROJECT" 2>&1 | log_cmd_output "$inst_name"; then
            CURRENT_STOPPED_INST=""
        else
            log "[${inst_name}] КРИТИЧЕСКАЯ ОШИБКА: Не удалось запустить инстанс обратно!"
            FAILURE_DETAILS+=("$inst_name — не удалось запустить источник обратно")
            instance_failed=1
        fi
    fi

    if [ "$COPY_OK" -eq 0 ]; then
        ((FAIL_COUNT++))
        continue
    fi

    timeout "$CLI_TIMEOUT" incus config set "$inst_name" boot.autostart=false --project "$BACKUP_PROJECT" >/dev/null 2>&1 || true
    timeout "$CLI_TIMEOUT" incus config set "$inst_name" security.protection.delete=false --project "$BACKUP_PROJECT" >/dev/null 2>&1 || true

    log "[${inst_name}] Очистка предыдущих транзитных снапшотов (${SNAP_PREFIX}*)..."
    mapfile -t OLD_SNAPS_SRC < <(
        timeout "$CLI_TIMEOUT" incus query "/1.0/instances/${inst_name}/snapshots?project=${SOURCE_PROJECT}&recursion=1" | \
        jq -r --arg pref "$SNAP_PREFIX" --arg keep "$NEW_ANCHOR" \
        '.[] | .name | select(startswith($pref) and . != $keep)'
    )
    for old_snap in "${OLD_SNAPS_SRC[@]}"; do
        [ -z "$old_snap" ] && continue
        timeout --kill-after=5s "$CLI_TIMEOUT" incus snapshot delete "$inst_name" "$old_snap" --project "$SOURCE_PROJECT" >/dev/null 2>&1 || true
    done

    mapfile -t OLD_SNAPS_DST < <(
        timeout "$CLI_TIMEOUT" incus query "/1.0/instances/${inst_name}/snapshots?project=${BACKUP_PROJECT}&recursion=1" | \
        jq -r --arg pref "$SNAP_PREFIX" --arg keep "$NEW_ANCHOR" \
        '.[] | .name | select(startswith($pref) and . != $keep)'
    )
    for old_snap in "${OLD_SNAPS_DST[@]}"; do
        [ -z "$old_snap" ] && continue
        timeout --kill-after=5s "$CLI_TIMEOUT" incus snapshot delete "$inst_name" "$old_snap" --project "$BACKUP_PROJECT" >/dev/null 2>&1 || true
    done

    if [ "$inst_type" = "virtual-machine" ]; then
        SUBVOL_SRC="${POOL_PATH}/virtual-machines/${BACKUP_PROJECT}_${inst_name}"
    else
        SUBVOL_SRC="${POOL_PATH}/containers/${BACKUP_PROJECT}_${inst_name}"
    fi

    INST_ARCHIVE_DIR="${ARCHIVE_DIR}/${inst_name}"
    mkdir -p "$INST_ARCHIVE_DIR"
    ARCHIVE_SNAP_PATH="${INST_ARCHIVE_DIR}/snap-${TIMESTAMP}"

    if [ -d "$SUBVOL_SRC" ]; then
        touch "$SUBVOL_SRC" 2>/dev/null || true
        if btrfs subvolume snapshot -r "$SUBVOL_SRC" "$ARCHIVE_SNAP_PATH" 2>&1 | log_cmd_output "$inst_name"; then
            log "[${inst_name}] Архивный read-only Btrfs-снапшот создан: ${ARCHIVE_SNAP_PATH}"
        else
            log "[${inst_name}] ОШИБКА: Не удалось создать Btrfs-снапшот из ${SUBVOL_SRC}"
            FAILURE_DETAILS+=("$inst_name — не удалось создать архивный Btrfs-снапшот")
            instance_failed=1
        fi
    else
        log "[${inst_name}] ОШИБКА: Сабвольюм ${SUBVOL_SRC} не найден!"
        FAILURE_DETAILS+=("$inst_name — отсутствует сабволюм копии")
        instance_failed=1
    fi

    # Учитываем каждый экземпляр один раз, даже если у него несколько ошибок.
    if [ "$instance_failed" -eq 1 ]; then
        ((FAIL_COUNT++))
    else
        INST_DURATION=$(( $(date +%s) - INST_START ))
        log "[${inst_name}] УСПЕШНО синхронизирован за ${INST_DURATION} сек."
        ((SUCCESS_COUNT++))
    fi
done

# ------------------------------------------------------------------------------
# 3. Ротация (Pruning) архивных Btrfs-снапшотов старше RETENTION_DAYS дней
# ------------------------------------------------------------------------------
log "----------------------------------------------------------------------"
log "[ШАГ 3/4] Ротация архивных Btrfs-снапшотов старше ${RETENTION_DAYS} дней..."

PRUNED_COUNT=0
while IFS= read -r -d '' old_subvol; do
    log "Удаление устаревшего архивного снапшота: ${old_subvol}"
    if btrfs property set -ts "$old_subvol" ro false >> "$LOG_FILE" 2>&1 && \
       btrfs subvolume delete "$old_subvol" >> "$LOG_FILE" 2>&1; then
        ((PRUNED_COUNT++))
    else
        log "ВНИМАНИЕ: Не удалось удалить сабвольюм ${old_subvol}"
    fi
done < <(find "$ARCHIVE_DIR" -mindepth 2 -maxdepth 2 -type d -name "snap-*" -mtime +"$RETENTION_DAYS" -print0)

log "Удалено устаревших архивных Btrfs-снапшотов: ${PRUNED_COUNT}"

# ------------------------------------------------------------------------------
# 4. Ротация дампов конфигураций кластера старше RETENTION_DAYS дней
# ------------------------------------------------------------------------------
log "[ШАГ 4/4] Очистка дампов конфигураций кластера старше ${RETENTION_DAYS} дней..."
find "$CONFIG_DUMP_DIR" -mindepth 1 -maxdepth 1 -type d -name "cfg-*" -mtime +"$RETENTION_DAYS" -exec rm -rf {} +

TOTAL_DURATION=$(( $(date +%s) - START_TIME ))
log "======================================================================"
log "ЗАВЕРШЕНО за ${TOTAL_DURATION} сек. Успешно: ${SUCCESS_COUNT}/${TOTAL_COUNT}, Ошибок: ${FAIL_COUNT}"
log "======================================================================"

# Сохраняем итог любого завершённого прохода, включая успешную синхронизацию.
# Приветствие показывает до трёх причин, подробности остаются в журнале на Omega.
details="экземпляров синхронизировано $SUCCESS_COUNT из $TOTAL_COUNT, ошибок $FAIL_COUNT"
if [ "$FAIL_COUNT" -gt 0 ]; then
    for reason in "${FAILURE_DETAILS[@]:0:3}"; do
        details+=" · $reason"
    done
    publish_sync_status ERROR "$details"
    exit 2
fi

publish_sync_status OK "$details"
exit 0
