#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${1:-${SCRIPT_DIR}/backup.env}"

log() {
    printf '[%s] %s\n' "$(date --iso-8601=seconds)" "$*"
}

die() {
    log "ОШИБКА: $*" >&2
    exit 1
}

[[ -r ${CONFIG_FILE} ]] || die "не найден файл настроек ${CONFIG_FILE}"
# shellcheck source=/dev/null
source "${CONFIG_FILE}"

: "${SOURCE_HOST:?SOURCE_HOST не задан}"
: "${SOURCE_DATA_PATH:?SOURCE_DATA_PATH не задан}"
: "${SOURCE_CONFIG_PATH:?SOURCE_CONFIG_PATH не задан}"
: "${STAGING_DIR:?STAGING_DIR не задан}"
: "${BORG_REPO:?BORG_REPO не задан}"

SOURCE_USER="${SOURCE_USER:-tuwunel-backup}"
SSH_IDENTITY_FILE="${SSH_IDENTITY_FILE:-}"
SSH_PORT="${SSH_PORT:-22}"
MIN_CHECKPOINT_AGE="${MIN_CHECKPOINT_AGE:-1800}"
BORG_COMPRESSION="${BORG_COMPRESSION:-lz4}"
KEEP_DAILY="${KEEP_DAILY:-7}"
KEEP_WEEKLY="${KEEP_WEEKLY:-4}"
KEEP_MONTHLY="${KEEP_MONTHLY:-6}"
LOCK_FILE="${LOCK_FILE:-${STAGING_DIR}/.backup.lock}"

