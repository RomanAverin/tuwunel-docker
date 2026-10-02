# Tuwunel Docker

Docker Compose-конфигурация Matrix homeserver Tuwunel с Traefik, Coturn,
опциональным Matrix RTC на базе LiveKit и мостом mautrix-telegram.

## Запуск

```bash
cp .env.example .env
docker network create proxy
docker compose up -d
```

Перед запуском заполните обязательные значения в `.env`. Для включения LiveKit
используйте `COMPOSE_FILE=docker-compose.yml:docker-compose.rtc.yml`, как показано
в `.env.example`.

## Превью ссылок

URL-превью включены для всех доменов по умолчанию. Tuwunel получает страницы
с заголовком `User-Agent: Mozilla/5.0 (compatible; Discordbot/2.0; +https://discordapp.com)`.
Запросы медиа превью наследуют эту строку, если в Tuwunel отдельно не задан
`url_preview_media_user_agent`. Стандартная фильтрация IP-адресов Tuwunel
продолжает действовать.

По умолчанию исходящие HTTP-запросы Tuwunel, включая страницы и медиа
URL-превью, используют SOCKS5-прокси `host.docker.internal:1080`.
Обращения к `mautrix-telegram`, `tuwunel`, `localhost` и `127.0.0.1`
идут напрямую. Прокси должен слушать доступный контейнерам IP
Docker-интерфейса хоста; одного `127.0.0.1:1080` на хосте недостаточно.
Используется `socks5://` с локальным разрешением адресов назначения,
чтобы сохранить фильтрацию IP-адресов URL-превью.
[Настройка исходящего прокси Tuwunel](https://github.com/matrix-construct/tuwunel/blob/main/tuwunel-example.toml).

Для другого прокси переопределите `TUWUNEL_PROXY` в `.env` по примеру
из `.env.example`. Чтобы отключить прокси Tuwunel, задайте
`TUWUNEL_PROXY='"none"'`.

Настройки можно переопределить в `.env`:

```dotenv
TUWUNEL_URL_PREVIEW_DOMAIN_EXPLICIT_ALLOWLIST='["*"]'
TUWUNEL_URL_PREVIEW_USER_AGENT='Mozilla/5.0 (compatible; Discordbot/2.0; +https://discordapp.com)'
```

Чтобы разрешить только выбранные домены, задайте, например,
`TUWUNEL_URL_PREVIEW_DOMAIN_EXPLICIT_ALLOWLIST='["github.com","wikipedia.org"]'`.
Имена проверяются на точное совпадение. Чтобы отключить превью, задайте
`TUWUNEL_URL_PREVIEW_DOMAIN_EXPLICIT_ALLOWLIST='[]'`.

После изменения `.env` пересоздайте контейнер:

```bash
docker compose up -d tuwunel
```

Проверьте, что установленная версия поддерживает `url_preview_user_agent`.
Для проверки на сервере получите превью обычной страницы и ссылки YouTube;
фактический User-Agent можно проверить через HTTP-сервис, возвращающий
заголовки запроса. Описание поведения и параметров:
[URL previews в документации Tuwunel](https://matrix-construct.github.io/tuwunel/media/url-previews.html).

## Мост Telegram

Мост включается профилем `telegram`. До первого запуска получите `api_id` и
`api_hash` на [my.telegram.org/apps](https://my.telegram.org/apps). Каталог
`mautrix-telegram/` содержит конфигурацию, токены, Telegram-сессии и ключи
шифрования; он исключён из Git. Образ моста использует UID 1337 для `/data`.

1. Создайте стандартную конфигурацию:

   ```bash
   docker compose run --rm --no-deps mautrix-telegram
   ```

2. В `mautrix-telegram/config.yaml` задайте следующие значения, сохранив
   остальные поля сгенерированного файла:

   | Поле | Значение |
   | --- | --- |
   | `network.api_id`, `network.api_hash` | Ваши ключи из Telegram |
   | `homeserver.address` | `http://tuwunel:6167` (или порт из `TUWUNEL_PORT`) |
   | `homeserver.domain` | Домен из `SERVER_NAME` без `https://` |
   | `appservice.address` | `http://mautrix-telegram:29317` |
   | `appservice.hostname`, `appservice.port` | `0.0.0.0`, `29317` |
   | `database.type` | `sqlite3-fk-wal` |
   | `database.uri` | `file:/data/telegram.db?_txlock=immediate` |
   | `encryption.allow`, `encryption.default` | `true`, `true` |

   В `bridge.permissions` удалите примерные `example.com` и `"*": relay`.
   Добавьте `"ВАШ_SERVER_NAME": user` и
   `"@администратор:ВАШ_SERVER_NAME": admin`. Локальные пользователи смогут
   входить в Telegram; федеративным пользователям доступ не выдаётся.
   Оставьте `encryption.appservice: false` для стандартного режима `/sync`.
   Новые комнаты моста будут зашифрованы. Значения `SERVER_NAME` из `.env`
   подставьте в YAML вручную: Compose не подставляет переменные в этот файл.
   Если файл принадлежит UID 1337, откройте его через `sudoedit`.

3. Повторно запустите одноразовый контейнер для генерации
   `mautrix-telegram/registration.yaml`:

   ```bash
   docker compose run --rm --no-deps mautrix-telegram
   ```

   Проверьте, что `url` в регистрации равен
   `http://mautrix-telegram:29317`, а домен в регулярных выражениях совпадает
   с `SERVER_NAME`. Не меняйте токены вручную. Ограничьте доступ к данным:

   ```bash
   sudo chmod 700 mautrix-telegram
   sudo chmod 600 mautrix-telegram/config.yaml mautrix-telegram/registration.yaml
   ```

4. В админ-комнате tuwunel отправьте **одним сообщением** команду
   `!admin appservices register` и содержимое `registration.yaml` ниже неё в
   блоке кода с тройными обратными кавычками.
   Командой `!admin appservices list` проверьте наличие `telegram`. Регистрация
   сохраняется в базе tuwunel; его перезапуск не нужен. Храните файл
   регистрации как секрет: в нём находятся токены appservice.

5. Запустите мост и проверьте журнал:

   ```bash
   docker compose --profile telegram up -d mautrix-telegram
   docker compose logs --tail=100 mautrix-telegram
   ```

   Откройте личный чат с `@telegrambot:ВАШ_SERVER_NAME` и войдите командой
   `login qr` либо `login phone +НОМЕР`. Проверьте отправку текста и медиа в обе
   стороны в новой зашифрованной комнате. Порт моста не публикуется через
   Traefik и доступен tuwunel только внутри сети Compose.

### Подключение к Telegram через прокси

По умолчанию мост подключается к Telegram через SOCKS5-прокси
`host.docker.internal:1080`. При каждом запуске скрипт
`scripts/mautrix-telegram-start.sh` устанавливает `network.proxy.type` и
`network.proxy.address` в `mautrix-telegram/config.yaml` из переменных Compose.
Эти значения можно переопределить в `.env`:

```dotenv
TELEGRAM_PROXY_TYPE=socks5
TELEGRAM_PROXY_ADDRESS=host.docker.internal:1080
```

Для прямого подключения задайте `TELEGRAM_PROXY_TYPE=disabled`.
Имя пользователя и пароль, если они нужны, задайте в
`network.proxy.username` и `network.proxy.password` файла конфигурации:

```yaml
network:
  proxy:
    type: socks5
    address: "host.docker.internal:1080"
    username: ""
    password: ""
```

В Compose для моста задано `host.docker.internal:host-gateway`. На Linux
прокси должен слушать доступный контейнеру IP Docker-интерфейса хоста:
если он слушает только `127.0.0.1:1080`, соединение не сработает.
При прослушивании `0.0.0.0:1080` ограничьте доступ к порту межсетевым экраном.
После добавления `extra_hosts` пересоздайте контейнер командой
`docker compose --profile telegram up -d mautrix-telegram`.

Для MTProxy задайте в `.env` `TELEGRAM_PROXY_TYPE=mtproxy` и
`TELEGRAM_PROXY_ADDRESS=хост:порт`, а секрет поместите в
`network.proxy.password`; `username` оставьте пустым. Поддерживаются
значения `disabled`, `socks5` и `mtproxy`.
`127.0.0.1` внутри контейнера указывает на сам мост: для прокси в другом
контейнере используйте его имя в общей Docker-сети, а для внешнего прокси —
доступный контейнеру IP-адрес или DNS-имя. После изменения `.env` или
Compose пересоздайте мост командой
`docker compose --profile telegram up -d mautrix-telegram`.
После изменения только имени пользователя или пароля в YAML достаточно
`docker compose --profile telegram restart mautrix-telegram`.
Регистрацию appservice менять не нужно. Эти параметры относятся к соединению
моста с Telegram; tuwunel по-прежнему обращается к мосту напрямую через
внутреннюю сеть. [Параметры прокси в конфигурации mautrix-telegram](https://docs.mau.fi/configs/mautrix-telegram/v26.09.html).

Для обновления моста измените зафиксированный тег образа после проверки
[заметок о выпуске](https://github.com/mautrix/telegram/releases), выполните
`docker compose pull mautrix-telegram` и
`docker compose --profile telegram up -d mautrix-telegram`. Если изменились
`homeserver.domain`, адрес или поля `appservice`, пересоздайте регистрацию и
повторно зарегистрируйте её в tuwunel.

## Резервное копирование

Защищённая схема с online checkpoint, read-only SSH pull и Borg описана в
[backup/README.md](backup/README.md).
