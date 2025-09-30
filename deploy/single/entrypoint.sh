#!/usr/bin/env bash
set -euo pipefail

# inputs
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

# 1) fetch apps if missing (runtime)
if [ ! -d "$APPS/erpnext" ]; then
  bench get-app --branch version-15 https://github.com/frappe/erpnext
fi
if [ ! -d "$APPS/hrms" ]; then
  bench get-app --branch version-15 https://github.com/frappe/hrms
fi

# 2) set redis in common_site_config if provided
if [ -n "${REDIS_CACHE:-}" ]; then bench set-config -g redis_cache    "$REDIS_CACHE"    ; fi
if [ -n "${REDIS_QUEUE:-}" ]; then bench set-config -g redis_queue    "$REDIS_QUEUE"    ; fi
if [ -n "${REDIS_SOCKETIO:-}" ]; then bench set-config -g redis_socketio "$REDIS_SOCKETIO" ; fi

# 3) create site if not exists
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

# 4) run dev stack (python on 8000; node/socketio on defaults)
# Railway routes to the listening port; set PORT=8000 in Variables.
exec bench start
