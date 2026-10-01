#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

CONTAINER_NAME="${TUWUNEL_CONTAINER_NAME:-tuwunel}"
BRIDGE_CONTAINER_NAME="${TELEGRAM_CONTAINER_NAME:-mautrix-telegram}"
BACKUP_USER="${BACKUP_USER:-tuwunel-backup}"
KEEP_DAYS="${CHECKPOINT_KEEP_DAYS:-7}"
WAIT_SECONDS="${CHECKPOINT_WAIT_SECONDS:-60}"
LOCK_FILE="${CHECKPOINT_LOCK_FILE:-/run/lock/tuwunel-checkpoint.lock}"
BRIDGE_TEMP_DIR=""
trap 'if [[ -n ${BRIDGE_TEMP_DIR} && -d ${BRIDGE_TEMP_DIR} ]]; then rm -rf -- "${BRIDGE_TEMP_DIR}"; fi' EXIT

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
[[ ${BACKUP_USER} =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]] || die "BACKUP_USER задан некорректно"

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

snapshot_bridge() {
    local checkpoint_name="$1"
    local bridge_data bridge_db snapshot_root snapshot_dir temp_dir check_result

    if ! docker inspect "${BRIDGE_CONTAINER_NAME}" >/dev/null 2>&1; then
        log "Контейнер ${BRIDGE_CONTAINER_NAME} не создан; снимок Telegram не требуется"
        return
    fi
    [[ $(docker inspect --format '{{.State.Running}}' "${BRIDGE_CONTAINER_NAME}") == true ]] ||
        die "контейнер ${BRIDGE_CONTAINER_NAME} остановлен"

    bridge_data="$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/data"}}{{println .Source}}{{end}}{{end}}' "${BRIDGE_CONTAINER_NAME}" | sed '/^[[:space:]]*$/d' | head -n 1)"
    [[ -n ${bridge_data} && -d ${bridge_data} ]] || die "не найден каталог /data моста"
    bridge_data="$(realpath -- "${bridge_data}")"
    [[ ${bridge_data} =~ ^/[A-Za-z0-9._/-]+$ && ${bridge_data} != / ]] ||
        die "путь к данным моста должен быть безопасным абсолютным путём"
    bridge_db="${bridge_data}/telegram.db"
    [[ -f ${bridge_db} ]] || die "не найдена база моста ${bridge_db}"
    [[ -f ${bridge_data}/config.yaml && -f ${bridge_data}/registration.yaml ]] ||
        die "не найдены config.yaml или registration.yaml моста"

    for command_name in sqlite3 setfacl; do
        command -v "${command_name}" >/dev/null 2>&1 || die "не найдена команда ${command_name}"
    done

    snapshot_root="$(dirname -- "${bridge_data}")/mautrix-telegram-checkpoints"
    snapshot_dir="${snapshot_root}/${checkpoint_name}"
    [[ ! -e ${snapshot_dir} ]] || die "снимок моста ${snapshot_dir} уже существует"
    install -d -m 0700 "${snapshot_root}"
    setfacl -m "u:${BACKUP_USER}:rx" "${snapshot_root}"
    temp_dir="$(mktemp -d "${snapshot_root}/.telegram-snapshot.XXXXXXXX")"
    BRIDGE_TEMP_DIR="${temp_dir}"
    install -d -m 0700 "${temp_dir}/database" "${temp_dir}/config"

    log "Создаётся согласованный снимок SQLite для ${checkpoint_name}"
    sqlite3 -readonly "${bridge_db}" ".backup '${temp_dir}/database/telegram.db'" ||
        die "не удалось создать снимок базы моста"
    check_result="$(sqlite3 -readonly "${temp_dir}/database/telegram.db" 'PRAGMA quick_check;')"
    [[ ${check_result} == ok ]] || die "проверка снимка SQLite завершилась ошибкой: ${check_result}"
    install -m 0600 "${bridge_data}/config.yaml" "${temp_dir}/config/config.yaml"
    install -m 0600 "${bridge_data}/registration.yaml" "${temp_dir}/config/registration.yaml"
    setfacl -m "u:${BACKUP_USER}:rx" "${temp_dir}" "${temp_dir}/database" "${temp_dir}/config"
    setfacl -m "u:${BACKUP_USER}:r" \
        "${temp_dir}/database/telegram.db" \
        "${temp_dir}/config/config.yaml" \
        "${temp_dir}/config/registration.yaml"
    mv -- "${temp_dir}" "${snapshot_dir}"
    BRIDGE_TEMP_DIR=""

    while IFS= read -r -d '' old_snapshot; do
        [[ $(realpath -- "$(dirname -- "${old_snapshot}")") == "${snapshot_root}" ]] ||
            die "неожиданный путь снимка моста: ${old_snapshot}"
        [[ $(basename -- "${old_snapshot}") =~ ^checkpoint-[0-9]+$ ]] ||
            die "неожиданное имя снимка моста: ${old_snapshot}"
        rm -rf -- "${old_snapshot}"
    done < <(find "${snapshot_root}" -mindepth 1 -maxdepth 1 -type d \
        -name 'checkpoint-[0-9]*' -mmin "+$((KEEP_DAYS * 24 * 60))" -print0)
}

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
        snapshot_bridge "${newest_checkpoint}"
        log "Результат команды будет записан в журнал контейнера; backup-сервер заберёт checkpoint после защитной задержки"
        exit 0
    fi
    sleep 2
done

die "новый checkpoint не появился за ${WAIT_SECONDS} секунд; проверьте docker logs ${CONTAINER_NAME}"
