#!/bin/bash
set -euo pipefail

# ---- Railway endpoints (public TCP) ----
DB_HOST="trolley.proxy.rlwy.net"
DB_PORT="51999"
DB_NAME="railway"
DB_USER="railway"
DB_PASS="hfxKFQNoMagViYHTotVOpsbiQ4Rzg_l-"

REDIS_HOST="nozomi.proxy.rlwy.net"
REDIS_PORT="46645"
REDIS_USER="default"
REDIS_PASS="TUwUwNxPhXtoaysMLvnyssapQWtRbGpz"

SITE="hrms.localhost"
ADMIN_PASSWORD="admin"

cd /home/frappe/frappe-bench

# Force external Redis + DB before any start
REDIS_URI="redis://${REDIS_USER}:${REDIS_PASS}@${REDIS_HOST}:${REDIS_PORT}"
bench set-redis-cache-host    "${REDIS_URI}" || true
bench set-redis-queue-host    "${REDIS_URI}" || true
bench set-redis-socketio-host "${REDIS_URI}" || true
sed -i '/^[[:space:]]*redis[[:space:]]*:/d' Procfile || true
sed -i '/^[[:space:]]*watch[[:space:]]*:/d' Procfile || true

bench set-config -g db_host "${DB_HOST}"
bench set-config -g db_port "${DB_PORT}"

wait_tcp() { timeout 20 bash -c "</dev/tcp/$1/$2" >/dev/null 2>&1; }
echo "Waiting for MariaDB ${DB_HOST}:${DB_PORT} ..."
until wait_tcp "${DB_HOST}" "${DB_PORT}"; do sleep 2; done
echo "Waiting for Redis ${REDIS_HOST}:${REDIS_PORT} ..."
until wait_tcp "${REDIS_HOST}" "${REDIS_PORT}"; do sleep 2; done

# Create site if missing (use DB user, not root)
if ! bench --site "${SITE}" version >/dev/null 2>&1; then
  echo "Creating site ${SITE}"
  bench new-site "${SITE}" \
    --force \
    --admin-password "${ADMIN_PASSWORD}" \
    --db-name "${DB_NAME}" \
    --db-host "${DB_HOST}" \
    --db-port "${DB_PORT}" \
    --db-username "${DB_USER}" \
    --db-password "${DB_PASS}" \
    --no-mariadb-socket

  bench --site "${SITE}" install-app erpnext
  bench --site "${SITE}" install-app hrms
  bench --site "${SITE}" set-config developer_mode 1
  bench --site "${SITE}" enable-scheduler
  bench --site "${SITE}" clear-cache
fi

bench use "${SITE}"

# Start nginx on $PORT, then bench (web:8000, socketio:9000)
echo "Starting nginx on port ${PORT:-8080}..."
# nginx runs as root; elevate briefly then drop back is fine
sudo -n true 2>/dev/null || true
/usr/sbin/nginx -g "daemon on;"

echo "Starting bench..."
exec bench start --no-dev
