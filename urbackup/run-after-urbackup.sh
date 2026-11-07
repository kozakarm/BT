#!/bin/bash
# ==============================================================================
# Скрипт обработки триггера завершения работы URBackup:
# 1. Остановка urbackupsrv
# 2. Запуск инкрементного бэкапа и ротации контейнеров Incus
# 3. Выключение продакшн-нод по списку через SSH
# 4. Выключение сервера OMEGA
# ==============================================================================

set -u
exec < /dev/null

# === КОНФИГУРАЦИЯ ===
# Список нод для выключения по SSH перед отключением OMEGA
SHUTDOWN_NODES=(
    "xi.lan"
    "sigma.lan"
)

TRIGGER_FILE="/var/urbackup/shutdown_now"
URBACKUP_POOL="/opt/urbackup-pool"
INCUS_BACKUP_SCRIPT="/usr/local/bin/incus-backup-sync.sh"
LOG_FILE="/var/log/urbackup-shutdown.log"

SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new"
# ====================

if [ ! -e "$TRIGGER_FILE" ]; then
    exit 0
fi

exec >> "$LOG_FILE" 2>&1
echo "======================================================================"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Обнаружен триггер ${TRIGGER_FILE}. Старт процедуры завершения."

# 1. Сначала удаляем файл-триггер и останавливаем urbackupsrv, чтобы скрипт не сработал повторно
rm -f "$TRIGGER_FILE"
systemctl stop urbackupsrv

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

# 3. Запуск скрипта резервного копирования и ротации контейнеров Incus
if [ -x "$INCUS_BACKUP_SCRIPT" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Запуск ${INCUS_BACKUP_SCRIPT}..."
    "$INCUS_BACKUP_SCRIPT"
    BACKUP_RC=$?
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Скрипт бэкапа Incus завершился с кодом: ${BACKUP_RC}"
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ОШИБКА: Скрипт ${INCUS_BACKUP_SCRIPT} не найден или не исполняемый!"
fi

# 4. Выключение продакшн-нод по списку через SSH
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Отправка команды выключения на продакшн-ноды: ${SHUTDOWN_NODES[*]}"
for node in "${SHUTDOWN_NODES[@]}"; do
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Гасим ноду: ${node}..."
    ssh $SSH_OPTS "root@${node}" "nohup shutdown -h now >/dev/null 2>&1 &" || \
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ВНИМАНИЕ: Не удалось отправить команду выключения на ${node}"
done

# Пауза 5 секунд для корректного закрытия сетевых соединений
sleep 5

# 5. Выключение сервера OMEGA
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Выключение сервера OMEGA (shutdown -h now)."
#shutdown -h now
