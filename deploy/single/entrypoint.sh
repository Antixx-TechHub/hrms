#!/usr/bin/env bash
set -euo pipefail

# -------- required env --------
: "${SITE_NAME:?SITE_NAME not set}"             # e.g. site1.local
: "${ADMIN_PASSWORD:?ADMIN_PASSWORD not set}"   # ERPNext admin password
: "${DB_HOST:?DB_HOST not set}"                 # if DB service is in same Railway project use: mariadb.railway.internal
: "${DB_PORT:?DB_PORT not set}"                 # usually 3306
: "${DB_ROOT_USER:?DB_ROOT_USER not set}"       # usually root
: "${DB_ROOT_PASSWORD:?DB_ROOT_PASSWORD not set}"
: "${DB_NAME:?DB_NAME not set}"                 # e.g. ATH_HRMS
: "${PORT:?PORT not set}"                       # provided by Railway

# Optional: skip ERPNext DB safety checks (collation/version guard)
SKIP_MARIADB_SAFEGUARDS="${SKIP_MARIADB_SAFEGUARDS:-0}"

BENCH="/home/frappe/frappe-bench"
SITES="$BENCH/sites"
APPS="$BENCH/apps"
SITE_PATH="$SITES/$SITE_NAME"
VENV="$BENCH/env"
PIP="$VENV/bin/pip"
GUNICORN="$VENV/bin/gunicorn"

cd "$BENCH"

# -------- make sure bench context exists --------
mkdir -p "$SITES"
[ -f ./apps.txt ] || : > ./apps.txt
[ -f "$SITES/apps.txt" ] || cp ./apps.txt "$SITES/apps.txt"
[ -f "$SITES/common_site_config.json" ] || echo '{}' > "$SITES/common_site_config.json"

# -------- start a local redis (no file perms / no config file) --------
# Frappe needs redis_cache to be reachable even if you use external Redis later.
if ! pgrep -x redis-server >/dev/null 2>&1; then
  redis-server --daemonize yes \
    --bind 127.0.0.1 --port 6379 \
    --save "" --appendonly no \
    --dir /home/frappe
fi

# Wire frappe to the local redis with proper URL schemes (avoid earlier errors)
cat > "$SITES/common_site_config.json" <<EOF
{
  "redis_cache":    "redis://127.0.0.1:6379/0",
  "redis_queue":    "redis://127.0.0.1:6379/1",
  "redis_socketio": "redis://127.0.0.1:6379/2"
}
EOF

# -------- fetch ERPNext + HRMS (idempotent) --------
[ -d "$APPS/erpnext" ] || git clone --depth 1 -b version-15 https://github.com/frappe/erpnext "$APPS/erpnext"
[ -d "$APPS/hrms"    ] || git clone --depth 1 -b version-15 https://github.com/frappe/hrms    "$APPS/hrms"

# Python deps for those apps (quietly; don't fail the container if a file is missing)
[ -f "$APPS/erpnext/requirements.txt" ] && "$PIP" install -q -r "$APPS/erpnext/requirements.txt" || true
[ -f "$APPS/hrms/requirements.txt"    ] && "$PIP" install -q -r "$APPS/hrms/requirements.txt"    || true

# -------- site init / migrate --------
init_or_migrate() {
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

    # Some MariaDB hosts enforce collations that Frappe warns about. Allow bypass if requested.
    if [ "${SKIP_MARIADB_SAFEGUARDS}" = "1" ]; then
      export DISABLE_MARIADB_SAFE_UPGRADE=1
    fi

    # Try to create the site; if it fails (e.g., DB already exists or collation guard), continue.
    if ! bench "${NEW_SITE_ARGS[@]}"; then
      echo "new-site failed; continuing (DB may already exist or server settings differ)."
    fi

    # Try installing HRMS (ignore if it’s already there)
    bench --site "$SITE_NAME" install-app hrms || true
  else
    echo ">>> Site exists. Running migrate + build."
    if ! bench --site "$SITE_NAME" migrate; then
      echo ">>> migrate failed; check DB credentials/privileges and connectivity."
    fi
  fi

  # Always try to build assets (needs yarn which we installed in the image)
  bench build || true
}

init_or_migrate

# -------- serve HTTP --------
export FRAPPE_SITE="$SITE_NAME"
exec "$GUNICORN" \
  -b 0.0.0.0:"$PORT" -w 2 -k gevent --timeout 120 \
  --chdir "$BENCH/apps/frappe" \
  frappe.app:application