[[ ${SOURCE_USER} =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]] || die "некорректный SOURCE_USER"
[[ ${SOURCE_HOST} =~ ^[A-Za-z0-9.-]+$ ]] || die "некорректный SOURCE_HOST"
[[ ${SOURCE_DATA_PATH} =~ ^/[A-Za-z0-9._/-]+$ ]] || die "SOURCE_DATA_PATH должен быть безопасным абсолютным путём"
[[ ${SOURCE_CONFIG_PATH} =~ ^/[A-Za-z0-9._/-]+$ ]] || die "SOURCE_CONFIG_PATH должен быть безопасным абсолютным путём"
[[ ${STAGING_DIR} == /* && ${STAGING_DIR} != / ]] || die "STAGING_DIR должен быть безопасным абсолютным путём"
[[ ${BORG_REPO} == /* && ${BORG_REPO} != / ]] || die "BORG_REPO должен быть локальным абсолютным путём"

for number_name in SSH_PORT MIN_CHECKPOINT_AGE KEEP_DAILY KEEP_WEEKLY KEEP_MONTHLY; do
    [[ ${!number_name} =~ ^[0-9]+$ ]] || die "${number_name} должен быть целым числом"
done

for command_name in borg flock find rsync ssh; do
    command -v "${command_name}" >/dev/null 2>&1 || die "не найдена команда ${command_name}"
done

if [[ -n ${SSH_IDENTITY_FILE} ]]; then
    [[ -r ${SSH_IDENTITY_FILE} ]] || die "не читается SSH-ключ ${SSH_IDENTITY_FILE}"
    [[ ${SSH_IDENTITY_FILE} != *[[:space:]]* ]] || die "путь SSH_IDENTITY_FILE не должен содержать пробелы"
    SSH_COMMAND="ssh -i ${SSH_IDENTITY_FILE} -p ${SSH_PORT} -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes"
else
    SSH_COMMAND="ssh -p ${SSH_PORT} -o BatchMode=yes -o StrictHostKeyChecking=yes"
fi

export BORG_REPO
if [[ -n ${BORG_PASSPHRASE:-} ]]; then
    export BORG_PASSPHRASE
elif [[ -n ${BORG_PASSCOMMAND:-} ]]; then
    export BORG_PASSCOMMAND
else
    die "задайте BORG_PASSPHRASE или BORG_PASSCOMMAND"
fi

mkdir -p "${STAGING_DIR}"
chmod 700 "${STAGING_DIR}"
exec 9>"${LOCK_FILE}"
flock -n 9 || die "другой процесс резервного копирования уже выполняется"

run_borg() {
    local rc
    set +e
    "$@"
    rc=$?
    set -e

    if (( rc >= 2 )); then
        die "команда Borg завершилась с кодом ${rc}: $*"
    elif (( rc == 1 )); then
        log "ПРЕДУПРЕЖДЕНИЕ: Borg завершил команду с кодом 1: $*" >&2
    fi
}

log "Проверяется Borg-репозиторий ${BORG_REPO}"
run_borg borg info "${BORG_REPO}"

remote="${SOURCE_USER}@${SOURCE_HOST}"
remote_data="${SOURCE_DATA_PATH%/}"
remote_config="${SOURCE_CONFIG_PATH%/}"

log "Ищется готовый checkpoint на ${SOURCE_HOST}"
set +e
checkpoint_listing="$(rsync --list-only -e "${SSH_COMMAND}" \
    "${remote}:${remote_data}/" 2>&1)"
rsync_rc=$?
set -e
(( rsync_rc == 0 )) || die "не удалось получить список checkpoint: ${checkpoint_listing}"

cutoff=$(( $(date +%s) - MIN_CHECKPOINT_AGE ))
selected_checkpoint=""
selected_epoch=0
while IFS= read -r candidate; do
    candidate="${candidate%/}"
    if [[ ${candidate} =~ ^checkpoint-([0-9]+)$ ]] &&
        (( BASH_REMATCH[1] <= cutoff && BASH_REMATCH[1] > selected_epoch )); then
        selected_checkpoint="${candidate}"
        selected_epoch="${BASH_REMATCH[1]}"
    fi
done < <(awk '{print $NF}' <<<"${checkpoint_listing}")

[[ -n ${selected_checkpoint} ]] ||
    die "нет checkpoint старше ${MIN_CHECKPOINT_AGE} секунд"
log "Выбран ${selected_checkpoint}"

mkdir -p "${STAGING_DIR}/database" "${STAGING_DIR}/media" "${STAGING_DIR}/config"

log "Синхронизируется RocksDB checkpoint"
rsync -rt --delete --safe-links -e "${SSH_COMMAND}" \
    "${remote}:${remote_data}/${selected_checkpoint}/" "${STAGING_DIR}/database/"

log "Синхронизируется media"
rsync -rt --delete --safe-links -e "${SSH_COMMAND}" \
    "${remote}:${remote_data}/media/" "${STAGING_DIR}/media/"

log "Синхронизируется конфигурация"
rsync -rt --delete --prune-empty-dirs -e "${SSH_COMMAND}" \
    --include='/.env' \
    --include='/docker-compose.yml' \
    --include='/docker-compose.rtc.yml' \
    --exclude='*' \
    "${remote}:${remote_config}/" "${STAGING_DIR}/config/"

[[ -f ${STAGING_DIR}/database/CURRENT ]] || die "в checkpoint отсутствует CURRENT"
[[ -n $(find "${STAGING_DIR}/database" -maxdepth 1 -type f -name 'MANIFEST-*' -print -quit) ]] ||
    die "в checkpoint отсутствует MANIFEST"
[[ -n $(find "${STAGING_DIR}/database" -maxdepth 1 -type f -name '*.sst' -print -quit) ]] ||
    die "в checkpoint отсутствуют SST-файлы"
[[ -d ${STAGING_DIR}/media ]] || die "не скачан каталог media"
for config_name in .env docker-compose.yml docker-compose.rtc.yml; do
    [[ -f ${STAGING_DIR}/config/${config_name} ]] || die "не скачан ${config_name}"
done

archive_host="${SOURCE_HOST//./-}"
archive_name="tuwunel-${archive_host}-$(date -u +%Y-%m-%dT%H-%M-%SZ)"
log "Создаётся архив ${archive_name}"
(
    cd "${STAGING_DIR}"
    run_borg borg create --stats --show-rc --compression "${BORG_COMPRESSION}" \
        "${BORG_REPO}::${archive_name}" database media config
)

log "Применяется политика хранения"
run_borg borg prune --list --show-rc --glob-archives 'tuwunel-*' \
    --keep-daily "${KEEP_DAILY}" \
    --keep-weekly "${KEEP_WEEKLY}" \
    --keep-monthly "${KEEP_MONTHLY}" \
    "${BORG_REPO}"
run_borg borg compact --show-rc "${BORG_REPO}"

log "Резервное копирование завершено: ${archive_name}"
