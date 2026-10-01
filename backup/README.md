# Резервное копирование Tuwunel

Схема не требует останавливать Tuwunel и не хранит на основном сервере ключи от
backup-сервера:

```text
Tuwunel -> RocksDB checkpoint
backup-сервер -> read-only rsync -> staging -> локальный Borg
```

Встроенный checkpoint содержит только RocksDB. Скрипт отдельно копирует
`media/`, `.env` и Compose-файлы. Оригинальное описание механизма находится в
[документации Tuwunel](https://github.com/matrix-construct/tuwunel/blob/v1.9.1/docs/backups.md).

## 1. Настройка Tuwunel-сервера

В `docker-compose.yml` уже настроена команда, выполняемая по `SIGUSR2`:

```yaml
TUWUNEL_ADMIN_SIGNAL_EXECUTE: '["server checkpoint-database"]'
```

После обновления конфигурации пересоздайте контейнер:

```bash
docker compose up -d tuwunel
```

Установите скрипт и проверьте его вручную:

```bash
sudo install -o root -g root -m 0755 backup/create-checkpoint.sh /usr/local/sbin/tuwunel-checkpoint
sudo /usr/local/sbin/tuwunel-checkpoint
docker logs --since 5m tuwunel
```

Пример `/etc/cron.d/tuwunel-checkpoint` для ежедневного запуска в 02:00:

```cron
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

0 2 * * * root /usr/local/sbin/tuwunel-checkpoint >>/var/log/tuwunel-checkpoint.log 2>&1
```

Скрипт хранит локальные checkpoint семь дней. Значение можно изменить через
`CHECKPOINT_KEEP_DAYS` в окружении cron.

Если запущен `mautrix-telegram`, скрипт также создаёт согласованный снимок его
SQLite-базы и копии конфигурации в
`mautrix-telegram-checkpoints/checkpoint-<timestamp>/`.
Для этого на Tuwunel-сервере должны быть установлены `sqlite3` и `setfacl`.
Исходная база `mautrix-telegram/telegram.db` в работающем контейнере напрямую
не копируется.

Узнайте каталог данных, который потребуется backup-серверу:

```bash
docker inspect --format '{{range .Mounts}}{{if eq .Destination "/var/lib/tuwunel"}}{{println .Source}}{{end}}{{end}}' tuwunel
```

### Read-only пользователь

Создайте отдельного пользователя `tuwunel-backup` с заблокированным паролем.
Пример ниже предполагает, что проект установлен в `/opt/tuwunel-docker`; сначала
проверьте оба вычисленных пути:

```bash
sudo useradd --create-home --shell /bin/bash tuwunel-backup
sudo passwd --lock tuwunel-backup

TUWUNEL_DATA_PATH="$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/var/lib/tuwunel"}}{{println .Source}}{{end}}{{end}}' tuwunel)"
TUWUNEL_PROJECT_PATH=/opt/tuwunel-docker
printf 'data=%s\nconfig=%s\n' "$TUWUNEL_DATA_PATH" "$TUWUNEL_PROJECT_PATH"

sudo setfacl -R -m u:tuwunel-backup:rX "$TUWUNEL_DATA_PATH"
sudo find "$TUWUNEL_DATA_PATH" -type d -exec setfacl -m d:u:tuwunel-backup:rX {} +
sudo setfacl -m u:tuwunel-backup:--x "$TUWUNEL_PROJECT_PATH"
sudo setfacl -m u:tuwunel-backup:r \
  "$TUWUNEL_PROJECT_PATH/.env" \
  "$TUWUNEL_PROJECT_PATH/docker-compose.yml" \
  "$TUWUNEL_PROJECT_PATH/docker-compose.rtc.yml"
```

Если пользователь не может пройти к Docker volume, добавьте ему только право
`--x` на недоступные родительские каталоги, не выдавая чтение их содержимого.
Проверьте доступ к каждому источнику через `sudo -u tuwunel-backup`; в частности,
новый checkpoint и media должны читаться, а посторонние файлы — оставаться
недоступными.

После настройки моста повторно запустите скрипт checkpoint. Он сам выдаст
пользователю резервного копирования чтение снимка базы, конфигурации и
регистрации. Достаточно уже описанного выше права прохода к каталогу проекта:

```bash
sudo /usr/local/sbin/tuwunel-checkpoint
sudo -u tuwunel-backup ls \
  "$TUWUNEL_PROJECT_PATH/mautrix-telegram-checkpoints"
```

Если мост настроен, но его контейнер остановлен, создание совместного снимка
завершится ошибкой. Проверьте журнал и возобновите работу моста до очередного
резервного копирования.

Найдите установленный `rrsync` командой `command -v rrsync` (часто это
`/usr/bin/rrsync` или пример из пакета `rsync`) и поместите публичный ключ backup-сервера в
`~tuwunel-backup/.ssh/authorized_keys`:

```text
restrict,command="/usr/bin/rrsync -ro /" ssh-ed25519 AAAA... backup-server
```

Опция `-ro` разрешает только чтение через rsync. Не выдавайте этому пользователю
sudo, доступ к Docker socket или парольный вход. Убедитесь, что ключ не позволяет
получить shell, записать или удалить файл. Из-за корневого пути `/` пользователь
увидит все файлы, которые разрешают обычные Unix-права, поэтому не выдавайте ему
лишних ACL.

## 2. Настройка backup-сервера

Установите Borg 1.x, rsync, SQLite CLI и OpenSSH client. Создайте непривилегированного
системного пользователя `borg` и его рабочие каталоги:

```bash
sudo useradd --system --create-home --home-dir /var/lib/borg --shell /usr/sbin/nologin borg
sudo install -d -o borg -g borg -m 0700 \
  /var/lib/borg/.ssh \
  /var/lib/borg/repositories \
  /var/lib/borg/secrets \
  /var/lib/borg/staging
sudo -u borg ssh-keygen -t ed25519 -f /var/lib/borg/.ssh/tuwunel-backup
```

Передайте только содержимое `tuwunel-backup.pub` на Tuwunel-сервер и добавьте
его в restricted `authorized_keys`, как описано выше. Приватный ключ не должен
существовать на Tuwunel-сервере. Все дальнейшие команды этого раздела выполняйте
от пользователя `borg`, например через `sudo -u borg`.

Скопируйте файлы и создайте конфигурацию:

```bash
install -m 0755 backup/backup.sh /var/lib/borg/backup.sh
install -m 0600 backup/backup.env.example /var/lib/borg/backup.env
```

Заполните `backup.env`. После включения моста добавьте
`SOURCE_BRIDGE_PATH=/opt/tuwunel-docker` (фактический путь к проекту на
Tuwunel-сервере). Без этого параметра старые установки продолжают архивировать
только tuwunel. Все пути должны быть абсолютными и не содержать пробелы.
Заранее добавьте SSH host key Tuwunel-сервера в `known_hosts`, сверив fingerprint
по независимому каналу.

Создайте локальный зашифрованный репозиторий:

```bash
set -a
. /var/lib/borg/backup.env
set +a
borg init --encryption=repokey-blake2 "$BORG_REPO"
borg key export "$BORG_REPO" /безопасное/внешнее/хранилище/tuwunel-borg-key
```

Экспортированный ключ и пароль должны храниться отдельно от backup-сервера.
Проверьте первый запуск:

```bash
/var/lib/borg/backup.sh /var/lib/borg/backup.env
borg list /var/lib/borg/repositories/tuwunel
```

Пример `/etc/cron.d/tuwunel-backup` для запуска в 03:00, через час после создания
checkpoint:

```cron
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin

0 3 * * * borg /var/lib/borg/backup.sh /var/lib/borg/backup.env >>/var/lib/borg/backup.log 2>&1
```

Checkpoint выбирается по timestamp в имени и должен быть старше
`MIN_CHECKPOINT_AGE` (по умолчанию 30 минут). При ошибке SSH, rsync или проверки
структуры новый архив не создаётся, а `prune` не запускается.

## 3. Проверка и восстановление

Периодически проверяйте репозиторий отдельно от ежедневного задания:

```bash
borg check /var/lib/borg/repositories/tuwunel
```

Для тестового восстановления:

```bash
mkdir /tmp/tuwunel-restore
cd /tmp/tuwunel-restore
borg extract /var/lib/borg/repositories/tuwunel::ИМЯ-АРХИВА
```

Остановите Tuwunel перед рабочим восстановлением. Перенесите содержимое
`database/` в пустой database path, `media/` — в каталог media, восстановите
`config/`, владельца и права файлов, затем запустите контейнер и проверьте
работу сервера. Существующие данные сначала сохраните отдельно для отката.

Если архив содержит `telegram/`, перед восстановлением остановите также
`mautrix-telegram`. Восстановите `telegram/config/config.yaml` и
`telegram/config/registration.yaml` в каталог `mautrix-telegram/`, а
`telegram/database/telegram.db` — как `mautrix-telegram/telegram.db`. Не
переносите старые файлы `telegram.db-wal` и `telegram.db-shm` поверх снимка.
Установите владельца данных моста UID 1337 и права на каталог `0700`, на
конфигурацию и регистрацию `0600`. Восстановите tuwunel из **того же архива**:
его база содержит регистрацию с токенами, которые должны совпадать с
`registration.yaml` и `config.yaml` моста. После запуска обоих контейнеров
проверьте `!admin appservices list`, вход бота и обмен сообщениями в
зашифрованной комнате.

## Усиление защиты

- Запускайте `borg` без root и не используйте этого пользователя для других задач.
- Ограничьте staging и репозиторий правами `0700` и настройте дисковую квоту.
- Делайте ZFS/Btrfs snapshots Borg-репозитория с политикой удаления, недоступной
  Tuwunel-серверу.
- Отслеживайте отсутствие новых архивов, резкое уменьшение их размера и свободное
  место. Захваченный Tuwunel-сервер не сможет удалить старые архивы, но сможет
  отдавать повреждённые или пустые новые данные.
