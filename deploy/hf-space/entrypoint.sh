#!/usr/bin/env bash
set -euo pipefail

export TEXLYRE_DATA_DIR="${TEXLYRE_DATA_DIR:-/data/texlyre}"

mkdir -p /tmp/nginx/client_body \
         /tmp/nginx/proxy \
         /tmp/nginx/fastcgi \
         /tmp/nginx/uwsgi \
         /tmp/nginx/scgi \
         /tmp/redis \
         /tmp/supervisor \
         "${TEXLYRE_DATA_DIR}/logs/supervisor" \
         "${TEXLYRE_DATA_DIR}/artifacts" \
         "${TEXLYRE_DATA_DIR}/cache"

exec /usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf
