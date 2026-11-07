#!/bin/bash

# ==========================================
# Принудительно работаем через локальный UNIX-сокет в обход сети
# ==========================================
export INCUS_SOCKET="/var/lib/incus/unix.socket"

# ==========================================
# Настройки резервного копирования
# ==========================================
# Пути к директориям
BACKUP_DIR="/storage/backup/incus"
CONFIG_BACKUP_DIR="$BACKUP_DIR/config"
CONTAINERS_BACKUP_DIR="$BACKUP_DIR/containers"
VMS_BACKUP_DIR="$BACKUP_DIR/virtual-machines"

# Количество потоков процессора для архивации (например, 6 из 8)
COMPRESSION_THREADS=6

# Списки для ИСКЛЮЧЕНИЯ (каждое имя в отдельных кавычках через пробел)
EXCLUDE_CONTAINERS=("some-container")
EXCLUDE_VMS=("some-vm")

# ==========================================
# Определение доступного компрессора
# ==========================================
if command -v zstd >/dev/null 2>&1; then
    COMPRESSOR="zstd -T${COMPRESSION_THREADS} -3"
    ARCHIVE_EXT="tar.zst"
elif command -v pigz >/dev/null 2>&1; then
    COMPRESSOR="pigz -p ${COMPRESSION_THREADS}"
    ARCHIVE_EXT="tar.gz"
elif command -v xz >/dev/null 2>&1; then
    COMPRESSOR="xz -T${COMPRESSION_THREADS} -3"
    ARCHIVE_EXT="tar.xz"
else
    COMPRESSOR="gzip"
    ARCHIVE_EXT="tar.gz"
fi

# 1. Вычисляем имя текущего узла кластера
LOCAL_NODE=$(incus info | awk '/^  server_name:/ {print $2}')

# Гарантируем наличие целевых директорий
mkdir -p "$CONFIG_BACKUP_DIR/profiles" \
         "$CONFIG_BACKUP_DIR/networks" \
         "$CONFIG_BACKUP_DIR/storage" \
         "$CONFIG_BACKUP_DIR/projects" \
         "$CONTAINERS_BACKUP_DIR" \
         "$VMS_BACKUP_DIR"

echo "=================================================="
echo "Запуск полного бэкапа Incus на узле: $LOCAL_NODE"
echo "Используется компрессор: $COMPRESSOR (потоков: $COMPRESSION_THREADS)"
echo "=================================================="

# ==========================================
# ЭТАП 1: Бэкап конфигурации и инфраструктуры Incus
# ==========================================
echo "[1/3] Сохраняем конфигурацию инфраструктуры..."

# 1.1. Единый файл восстановления всей системы (Preseed)
incus admin init --dump > "$CONFIG_BACKUP_DIR/incus-preseed.yaml"

# 1.2. Попрофильный дамп (YAML)
for p in $(incus profile list -c n --format csv); do
    incus profile show "$p" > "$CONFIG_BACKUP_DIR/profiles/${p}.yaml"
done

# 1.3. Дамп настроек сетей (YAML)
for n in $(incus network list -c n --format csv); do
    incus network show "$n" > "$CONFIG_BACKUP_DIR/networks/${n}.yaml" 2>/dev/null || true
done

# 1.4. Дамп настроек хранилищ (YAML)
for s in $(incus storage list -c n --format csv); do
    incus storage show "$s" > "$CONFIG_BACKUP_DIR/storage/${s}.yaml"
done

# 1.5. Дамп настроек проектов (YAML)
for pr in $(incus project list -c n --format csv); do
    incus project show "$pr" > "$CONFIG_BACKUP_DIR/projects/${pr}.yaml" 2>/dev/null || true
done

# 1.6. Сохранение маппинга UID/GID непривилегированных контейнеров
cp -f /etc/subuid "$CONFIG_BACKUP_DIR/subuid.backup" 2>/dev/null || true
cp -f /etc/subgid "$CONFIG_BACKUP_DIR/subgid.backup" 2>/dev/null || true

echo "Конфигурация инфраструктуры выгружена в: $CONFIG_BACKUP_DIR"
echo "--------------------------------------------------"

