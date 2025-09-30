#!/usr/bin/env bash
set -euo pipefail

# -------- required env --------
: "${SITE_NAME:?SITE_NAME not set}"             # e.g. site1.local
: "${ADMIN_PASSWORD:?ADMIN_PASSWORD not set}"   # ERPNext admin password
: "${DB_HOST:?DB_HOST not set}"                 # mariadb.railway.internal if same project
: "${DB_PORT:?DB_PORT not set}"                 # 3306
: "${DB_ROOT_USER:?DB_ROOT_USER not set}"       # root
: "${DB_ROOT_PASSWORD:?DB_ROOT_PASSWORD not set}"
: "${DB_NAME:?DB_NAME not set}"                 # e.g. ATH_HRMS
: "${PORT:?PORT not set}"

# Optional: bypass MariaDB safety checks (collation/version guard)
SKIP_MARIADB_SAFEGUARDS="${SKIP_MARIADB_SAFEGUARDS:-0}"

BENCH="/home/frappe/frappe-bench"
SITES="$BENCH/sites"
APPS="$BENCH/apps"
SITE_PATH="$SITES/$SITE_NAME"
VENV="$BENCH/env"
PIP="$VENV/bin/pip"
GUNICORN="$VENV/bin/gunicorn"

cd "$BENCH"

# -------- bench context --------
mkdir -p "$SITES"
[ -f ./apps.txt ] || : > ./apps.txt
[ -f "$SITES/common_site_config.json" ] || echo '{}' > "$SITES/common_site_config.json"

# -------- local redis (no config file) --------
if ! pgrep -x redis-server >/dev/null 2>&1; then
  redis-server --daemonize yes \
    --bind 127.0.0.1 --port 6379 \
    --save "" --appendonly no \
    --dir /home/frappe
fi

# proper redis URLs for frappe
cat > "$SITES/common_site_config.json" <<EOF
{
  "redis_cache":    "redis://127.0.0.1:6379/0",
  "redis_queue":    "redis://127.0.0.1:6379/1",
  "redis_socketio": "redis://127.0.0.1:6379/2"
}
EOF

# -------- fetch apps (idempotent) --------
[ -d "$APPS/erpnext" ] || git clone --depth 1 -b version-15 https://github.com/frappe/erpnext "$APPS/erpnext"
[ -d "$APPS/hrms"    ] || git clone --depth 1 -b version-15 https://github.com/frappe/hrms    "$APPS/hrms"

# ensure bench can see them (bench get-app would write these; we mirror it)
printf "frappe\nerpnext\nhrms\n" > ./apps.txt
cp ./apps.txt "$SITES/apps.txt"

# -------- python deps --------
[ -f "$APPS/erpnext/requirements.txt" ] && "$PIP" install -q -r "$APPS/erpnext/requirements.txt" || true
[ -f "$APPS/hrms/requirements.txt"    ] && "$PIP" install -q -r "$APPS/hrms/requirements.txt"    || true

# -------- site init / migrate --------
if [ ! -f "$SITE_PATH/site_config.json" ]; then
  echo ">>> Initializing site $SITE_NAME with DB $DB_NAME"

  NEW_SITE_ARGS=(
    "new-site" "$SITE_NAME"
    --db-name "$DB_NAME"
    --db-host "$DB_HOST" --db-port "$DB_PORT"
    --db-root-username "$DB_ROOT_USER"
    --mariadb-root-password "$DB_ROOT_PASSWORD"
    --no-mariadb-socket
    --admin-password "$ADMIN_PASSWORD"
    --install-app erpnext
    --force
  )

  if [ "${SKIP_MARIADB_SAFEGUARDS}" = "1" ]; then
    export DISABLE_MARIADB_SAFE_UPGRADE=1
  fi

  # Create site; if MariaDB guards complain, continue (DB may still be usable)
  if ! bench "${NEW_SITE_ARGS[@]}"; then
    echo "new-site failed; continuing (DB may already exist or server settings differ)."
  fi

  # Install HRMS if present
  if [ -d "$APPS/hrms" ]; then
    bench --site "$SITE_NAME" install-app hrms || true
  fi
else
  echo ">>> Site exists. Running migrate."
  bench --site "$SITE_NAME" migrate || echo ">>> migrate failed; check DB connectivity/privs."
fi

# -------- frontend deps then build --------
# Bench sometimes assumes deps already present; install them explicitly.
if command -v yarn >/dev/null 2>&1; then
  (
    cd "$APPS/frappe"
    yarn install --network-timeout 600000 || yarn install
  ) || true
fi

bench build || true

# -------- serve HTTP --------
export FRAPPE_SITE="$SITE_NAME"
exec "$GUNICORN" \
  -b 0.0.0.0:"$PORT" -w 2 -k gevent --timeout 120 \
  --chdir "$APPS/frappe" \
  frappe.app:application
