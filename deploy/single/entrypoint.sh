#!/usr/bin/env bash
set -euo pipefail

# ---- required env ----
SITE_NAME="${SITE_NAME:-site1.local}"
DB_HOST="${DB_HOST:?set DB_HOST}"
DB_PORT="${DB_PORT:?set DB_PORT}"
DB_ROOT_USER="${DB_ROOT_USER:-root}"
DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:?set DB_ROOT_PASSWORD}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:?set ADMIN_PASSWORD}"
# optional: REDIS_CACHE, REDIS_QUEUE, REDIS_SOCKETIO, PORT=8000

# ---- paths ----
BENCH=/home/frappe/frappe-bench
SITES="$BENCH/sites"
APPS="$BENCH/apps"
SITE_PATH="$SITES/$SITE_NAME"
PIP="$BENCH/env/bin/pip"

cd "$BENCH"

# 1) minimal bench context so bench CLI doesn't crash
mkdir -p "$SITES"
[ -f ./apps.txt ] || : > ./apps.txt
[ -f "$SITES/apps.txt" ] || cp ./apps.txt "$SITES/apps.txt"

# 2) create global config JSON (preferred over bench set-config here)
if [ -n "${REDIS_CACHE:-}" ] || [ -n "${REDIS_QUEUE:-}" ] || [ -n "${REDIS_SOCKETIO:-}" ]; then
  jq -n \
    --arg cache "${REDIS_CACHE:-}" \
    --arg queue "${REDIS_QUEUE:-}" \
    --arg sio   "${REDIS_SOCKETIO:-}" \
    '{
      ( $cache | length > 0 ) as $c |
      ( $queue | length > 0 ) as $q |
      ( $sio   | length > 0 ) as $s
    }
    |
    if $c then .redis_cache=$cache else . end
    |
    if $q then .redis_queue=$queue else . end
    |
    if $s then .redis_socketio=$sio else . end' > "$SITES/common_site_config.json"
else
  [ -f "$SITES/common_site_config.json" ] || echo '{}' > "$SITES/common_site_config.json"
fi

# 3) fetch apps via git (avoid 'bench get-app')
if [ ! -d "$APPS/erpnext" ]; then
  git clone --depth 1 -b version-15 https://github.com/frappe/erpnext "$APPS/erpnext"
fi
if [ ! -d "$APPS/hrms" ]; then
  git clone --depth 1 -b version-15 https://github.com/frappe/hrms "$APPS/hrms"
fi

# 4) python deps for apps (replace missing 'bench setup requirements')
# ignore if a requirements file is absent
[ -f "$APPS/erpnext/requirements.txt" ] && "$PIP" install -q -r "$APPS/erpnext/requirements.txt" || true
[ -f "$APPS/hrms/requirements.txt" ]    && "$PIP" install -q -r "$APPS/hrms/requirements.txt" || true

# 5) build assets for these apps
bench build --apps erpnext hrms || true

# 6) create site if missing, then install apps
if [ ! -f "$SITE_PATH/site_config.json" ]; then
  bench new-site "$SITE_NAME" \
    --mariadb-root-password "$DB_ROOT_PASSWORD" \
    --admin-password "$ADMIN_PASSWORD" \
    --db-host "$DB_HOST" --db-port "$DB_PORT" \
    --db-root-username "$DB_ROOT_USER"

  bench --site "$SITE_NAME" install-app erpnext
  bench --site "$SITE_NAME" install-app hrms

  bench build || true
fi

# 7) start dev stack (listen on 8000)
exec bench start