# ==========================================
# ОБЩАЯ ФУНКЦИЯ РЕЗЕРВНОГО КОПИРОВАНИЯ ИНСТАНСА
# ==========================================
backup_instance() {
    local INSTANCE="$1"
    local TARGET_DIR="$2"
    local TYPE_NAME="$3"

    echo "Начинаем резервное копирование ($TYPE_NAME): $INSTANCE"

    FINAL_FILE="$TARGET_DIR/${INSTANCE}.${ARCHIVE_EXT}"
    TMP_FILE="${FINAL_FILE}.tmp"

    # Шаг 0: Прячем старый бэкап во временный файл (включая старые .tar.xz при переходе на zstd)
    if [ -f "$FINAL_FILE" ]; then
        mv -f "$FINAL_FILE" "$TMP_FILE"
    elif [ -f "$TARGET_DIR/${INSTANCE}.tar.xz" ]; then
        mv -f "$TARGET_DIR/${INSTANCE}.tar.xz" "$TMP_FILE"
    fi

    # Запоминаем текущее состояние инстанса (RUNNING или STOPPED)
    WAS_RUNNING=false
    if incus info "$INSTANCE" | grep -q "Status: RUNNING"; then
        WAS_RUNNING=true
    fi

    # 1. Останавливаем инстанс ТОЛЬКО если он был запущен (таймаут 120 секунд)
    if [ "$WAS_RUNNING" = true ]; then
        echo "Останавливаем $INSTANCE (ожидание до 120 сек)..."
        if ! incus stop "$INSTANCE" --timeout 120; then
            echo "ВНИМАНИЕ: $INSTANCE не остановился за 120 сек. Пробуем принудительную остановку (--force)..."
            if ! incus stop "$INSTANCE" --force; then
                echo "ОШИБКА: Не удалось остановить $INSTANCE! Пропускаем во избежание повреждения данных."
                if [ -f "$TMP_FILE" ]; then
                    mv -f "$TMP_FILE" "$FINAL_FILE"
                fi
                echo "--------------------------------------------------"
                return 1
            fi
        fi
    else
        echo "$INSTANCE был остановлен до начала бэкапа. Пропускаем остановку."
    fi

    # 2. Делаем мгновенный снапшот
    SNAP_NAME="snap-backup-$(date +%Y%m%d%H%M%S)"
    incus snapshot create "$INSTANCE" "$SNAP_NAME"

    # 3. Запускаем инстанс обратно ТОЛЬКО если он изначально работал
    if [ "$WAS_RUNNING" = true ]; then
        incus start "$INSTANCE"
    else
        echo "$INSTANCE остается в остановленном состоянии."
    fi

    # 4. Создаем временный клон из снапшота локально на Btrfs (CoW)
    TEMP_INST="${INSTANCE}-backup-clone"
    incus copy "$INSTANCE/$SNAP_NAME" "$TEMP_INST" --target "$LOCAL_NODE"

    # 5. Экспортируем клон и сжимаем на лету в указанное количество потоков
    echo "Экспорт и архивация $INSTANCE в $COMPRESSION_THREADS потоков..."
    incus export "$TEMP_INST" - -q --compression=none --optimized-storage | $COMPRESSOR > "$FINAL_FILE"
    PIPE_STATUS=("${PIPESTATUS[@]}")

    # Проверяем коды возврата как команды incus export, так и компрессора
    if [ "${PIPE_STATUS[0]}" -eq 0 ] && [ "${PIPE_STATUS[1]}" -eq 0 ]; then
        echo "Экспорт $INSTANCE прошел успешно. Удаляем старый .tmp файл..."
        rm -f "$TMP_FILE"
    else
        echo "ОШИБКА: Экспорт $INSTANCE не удался (код incus: ${PIPE_STATUS[0]}, код архиватора: ${PIPE_STATUS[1]})!"
        rm -f "$FINAL_FILE"
        if [ -f "$TMP_FILE" ]; then
            echo "Восстанавливаем предыдущую копию из .tmp..."
            mv -f "$TMP_FILE" "$FINAL_FILE"
        fi
    fi

    # 6. Зачищаем следы
    incus config set "$TEMP_INST" security.protection.delete=false 2>/dev/null || true
    incus delete -f "$TEMP_INST"
    incus snapshot delete "$INSTANCE" "$SNAP_NAME"

    echo "Бэкап $INSTANCE завершен."
    echo "--------------------------------------------------"
}

# ==========================================
# ЭТАП 2: Бэкап контейнеров
# ==========================================
echo "[2/3] Запуск резервного копирования контейнеров..."

for CONTAINER in $(incus list type=container location="$LOCAL_NODE" -c n --format csv); do
    # Проверка списка исключений
    SKIP=false
    for EXCLUDED in "${EXCLUDE_CONTAINERS[@]}"; do
        if [ "$CONTAINER" = "$EXCLUDED" ]; then
            SKIP=true
            break
        fi
    done

    if [ "$SKIP" = true ]; then
        echo "Контейнер $CONTAINER в списке исключений. Пропускаем."
        echo "--------------------------------------------------"
        continue
    fi

    backup_instance "$CONTAINER" "$CONTAINERS_BACKUP_DIR" "Контейнер"
done

# ==========================================
# ЭТАП 3: Бэкап виртуальных машин
# ==========================================
echo "[3/3] Запуск резервного копирования виртуальных машин..."

for VM in $(incus list type=virtual-machine location="$LOCAL_NODE" -c n --format csv); do
    # Проверка списка исключений
    SKIP=false
    for EXCLUDED in "${EXCLUDE_VMS[@]}"; do
        if [ "$VM" = "$EXCLUDED" ]; then
            SKIP=true
            break
        fi
    done

    if [ "$SKIP" = true ]; then
        echo "Виртуальная машина $VM в списке исключений. Пропускаем."
        echo "--------------------------------------------------"
        continue
    fi

    backup_instance "$VM" "$VMS_BACKUP_DIR" "VM"
done

echo "=================================================="
echo "Все операции резервного копирования успешно завершены!"
echo "=================================================="
