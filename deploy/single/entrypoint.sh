#!/usr/bin/env bash
set -euo pipefail

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

# minimal bench context
mkdir -p "$SITES"
[ -f ./apps.txt ] || : > ./apps.txt
[ -f "$SITES/apps.txt" ] || cp ./apps.txt "$SITES/apps.txt"
[ -f "$SITES/common_site_config.json" ] || echo '{}' > "$SITES/common_site_config.json"

# local redis (no root paths)
mkdir -p /home/frappe/redis
if ! pgrep -x redis-server >/dev/null 2>&1; then
  redis-server --daemonize yes --bind 127.0.0.1 --port 6379 \
    --save "" --appendonly no --dir /home/frappe/redis \
    --pidfile /home/frappe/redis/redis.pid
fi

# wire frappe -> local redis (proper URL scheme)
cat > "$SITES/common_site_config.json" <<EOF
{
  "redis_cache":   "redis://127.0.0.1:6379/0",
  "redis_queue":   "redis://127.0.0.1:6379/1",
  "redis_socketio":"redis://127.0.0.1:6379/2"
}
EOF

# get apps
[ -d "$APPS/erpnext" ] || git clone --depth 1 -b version-15 https://github.com/frappe/erpnext "$APPS/erpnext"
[ -d "$APPS/hrms" ]    || git clone --depth 1 -b version-15 https://github.com/frappe/hrms    "$APPS/hrms"

# deps (also yarn for build)
apt-get update -y && apt-get install -y nodejs npm mariadb-client >/dev/null
npm install -g yarn >/dev/null || true
[ -f "$APPS/erpnext/requirements.txt" ] && "$PIP" install -q -r "$APPS/erpnext/requirements.txt" || true
[ -f "$APPS/hrms/requirements.txt" ]    && "$PIP" install -q -r "$APPS/hrms/requirements.txt"    || true

mysql() {
  command mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_ROOT_USER" "-p$DB_ROOT_PASSWORD" --protocol=TCP -N -e "$1"
}

# ---- MariaDB FIX & CLEAN ----
echo ">>> Ensuring MariaDB globals (charset/collation) and clean DB…"
mysql "SET GLOBAL character_set_server='utf8mb4';
       SET GLOBAL collation_server='utf8mb4_unicode_ci';" || true

# drop any broken attempt, then recreate empty DB
mysql "DROP DATABASE IF EXISTS \`$DB_NAME\`;"
mysql "DROP USER IF EXISTS '$DB_NAME'@'%';"
mysql "CREATE DATABASE \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"

# ---- Site init / migrate ----
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
fi

# build frontend assets (ignore non-fatal)
bench build || true

# serve
export FRAPPE_SITE="$SITE_NAME"
exec "$GUNICORN" -b 0.0.0.0:"$PORT" -w 2 -k gevent --timeout 120 \
  --chdir "$BENCH/apps/frappe" frappe.app:application
