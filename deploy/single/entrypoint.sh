#!/usr/bin/env bash
set -euo pipefail

SITE_NAME="${SITE_NAME:-site1.local}"
DB_HOST="${DB_HOST:?set DB_HOST}"
DB_PORT="${DB_PORT:?set DB_PORT}"
DB_ROOT_USER="${DB_ROOT_USER:-root}"
DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:?set DB_ROOT_PASSWORD}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:?set ADMIN_PASSWORD}"

SITES=/home/frappe/frappe-bench/sites
APPS=/home/frappe/frappe-bench/apps
SITE_PATH="$SITES/$SITE_NAME"

mkdir -p "$SITES"

# add redis endpoints if provided
[ -n "${REDIS_CACHE:-}" ]    && bench set-config -g redis_cache "$REDIS_CACHE"
[ -n "${REDIS_QUEUE:-}" ]    && bench set-config -g redis_queue "$REDIS_QUEUE"
[ -n "${REDIS_SOCKETIO:-}" ] && bench set-config -g redis_socketio "$REDIS_SOCKETIO"

# fetch apps at runtime if missing
[ ! -d "$APPS/erpnext" ] && bench get-app --branch version-15 https://github.com/frappe/erpnext
[ ! -d "$APPS/hrms" ]    && bench get-app --branch version-15 https://github.com/frappe/hrms

# create site once
if [ ! -f "$SITE_PATH/site_config.json" ]; then
  bench new-site "$SITE_NAME" \
    --mariadb-root-password "$DB_ROOT_PASSWORD" \
    --admin-password "$ADMIN_PASSWORD" \
    --db-host "$DB_HOST" --db-port "$DB_PORT" \
    --db-root-username "$DB_ROOT_USER"
  bench --site "$SITE_NAME" install-app erpnext
  bench --site "$SITE_NAME" install-app hrms
  bench build
fi

# dev server on 8000
exec bench start
