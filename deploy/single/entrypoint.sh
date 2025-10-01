#!/usr/bin/env bash
set -euo pipefail

# ---- required env ----
: "${SITE_NAME:?SITE_NAME not set}"
: "${ADMIN_PASSWORD:?ADMIN_PASSWORD not set}"
: "${DB_HOST:?DB_HOST not set}"
: "${DB_PORT:?DB_PORT not set}"
: "${DB_NAME:?DB_NAME not set}"
: "${DB_USER:?DB_USER not set}"
: "${DB_PASSWORD:?DB_PASSWORD not set}"
: "${PORT:?PORT not set}"

BENCH="/home/frappe/frappe-bench"
SITES="$BENCH/sites"
SITE_PATH="$SITES/$SITE_NAME"
VENV="$BENCH/env"
PIP="$VENV/bin/pip"
GUNICORN="$VENV/bin/gunicorn"

cd "$BENCH"

echo ">>> Starting local Redis"
mkdir -p /home/frappe/redis
# no config file path; run with args so we don't hit /etc/redis perms
redis-server --daemonize yes --bind 127.0.0.1 --port 6379 --save "" --appendonly no \
  --dir /home/frappe/redis --pidfile /home/frappe/redis/redis.pid

# wire frappe to local redis with proper URL scheme
mkdir -p "$SITES"
cat > "$SITES/common_site_config.json" <<EOF
{
  "redis_cache": "redis://127.0.0.1:6379/0",
  "redis_queue": "redis://127.0.0.1:6379/1",
  "redis_socketio": "redis://127.0.0.1:6379/2"
}
EOF

# ensure DB exists and has proper settings (schema-level, not server-level)
echo ">>> Ensuring database $DB_NAME exists with correct charset/collation"
mysql --protocol=TCP -h "$DB_HOST" -P "$DB_PORT" -u"$DB_USER" -p"$DB_PASSWORD" \
  -e "CREATE DATABASE IF NOT EXISTS \`$DB_NAME\`
      CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
# set row_format on all new tables in this DB (Barracuda-ish)
mysql --protocol=TCP -h "$DB_HOST" -P "$DB_PORT" -u"$DB_USER" -p"$DB_PASSWORD" "$DB_NAME" \
  -e "SET SESSION sql_require_primary_key=OFF;"

# Python deps for apps (safe, idempotent)
[ -f apps/erpnext/requirements.txt ] && "$PIP" install -q -r apps/erpnext/requirements.txt || true
[ -f apps/hrms/requirements.txt ]    && "$PIP" install -q -r apps/hrms/requirements.txt    || true

# Node deps for frappe build (idempotent)
echo ">>> yarn install (apps/frappe)"
( cd apps/frappe && yarn install --frozen-lockfile || yarn install )

# create site if missing (use normal DB user; skip server-level checks)
if [ ! -f "$SITE_PATH/site_config.json" ]; then
  echo ">>> Creating site $SITE_NAME on $DB_NAME"
  bench new-site "$SITE_NAME" \
    --db-name "$DB_NAME" \
    --db-host "$DB_HOST" --db-port "$DB_PORT" \
    --mariadb-root-username "$DB_USER" \
    --mariadb-root-password "$DB_PASSWORD" \
    --no-mariadb-socket \
    --admin-password "$ADMIN_PASSWORD" \
    --force || echo "new-site failed; continuing (DB may already exist)."
fi

# install apps (idempotent: ignored if already installed)
echo ">>> Installing ERPNext"
bench --site "$SITE_NAME" install-app erpnext || echo "erpnext already installed or failed; continuing."
echo ">>> Installing HRMS"
bench --site "$SITE_NAME" install-app hrms || echo "hrms already installed or failed; continuing."

# migrate & build
echo ">>> Migrating $SITE_NAME"
bench --site "$SITE_NAME" migrate || (echo "migrate failed; continuing."; true)

echo ">>> Building assets"
bench build || (echo "bench build failed; serving anyway."; true)

# serve
export FRAPPE_SITE="$SITE_NAME"
echo ">>> Starting gunicorn on 0.0.0.0:${PORT}"
exec "$GUNICORN" -b "0.0.0.0:${PORT}" -w 2 -k gevent --timeout 180 \
  --chdir "$BENCH/apps/frappe" frappe.app:application
