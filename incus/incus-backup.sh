#!/bin/bash

# Экспортируем экземпляры проекта backup и конфигурацию Incus в хранилище Omega.
# Проверяем хранилище, сохраняем конфигурацию и по очереди обновляем архивы.
# Работающие экземпляры в backup останавливаем и оставляем остановленными.
# Нужны Incus CLI, jq, findmnt, flock, GNU coreutils и доступный компрессор
# из списка zstd, pigz, xz, gzip. Для доставки статуса используем scp и ssh.

# pipefail позволяет обнаружить сбой Incus или компрессора при потоковом экспорте.
set -uo pipefail

# Ограничиваем доступ к создаваемым архивам и дампам конфигурации.
umask 077

# ==========================================
# Подключаем Incus CLI к локальному демону через UNIX-сокет.
# Через этот демон доступны экземпляры на всех нодах кластера.
# ==========================================
export INCUS_SOCKET="/var/lib/incus/unix.socket"

# ==========================================
# Настройки резервного копирования
# ==========================================
# Проект, из которого берём экземпляры для остановки и экспорта.
BACKUP_PROJECT="backup"

# Путь к хранилищу архивов и параметры его монтирования.
BACKUP_DIR="/storage/incus-backup"
BACKUP_UUID="35d1981e-0f8d-4e6c-ace8-49d0387390de"
BACKUP_SUBVOLUME="/@incus-backup"

# Минимум свободного места перед запуском в байтах. Здесь один десятичный ТБ.
MIN_FREE_BYTES=1000000000000

# Путь к локальному файлу блокировки от параллельного запуска экспортёра.
LOCK_FILE="/run/lock/bt-incus-backup.lock"

# Последний результат экспорта на Omega и ноды для его доставки.
STATUS_FILE="/var/log/incus-backup-export-status.txt"
STATUS_NODES=("xi.lan" "sigma.lan")
STATUS_OPERATION="Экспорт проекта $BACKUP_PROJECT"

# Число потоков сжатия для zstd, pigz и xz. Резервный gzip работает в один поток.
COMPRESSION_THREADS=3

# Время ожидания штатной остановки экземпляра в секундах.
# Если остановка завершится ошибкой, этот экземпляр пропускается.
STOP_TIMEOUT=120

# ==========================================
# Общие проверки и завершение запуска
# ==========================================
# После захвата блокировки публикуем ранние сбои, например недоступное хранилище.
# При повторном запуске с занятой блокировкой остаётся результат предыдущего прохода.
status_active=false
fail() {
    printf 'ОШИБКА: %s\n' "$*" >&2
    if [[ "$status_active" == true ]]; then
        publish_backup_status "$STATUS_FILE" ERROR "$STATUS_OPERATION" "$*" "${STATUS_NODES[@]}"
    fi
    exit 1
}

# Проверяем точное монтирование сабволюма и свободное место до записи файлов.
check_destination() {
    local mount_info expected_mount available

    # Проверяем именно точку монтирования, чтобы при её отсутствии не писать на системный диск.
    if ! mount_info=$(findmnt -rn --mountpoint "$BACKUP_DIR" -o FSTYPE,FSROOT,UUID); then
        fail "$BACKUP_DIR не смонтирован."
    fi

    expected_mount="btrfs $BACKUP_SUBVOLUME $BACKUP_UUID"
    if [[ "$mount_info" != "$expected_mount" ]]; then
        fail "В $BACKUP_DIR смонтирована другая файловая система или другой сабволюм."
    fi

    # Берём число из второй строки df. Первая строка содержит заголовок.
    if ! available=$(df -B1 --output=avail -- "$BACKUP_DIR" | awk 'NR == 2 {print $1}'); then
        fail "Не удалось проверить свободное место в $BACKUP_DIR."
    fi

    if [[ ! "$available" =~ ^[0-9]+$ ]]; then
        fail "Не удалось определить количество свободных байт в $BACKUP_DIR."
    fi
    if (( available < MIN_FREE_BYTES )); then
        fail "В $BACKUP_DIR доступно $available байт, требуется $MIN_FREE_BYTES."
    fi
}

