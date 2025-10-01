#!/usr/bin/env bash
set -euo pipefail

# ── Required env (Railway → App) ────────────────────────────────────────────────
: "${SITE_NAME:?SITE_NAME not set}"
: "${PORT:?PORT not set}"

# DB (use Railway MariaDB vars mapped into app vars)
: "${DB_HOST:?DB_HOST not set}"
: "${DB_PORT:?DB_PORT not set}"
: "${DB_NAME:?DB_NAME not set}"           # should usually be ${MARIADB_DATABASE}
: "${DB_USER:?DB_USER not set}"           # map from ${MARIADB_USER}
: "${DB_PASSWORD:?DB_PASSWORD not set}"   # map from ${MARIADB_PASSWORD}

# Root (to let bench create/prepare the DB if needed)
: "${DB_ROOT_USER:?DB_ROOT_USER not set}"               # usually "root"
: "${DB_ROOT_PASSWORD:?DB_ROOT_PASSWORD not set}"       # ${MARIADB_ROOT_PASSWORD}

# Optional: provide Redis URLs if you have a Railway Redis service
REDIS_CACHE_URL="${REDIS_CACHE:-}"
REDIS_QUEUE_URL="${REDIS_QUEUE:-}"
REDIS_SOCKETIO_URL="${REDIS_SOCKETIO:-}"

# Optional: relax MariaDB checks on managed hosts (collation, row format, etc.)
export SKIP_MARIADB_SAFEGUARDS="${SKIP_MARIADB_SAFEGUARDS:-1}"

BENCH=/home/frappe/frappe-bench
SITES="$BENCH/sites"
SITE_PATH="$SITES/$SITE_NAME"
VENV="$BENCH/env"
GUNICORN="$VENV/bin/gunicorn"

cd "$BENCH"

# ── Ensure bench context exists ────────────────────────────────────────────────
mkdir -p "$SITES"
[ -f ./apps.txt ] || : > ./apps.txt
[ -f "$SITES/apps.txt" ] || cp ./apps.txt "$SITES/apps.txt"
[ -f "$SITES/common_site_config.json" ] || echo '{}' > "$SITES/common_site_config.json"

# Write/merge common_site_config with Redis (if provided)
if [ -n "$REDIS_CACHE_URL" ] || [ -n "$REDIS_QUEUE_URL" ] || [ -n "$REDIS_SOCKETIO_URL" ]; then
  cat > "$SITES/common_site_config.json" <<EOF
{
  $( [ -n "$REDIS_CACHE_URL" ] && echo "\"redis_cache\": \"${REDIS_CACHE_URL}\"," )
  $( [ -n "$REDIS_QUEUE_URL" ] && echo "\"redis_queue\": \"${REDIS_QUEUE_URL}\"," )
  $( [ -n "$REDIS_SOCKETIO_URL" ] && echo "\"redis_socketio\": \"${REDIS_SOCKETIO_URL}\"," )
  "rate_limit": {"window": 60, "limit": 1000}
}
EOF
fi

# ── Site init / migrate ────────────────────────────────────────────────────────
if [ ! -f "$SITE_PATH/site_config.json" ]; then
  echo ">>> Initializing site ${SITE_NAME} with DB ${DB_NAME}"
  set +e
  bench new-site "$SITE_NAME" \
    --db-name "$DB_NAME" \
    --db-host "$DB_HOST" --db-port "$DB_PORT" \
    --db-root-username "$DB_ROOT_USER" \
    --mariadb-root-password "$DB_ROOT_PASSWORD" \
    --no-mariadb-socket \
    --admin-password "${ADMIN_PASSWORD:-admin}" \
    --force
  newsite_rc=$?
  set -e
  if [ $newsite_rc -ne 0 ]; then
    echo "new-site returned $newsite_rc; continuing (DB may already exist or host enforces managed settings)"
    # Ensure site directory exists so we can patch config below
    mkdir -p "$SITE_PATH"
    [ -f "$SITE_PATH/site_config.json" ] || echo '{}' > "$SITE_PATH/site_config.json"
  fi

  # Force site to use Railway's managed DB user (not the auto-created user)
  # Frappe reads these from site_config.json
  python3 - <<PY
import json,sys
p="$SITE_PATH/site_config.json"
cfg=json.load(open(p))
cfg.update({
  "db_type":"mariadb",
  "db_host":"$DB_HOST",
  "db_port":"$DB_PORT",
  "db_name":"$DB_NAME",
  "db_user":"$DB_USER",
  "db_password":"$DB_PASSWORD"
})
open(p,"w").write(json.dumps(cfg, indent=2))
PY

  # Install apps (erpnext first, hrms next if present)
  set +e
  bench --site "$SITE_NAME" install-app erpnext
  bench --site "$SITE_NAME" install-app hrms
  set -e
else
  echo ">>> Site exists. Running migrate + build."
fi

# Try migrate & build (don’t hard-fail the container on build errors)
set +e
bench --site "$SITE_NAME" migrate
bench build
set -e

# ── Serve ─────────────────────────────────────────────────────────────────────
export FRAPPE_SITE="$SITE_NAME"
exec "$GUNICORN" \
  -b 0.0.0.0:"$PORT" -w 2 -k gevent --timeout 120 \
  --chdir "$BENCH/apps/frappe" \
  frappe.app:application
