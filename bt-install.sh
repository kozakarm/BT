#!/bin/bash

# Подключаем три рабочие утилиты BT на Omega симлинками в /usr/local/bin.
# Проверяем источники и все пути заранее. При сбое удаляем ссылки этого запуска.
# Нужны Bash и стандартные утилиты Linux hostname, readlink, ln и unlink.
set -u

# Рабочий checkout, из которого cron и systemd будут запускать утилиты.
REPO_DIR="/root/BT"
BIN_DIR="/usr/local/bin"
INSTALL_HOST="omega"

# Только рабочие точки входа. Файлы функций скрипты читают из репозитория.
LINK_SOURCES=(
    "incus/incus-backup.sh"
    "incus/incus-backup-sync.sh"
    "urbackup/run-after-urbackup.sh"
)
REQUIRED_HELPERS=(
    "incus/incus-backup-status.sh"
    "incus/incus-backup-schedule.sh"
)

# Печатаем причину и останавливаем установку с кодом 1.
fail() {
    printf 'ОШИБКА: %s\n' "$*" >&2
    exit 1
}

# При ошибке убираем только ссылки, созданные этим запуском и всё ещё
# указывающие на исходные файлы. Ранее установленные ссылки сюда не попадают.
rollback_links() {
    local target link actual_target
    for target in "${created_targets[@]}"; do
        link="$BIN_DIR/${target##*/}"
        if [[ ! -L "$link" ]]; then
            continue
        fi
        if ! actual_target=$(readlink -- "$link"); then
            continue
        fi
        if [[ "$actual_target" == "$target" ]]; then
            if ! unlink -- "$link"; then
                printf 'ВНИМАНИЕ: не удалось убрать %s после сбоя установки.\n' "$link" >&2
            fi
        fi
    done
}

# Защищаем действующие ссылки от установки из учебной рабочей копии.
if [[ "$#" -ne 0 ]]; then
    fail "Использование: bt-install.sh"
fi
if [[ "$EUID" -ne 0 || "$(hostname -s)" != "$INSTALL_HOST" ]]; then
    fail "Запустите установщик от root на Omega."
fi
if ! installer_path=$(readlink -f -- "${BASH_SOURCE[0]}"); then
    fail "Не удалось определить путь установщика."
fi
if [[ "$installer_path" != "$REPO_DIR/bt-install.sh" ]]; then
    fail "Запустите установщик из рабочей копии $REPO_DIR."
fi
if [[ ! -d "$BIN_DIR" ]]; then
    fail "Каталог $BIN_DIR недоступен."
fi

# Проверяем общие файлы, без которых новые скрипты не запустятся.
for relative_path in "${REQUIRED_HELPERS[@]}"; do
    target="$REPO_DIR/$relative_path"
    if [[ ! -f "$target" || ! -r "$target" ]]; then
        fail "Не найден файл функций $target."
    fi
done

# Собираем список недостающих ссылок. Существующие проверяем по фактической цели,
# чтобы сохранить и корректные относительные ссылки.
missing_targets=()
for relative_path in "${LINK_SOURCES[@]}"; do
    target="$REPO_DIR/$relative_path"
    link="$BIN_DIR/${relative_path##*/}"
    if [[ ! -f "$target" || ! -x "$target" ]]; then
        fail "Скрипт $target отсутствует или не исполняемый."
    fi
    if [[ -L "$link" ]]; then
        if ! actual_target=$(readlink -f -- "$link"); then
            fail "Не удалось определить цель ссылки $link."
        fi
        if [[ "$actual_target" != "$target" ]]; then
            fail "Ссылка $link указывает на $actual_target. Ожидался $target."
        fi
        printf 'Уже подключён %s → %s\n' "$link" "$target"
    elif [[ -e "$link" ]]; then
        fail "Путь $link занят существующим файлом или каталогом."
    else
        missing_targets+=("$target")
    fi
done

# Создаём ссылки только после проверки всех путей. -T задаёт точный путь ссылки.
created_targets=()
trap rollback_links EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
for target in "${missing_targets[@]}"; do
    link="$BIN_DIR/${target##*/}"
    if ! ln -sT -- "$target" "$link"; then
        fail "Не удалось создать ссылку $link."
    fi
    created_targets+=("$target")
    printf 'Подключён %s → %s\n' "$link" "$target"
done
trap - EXIT