# ==========================================
# Выгрузка конфигурации Incus
# ==========================================
# Первый аргумент задаёт путь дампа, остальные задают команду и её аргументы.
# Пишем вывод во временный файл рядом с дампом и заменяем прежний дамп после успеха.
# Тело функции работает в отдельной оболочке. Её обработчик EXIT убирает
# временный файл при выходе из функции, в том числе после ошибки команды.
save_config_file() (
    local destination="$1"
    local temporary
    shift

    if ! temporary=$(mktemp -- "${destination}.part.XXXXXX"); then
        exit 1
    fi
    trap 'rm -f -- "$temporary"' EXIT

    if ! "$@" > "$temporary"; then
        exit 1
    fi
    mv -fT -- "$temporary" "$destination"
)

# Принимаем тип объекта Incus, каталог дампов и дополнительные параметры CLI.
# Сохраняем YAML каждого объекта. Возвращаем 1, если список или один из дампов недоступен.
dump_config_group() {
    local resource="$1"
    local directory="$2"
    local names name
    local failed=0
    shift 2

    if ! names=$(incus --force-local "$resource" list -c n --format csv "$@"); then
        return 1
    fi

    while IFS= read -r name; do
        if [[ -z "$name" ]]; then
            continue
        fi
        if ! save_config_file "$directory/$name.yaml" \
            incus --force-local "$resource" show "$name" "$@"; then
            printf 'ОШИБКА: не удалось сохранить %s %s.\n' "$resource" "$name" >&2
            failed=1
        fi
    done <<< "$names"
    return "$failed"
}

# Собираем preseed, состав кластера, настройки профилей, сетей, пулов и проектов.
# Ошибки отдельных дампов учитываем, продолжая сохранять остальные.
dump_configuration() {
    local directory="$BACKUP_DIR/config"
    local file
    local failed=0

    if ! mkdir -p -- "$directory"/{profiles,networks,storage,projects}; then
        return 1
    fi

    # Сохраняем общий дамп настройки Incus и список нод кластера.
    if ! save_config_file "$directory/incus-preseed.yaml" incus --force-local admin init --dump; then
        failed=1
    fi
    if ! save_config_file "$directory/cluster-list.yaml" incus --force-local cluster list --format yaml; then
        failed=1
    fi

    # Профили и сети выгружаем в контексте проекта backup, пулы и проекты выгружаем отдельно.
    if ! dump_config_group profile "$directory/profiles" --project "$BACKUP_PROJECT"; then
        failed=1
    fi
    if ! dump_config_group network "$directory/networks" --project "$BACKUP_PROJECT"; then
        failed=1
    fi
    if ! dump_config_group storage "$directory/storage"; then
        failed=1
    fi
    if ! dump_config_group project "$directory/projects"; then
        failed=1
    fi

    # Сохраняем диапазоны UID и GID для непривилегированных контейнеров.
    for file in subuid subgid; do
        if [[ ! -e "/etc/$file" ]]; then
            continue
        fi
        if ! save_config_file "$directory/$file.backup" cat -- "/etc/$file"; then
            failed=1
        fi
    done
    return "$failed"
}

