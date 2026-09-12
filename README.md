# Tuwunel Docker

Docker Compose-конфигурация Matrix homeserver Tuwunel с Traefik, Coturn и
опциональным Matrix RTC на базе LiveKit.

## Запуск

```bash
cp .env.example .env
docker network create proxy
docker compose up -d
```

Перед запуском заполните обязательные значения в `.env`. Для включения LiveKit
используйте `COMPOSE_FILE=docker-compose.yml:docker-compose.rtc.yml`, как показано
в `.env.example`.

## Резервное копирование

Защищённая схема с online checkpoint, read-only SSH pull и Borg описана в
[backup/README.md](backup/README.md).
