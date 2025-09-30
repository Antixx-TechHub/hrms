#!/usr/bin/env bash
set -euo pipefail

# ---- required env ----
: "${SITE_NAME:?SITE_NAME not set}"
: "${ADMIN_PASSWORD:?ADMIN_PASSWORD not set}"
: "${DB_HOST:?DB_HOST not set}"
: "${DB_PORT:?DB_PORT not set}"
: "${DB_ROOT_USER:?DB_ROOT_USER not set}"
: "${DB_ROOT_PASSWORD:?DB_ROOT_PASSWORD not set}"
: "${DB_NAME:?DB_NAME not set}"
: "${PORT:?PORT not set}"

BENCH=/home/frappe/frappe-bench
SITES="$BENCH/sites"
APPS="$BENCH/apps"
SITE_PATH="$SITES/$SITE_NAME"
VENV="$BENCH/env"
PIP="$VENV/bin/pip"
GUNICORN="$VENV/bin/gunicorn"

cd "$BENCH"

# ---- bench context ----
mkdir -p "$SITES"
[ -f ./apps.txt ] || : > ./apps.txt
[ -f "$SITES/apps.txt" ] || cp ./apps.txt "$SITES/apps.txt"
[ -f "$SITES/common_site_config.json" ] || echo '{}' > "$SITES/common_site_config.json"

# ---- start local redis and wire Frappe to it (mandatory for migrate) ----
if command -v redis-server >/dev/null 2>&1; then
  # start in background
  redis-server /etc/redis/redis.conf --daemonize yes
  # write host:port endpoints expected by Frappe v15
  cat > "$SITES/common_site_config.json" <<EOF
{
  "redis_cache": "127.0.0.1:6379",
  "redis_queue": "127.0.0.1:6379",
  "redis_socketio": "127.0.0.1:6379"
}
EOF
fi

# ---- apps ----
[ -d "$APPS/erpnext" ] || git clone --depth 1 -b version-15 https://github.com/frappe/erpnext "$APPS/erpnext"
[ -d "$APPS/hrms" ]    || git clone --depth 1 -b version-15 https://github.com/frappe/hrms    "$APPS/hrms"

# ---- python deps (best effort) ----
[ -f "$APPS/erpnext/requirements.txt" ] && "$PIP" install -q -r "$APPS/erpnext/requirements.txt" || true
[ -f "$APPS/hrms/requirements.txt" ]    && "$PIP" install -q -r "$APPS/hrms/requirements.txt"    || true

# ---- initial site (bypass MariaDB collation guard via service env SKIP_MARIADB_SAFEGUARDS=1) ----
if [ ! -f "$SITE_PATH/site_config.json" ]; then
  echo ">>> Initializing site $SITE_NAME with DB $DB_NAME"
  bench new-site "$SITE_NAME" \
    --db-name "$DB_NAME" \
    --db-host "$DB_HOST" --db-port "$DB_PORT" \
    --db-root-username "$DB_ROOT_USER" \
    --mariadb-root-password "$DB_ROOT_PASSWORD" \
    --no-mariadb-socket \
    --admin-password "$ADMIN_PASSWORD" \
    --force

  bench --site "$SITE_NAME" install-app erpnext
  bench --site "$SITE_NAME" install-app hrms
else
  echo ">>> Site exists. Running migrate + build."
  bench --site "$SITE_NAME" migrate
  bench build || true
fi

# ---- serve HTTP ----
export FRAPPE_SITE="$SITE_NAME"
exec "$GUNICORN" \
  -b 0.0.0.0:"$PORT" -w 2 -k gevent --timeout 120 \
  --chdir "$BENCH/apps/frappe" \
  frappe.app:application