# ==========================================
# Экспорт и ротация архива одного экземпляра
# ==========================================
# Принимаем имя экземпляра, каталог архива и состояние из списка Incus.
# Используем компрессор и расширение, выбранные для текущего запуска.
# Отдельная оболочка ограничивает очистку временного файла рамками одного экземпляра.
backup_instance() (
    local instance="$1"
    local directory="$2"
    local status="$3"
    local archive="$directory/$instance.$ARCHIVE_EXT"
    local previous=""
    local temporary extension stop_wait_seconds

    # Проект backup предназначен для остановленных копий.
    # Если экземпляр работает, останавливаем его и оставляем остановленным после экспорта.
    # Коды выхода 2–7 передают этап сбоя в итоговый статус запуска.
    if [[ "$status" != Stopped ]]; then
        printf '[%s] Останавливаем экземпляр в проекте %s.\n' "$instance" "$BACKUP_PROJECT"

        # Даём CLI ещё 30 секунд сверх ожидания штатной остановки.
        # Если CLI зависнет, timeout остановит саму команду.
        stop_wait_seconds=$((STOP_TIMEOUT + 30))
        if ! timeout --kill-after=10s "${stop_wait_seconds}s" \
            incus --force-local stop "$instance" --project "$BACKUP_PROJECT" --timeout "$STOP_TIMEOUT"; then
            printf 'ОШИБКА [%s]: не удалось остановить экземпляр.\n' "$instance" >&2
            exit 2
        fi
    fi

    # Сначала ищем архив в текущем формате, затем в других поддерживаемых форматах.
    # Запоминаем только одну предыдущую копию для ротации.
    for extension in "$ARCHIVE_EXT" tar.zst tar.gz tar.xz; do
        if [[ -f "$directory/$instance.$extension" ]]; then
            previous="$directory/$instance.$extension"
            break
        fi
    done

    # Пишем в файл .part рядом с готовым архивом. При ошибке обработчик EXIT удалит .part.
    if ! temporary=$(mktemp -- "${archive}.part.XXXXXX"); then
        exit 3
    fi
    trap 'rm -f -- "$temporary"' EXIT

    # Передаём текущее состояние без истории снапшотов напрямую компрессору.
    # Поток не нужно целиком хранить в памяти или писать в несжатый файл.
    # Во время экспорта предыдущий архив доступен под своим именем.
    if ! incus --force-local export "$instance" - --quiet --project "$BACKUP_PROJECT" \
        --instance-only --compression=none | "${COMPRESSOR[@]}" > "$temporary"; then
        printf 'ОШИБКА [%s]: сбой экспорта или сжатия.\n' "$instance" >&2
        exit 4
    fi

    # Проверяем размер, сбрасываем данные на диск и заменяем архив переименованием.
    if [[ ! -s "$temporary" ]]; then
        exit 5
    fi
    if ! sync -d -- "$temporary"; then
        exit 5
    fi
    if ! mv -fT -- "$temporary" "$archive"; then
        exit 6
    fi

    # При совпадении формата переименование уже заменило предыдущий архив.
    # При смене формата удаляем одну предыдущую копию после сохранения новой.
    if [[ -n "$previous" && "$previous" != "$archive" ]]; then
        if ! rm -- "$previous"; then
            exit 7
        fi
    fi
    printf '[%s] Архив сохранён в %s.\n' "$instance" "$archive"
)

# ==========================================
# Основной проход
# ==========================================
# Проверяем хост перед обращением к Incus и записью результатов.
current_host=$(hostname -s)
if [[ "$current_host" != omega ]]; then
    fail "Запускайте экспортёр на Omega."
fi
# При запуске через симлинк ищем файл функций рядом с оригиналом скрипта.
if ! script_path=$(readlink -f -- "${BASH_SOURCE[0]}"); then
    fail "Не удалось определить путь к скрипту."
