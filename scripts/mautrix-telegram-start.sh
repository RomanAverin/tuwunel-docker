#!/bin/sh
set -eu

# Let the image generate its complete default config before setting the proxy.
generated=false
if [ ! -f /data/config.yaml ]; then
    /docker-run.sh
    generated=true
fi

# Credentials remain in config.yaml; Compose owns the proxy type and address.
yq -I4 -i '
    .network.proxy.type = strenv(TELEGRAM_PROXY_TYPE) |
    .network.proxy.address = strenv(TELEGRAM_PROXY_ADDRESS)
' /data/config.yaml

if [ "$generated" = true ]; then
    exit 0
fi

exec /docker-run.sh
