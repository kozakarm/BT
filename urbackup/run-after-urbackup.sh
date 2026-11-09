#!/bin/bash
# ==============================================================================
# Обрабатываем триггер завершения UrBackup на Omega.
# Под блокировкой обработчика останавливаем urbackupsrv и запускаем синхронизацию Incus.
# После завершённой попытки удаляем триггер и отправляем нодам команды выключения.
# Нужны flock, systemctl, ssh и установленный скрипт синхронизации.
# ==============================================================================

set -u
exec < /dev/null

# === КОНФИГУРАЦИЯ ===
# Список нод для выключения по SSH перед отключением OMEGA
SHUTDOWN_NODES=(
    "xi.lan"
    "sigma.lan"
)

# UrBackup создаёт этот файл, когда можно начинать синхронизацию.
TRIGGER_FILE="/var/urbackup/shutdown_now"

# Не даём двум вызовам cron одновременно обработать один триггер.
LOCK_FILE="/run/lock/bt-urbackup-handler.lock"
# flock вернёт этот код, если блокировку уже держит другой процесс.
LOCK_BUSY_CODE=75

# Хранилище использовалось в оставленном ниже блоке дедупликации.
URBACKUP_POOL="/opt/urbackup-pool"
INCUS_BACKUP_SCRIPT="/usr/local/bin/incus-backup-sync.sh"
LOG_FILE="/var/log/urbackup-shutdown.log"

# Ограничиваем установление SSH-соединения десятью секундами.
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)
# ====================

# Сначала проверяем триггер, чтобы обычный опрос cron не открывал журнал и блокировку.
if [ ! -e "$TRIGGER_FILE" ]; then
    exit 0
fi

if ! exec >> "$LOG_FILE" 2>&1; then
    exit 1
fi

# Дескриптор 9 удерживает блокировку до завершения работы с триггером и выключения.
if ! exec 9>"$LOCK_FILE"; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ОШИБКА: Не удалось открыть файл блокировки $LOCK_FILE."
    exit 1
fi

flock -n -E "$LOCK_BUSY_CODE" 9
lock_result=$?
if [ "$lock_result" -eq "$LOCK_BUSY_CODE" ]; then
    # Cron повторит проверку, когда другой обработчик освободит блокировку.
    exit 0
fi
if [ "$lock_result" -ne 0 ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ОШИБКА: flock завершился с кодом $lock_result."
    exit 1
fi

# Другой запуск мог обработать триггер между первой проверкой и захватом блокировки.
if [ ! -e "$TRIGGER_FILE" ]; then
    exit 0
fi

echo "======================================================================"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Обнаружен триггер ${TRIGGER_FILE}. Старт процедуры завершения."

# 1. Проверяем возможность синхронизации и останавливаем UrBackup перед её началом.
# Пока служба работает, она может заново создать триггер.
if [ ! -x "$INCUS_BACKUP_SCRIPT" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ОШИБКА: Скрипт ${INCUS_BACKUP_SCRIPT} не найден или не исполняемый."
    exit 1
fi
if ! systemctl stop urbackupsrv; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ОШИБКА: Не удалось остановить urbackupsrv. Триггер сохранён."
    exit 1
fi

# 2. Блок дедупликации (закомментирован за ненадобностью, пути обновлены на /opt/urbackup-pool)
# # Снимаем защиту от записи перед duperemove
# for sub in ${URBACKUP_POOL}/*/*; do
#     btrfs property set "$sub" ro false 2>/dev/null
# done
#
# /usr/bin/duperemove -drh --hashfile=/var/cache/duperemove-storage.hash "${URBACKUP_POOL}" >> /var/log/duperemove.log 2>&1
#
# # Возвращаем защиту от записи после duperemove
# for sub in ${URBACKUP_POOL}/*/*; do
#     btrfs property set "$sub" ro true 2>/dev/null
# done

# 3. Запускаем синхронизацию и оставляем триггер до получения её результата.
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Запуск ${INCUS_BACKUP_SCRIPT}..."
"$INCUS_BACKUP_SCRIPT"
BACKUP_RC=$?
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Скрипт бэкапа Incus завершился с кодом: ${BACKUP_RC}"

# Коды 0 и 2 означают завершённую попытку. Код 2 уже отражён в статусе синхронизации.
# При остальных кодах, например при прерывании, оставляем триггер для повторного запуска.
if [ "$BACKUP_RC" -ne 0 ] && [ "$BACKUP_RC" -ne 2 ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ОШИБКА: Синхронизация не завершила проход. Триггер сохранён."
    exit "$BACKUP_RC"
fi
if ! rm -f -- "$TRIGGER_FILE"; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ОШИБКА: Не удалось удалить обработанный триггер."
    exit 1
fi

# 4. Выключение продакшн-нод по списку через SSH
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Отправка команды выключения на продакшн-ноды: ${SHUTDOWN_NODES[*]}"
for node in "${SHUTDOWN_NODES[@]}"; do
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Гасим ноду: ${node}..."
    if ! ssh "${SSH_OPTS[@]}" "root@${node}" "nohup shutdown -h now >/dev/null 2>&1 &"; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ВНИМАНИЕ: Не удалось отправить команду выключения на ${node}"
    fi
done

# Пауза 5 секунд для корректного закрытия сетевых соединений
sleep 5

# 5. Выключение Omega временно отключено для отладки.
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Автоматическое выключение Omega отключено для отладки."
shutdown -h now