fi
script_directory=${script_path%/*}
if ! source "$script_directory/incus-backup-status.sh"; then
    fail "Не удалось загрузить функции оповещения."
fi

# Открываем файл блокировки как дескриптор 9 и удерживаем его до завершения работы.
# flock с флагом -n проверяет блокировку сразу и не ждёт завершения другого запуска.
if ! exec 9>"$LOCK_FILE"; then
    fail "Не удалось открыть $LOCK_FILE."
fi
if ! flock -n 9; then
    fail "Другой процесс уже выполняет экспорт Incus."
fi
status_active=true
check_destination

# Выбираем доступный компрессор и расширение в порядке предпочтения.
# Массив хранит команду и аргументы отдельно для безопасного вызова.
if command -v zstd >/dev/null 2>&1; then
    COMPRESSOR=(zstd "-T$COMPRESSION_THREADS" -3)
    ARCHIVE_EXT="tar.zst"
elif command -v pigz >/dev/null 2>&1; then
    COMPRESSOR=(pigz -p "$COMPRESSION_THREADS")
    ARCHIVE_EXT="tar.gz"
elif command -v xz >/dev/null 2>&1; then
    COMPRESSOR=(xz "-T$COMPRESSION_THREADS" -3)
    ARCHIVE_EXT="tar.xz"
else
    COMPRESSOR=(gzip)
    ARCHIVE_EXT="tar.gz"
fi

# Получаем список проекта backup по всему кластеру.
# jq проверяет, что ответ является массивом, и выдаёт имя, тип и состояние через табуляцию.
if ! inventory=$(incus --force-local list --project "$BACKUP_PROJECT" --format json); then
    fail "Не удалось получить список экземпляров проекта $BACKUP_PROJECT."
fi
if ! instances=$(jq -r '
    if type != "array" then
        error("Ожидался массив экземпляров Incus")
    else
        .[] | [.name, .type, .status] | @tsv
    end
' <<< "$inventory"); then
    fail "Не удалось разобрать список экземпляров."
fi

# Разводим контейнеры и ВМ по разным каталогам внутри проверенного хранилища.
if ! mkdir -p -- "$BACKUP_DIR"/{containers,virtual-machines}; then
    fail "Не удалось создать каталоги для архивов."
fi

# Сохраняем конфигурацию перед экспортом экземпляров. При ошибке продолжаем экспорт.
configuration_failed=0
if ! dump_configuration; then
    printf 'ОШИБКА: дамп конфигурации Incus сохранён не полностью.\n' >&2
    configuration_failed=1
fi

# Обрабатываем экземпляры по очереди. Ошибка одного архива не прерывает обход.
success_count=0
failure_count=0
failure_details=()
while IFS=$'\t' read -r instance instance_type status; do
    if [[ -z "$instance" ]]; then
        continue
    fi

    case "$instance_type" in
        container)
            directory="$BACKUP_DIR/containers"
            ;;
        virtual-machine)
            directory="$BACKUP_DIR/virtual-machines"
            ;;
        *)
            printf 'ОШИБКА [%s]: неизвестный тип экземпляра %s.\n' "$instance" "$instance_type" >&2
            failure_details+=("$instance — неизвестный тип $instance_type")
            ((failure_count += 1))
            continue
            ;;
    esac

    if backup_instance "$instance" "$directory" "$status"; then
        ((success_count += 1))
    else
        case "$?" in
            2) failure_reason="не удалось остановить экземпляр" ;;
            3) failure_reason="не удалось создать временный файл" ;;
            4) failure_reason="сбой экспорта или сжатия" ;;
            5) failure_reason="пустой архив или ошибка записи" ;;
            6) failure_reason="не удалось заменить архив" ;;
            7) failure_reason="не удалось удалить предыдущий архив" ;;
            *) failure_reason="неизвестный сбой" ;;
        esac
        printf 'ОШИБКА [%s]: %s.\n' "$instance" "$failure_reason" >&2
        failure_details+=("$instance — $failure_reason")
        ((failure_count += 1))
    fi
done <<< "$instances"

# Печатаем итог и сохраняем статус. Ошибка доставки не меняет результат экспорта.
printf 'Экспорт Incus завершён. Архивов обновлено: %d. Ошибок экземпляров: %d. Ошибка конфигурации: %d.\n' \
    "$success_count" "$failure_count" "$configuration_failed"
details="архивов обновлено $success_count, ошибок экземпляров $failure_count"
if (( configuration_failed != 0 )); then
    details+=" · неполный дамп конфигурации"
fi
if (( failure_count > 0 || configuration_failed != 0 )); then
    # Для приветствия достаточно трёх причин. Остальные остаются в выводе скрипта.
    for reason in "${failure_details[@]:0:3}"; do
        details+=" · $reason"
    done
    publish_backup_status "$STATUS_FILE" ERROR "$STATUS_OPERATION" "$details" "${STATUS_NODES[@]}"
    exit 1
fi
publish_backup_status "$STATUS_FILE" OK "$STATUS_OPERATION" "$details" "${STATUS_NODES[@]}"
exit 0
