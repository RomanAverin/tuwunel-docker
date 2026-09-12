#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

CONTAINER_NAME="${TUWUNEL_CONTAINER_NAME:-tuwunel}"
KEEP_DAYS="${CHECKPOINT_KEEP_DAYS:-7}"
WAIT_SECONDS="${CHECKPOINT_WAIT_SECONDS:-60}"
LOCK_FILE="${CHECKPOINT_LOCK_FILE:-/run/lock/tuwunel-checkpoint.lock}"

log() {
    printf '[%s] %s\n' "$(date --iso-8601=seconds)" "$*"
}

die() {
    log "ОШИБКА: $*" >&2
    exit 1
}

[[ ${EUID} -eq 0 ]] || die "скрипт необходимо запускать от root"
[[ ${KEEP_DAYS} =~ ^[0-9]+$ ]] || die "CHECKPOINT_KEEP_DAYS должен быть целым числом"
[[ ${WAIT_SECONDS} =~ ^[0-9]+$ ]] || die "CHECKPOINT_WAIT_SECONDS должен быть целым числом"

for command_name in docker flock find realpath; do
    command -v "${command_name}" >/dev/null 2>&1 || die "не найдена команда ${command_name}"
done

mkdir -p "$(dirname "${LOCK_FILE}")"
exec 9>"${LOCK_FILE}"
flock -n 9 || die "другой процесс создания checkpoint уже выполняется"

[[ $(docker inspect --format '{{.State.Running}}' "${CONTAINER_NAME}" 2>/dev/null) == true ]] ||
    die "контейнер ${CONTAINER_NAME} не запущен"

DATA_PATH="$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/var/lib/tuwunel"}}{{println .Source}}{{end}}{{end}}' "${CONTAINER_NAME}" | sed '/^[[:space:]]*$/d' | head -n 1)"
[[ -n ${DATA_PATH} && -d ${DATA_PATH} ]] || die "не удалось определить каталог /var/lib/tuwunel"

DATA_PATH="$(realpath -- "${DATA_PATH}")"
[[ ${DATA_PATH} != / ]] || die "небезопасный путь к данным"

remove_expired_checkpoints() {
    local checkpoint checkpoint_parent checkpoint_name

    while IFS= read -r -d '' checkpoint; do
        checkpoint_name="$(basename -- "${checkpoint}")"
        checkpoint_parent="$(realpath -- "$(dirname -- "${checkpoint}")")"

        [[ ${checkpoint_parent} == "${DATA_PATH}" ]] || die "неожиданный путь checkpoint: ${checkpoint}"
        [[ ${checkpoint_name} =~ ^checkpoint-[0-9]+$ ]] || die "неожиданное имя checkpoint: ${checkpoint_name}"

        log "Удаляется локальный checkpoint старше ${KEEP_DAYS} дней: ${checkpoint_name}"
        rm -rf -- "${checkpoint}"
    done < <(find "${DATA_PATH}" -mindepth 1 -maxdepth 1 -type d \
        -name 'checkpoint-[0-9]*' -mmin "+$((KEEP_DAYS * 24 * 60))" -print0)
}

remove_expired_checkpoints

before_epoch="$(date +%s)"
log "Отправляется SIGUSR2 контейнеру ${CONTAINER_NAME}"
docker kill --signal=USR2 "${CONTAINER_NAME}" >/dev/null

deadline=$((SECONDS + WAIT_SECONDS))
while (( SECONDS < deadline )); do
    newest_checkpoint="$(find "${DATA_PATH}" -mindepth 1 -maxdepth 1 -type d \
        -name 'checkpoint-[0-9]*' -printf '%f\n' | sort -t- -k2,2n | tail -n 1)"

    if [[ ${newest_checkpoint:-} =~ ^checkpoint-([0-9]+)$ ]] &&
        (( BASH_REMATCH[1] >= before_epoch )); then
        log "Tuwunel начал создание ${newest_checkpoint}"
        log "Результат команды будет записан в журнал контейнера; backup-сервер заберёт checkpoint после защитной задержки"
        exit 0
    fi
    sleep 2
done

die "новый checkpoint не появился за ${WAIT_SECONDS} секунд; проверьте docker logs ${CONTAINER_NAME}"
